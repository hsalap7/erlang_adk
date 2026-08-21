%% @doc Bounded, opt-in retention for redacted local model payloads.
%%
%% The store accepts only already-normalized JSON documents from the
%% developer payload plugin.  It is never started unless the operator enables
%% the local developer inspection feature, and the HTTP route remains behind
%% the existing loopback-only developer bearer boundary.
-module(adk_dev_payload_store).
-behaviour(gen_server).

-export([start_link/1, child_spec/1, validate_options/1, append_json/4,
         query/2, clear/1, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_EVENTS, 128).
-define(DEFAULT_MAX_EVENT_BYTES, 65536).
-define(DEFAULT_MAX_TOTAL_BYTES, 1048576).
-define(DEFAULT_RETENTION_MS, 300000).
-define(DEFAULT_QUERY_LIMIT, 50).
-define(MAX_EVENTS, 10000).
-define(MAX_EVENT_BYTES, 1048576).
-define(MAX_TOTAL_BYTES, 16777216).
-define(MAX_RETENTION_MS, 3600000).
-define(MAX_QUERY_LIMIT, 1000).
-define(DEFAULT_CALL_TIMEOUT, 500).

-record(state, {
    events = queue:new() :: queue:queue(),
    event_count = 0 :: non_neg_integer(),
    total_bytes = 0 :: non_neg_integer(),
    next_cursor = 1 :: pos_integer(),
    dropped = 0 :: non_neg_integer(),
    max_events :: pos_integer(),
    max_event_bytes :: pos_integer(),
    max_total_bytes :: pos_integer(),
    retention_ms :: pos_integer()
}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    case maps:get(name, Options, ?MODULE) of
        undefined -> gen_server:start_link(?MODULE, Options, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Options, []);
        _ -> {error, invalid_dev_payload_store_name}
    end;
start_link(_Options) ->
    {error, invalid_dev_payload_store_options}.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) when is_map(Options) ->
    #{id => maps:get(name, Options, ?MODULE),
      start => {?MODULE, start_link, [Options]},
      restart => permanent, shutdown => 5000, type => worker,
      modules => [?MODULE]}.

-spec validate_options(map()) -> {ok, map()} | {error, term()}.
validate_options(Options) when is_map(Options) ->
    normalize_options(Options);
validate_options(_Options) ->
    {error, invalid_dev_payload_store_options}.

%% @doc Append a JSON object prepared by adk_dev_payload_plugin.
-spec append_json(gen_server:server_ref(), binary(), binary(), timeout()) ->
    {ok, non_neg_integer()} | {error, term()}.
append_json(Server, Phase, Json, Timeout)
  when is_binary(Phase), is_binary(Json),
       ((is_integer(Timeout) andalso Timeout > 0) orelse Timeout =:= infinity) ->
    try gen_server:call(Server, {append_json, Phase, Json}, Timeout) of
        Reply -> Reply
    catch
        exit:_ -> {error, payload_store_unavailable}
    end;
append_json(_Server, _Phase, _Json, _Timeout) ->
    {error, invalid_payload_event}.

-spec query(gen_server:server_ref(), map()) ->
    {ok, map()} | {error, term()}.
query(Server, Options) when is_map(Options) ->
    call(Server, {query, Options});
query(_Server, _Options) ->
    {error, invalid_payload_query}.

-spec clear(gen_server:server_ref()) -> ok | {error, term()}.
clear(Server) -> call(Server, clear).

-spec status(gen_server:server_ref()) -> {ok, map()} | {error, term()}.
status(Server) -> call(Server, status).

init(Options) ->
    case normalize_options(Options) of
        {ok, Limits} ->
            {ok, #state{max_events = maps:get(max_events, Limits),
                        max_event_bytes = maps:get(max_event_bytes, Limits),
                        max_total_bytes = maps:get(max_total_bytes, Limits),
                        retention_ms = maps:get(retention_ms, Limits)}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({append_json, Phase, Json}, _From, State0) ->
    NowMono = erlang:monotonic_time(millisecond),
    State1 = prune_expired(NowMono, State0),
    case prepare_event(Phase, Json, State1#state.max_event_bytes) of
        {ok, Payload} ->
            Cursor = State1#state.next_cursor,
            ReceivedAt = erlang:system_time(millisecond),
            Public = #{<<"cursor">> => Cursor,
                       <<"received_at">> => ReceivedAt,
                       <<"phase">> => Phase,
                       <<"context">> => maps:get(<<"context">>, Payload),
                       <<"payload">> => maps:get(<<"payload">>, Payload)},
            Encoded = jsx:encode(Public),
            Charge = byte_size(Encoded),
            case Charge =< State1#state.max_event_bytes of
                true ->
                    Item = {Cursor, NowMono, Charge, Public},
                    State2 = State1#state{
                               events = queue:in(Item, State1#state.events),
                               event_count = State1#state.event_count + 1,
                               total_bytes = State1#state.total_bytes + Charge,
                               next_cursor = Cursor + 1},
                    State3 = enforce_capacity(State2),
                    {reply, {ok, Cursor}, State3};
                false ->
                    {reply, {error, payload_event_too_large}, State1}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State1}
    end;
handle_call({query, Options}, _From, State0) ->
    State = prune_expired(erlang:monotonic_time(millisecond), State0),
    {reply, query_events(Options, State), State};
handle_call(clear, _From, State0) ->
    Removed = State0#state.event_count,
    State = State0#state{events = queue:new(), event_count = 0,
                         total_bytes = 0,
                         dropped = State0#state.dropped + Removed},
    {reply, ok, State};
handle_call(status, _From, State0) ->
    State = prune_expired(erlang:monotonic_time(millisecond), State0),
    {reply, {ok, public_status(State)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_payload_store_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% Retained payloads and in-flight calls never enter supervisor status or
%% crash-report formatting.
format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, State) when is_record(State, state) -> public_status(State);
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> Value
      end, Status);
format_status(Status) -> Status.

prepare_event(Phase, Json, MaxBytes) ->
    case valid_phase(Phase) andalso byte_size(Json) =< MaxBytes of
        false -> {error, invalid_payload_event};
        true ->
            try jsx:decode(Json, [return_maps]) of
                #{<<"schema_version">> := 1,
                  <<"context">> := Context,
                  <<"payload">> := Payload} = Event
                  when is_map(Context), map_size(Event) =:= 3 ->
                    %% Re-encode to prove the accepted value is JSON and to
                    %% enforce the bound on its canonical retained shape.
                    case byte_size(jsx:encode(
                                     #{<<"context">> => Context,
                                       <<"payload">> => Payload})) =< MaxBytes of
                        true -> {ok, Event};
                        false -> {error, payload_event_too_large}
                    end;
                _ -> {error, invalid_payload_event}
            catch
                _:_ -> {error, invalid_payload_event}
            end
    end.

valid_phase(<<"request">>) -> true;
valid_phase(<<"response">>) -> true;
valid_phase(<<"error">>) -> true;
valid_phase(_) -> false.

query_events(Options, State) ->
    After = maps:get(after_cursor, Options, oldest_cursor(State) - 1),
    Limit = maps:get(limit, Options, ?DEFAULT_QUERY_LIMIT),
    case map_size(maps:without([after_cursor, limit], Options)) =:= 0
         andalso is_integer(After) andalso After >= 0
         andalso is_integer(Limit) andalso Limit > 0
         andalso Limit =< ?MAX_QUERY_LIMIT of
        false -> {error, invalid_payload_query};
        true -> page_events(After, Limit, State)
    end.

page_events(After, Limit, State) ->
    Current = State#state.next_cursor - 1,
    Oldest = oldest_cursor(State),
    case After > Current of
        true ->
            {error, {cursor_ahead,
                     #{<<"requested_cursor">> => After,
                       <<"current_cursor">> => Current}}};
        false when After + 1 < Oldest ->
            {error, {replay_gap,
                     #{<<"requested_cursor">> => After,
                       <<"oldest_cursor">> => Oldest,
                       <<"current_cursor">> => Current}}};
        false ->
            Items0 = [Public || {Cursor, _Mono, _Bytes, Public} <-
                                  queue:to_list(State#state.events),
                                Cursor > After],
            {Items, HasMore} = take_page(Items0, Limit),
            Next = case Items of
                [] -> After;
                _ -> maps:get(<<"cursor">>, lists:last(Items))
            end,
            {ok, #{<<"schema_version">> => 1,
                   <<"items">> => Items,
                   <<"next_cursor">> => Next,
                   <<"has_more">> => HasMore,
                   <<"retention">> => public_status(State)}}
    end.

take_page(Items, Limit) ->
    case length(Items) > Limit of
        true -> {lists:sublist(Items, Limit), true};
        false -> {Items, false}
    end.

oldest_cursor(#state{event_count = 0, next_cursor = Next}) -> Next;
oldest_cursor(#state{events = Events}) ->
    {{value, {Cursor, _Mono, _Bytes, _Public}}, _} = queue:out(Events),
    Cursor.

prune_expired(_Now, State = #state{event_count = 0}) -> State;
prune_expired(Now, State = #state{events = Events,
                                  retention_ms = Retention}) ->
    case queue:peek(Events) of
        {value, {_Cursor, Inserted, _Bytes, _Public}}
          when Now - Inserted >= Retention ->
            prune_expired(Now, drop_oldest(State));
        _ -> State
    end.

enforce_capacity(State = #state{event_count = Count,
                                total_bytes = Bytes,
                                max_events = MaxEvents,
                                max_total_bytes = MaxBytes})
  when Count > MaxEvents; Bytes > MaxBytes ->
    enforce_capacity(drop_oldest(State));
enforce_capacity(State) -> State.

drop_oldest(State = #state{events = Events, event_count = Count,
                           total_bytes = Total, dropped = Dropped}) ->
    case queue:out(Events) of
        {{value, {_Cursor, _Mono, Bytes, _Public}}, Rest} ->
            State#state{events = Rest, event_count = Count - 1,
                        total_bytes = Total - Bytes, dropped = Dropped + 1};
        {empty, _} -> State
    end.

public_status(State) ->
    #{<<"event_count">> => State#state.event_count,
      <<"total_bytes">> => State#state.total_bytes,
      <<"dropped_events">> => State#state.dropped,
      <<"current_cursor">> => State#state.next_cursor - 1,
      <<"oldest_cursor">> => oldest_cursor(State),
      <<"max_events">> => State#state.max_events,
      <<"max_event_bytes">> => State#state.max_event_bytes,
      <<"max_total_bytes">> => State#state.max_total_bytes,
      <<"retention_ms">> => State#state.retention_ms}.

normalize_options(Options) ->
    Allowed = [name, max_events, max_event_bytes, max_total_bytes,
               retention_ms, call_timeout_ms],
    MaxEvents = maps:get(max_events, Options, ?DEFAULT_MAX_EVENTS),
    MaxEventBytes = maps:get(max_event_bytes, Options,
                             ?DEFAULT_MAX_EVENT_BYTES),
    MaxTotalBytes = maps:get(max_total_bytes, Options,
                             ?DEFAULT_MAX_TOTAL_BYTES),
    Retention = maps:get(retention_ms, Options, ?DEFAULT_RETENTION_MS),
    Name = maps:get(name, Options, ?MODULE),
    CallTimeout = maps:get(call_timeout_ms, Options,
                           ?DEFAULT_CALL_TIMEOUT),
    case map_size(maps:without(Allowed, Options)) =:= 0
         andalso ((is_atom(Name) andalso Name =/= undefined)
                  orelse Name =:= undefined)
         andalso positive_bounded(MaxEvents, ?MAX_EVENTS)
         andalso positive_bounded(MaxEventBytes, ?MAX_EVENT_BYTES)
         andalso positive_bounded(MaxTotalBytes, ?MAX_TOTAL_BYTES)
         andalso MaxEventBytes =< MaxTotalBytes
         andalso positive_bounded(Retention, ?MAX_RETENTION_MS)
         andalso valid_call_timeout(CallTimeout) of
        true ->
            {ok, #{name => Name,
                   max_events => MaxEvents,
                   max_event_bytes => MaxEventBytes,
                   max_total_bytes => MaxTotalBytes,
                   retention_ms => Retention,
                   call_timeout_ms => CallTimeout}};
        false -> {error, invalid_dev_payload_store_options}
    end.

positive_bounded(Value, Maximum) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Maximum.

valid_call_timeout(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< 5000.

call(Server, Request) ->
    try gen_server:call(Server, Request, 5000) of
        Reply -> Reply
    catch
        exit:_ -> {error, payload_store_unavailable}
    end.
