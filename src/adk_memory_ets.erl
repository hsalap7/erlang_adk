%% @doc Volatile, deterministic lexical memory adapter.
%%
%% The table is private and owned by an OTP process.  All writes are validated
%% before they enter ETS, storage is quota bounded, and result construction is
%% bounded by both hit count and bytes.  This adapter is intended for tests and
%% local development; use `adk_memory_mnesia' when restart durability matters.
-module(adk_memory_ets).
-behaviour(gen_server).
-behaviour(adk_memory_service).

-export([start_link/1, init/1, stop/1, capabilities/1,
         add_entry/4, add_entry/5,
         add_events/5, add_events/6, add_session_to_memory/5,
         search/4, search/5,
         delete_entry/3, delete_entry/4,
         delete_session/3, delete_session/4,
         delete_user/2, delete_user/3,
         add/3, delete/2, add_session_to_memory/3]).
-export([handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {table, limits, entries = 0, bytes = 0}).

-define(LEGACY_SCOPE, {user, <<"legacy">>, <<"legacy">>}).
-define(DEFAULT_TIMEOUT, 5000).

start_link(Config) ->
    case adk_memory_contract:compile_config(Config) of
        {ok, Limits} ->
            gen_server:start_link(?MODULE, {server_limits, Limits}, []);
        {error, _} = Error -> Error
    end.

%% Compatibility constructor.  The tagged clause is the OTP callback.
init(Config) when is_map(Config) -> start_link(Config);
init({server_limits, Limits}) ->
    Table = ets:new(?MODULE, [set, private, {read_concurrency, true}]),
    {ok, #state{table = Table, limits = Limits}}.

stop(Pid) ->
    try gen_server:stop(Pid, normal, 5000) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:noproc -> ok
    end.

capabilities(Pid) -> call(Pid, capabilities).

add_entry(Pid, Scope, Input, Opts) ->
    add_entry(Pid, Scope, Input, Opts, #{}).
add_entry(Pid, Scope, Input, Opts, CallOptions) ->
    timed_call(Pid,
               fun(Deadline) ->
                   {add_entry, Scope, Input, Opts, Deadline}
               end, CallOptions).

add_events(Pid, Scope, SessionId, Events, Opts) ->
    add_events(Pid, Scope, SessionId, Events, Opts, #{}).
add_events(Pid, Scope, SessionId, Events, Opts, CallOptions) ->
    timed_call(Pid,
               fun(Deadline) ->
                   {add_events, Scope, SessionId, Events, Opts, Deadline}
               end, CallOptions).

add_session_to_memory(Pid, Scope, SessionId, Events, Opts) ->
    add_events(Pid, Scope, SessionId, Events, Opts).

search(Pid, {user, _, _} = Scope, Query, Opts) ->
    search(Pid, Scope, Query, Opts, #{});
search(Pid, Query, Filter, Limit) ->
    search(Pid, ?LEGACY_SCOPE, Query,
           #{filter => Filter, limit => Limit}, #{}).
search(Pid, Scope, Query, Opts, CallOptions) ->
    timed_call(Pid,
               fun(Deadline) -> {search, Scope, Query, Opts, Deadline} end,
               CallOptions).

delete_entry(Pid, Scope, Id) -> delete_entry(Pid, Scope, Id, #{}).
delete_entry(Pid, Scope, Id, CallOptions) ->
    timed_call(Pid,
               fun(Deadline) -> {delete_entry, Scope, Id, Deadline} end,
               CallOptions).
delete_session(Pid, Scope, SessionId) ->
    delete_session(Pid, Scope, SessionId, #{}).
delete_session(Pid, Scope, SessionId, CallOptions) ->
    timed_call(Pid,
               fun(Deadline) ->
                   {delete_session, Scope, SessionId, Deadline}
               end, CallOptions).
delete_user(Pid, Scope) -> delete_user(Pid, Scope, #{}).
delete_user(Pid, Scope, CallOptions) ->
    timed_call(Pid,
               fun(Deadline) -> {delete_user, Scope, Deadline} end,
               CallOptions).

%% Version-1 wrappers use one reserved scope.  They remain intentionally
%% idempotent on delete to preserve the old API.
add(Pid, Content, Metadata) ->
    case add_entry(Pid, ?LEGACY_SCOPE,
                   #{content => Content, metadata => Metadata}, #{}) of
        {ok, Entry} -> {ok, maps:get(id, Entry)};
        {error, _} = Error -> Error
    end.

delete(Pid, Id) ->
    case delete_entry(Pid, ?LEGACY_SCOPE, Id) of
        {error, not_found} -> ok;
        Reply -> Reply
    end.

add_session_to_memory(Pid, SessionId, Events) ->
    call(Pid, {legacy_session, SessionId, Events}).

call(Pid, Request) when is_pid(Pid) ->
    case process_info(Pid, message_queue_len) of
        undefined -> {error, memory_service_unavailable};
        {message_queue_len, Length} when Length >= 1000 ->
            {error, memory_service_overloaded};
        _ ->
            try gen_server:call(Pid, Request, 5000) of
                Reply -> Reply
            catch
                exit:{timeout, _} -> {error, timeout};
                exit:{noproc, _} -> {error, memory_service_unavailable};
                exit:{normal, _} -> {error, memory_service_unavailable}
            end
    end;
call(_, _) -> {error, invalid_memory_handle}.

timed_call(Pid, RequestFun, CallOptions) when is_map(CallOptions) ->
    case maps:keys(maps:without([timeout_ms], CallOptions)) of
        [] ->
            Timeout = maps:get(timeout_ms, CallOptions, ?DEFAULT_TIMEOUT),
            case is_integer(Timeout) andalso Timeout > 0 of
                true ->
                    Deadline = erlang:monotonic_time(millisecond) + Timeout,
                    call(Pid, RequestFun(Deadline), Timeout + 100);
                false -> {error, invalid_memory_call_timeout}
            end;
        Unknown -> {error, {invalid_memory_call_options,
                            {unknown_keys, lists:sort(Unknown)}}}
    end;
timed_call(_Pid, _RequestFun, _CallOptions) ->
    {error, invalid_memory_call_options}.

call(Pid, Request, Timeout) when is_pid(Pid), is_integer(Timeout), Timeout > 0 ->
    case process_info(Pid, message_queue_len) of
        undefined -> {error, memory_service_unavailable};
        {message_queue_len, Length} when Length >= 1000 ->
            {error, memory_service_overloaded};
        _ ->
            try gen_server:call(Pid, Request, Timeout) of
                Reply -> Reply
            catch
                exit:{timeout, _} -> {error, timeout};
                exit:{noproc, _} -> {error, memory_service_unavailable};
                exit:{normal, _} -> {error, memory_service_unavailable}
            end
    end;
call(_, _, _) -> {error, invalid_memory_handle}.

handle_call(capabilities, _From, State) ->
    {reply, adk_memory_contract:capabilities(ets, State#state.limits), State};
handle_call({add_entry, Scope, Input, Opts, Deadline}, _From, State) ->
    case request_expired(Deadline) of
        true -> {reply, {error, timeout}, State};
        false ->
            case adk_memory_contract:prepare_entry(
                   Scope, Input, Opts, State#state.limits) of
                {ok, Entry} ->
                    case request_expired(Deadline) of
                        true -> {reply, {error, timeout}, State};
                        false ->
                            case store_entries([Entry], State) of
                                {ok, _Added, _Duplicates, NewState} ->
                                    {reply,
                                     {ok, public_entry(
                                            lookup_entry(Entry, NewState))},
                                     NewState};
                                {error, _} = Error -> {reply, Error, State}
                            end
                    end;
                {error, _} = Error -> {reply, Error, State}
            end
    end;
handle_call({add_events, Scope, SessionId, Events, Opts, Deadline},
            _From, State) ->
    case request_expired(Deadline) of
        true -> {reply, {error, timeout}, State};
        false ->
            case adk_memory_contract:prepare_events(
                   Scope, SessionId, Events, Opts, State#state.limits) of
                {ok, Entries, Skipped} ->
                    case request_expired(Deadline) of
                        true -> {reply, {error, timeout}, State};
                        false ->
                            case store_entries(Entries, State) of
                                {ok, Added, Duplicates, NewState} ->
                                    {reply,
                                     {ok, #{added => Added,
                                            duplicates => Duplicates,
                                            skipped => Skipped}}, NewState};
                                {error, _} = Error -> {reply, Error, State}
                            end
                    end;
                {error, _} = Error -> {reply, Error, State}
            end
    end;
handle_call({legacy_session, SessionId, Events}, _From, State) ->
    case adk_memory_contract:prepare_legacy_session(
           SessionId, Events, State#state.limits) of
        {ok, none} -> {reply, ok, State};
        {ok, Entry} ->
            case store_entries([Entry], State) of
                {ok, _, _, NewState} -> {reply, ok, NewState};
                {error, _} = Error -> {reply, Error, State}
            end;
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call({search, Scope, Query, Opts, Deadline}, _From, State) ->
    case request_expired(Deadline) of
        true -> {reply, {error, timeout}, State};
        false -> handle_search(Scope, Query, Opts, State)
    end;
handle_call({delete_entry, Scope, Id, Deadline}, _From, State) ->
    case {request_expired(Deadline), validate_delete(Scope, Id)} of
        {true, _} -> {reply, {error, timeout}, State};
        {false, {ok, CanonScope}} ->
            Key = {CanonScope, Id},
            case ets:lookup(State#state.table, Key) of
                [{Key, Entry}] ->
                    case request_expired(Deadline) of
                        true -> {reply, {error, timeout}, State};
                        false ->
                            true = ets:delete(State#state.table, Key),
                            {reply, ok, subtract_entry(Entry, State)}
                    end;
                [] -> {reply, {error, not_found}, State}
            end;
        {false, {error, _} = Error} -> {reply, Error, State}
    end;
handle_call({delete_session, Scope, SessionId, Deadline}, _From, State) ->
    case validate_delete(Scope, SessionId) of
        {ok, CanonScope} ->
            Entries = [{Key, Entry} || {Key = {EntryScope, _}, Entry}
                                          <- ets:tab2list(State#state.table),
                                      EntryScope =:= CanonScope,
                                      maps:get(session_id,
                                               maps:get(provenance, Entry),
                                               undefined) =:= SessionId],
            case request_expired(Deadline) of
                true -> {reply, {error, timeout}, State};
                false -> delete_matches(Entries, State)
            end;
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call({delete_user, Scope, Deadline}, _From, State) ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, CanonScope} ->
            Entries = [{Key, Entry} || {Key = {EntryScope, _}, Entry}
                                          <- ets:tab2list(State#state.table),
                                      EntryScope =:= CanonScope],
            case request_expired(Deadline) of
                true -> {reply, {error, timeout}, State};
                false -> delete_matches(Entries, State)
            end;
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_memory_operation}, State}.

handle_search(Scope, Query, Opts, State) ->
    case adk_memory_contract:prepare_search(
           Scope, Query, Opts, State#state.limits) of
        {ok, CanonScope, Tokens, Filter, Limit} ->
            Hits0 = [adk_memory_contract:hit(Entry, Tokens) ||
                      {{EntryScope, _Id}, Entry} <-
                          ets:tab2list(State#state.table),
                      EntryScope =:= CanonScope,
                      adk_memory_contract:metadata_matches(
                        maps:get(metadata, Entry), Filter)],
            Positive = [Hit || Hit <- Hits0, maps:get(score, Hit) > 0.0],
            Sorted = lists:sort(fun compare_hits/2, Positive),
            Hits = bound_hits(Sorted, Limit,
                              maps:get(max_result_bytes,
                                       State#state.limits)),
            {reply, {ok, Hits}, State};
        {error, _} = Error -> {reply, Error, State}
    end.

%% Preserve correlation for callers that used the pre-OTP raw message API.
handle_info({add, From, Ref, Content, Metadata}, State) when is_pid(From) ->
    {Reply, NewState} = legacy_add_internal(Content, Metadata, State),
    From ! {memory_reply, Ref, Reply},
    {noreply, NewState};
handle_info(_Info, State) -> {noreply, State}.

handle_cast(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

legacy_add_internal(Content, Metadata, State) ->
    case adk_memory_contract:prepare_entry(
           ?LEGACY_SCOPE, #{content => Content, metadata => Metadata}, #{},
           State#state.limits) of
        {ok, Entry} ->
            case store_entries([Entry], State) of
                {ok, _, _, NewState} ->
                    {{ok, maps:get(id, Entry)}, NewState};
                {error, _} = Error -> {Error, State}
            end;
        {error, _} = Error -> {Error, State}
    end.

store_entries(Entries, State) ->
    case classify_entries(Entries, State, #{}, 0) of
        {ok, NewByKey, Duplicates} ->
            NewEntries = maps:values(NewByKey),
            Added = length(NewEntries),
            AddedBytes = lists:sum([maps:get(storage_bytes, E)
                                    || E <- NewEntries]),
            case capacity_ok(Added, AddedBytes, State) of
                true ->
                    true = ets:insert(State#state.table,
                                      [{{maps:get(scope, E), maps:get(id, E)}, E}
                                       || E <- NewEntries]),
                    {ok, Added, Duplicates,
                     State#state{entries = State#state.entries + Added,
                                 bytes = State#state.bytes + AddedBytes}};
                false -> {error, memory_capacity_exceeded}
            end;
        {error, _} = Error -> Error
    end.

classify_entries([], _State, NewByKey, Duplicates) ->
    {ok, NewByKey, Duplicates};
classify_entries([Entry | Rest], State, NewByKey, Duplicates) ->
    Key = {maps:get(scope, Entry), maps:get(id, Entry)},
    case maps:find(Key, NewByKey) of
        {ok, Existing} ->
            case same_entry(Existing, Entry) of
                true -> classify_entries(Rest, State, NewByKey, Duplicates + 1);
                false -> {error, idempotency_conflict}
            end;
        error ->
            case ets:lookup(State#state.table, Key) of
                [] -> classify_entries(Rest, State, NewByKey#{Key => Entry},
                                       Duplicates);
                [{Key, Existing}] ->
                    case same_entry(Existing, Entry) of
                        true -> classify_entries(Rest, State, NewByKey,
                                                 Duplicates + 1);
                        false -> {error, idempotency_conflict}
                    end
            end
    end.

same_entry(Left, Right) ->
    maps:get(digest, Left) =:= maps:get(digest, Right) andalso
    maps:get(metadata, Left) =:= maps:get(metadata, Right) andalso
    maps:get(provenance, Left) =:= maps:get(provenance, Right).

capacity_ok(Added, AddedBytes, State) ->
    State#state.entries + Added =< maps:get(max_entries, State#state.limits)
    andalso State#state.bytes + AddedBytes =<
            maps:get(max_total_bytes, State#state.limits).

lookup_entry(Entry, State) ->
    Key = {maps:get(scope, Entry), maps:get(id, Entry)},
    [{Key, Stored}] = ets:lookup(State#state.table, Key),
    Stored.

public_entry(Entry) -> maps:without([storage_bytes], Entry).

compare_hits(Left, Right) ->
    {-maps:get(score, Left), maps:get(timestamp, Left), maps:get(id, Left)} =<
    {-maps:get(score, Right), maps:get(timestamp, Right), maps:get(id, Right)}.

bound_hits(Hits, Limit, MaxBytes) ->
    bound_hits(Hits, Limit, MaxBytes, 0, []).
bound_hits(_, 0, _MaxBytes, _Bytes, Acc) -> lists:reverse(Acc);
bound_hits([], _Limit, _MaxBytes, _Bytes, Acc) -> lists:reverse(Acc);
bound_hits([Hit | Rest], Limit, MaxBytes, Bytes, Acc) ->
    HitBytes = adk_memory_contract:entry_storage_bytes(Hit),
    case Bytes + HitBytes =< MaxBytes of
        true -> bound_hits(Rest, Limit - 1, MaxBytes,
                           Bytes + HitBytes, [Hit | Acc]);
        false -> lists:reverse(Acc)
    end.

validate_delete(Scope, Id) ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, CanonScope} when is_binary(Id), byte_size(Id) > 0,
                              byte_size(Id) =< 512 -> {ok, CanonScope};
        {ok, _} -> {error, invalid_memory_identifier};
        {error, _} = Error -> Error
    end.

delete_matches([], State) -> {reply, {error, not_found}, State};
delete_matches(Entries, State) ->
    lists:foreach(fun({Key, _}) -> true = ets:delete(State#state.table, Key) end,
                  Entries),
    NewState = lists:foldl(fun({_Key, Entry}, Acc) ->
                                   subtract_entry(Entry, Acc)
                           end, State, Entries),
    {reply, ok, NewState}.

subtract_entry(Entry, State) ->
    State#state{entries = State#state.entries - 1,
                bytes = State#state.bytes - maps:get(storage_bytes, Entry)}.

request_expired(Deadline) ->
    erlang:monotonic_time(millisecond) >= Deadline.
