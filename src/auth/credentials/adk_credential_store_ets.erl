%% @doc Owner-private ETS credential store.
%%
%% The ETS table identifier is held by this gen_server and the table is
%% private, so raw credentials cannot be read by other processes. Public
%% operations always require the original principal and provider scope.
-module(adk_credential_store_ets).

-behaviour(gen_server).
-behaviour(adk_credential_store).

-export([start_link/0, start_link/1, child_spec/1, put/4, fetch/4, delete/4,
         compare_and_swap/6]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {table :: ets:tid(),
                max_entries :: pos_integer(),
                max_credential_bytes :: pos_integer()}).

-define(DEFAULT_MAX_ENTRIES, 4096).
-define(MAX_ENTRIES_CEILING, 1048576).
-define(DEFAULT_MAX_CREDENTIAL_BYTES, 1048576).
-define(MAX_CREDENTIAL_BYTES_CEILING, 8388608).
-define(MAX_ID_BYTES, 4096).
-define(MAX_OPTIONS_BYTES, 65536).
-define(CALL_TIMEOUT_MS, 15000).
-define(REF_GENERATION_ATTEMPTS, 8).

-type server() :: gen_server:server_ref().

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    case valid_start_options(Opts) of
        true ->
            case maps:get(name, Opts, ?MODULE) of
                undefined -> gen_server:start_link(?MODULE, Opts, []);
                Name -> gen_server:start_link({local, Name}, ?MODULE,
                                              Opts, [])
            end;
        false ->
            {error, invalid_credential_store_options}
    end;
start_link(_Opts) ->
    {error, invalid_credential_store_options}.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec put(server(), adk_credential_store:principal(),
          adk_credential_store:provider_id(),
          adk_credential_store:credential()) ->
    {ok, adk_credential_store:credential_ref()} |
    {error, adk_credential_store:error_reason()}.
put(Server, Principal, Provider, Credential) ->
    case valid_input(Principal, Provider, Credential,
                     ?MAX_CREDENTIAL_BYTES_CEILING) of
        ok -> safe_call(Server, {put, Principal, Provider, Credential});
        {error, _} = Error -> Error
    end.

-spec fetch(server(), adk_credential_store:principal(),
            adk_credential_store:provider_id(),
            adk_credential_store:credential_ref()) ->
    {ok, adk_credential_store:credential()} |
    {error, adk_credential_store:error_reason()}.
fetch(Server, Principal, Provider, Ref) ->
    case valid_scope_ref(Principal, Provider, Ref) of
        ok -> safe_call(Server, {fetch, Principal, Provider, Ref});
        {error, _} = Error -> Error
    end.

-spec delete(server(), adk_credential_store:principal(),
             adk_credential_store:provider_id(),
             adk_credential_store:credential_ref()) ->
    ok | {error, adk_credential_store:error_reason()}.
delete(Server, Principal, Provider, Ref) ->
    case valid_scope_ref(Principal, Provider, Ref) of
        ok -> safe_call(Server, {delete, Principal, Provider, Ref});
        {error, _} = Error -> Error
    end.

%% @doc Atomically replace a credential while keeping the same opaque
%% reference. The gen_server owns the private ETS table, so the comparison and
%% replacement are serialized with fetch/delete/put operations.
-spec compare_and_swap(server(), adk_credential_store:principal(),
                       adk_credential_store:provider_id(),
                       adk_credential_store:credential_ref(),
                       adk_credential_store:credential(),
                       adk_credential_store:credential()) ->
    ok | {error, adk_credential_store:error_reason()}.
compare_and_swap(Server, Principal, Provider, Ref, Expected, Replacement) ->
    case {valid_scope_ref(Principal, Provider, Ref),
          valid_input(Principal, Provider, Expected,
                      ?MAX_CREDENTIAL_BYTES_CEILING),
          valid_input(Principal, Provider, Replacement,
                      ?MAX_CREDENTIAL_BYTES_CEILING),
          bounded_term({Expected, Replacement},
                       ?MAX_CREDENTIAL_BYTES_CEILING)} of
        {ok, ok, ok, true} ->
            safe_call(Server,
                      {compare_and_swap, Principal, Provider, Ref,
                       Expected, Replacement});
        {{error, invalid_scope}, _, _, _} -> {error, invalid_scope};
        {_, {error, invalid_scope}, _, _} -> {error, invalid_scope};
        {_, _, {error, invalid_scope}, _} -> {error, invalid_scope};
        _ -> {error, invalid_credential}
    end.

init(Opts) ->
    MaxEntries = maps:get(max_entries, Opts, ?DEFAULT_MAX_ENTRIES),
    MaxCredentialBytes = maps:get(max_credential_bytes, Opts,
                                  ?DEFAULT_MAX_CREDENTIAL_BYTES),
    case validate_options(MaxEntries, MaxCredentialBytes) of
        ok ->
            Table = ets:new(?MODULE, [set, private,
                                      {read_concurrency, true},
                                      {write_concurrency, true}]),
            {ok, #state{table = Table,
                        max_entries = MaxEntries,
                        max_credential_bytes = MaxCredentialBytes}};
        error ->
            {stop, invalid_credential_store_options}
    end.

handle_call({put, Principal, Provider, Credential}, _From,
            State = #state{table = Table, max_entries = MaxEntries,
                           max_credential_bytes = MaxCredentialBytes}) ->
    case valid_input(Principal, Provider, Credential,
                     MaxCredentialBytes) of
        ok ->
            case ets:info(Table, size) < MaxEntries of
                true ->
                    Reply = insert_with_fresh_ref(
                              Table, Principal, Provider, Credential,
                              ?REF_GENERATION_ATTEMPTS),
                    {reply, Reply, State};
                false ->
                    {reply, {error, capacity_reached}, State}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({fetch, Principal, Provider, Ref}, _From,
            State = #state{table = Table}) ->
    Reply = case ets:lookup(Table, Ref) of
        [{Ref, Principal, Provider, Credential}] -> {ok, Credential};
        _ -> {error, not_found}
    end,
    {reply, Reply, State};
handle_call({delete, Principal, Provider, Ref}, _From,
            State = #state{table = Table}) ->
    Reply = case ets:lookup(Table, Ref) of
        [{Ref, Principal, Provider, _Credential}] ->
            true = ets:delete(Table, Ref),
            ok;
        _ ->
            {error, not_found}
    end,
    {reply, Reply, State};
handle_call({compare_and_swap, Principal, Provider, Ref,
             Expected, Replacement}, _From,
            State = #state{table = Table}) ->
    Reply = compare_and_swap_credential(
              Table, Principal, Provider, Ref, Expected, Replacement,
              State#state.max_credential_bytes),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unavailable}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Keep raw credentials out of sys status and abnormal-termination reports.
format_status(Status) ->
    maps:map(
      fun(state, State = #state{}) ->
              #{storage => private,
                entries => table_size(State#state.table),
                max_entries => State#state.max_entries,
                max_credential_bytes => State#state.max_credential_bytes};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

compare_and_swap_credential(Table, Principal, Provider, Ref,
                            Expected, Replacement, MaxCredentialBytes) ->
    case {valid_input(Principal, Provider, Expected, MaxCredentialBytes),
          valid_input(Principal, Provider, Replacement,
                      MaxCredentialBytes)} of
        {ok, ok} ->
            case ets:lookup(Table, Ref) of
                [{Ref, Principal, Provider, Expected}] ->
                    true = ets:insert(
                             Table,
                             {Ref, Principal, Provider, Replacement}),
                    ok;
                [{Ref, Principal, Provider, _Current}] ->
                    {error, conflict};
                _ ->
                    {error, not_found}
            end;
        {{error, invalid_scope}, _} -> {error, invalid_scope};
        {_, {error, invalid_scope}} -> {error, invalid_scope};
        _ -> {error, invalid_credential}
    end.

valid_input(Principal, Provider, Credential, MaxCredentialBytes)
  when is_map(Credential) ->
    case valid_identity(Principal) andalso valid_identity(Provider) andalso
         bounded_term(Credential, MaxCredentialBytes) of
        true -> ok;
        false ->
            case valid_identity(Principal) andalso valid_identity(Provider) of
                true -> {error, invalid_credential};
                false -> {error, invalid_scope}
            end
    end;
valid_input(_Principal, _Provider, _Credential, _MaxCredentialBytes) ->
    {error, invalid_credential}.

valid_identity(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< ?MAX_ID_BYTES;
valid_identity(Value) when is_atom(Value) -> Value =/= undefined;
valid_identity(_) -> false.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.

valid_scope_ref(Principal, Provider, Ref) ->
    case valid_identity(Principal) andalso valid_identity(Provider) of
        false -> {error, invalid_scope};
        true ->
            case adk_credential_store:is_ref(Ref) of
                true -> ok;
                false -> {error, not_found}
            end
    end.

valid_start_options(Opts) ->
    Allowed = [name, id, max_entries, max_credential_bytes],
    bounded_term(Opts, ?MAX_OPTIONS_BYTES) andalso
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Opts)) andalso
    validate_options(maps:get(max_entries, Opts, ?DEFAULT_MAX_ENTRIES),
                     maps:get(max_credential_bytes, Opts,
                              ?DEFAULT_MAX_CREDENTIAL_BYTES)) =:= ok andalso
    case maps:get(name, Opts, ?MODULE) of
        undefined -> true;
        Name when is_atom(Name) -> Name =/= undefined;
        _ -> false
    end.

validate_options(MaxEntries, MaxCredentialBytes)
  when is_integer(MaxEntries), MaxEntries > 0,
       MaxEntries =< ?MAX_ENTRIES_CEILING,
       is_integer(MaxCredentialBytes), MaxCredentialBytes > 0,
       MaxCredentialBytes =< ?MAX_CREDENTIAL_BYTES_CEILING -> ok;
validate_options(_MaxEntries, _MaxCredentialBytes) ->
    error.

insert_with_fresh_ref(_Table, _Principal, _Provider, _Credential, 0) ->
    {error, unavailable};
insert_with_fresh_ref(Table, Principal, Provider, Credential, Attempts) ->
    Ref = adk_credential_store:new_ref(),
    case ets:insert_new(Table, {Ref, Principal, Provider, Credential}) of
        true -> {ok, Ref};
        false -> insert_with_fresh_ref(
                   Table, Principal, Provider, Credential, Attempts - 1)
    end.

safe_call(Server, Request) when is_pid(Server); is_atom(Server) ->
    try gen_server:call(Server, Request, ?CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:_ -> {error, unavailable}
    end;
safe_call(_Server, _Request) ->
    {error, unavailable}.

table_size(Table) ->
    case ets:info(Table, size) of
        Size when is_integer(Size) -> Size;
        undefined -> 0
    end.
