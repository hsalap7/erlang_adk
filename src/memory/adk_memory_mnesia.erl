%% @doc Durable local implementation of the version-2 memory contract.
%%
%% Entries and per-principal quota accounting are committed in one Mnesia
%% transaction.  Stable IDs derived from idempotency keys make concurrent and
%% restart retries deterministic.  Lexical ranking deliberately matches the
%% ETS reference adapter; vector/managed services can implement the same
%% behaviour without becoming runtime dependencies.
-module(adk_memory_mnesia).
-behaviour(gen_server).
-behaviour(adk_memory_service).

-export([start_link/1, init/1, stop/1, table_names/0,
         capabilities/1, add_entry/4, add_entry/5,
         add_events/5, add_events/6,
         add_session_to_memory/5, search/4, search/5,
         delete_entry/3, delete_entry/4,
         delete_session/3, delete_session/4,
         delete_user/2, delete_user/3,
         add/3, delete/2, add_session_to_memory/3]).
-export([handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(adk_memory_mnesia_entry,
        {key, entry, session_id = undefined, storage_bytes = 0}).
-record(adk_memory_mnesia_usage, {scope, entries = 0, bytes = 0}).
-record(state, {limits}).

-define(LEGACY_SCOPE, {user, <<"legacy">>, <<"legacy">>}).
-define(ENTRY_TABLE, adk_memory_mnesia_entry).
-define(USAGE_TABLE, adk_memory_mnesia_usage).
-define(DEFAULT_TIMEOUT, 5000).

start_link(Config) ->
    case adk_memory_contract:compile_config(Config) of
        {ok, Limits} ->
            gen_server:start_link(?MODULE, {server_limits, Limits}, []);
        {error, _} = Error -> Error
    end.

%% Compatibility constructor plus OTP callback clause.
init(Config) when is_map(Config) -> start_link(Config);
init({server_limits, Limits}) ->
    case ensure_tables() of
        ok -> {ok, #state{limits = Limits}};
        {error, Reason} -> {stop, Reason}
    end.

stop(Pid) ->
    try gen_server:stop(Pid, normal, 5000) of
        ok -> ok
    catch
        exit:{noproc, _} -> ok;
        exit:noproc -> ok
    end.

table_names() -> [?ENTRY_TABLE, ?USAGE_TABLE].

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
    {reply, adk_memory_contract:capabilities(mnesia, State#state.limits), State};
handle_call({add_entry, Scope, Input, Opts, Deadline}, _From, State) ->
    case request_expired(Deadline) of
        true -> {reply, {error, timeout}, State};
        false ->
            case adk_memory_contract:prepare_entry(
                   Scope, Input, Opts, State#state.limits) of
                {ok, Entry} ->
                    case store_entries([Entry], State#state.limits,
                                       Deadline) of
                        {ok, _Added, _Duplicates} ->
                            {reply, {ok, public_entry(read_entry(Entry))},
                             State};
                        {error, _} = Error -> {reply, Error, State}
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
                    case store_entries(Entries, State#state.limits,
                                       Deadline) of
                        {ok, Added, Duplicates} ->
                            {reply,
                             {ok, #{added => Added,
                                    duplicates => Duplicates,
                                    skipped => Skipped}}, State};
                        {error, _} = Error -> {reply, Error, State}
                    end;
                {error, _} = Error -> {reply, Error, State}
            end
    end;
handle_call({legacy_session, SessionId, Events}, _From, State) ->
    case adk_memory_contract:prepare_legacy_session(
           SessionId, Events, State#state.limits) of
        {ok, none} -> {reply, ok, State};
        {ok, Entry} ->
            case store_entries([Entry], State#state.limits, infinity) of
                {ok, _, _} -> {reply, ok, State};
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
    Reply = case {request_expired(Deadline), validate_delete(Scope, Id)} of
        {true, _} -> {error, timeout};
        {false, {ok, CanonScope}} ->
            delete_entry_tx(CanonScope, Id, Deadline);
        {false, {error, _} = Error} -> Error
    end,
    {reply, Reply, State};
handle_call({delete_session, Scope, SessionId, Deadline}, _From, State) ->
    Reply = case {request_expired(Deadline),
                  validate_delete(Scope, SessionId)} of
        {true, _} -> {error, timeout};
        {false, {ok, CanonScope}} ->
            delete_matching_tx(
              CanonScope,
              fun(#adk_memory_mnesia_entry{session_id = Seen}) ->
                      Seen =:= SessionId
              end, Deadline);
        {false, {error, _} = Error} -> Error
    end,
    {reply, Reply, State};
handle_call({delete_user, Scope, Deadline}, _From, State) ->
    Reply = case {request_expired(Deadline),
                  adk_memory_contract:validate_scope(Scope)} of
        {true, _} -> {error, timeout};
        {false, {ok, CanonScope}} ->
            delete_matching_tx(CanonScope, fun(_) -> true end, Deadline);
        {false, {error, _} = Error} -> Error
    end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_memory_operation}, State}.

handle_search(Scope, Query, Opts, State) ->
    case adk_memory_contract:prepare_search(
           Scope, Query, Opts, State#state.limits) of
        {ok, CanonScope, Tokens, Filter, Limit} ->
            case transaction(fun() -> scope_entries_tx(CanonScope) end) of
                {ok, Entries} ->
                    Hits0 = [adk_memory_contract:hit(Entry, Tokens) ||
                              Entry <- Entries,
                              adk_memory_contract:metadata_matches(
                                maps:get(metadata, Entry), Filter)],
                    Positive = [Hit || Hit <- Hits0,
                                       maps:get(score, Hit) > 0.0],
                    Sorted = lists:sort(fun compare_hits/2, Positive),
                    Hits = bound_hits(
                             Sorted, Limit,
                             maps:get(max_result_bytes, State#state.limits)),
                    {reply, {ok, Hits}, State};
                {error, _} = Error -> {reply, Error, State}
            end;
        {error, _} = Error -> {reply, Error, State}
    end.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

ensure_tables() ->
    case application:ensure_all_started(mnesia) of
        {ok, _} -> ensure_disk_schema_and_tables();
        {error, Reason} -> {error, {mnesia_start_failed, Reason}}
    end.

ensure_disk_schema_and_tables() ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> create_tables();
        {aborted, {already_exists, schema, Node, disc_copies}}
          when Node =:= node() -> create_tables();
        {aborted, Reason} ->
            {error, {memory_schema_configuration_failed, Reason}}
    end.

create_tables() ->
    Tables = [{?ENTRY_TABLE,
               [{attributes,
                 record_info(fields, adk_memory_mnesia_entry)},
                {disc_copies, [node()]}, {type, set}]},
              {?USAGE_TABLE,
               [{attributes,
                 record_info(fields, adk_memory_mnesia_usage)},
                {disc_copies, [node()]}, {type, set}]}],
    case create_tables(Tables) of
        ok ->
            case mnesia:wait_for_tables(table_names(), 5000) of
                ok -> ok;
                {timeout, Missing} ->
                    {error, {memory_table_wait_timeout, Missing}};
                {error, Reason} ->
                    {error, {memory_table_wait_failed, Reason}}
            end;
        {error, _} = Error -> Error
    end.

create_tables([]) -> ok;
create_tables([{Name, Options} | Rest]) ->
    case mnesia:create_table(Name, Options) of
        {atomic, ok} -> create_tables(Rest);
        {aborted, {already_exists, Name}} -> create_tables(Rest);
        {aborted, Reason} ->
            {error, {memory_table_creation_failed, Name, Reason}}
    end.

store_entries(Entries, Limits, Deadline) ->
    case transaction(
           fun() -> store_entries_tx(Entries, Limits, Deadline) end) of
        {ok, Result} -> Result;
        {error, Reason} -> {error, Reason}
    end.

store_entries_tx([], _Limits, _Deadline) -> {ok, 0, 0};
store_entries_tx(Entries, Limits, Deadline) ->
    abort_if_expired(Deadline),
    Scope = maps:get(scope, hd(Entries)),
    Usage = case mnesia:read(?USAGE_TABLE, Scope, write) of
        [Stored] -> Stored;
        [] -> #adk_memory_mnesia_usage{scope = Scope}
    end,
    case classify_entries_tx(Entries, #{}, 0) of
        {ok, NewByKey, Duplicates} ->
            NewEntries = maps:values(NewByKey),
            Added = length(NewEntries),
            AddedBytes = lists:sum([maps:get(storage_bytes, E)
                                    || E <- NewEntries]),
            NewCount = Usage#adk_memory_mnesia_usage.entries + Added,
            NewBytes = Usage#adk_memory_mnesia_usage.bytes + AddedBytes,
            case NewCount =< maps:get(max_entries, Limits) andalso
                 NewBytes =< maps:get(max_total_bytes, Limits) of
                true ->
                    abort_if_expired(Deadline),
                    lists:foreach(fun write_entry_tx/1, NewEntries),
                    mnesia:write(Usage#adk_memory_mnesia_usage{
                                   entries = NewCount, bytes = NewBytes}),
                    {ok, Added, Duplicates};
                false -> mnesia:abort(memory_capacity_exceeded)
            end;
        {error, Reason} -> mnesia:abort(Reason)
    end.

classify_entries_tx([], NewByKey, Duplicates) ->
    {ok, NewByKey, Duplicates};
classify_entries_tx([Entry | Rest], NewByKey, Duplicates) ->
    Key = {maps:get(scope, Entry), maps:get(id, Entry)},
    case maps:find(Key, NewByKey) of
        {ok, Existing} ->
            case same_entry(Existing, Entry) of
                true -> classify_entries_tx(Rest, NewByKey, Duplicates + 1);
                false -> {error, idempotency_conflict}
            end;
        error ->
            case mnesia:read(?ENTRY_TABLE, Key, write) of
                [] -> classify_entries_tx(Rest, NewByKey#{Key => Entry},
                                          Duplicates);
                [#adk_memory_mnesia_entry{entry = Existing}] ->
                    case same_entry(Existing, Entry) of
                        true -> classify_entries_tx(Rest, NewByKey,
                                                    Duplicates + 1);
                        false -> {error, idempotency_conflict}
                    end
            end
    end.

write_entry_tx(Entry) ->
    Scope = maps:get(scope, Entry),
    Id = maps:get(id, Entry),
    SessionId = maps:get(session_id, maps:get(provenance, Entry), undefined),
    mnesia:write(#adk_memory_mnesia_entry{
                   key = {Scope, Id}, entry = Entry, session_id = SessionId,
                   storage_bytes = maps:get(storage_bytes, Entry)}).

read_entry(Entry) ->
    Key = {maps:get(scope, Entry), maps:get(id, Entry)},
    case transaction(fun() -> mnesia:read(?ENTRY_TABLE, Key, read) end) of
        {ok, [#adk_memory_mnesia_entry{entry = Stored}]} -> Stored;
        _ -> Entry
    end.

scope_entries_tx(Scope) ->
    Pattern = #adk_memory_mnesia_entry{key = {Scope, '_'}, _ = '_'},
    [Entry || #adk_memory_mnesia_entry{entry = Entry}
                  <- mnesia:match_object(?ENTRY_TABLE, Pattern, read)].

delete_entry_tx(Scope, Id, Deadline) ->
    case transaction(fun() ->
        abort_if_expired(Deadline),
        Key = {Scope, Id},
        case mnesia:read(?ENTRY_TABLE, Key, write) of
            [] -> {error, not_found};
            [Record] ->
                abort_if_expired(Deadline),
                mnesia:delete({?ENTRY_TABLE, Key}),
                subtract_usage_tx(Scope, [Record]),
                ok
        end
    end) of
        {ok, Reply} -> Reply;
        {error, Reason} -> {error, Reason}
    end.

delete_matching_tx(Scope, Predicate, Deadline) ->
    case transaction(fun() ->
        abort_if_expired(Deadline),
        Pattern = #adk_memory_mnesia_entry{key = {Scope, '_'}, _ = '_'},
        Matches = [Record || Record <-
                     mnesia:match_object(?ENTRY_TABLE, Pattern, write),
                   Predicate(Record)],
        case Matches of
            [] -> {error, not_found};
            _ ->
                abort_if_expired(Deadline),
                lists:foreach(
                  fun(#adk_memory_mnesia_entry{key = Key}) ->
                          mnesia:delete({?ENTRY_TABLE, Key})
                  end, Matches),
                subtract_usage_tx(Scope, Matches),
                ok
        end
    end) of
        {ok, Reply} -> Reply;
        {error, Reason} -> {error, Reason}
    end.

subtract_usage_tx(Scope, Records) ->
    RemovedCount = length(Records),
    RemovedBytes = lists:sum(
                     [Bytes || #adk_memory_mnesia_entry{storage_bytes = Bytes}
                                   <- Records]),
    case mnesia:read(?USAGE_TABLE, Scope, write) of
        [Usage] ->
            NewCount = erlang:max(
                         0, Usage#adk_memory_mnesia_usage.entries - RemovedCount),
            NewBytes = erlang:max(
                         0, Usage#adk_memory_mnesia_usage.bytes - RemovedBytes),
            case NewCount of
                0 -> mnesia:delete({?USAGE_TABLE, Scope});
                _ -> mnesia:write(Usage#adk_memory_mnesia_usage{
                                      entries = NewCount, bytes = NewBytes})
            end;
        [] -> ok
    end.

transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic, Result} -> {ok, Result};
        {aborted, idempotency_conflict} -> {error, idempotency_conflict};
        {aborted, memory_capacity_exceeded} ->
            {error, memory_capacity_exceeded};
        {aborted, timeout} -> {error, timeout};
        {aborted, Reason} -> {error, {memory_transaction_failed, Reason}}
    end.

same_entry(Left, Right) ->
    maps:get(digest, Left) =:= maps:get(digest, Right) andalso
    maps:get(metadata, Left) =:= maps:get(metadata, Right) andalso
    maps:get(provenance, Left) =:= maps:get(provenance, Right).

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

request_expired(infinity) -> false;
request_expired(Deadline) ->
    erlang:monotonic_time(millisecond) >= Deadline.

abort_if_expired(Deadline) ->
    case request_expired(Deadline) of
        true -> mnesia:abort(timeout);
        false -> ok
    end.
