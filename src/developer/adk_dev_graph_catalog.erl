%% @doc Bounded server-owned catalog of inspectable workflow graphs.
%%
%% Graphs can be published only through this local Erlang API.  The developer
%% HTTP boundary is read-only and receives an already-bound owner, so a bearer
%% cannot enumerate another owner by supplying an identifier in the URI.
-module(adk_dev_graph_catalog).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1, publish/4,
         get/3, list/3, remove/3, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_GRAPHS, 256).
-define(DEFAULT_MAX_GRAPH_BYTES, 1048576).
-define(DEFAULT_MAX_TOTAL_BYTES, 16777216).
-define(DEFAULT_LIST_LIMIT, 100).
-define(MAX_LIST_LIMIT, 1000).
-define(MAX_ID_BYTES, 256).
-define(CALL_TIMEOUT, 5000).

start_link() -> start_link(#{}).

start_link(Options) when is_map(Options) ->
    case maps:get(name, Options, ?MODULE) of
        undefined -> gen_server:start_link(?MODULE, Options, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Options, []);
        _ -> {error, invalid_graph_catalog_name}
    end;
start_link(_Options) -> {error, invalid_graph_catalog_options}.

child_spec(Options) ->
    #{id => maps:get(name, Options, ?MODULE),
      start => {?MODULE, start_link, [Options]}, restart => permanent,
      shutdown => 5000, type => worker, modules => [?MODULE]}.

%% Compiled is the opaque value returned by adk_workflow:compile/1.  Accepting
%% that value instead of arbitrary JSON keeps executable callbacks and raw
%% state out of the retained descriptor.
publish(Server, Owner, GraphId, Compiled) ->
    call(Server, {publish, Owner, GraphId, Compiled}).

get(Server, Owner, GraphId) -> call(Server, {get, Owner, GraphId}).
list(Server, Owner, Options) -> call(Server, {list, Owner, Options}).
remove(Server, Owner, GraphId) -> call(Server, {remove, Owner, GraphId}).
status(Server) -> call(Server, status).

init(Options) ->
    case normalize_options(Options) of
        {ok, Limits} ->
            {ok, #{limits => Limits, graphs => #{}, total_bytes => 0,
                   generation => 0}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({publish, Owner, GraphId, Compiled}, _From, State0) ->
    case prepare_graph(Owner, GraphId, Compiled,
                       maps:get(limits, State0)) of
        {ok, Key, Descriptor, Bytes, Fingerprint} ->
            Graphs0 = maps:get(graphs, State0),
            PreviousBytes = case maps:get(Key, Graphs0, undefined) of
                #{bytes := ExistingBytes} -> ExistingBytes;
                undefined -> 0
            end,
            Limits = maps:get(limits, State0),
            NewCount = case maps:is_key(Key, Graphs0) of
                true -> map_size(Graphs0);
                false -> map_size(Graphs0) + 1
            end,
            NewTotal = maps:get(total_bytes, State0) - PreviousBytes + Bytes,
            case NewCount =< maps:get(max_graphs, Limits) andalso
                 NewTotal =< maps:get(max_total_bytes, Limits) of
                true ->
                    Generation = maps:get(generation, State0) + 1,
                    Entry = #{id => GraphId, descriptor => Descriptor,
                              fingerprint => Fingerprint, bytes => Bytes,
                              generation => Generation,
                              updated_at => erlang:system_time(millisecond)},
                    State = State0#{graphs => Graphs0#{Key => Entry},
                                    total_bytes => NewTotal,
                                    generation => Generation},
                    {reply, {ok, public_entry(Entry)}, State};
                false ->
                    {reply, {error, graph_catalog_capacity_reached}, State0}
            end;
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({get, Owner, GraphId}, _From, State) ->
    Reply = case valid_owner(Owner) andalso valid_id(GraphId) of
        true ->
            case maps:find({owner_key(Owner), GraphId}, maps:get(graphs, State)) of
                {ok, Entry} -> {ok, public_entry(Entry)};
                error -> {error, not_found}
            end;
        false -> {error, invalid_graph_lookup}
    end,
    {reply, Reply, State};
handle_call({list, Owner, Options}, _From, State) ->
    {reply, list_graphs(Owner, Options, State), State};
handle_call({remove, Owner, GraphId}, _From, State0) ->
    case valid_owner(Owner) andalso valid_id(GraphId) of
        false -> {reply, {error, invalid_graph_lookup}, State0};
        true ->
            Key = {owner_key(Owner), GraphId},
            case maps:take(Key, maps:get(graphs, State0)) of
                {Entry, Graphs} ->
                    State = State0#{graphs => Graphs,
                                    total_bytes => maps:get(total_bytes, State0)
                                                   - maps:get(bytes, Entry),
                                    generation => maps:get(generation, State0) + 1},
                    {reply, ok, State};
                error -> {reply, {error, not_found}, State0}
            end
    end;
handle_call(status, _From, State) ->
    {reply, #{graph_count => map_size(maps:get(graphs, State)),
              total_bytes => maps:get(total_bytes, State),
              generation => maps:get(generation, State),
              limits => maps:get(limits, State)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_graph_catalog_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.
format_status(State) ->
    maps:with([total_bytes, generation, limits], State).

prepare_graph(Owner, GraphId, Compiled, Limits) ->
    case valid_owner(Owner) andalso valid_id(GraphId) of
        false -> {error, invalid_graph_publish};
        true ->
            case adk_graph_inspect:describe(Compiled) of
                {ok, Descriptor} ->
                    try jsx:encode(Descriptor) of
                        Encoded when byte_size(Encoded) =<
                                     map_get(max_graph_bytes, Limits) ->
                            Fingerprint = binary:encode_hex(
                                            crypto:hash(sha256, Encoded),
                                            lowercase),
                            {ok, {owner_key(Owner), GraphId}, Descriptor,
                             byte_size(Encoded), Fingerprint};
                        _ -> {error, graph_too_large}
                    catch
                        _:_ -> {error, invalid_graph_descriptor}
                    end;
                {error, _} -> {error, invalid_compiled_graph}
            end
    end.

list_graphs(Owner, Options, State) when is_map(Options) ->
    Limit = maps:get(limit, Options, ?DEFAULT_LIST_LIMIT),
    After = maps:get('after', Options, <<>>),
    case valid_owner(Owner) andalso is_integer(Limit) andalso Limit > 0
         andalso Limit =< ?MAX_LIST_LIMIT andalso
         (After =:= <<>> orelse valid_id(After)) of
        false -> {error, invalid_graph_list_options};
        true ->
            OwnerKey = owner_key(Owner),
            Entries0 = [{Id, Entry} || {{SeenOwner, Id}, Entry} <-
                                          maps:to_list(maps:get(graphs, State)),
                                      SeenOwner =:= OwnerKey, Id > After],
            Entries = lists:keysort(1, Entries0),
            {Page, More} = take_page(Entries, Limit),
            Next = case {More, Page} of
                {true, _} -> element(1, lists:last(Page));
                _ -> null
            end,
            {ok, #{<<"graphs">> => [public_summary(E) || {_Id, E} <- Page],
                   <<"next_cursor">> => Next,
                   <<"truncated">> => More}}
    end;
list_graphs(_Owner, _Options, _State) ->
    {error, invalid_graph_list_options}.

take_page(Items, Limit) ->
    case length(Items) > Limit of
        true -> {lists:sublist(Items, Limit), true};
        false -> {Items, false}
    end.

public_entry(Entry) ->
    (public_summary(Entry))#{<<"graph">> => maps:get(descriptor, Entry)}.

public_summary(Entry) ->
    #{<<"id">> => maps:get(id, Entry),
      <<"fingerprint">> => maps:get(fingerprint, Entry),
      <<"generation">> => maps:get(generation, Entry),
      <<"updated_at">> => maps:get(updated_at, Entry),
      <<"encoded_bytes">> => maps:get(bytes, Entry)}.

normalize_options(Options) ->
    Limits = #{max_graphs => maps:get(max_graphs, Options,
                                      ?DEFAULT_MAX_GRAPHS),
               max_graph_bytes => maps:get(max_graph_bytes, Options,
                                            ?DEFAULT_MAX_GRAPH_BYTES),
               max_total_bytes => maps:get(max_total_bytes, Options,
                                            ?DEFAULT_MAX_TOTAL_BYTES)},
    case lists:all(fun positive_integer/1, maps:values(Limits)) andalso
         maps:get(max_graph_bytes, Limits) =< maps:get(max_total_bytes, Limits) of
        true -> {ok, Limits};
        false -> {error, invalid_graph_catalog_options}
    end.

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

valid_owner(Value) when is_binary(Value), byte_size(Value) > 0,
                             byte_size(Value) =< ?MAX_ID_BYTES -> valid_utf8(Value);
valid_owner(_) -> false.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< ?MAX_ID_BYTES -> valid_utf8(Value);
valid_id(_) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end.

owner_key(Owner) -> crypto:hash(sha256, Owner).

call(Server, Request) ->
    try gen_server:call(Server, Request, ?CALL_TIMEOUT) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, graph_catalog_timeout};
        exit:_ -> {error, graph_catalog_unavailable}
    end.
