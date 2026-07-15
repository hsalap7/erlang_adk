%% @doc erlang_adk_session_mnesia - Mnesia-backed implementation of adk_session_service.
-module(erlang_adk_session_mnesia).
-include("adk_event.hrl").
-behaviour(adk_session_service).

-export([init/0, create_session/3, get_session/3, list_sessions/2, delete_session/3,
         update_state/4, add_event/4, clear_temp_state/3, take_state/4,
         add_event_if_state/6, compact_events/5]).
-export([save/2, load/1, delete/1]). %% Legacy API

-record(adk_sessions_mnesia, {id, memory}).
-record(adk_session_v2, {key, state, events, last_update}).
-record(adk_session_scope, {key, state = #{}}).

%% @doc Initialize the Mnesia tables. Call this if you intend to use Mnesia sessions.
init() ->
    case application:ensure_all_started(mnesia) of
        {ok, _StartedApps} -> init_schema_and_tables();
        {error, Reason} -> {error, {mnesia_start_failed, Reason}}
    end.

init_schema_and_tables() ->
    case ensure_disk_schema() of
        ok ->
            Tables = [
                {adk_sessions_mnesia,
                 [{attributes, record_info(fields, adk_sessions_mnesia)},
                  {disc_copies, [node()]}]},
                {adk_session_v2,
                 [{attributes, record_info(fields, adk_session_v2)},
                  {disc_copies, [node()]}]},
                {adk_session_scope,
                 [{attributes, record_info(fields, adk_session_scope)},
                  {disc_copies, [node()]}]}
            ],
            case ensure_tables(Tables) of
                ok -> wait_for_tables();
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

ensure_disk_schema() ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, schema, Node, disc_copies}}
          when Node =:= node() -> ok;
        {aborted, Reason} -> {error, {schema_configuration_failed, Reason}}
    end.

ensure_tables([]) ->
    ok;
ensure_tables([{Table, Options} | Rest]) ->
    case mnesia:create_table(Table, Options) of
        {atomic, ok} -> ensure_tables(Rest);
        {aborted, {already_exists, Table}} -> ensure_tables(Rest);
        {aborted, Reason} -> {error, {table_creation_failed, Table, Reason}}
    end.

wait_for_tables() ->
    Tables = [adk_sessions_mnesia, adk_session_v2, adk_session_scope],
    case mnesia:wait_for_tables(Tables, 5000) of
        ok -> ok;
        {timeout, Unavailable} ->
            {error, {table_wait_timeout, Unavailable}};
        {error, Reason} ->
            {error, {table_wait_failed, Reason}}
    end.

%% --- Legacy API for backward compatibility ---
save(SessionId, Memory) ->
    Fun = fun() ->
        mnesia:write(#adk_sessions_mnesia{id = SessionId, memory = Memory})
    end,
    {atomic, _} = mnesia:transaction(Fun),
    ok.

load(SessionId) ->
    Fun = fun() -> mnesia:read({adk_sessions_mnesia, SessionId}) end,
    case mnesia:transaction(Fun) of
        {atomic, [#adk_sessions_mnesia{memory = Memory}]} -> Memory;
        {atomic, []} -> [];
        _ -> []
    end.

delete(SessionId) ->
    Fun = fun() -> mnesia:delete({adk_sessions_mnesia, SessionId}) end,
    {atomic, _} = mnesia:transaction(Fun),
    ok.

%% --- ADK session service API ---

create_session(AppName, UserId, Opts) ->
    SessionId = maps:get(session_id, Opts, generate_id()),
    InitialState = maps:get(state, Opts, #{}),
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        %% Acquire locks in session/app/user order across all mutating operations.
        case mnesia:read(adk_session_v2, SessionKey, write) of
            [#adk_session_v2{state = StoredState,
                             events = Events,
                             last_update = Timestamp}] ->
                %% Idempotent creation prevents concurrent first invocations
                %% from replacing the winning session's state or events.
                State = effective_state_tx(AppName, UserId, StoredState),
                {ok, session_map(AppName, UserId, SessionId,
                                 State, lists:reverse(Events), Timestamp)};
            [] ->
                {LocalState, UserDelta, AppDelta} = split_state(InitialState),
                AppState = update_scope_tx(app_scope_key(AppName), #{}, AppDelta),
                UserState = update_scope_tx(user_scope_key(AppName, UserId),
                                            #{}, UserDelta),
                Timestamp = erlang:system_time(millisecond),
                mnesia:write(#adk_session_v2{key = SessionKey,
                                             state = LocalState,
                                             events = [],
                                             last_update = Timestamp}),
                {ok, session_map(AppName, UserId, SessionId,
                                 compose_state(LocalState, UserState, AppState),
                                 [], Timestamp)}
        end
    end).

get_session(AppName, UserId, SessionId) ->
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        case mnesia:read(adk_session_v2, SessionKey, read) of
            [#adk_session_v2{state = StoredState,
                             events = Events,
                             last_update = Timestamp}] ->
                State = effective_state_tx(AppName, UserId, StoredState),
                {ok, session_map(AppName, UserId, SessionId,
                                 State, lists:reverse(Events), Timestamp)};
            [] ->
                {error, not_found}
        end
    end).

list_sessions(AppName, UserId) ->
    transaction(fun() ->
        Records = mnesia:match_object(
                    #adk_session_v2{key = {AppName, UserId, '_'}, _ = '_'}),
        Sessions = [#{id => SessionId, timestamp => Timestamp} ||
                     #adk_session_v2{key = {_, _, SessionId},
                                     last_update = Timestamp} <- Records],
        {ok, Sessions}
    end).

delete_session(AppName, UserId, SessionId) ->
    transaction(fun() ->
        mnesia:delete({adk_session_v2, {AppName, UserId, SessionId}}),
        ok
    end).

update_state(AppName, UserId, SessionId, StateDelta) ->
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        case mnesia:read(adk_session_v2, SessionKey, write) of
            [Record = #adk_session_v2{state = StoredState}] ->
                {LocalState0, LegacyUserState, LegacyAppState} = split_state(StoredState),
                {LocalDelta, UserDelta, AppDelta} = split_state(StateDelta),
                LocalState = maps:merge(LocalState0, LocalDelta),
                update_scope_tx(app_scope_key(AppName), LegacyAppState, AppDelta),
                update_scope_tx(user_scope_key(AppName, UserId), LegacyUserState, UserDelta),
                mnesia:write(Record#adk_session_v2{
                    state = LocalState,
                    last_update = erlang:system_time(millisecond)
                }),
                ok;
            [] ->
                {error, not_found}
        end
    end).

add_event(AppName, UserId, SessionId, Event) ->
    StateDelta = maps:get(<<"state_delta">>, Event#adk_event.actions, #{}),
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        case mnesia:read(adk_session_v2, SessionKey, write) of
            [Record = #adk_session_v2{state = StoredState, events = Events}] ->
                {LocalState0, LegacyUserState, LegacyAppState} = split_state(StoredState),
                {LocalDelta, UserDelta, AppDelta} = split_state(StateDelta),
                LocalState = maps:merge(LocalState0, LocalDelta),
                update_scope_tx(app_scope_key(AppName), LegacyAppState, AppDelta),
                update_scope_tx(user_scope_key(AppName, UserId), LegacyUserState, UserDelta),
                mnesia:write(Record#adk_session_v2{
                    state = LocalState,
                    events = [Event | Events],
                    last_update = erlang:system_time(millisecond)
                }),
                ok;
            [] ->
                {error, not_found}
        end
    end).

%% @doc Remove invocation-scoped temp: state after an invocation has completed.
clear_temp_state(AppName, UserId, SessionId) ->
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        case mnesia:read(adk_session_v2, SessionKey, write) of
            [Record = #adk_session_v2{state = StoredState}] ->
                {LocalState0, LegacyUserState, LegacyAppState} = split_state(StoredState),
                LocalState = maps:filter(
                    fun(Key, _Value) -> state_scope(Key) =/= temp end,
                    LocalState0),
                update_scope_tx(app_scope_key(AppName), LegacyAppState, #{}),
                update_scope_tx(user_scope_key(AppName, UserId), LegacyUserState, #{}),
                mnesia:write(Record#adk_session_v2{
                    state = LocalState,
                    last_update = erlang:system_time(millisecond)
                }),
                ok;
            [] ->
                {error, not_found}
        end
    end).

%% @doc Atomically read and remove one state value.
%% Missing sessions and missing keys both return {error, not_found}.
take_state(AppName, UserId, SessionId, Key) ->
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        case mnesia:read(adk_session_v2, SessionKey, write) of
            [Record = #adk_session_v2{state = StoredState}] ->
                {LocalState, LegacyUserState, LegacyAppState} =
                    split_state(StoredState),
                %% Preserve the common session/app/user lock order and migrate
                %% legacy scoped values before taking the requested key.
                update_scope_tx(app_scope_key(AppName), LegacyAppState, #{}),
                update_scope_tx(user_scope_key(AppName, UserId),
                                LegacyUserState, #{}),
                case state_scope(Key) of
                    app ->
                        take_scoped_state_tx(Record, LocalState,
                                             app_scope_key(AppName), Key);
                    user ->
                        take_scoped_state_tx(Record, LocalState,
                                             user_scope_key(AppName, UserId), Key);
                    _ ->
                        take_local_state_tx(Record, LocalState, Key)
                end;
            [] ->
                {error, not_found}
        end
    end).

%% @doc Mnesia compare-and-append counterpart to the ETS session service.
add_event_if_state(AppName, UserId, SessionId, Key, Expected, Event)
  when is_record(Event, adk_event) ->
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        case mnesia:read(adk_session_v2, SessionKey, write) of
            [Record = #adk_session_v2{state = StoredState,
                                      events = Events}] ->
                {LocalState0, LegacyUserState, LegacyAppState} =
                    split_state(StoredState),
                AppState0 = maps:merge(
                              LegacyAppState,
                              read_scope_tx(app_scope_key(AppName), write)),
                UserState0 = maps:merge(
                               LegacyUserState,
                               read_scope_tx(user_scope_key(AppName, UserId),
                                             write)),
                Current = compose_state(LocalState0, UserState0, AppState0),
                case maps:find(Key, Current) of
                    {ok, Expected} ->
                        StateDelta = maps:get(
                                       <<"state_delta">>,
                                       Event#adk_event.actions, #{}),
                        {LocalDelta, UserDelta, AppDelta} =
                            split_state(StateDelta),
                        LocalState = maps:merge(LocalState0, LocalDelta),
                        update_scope_tx(app_scope_key(AppName),
                                        AppState0, AppDelta),
                        update_scope_tx(user_scope_key(AppName, UserId),
                                        UserState0, UserDelta),
                        mnesia:write(
                          Record#adk_session_v2{
                            state = LocalState,
                            events = [Event | Events],
                            last_update = erlang:system_time(millisecond)}),
                        ok;
                    {ok, _Other} ->
                        {error, conflict};
                    error ->
                        {error, not_found}
                end;
            [] ->
                {error, not_found}
        end
    end);
add_event_if_state(_AppName, _UserId, _SessionId, _Key, _Expected, _Event) ->
    {error, invalid_event}.

%% @doc Transactional Mnesia counterpart to compact_events/5.
compact_events(AppName, UserId, SessionId, ExpectedIds, SummaryEvent)
  when is_list(ExpectedIds), ExpectedIds =/= [],
       is_record(SummaryEvent, adk_event) ->
    transaction(fun() ->
        SessionKey = {AppName, UserId, SessionId},
        case mnesia:read(adk_session_v2, SessionKey, write) of
            [Record = #adk_session_v2{events = Events}] ->
                Chronological = lists:reverse(Events),
                case replace_expected_prefix(
                       Chronological, ExpectedIds, SummaryEvent) of
                    {ok, Compacted} ->
                        mnesia:write(
                          Record#adk_session_v2{
                            events = lists:reverse(Compacted),
                            last_update = erlang:system_time(millisecond)}),
                        ok;
                    conflict -> {error, conflict}
                end;
            [] -> {error, not_found}
        end
    end);
compact_events(_AppName, _UserId, _SessionId, _ExpectedIds, _SummaryEvent) ->
    {error, invalid_compaction}.

replace_expected_prefix(Events, ExpectedIds, SummaryEvent) ->
    case take_matching_prefix(Events, ExpectedIds) of
        {ok, Rest} -> {ok, [SummaryEvent | Rest]};
        conflict -> conflict
    end.

take_matching_prefix(Rest, []) -> {ok, Rest};
take_matching_prefix([#adk_event{id = Id} | Events], [Id | Ids]) ->
    take_matching_prefix(Events, Ids);
take_matching_prefix(_, _) -> conflict.

%% --- Internal functions ---

transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

session_map(AppName, UserId, SessionId, State, Events, Timestamp) ->
    #{id => SessionId,
      app_name => AppName,
      user_id => UserId,
      state => State,
      events => Events,
      timestamp => Timestamp}.

effective_state_tx(AppName, UserId, StoredState) ->
    {LocalState, LegacyUserState, LegacyAppState} = split_state(StoredState),
    AppState = maps:merge(LegacyAppState, read_scope_tx(app_scope_key(AppName), read)),
    UserState = maps:merge(LegacyUserState,
                           read_scope_tx(user_scope_key(AppName, UserId), read)),
    compose_state(LocalState, UserState, AppState).

compose_state(LocalState, UserState, AppState) ->
    maps:merge(maps:merge(AppState, UserState), LocalState).

split_state(State) ->
    maps:fold(
      fun(Key, Value, {LocalAcc, UserAcc, AppAcc}) ->
          case state_scope(Key) of
              user -> {LocalAcc, UserAcc#{Key => Value}, AppAcc};
              app -> {LocalAcc, UserAcc, AppAcc#{Key => Value}};
              _ -> {LocalAcc#{Key => Value}, UserAcc, AppAcc}
          end
      end,
      {#{}, #{}, #{}},
      State).

state_scope(<<"user:", _/binary>>) -> user;
state_scope(<<"app:", _/binary>>) -> app;
state_scope(<<"temp:", _/binary>>) -> temp;
state_scope(_) -> session.

app_scope_key(AppName) ->
    {app, AppName}.

user_scope_key(AppName, UserId) ->
    {user, AppName, UserId}.

read_scope_tx(Key, LockKind) ->
    case mnesia:read(adk_session_scope, Key, LockKind) of
        [#adk_session_scope{state = State}] -> State;
        [] -> #{}
    end.

update_scope_tx(Key, LegacyState, Delta) ->
    CurrentState = read_scope_tx(Key, write),
    NewState = maps:merge(maps:merge(LegacyState, CurrentState), Delta),
    case map_size(NewState) of
        0 -> ok;
        _ -> mnesia:write(#adk_session_scope{key = Key, state = NewState})
    end,
    NewState.

take_local_state_tx(Record, LocalState, Key) ->
    case maps:take(Key, LocalState) of
        {Value, NewLocalState} ->
            write_session_state(Record, NewLocalState),
            {ok, Value};
        error ->
            {error, not_found}
    end.

take_scoped_state_tx(Record, LocalState, ScopeKey, Key) ->
    ScopeState = read_scope_tx(ScopeKey, write),
    case maps:take(Key, ScopeState) of
        {Value, NewScopeState} ->
            case map_size(NewScopeState) of
                0 -> mnesia:delete({adk_session_scope, ScopeKey});
                _ -> mnesia:write(#adk_session_scope{
                                      key = ScopeKey,
                                      state = NewScopeState})
            end,
            %% Normalize any legacy scoped values out of the session record.
            write_session_state(Record, LocalState),
            {ok, Value};
        error ->
            {error, not_found}
    end.

write_session_state(Record, State) ->
    mnesia:write(Record#adk_session_v2{
        state = State,
        last_update = erlang:system_time(millisecond)
    }).

generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("sess-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).
