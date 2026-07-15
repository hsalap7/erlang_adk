%% @doc erlang_adk_session - ETS-backed implementation of adk_session_service.
-module(erlang_adk_session).
-include("adk_event.hrl").
-behaviour(adk_session_service).

-export([init/0, create_session/3, get_session/3, list_sessions/2, delete_session/3,
         update_state/4, add_event/4, clear_temp_state/3, take_state/4,
         add_event_if_state/6, compact_events/5]).
-export([save/2, load/1, delete/1]). %% Legacy API

-define(TABLE, adk_sessions).
-define(SCOPE_TAG, '$adk_scope').

%% Legacy Session Structure: {SessionId, Memory}
%% New Session Structure: {{AppName, UserId, SessionId}, LocalState, EventList, Timestamp}
%% Scope Structure: {{'$adk_scope', app | user, ...}, State}

%% @doc Initialize the session storage.
init() ->
    erlang_adk_session_owner:ensure_table().

%% --- Legacy API for backward compatibility ---
save(SessionId, Memory) ->
    ets:insert(?TABLE, {SessionId, Memory}),
    ok.

load(SessionId) ->
    case ets:lookup(?TABLE, SessionId) of
        [{SessionId, Memory}] when is_list(Memory) -> Memory;
        _ -> []
    end.

delete(SessionId) ->
    ets:delete(?TABLE, SessionId),
    ok.

%% --- ADK session service API ---

create_session(AppName, UserId, Opts) ->
    SessionId = maps:get(session_id, Opts, generate_id()),
    InitialState = maps:get(state, Opts, #{}),
    {_, UserDelta0, AppDelta0} = split_state(InitialState),
    with_scope_locks(AppName, UserId, SessionId,
                     map_size(AppDelta0) > 0,
                     map_size(UserDelta0) > 0,
                     fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events, Timestamp}] ->
                %% Idempotent creation prevents concurrent first invocations from
                %% replacing state or events written by the winning creator.
                State = effective_state(AppName, UserId, StoredState),
                {ok, session_map(AppName, UserId, SessionId,
                                 State, lists:reverse(Events), Timestamp)};
            [] ->
                {LocalState, UserDelta, AppDelta} = split_state(InitialState),
                AppState = update_scope(app_scope_key(AppName), #{}, AppDelta),
                UserState = update_scope(user_scope_key(AppName, UserId), #{}, UserDelta),
                Timestamp = erlang:system_time(millisecond),
                ets:insert(?TABLE, {{AppName, UserId, SessionId}, LocalState, [], Timestamp}),
                {ok, session_map(AppName, UserId, SessionId,
                                 compose_state(LocalState, UserState, AppState), [], Timestamp)}
        end
    end).

get_session(AppName, UserId, SessionId) ->
    with_session_lock(AppName, UserId, SessionId, fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events, Timestamp}] ->
                State = effective_state(AppName, UserId, StoredState),
                {ok, session_map(AppName, UserId, SessionId,
                                 State, lists:reverse(Events), Timestamp)};
            [] ->
                {error, not_found}
        end
    end).

list_sessions(AppName, UserId) ->
    %% ETS selection is concurrency-safe and intentionally returns a weakly
    %% consistent snapshot when sessions are created/deleted concurrently.
    %% It must not serialize unrelated sessions belonging to the same app.
    MatchSpec = [{{{AppName, UserId, '$1'}, '_', '_', '$2'},
                  [], [#{id => '$1', timestamp => '$2'}]}],
    {ok, ets:select(?TABLE, MatchSpec)}.

delete_session(AppName, UserId, SessionId) ->
    with_session_lock(AppName, UserId, SessionId, fun() ->
        ets:delete(?TABLE, {AppName, UserId, SessionId}),
        ok
    end).

update_state(AppName, UserId, SessionId, StateDelta) ->
    with_mutation_locks(AppName, UserId, SessionId, StateDelta, fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events, _Timestamp}] ->
                {LocalState0, LegacyUserState, LegacyAppState} = split_state(StoredState),
                {LocalDelta, UserDelta, AppDelta} = split_state(StateDelta),
                LocalState = maps:merge(LocalState0, LocalDelta),
                update_scope(app_scope_key(AppName), LegacyAppState, AppDelta),
                update_scope(user_scope_key(AppName, UserId), LegacyUserState, UserDelta),
                ets:insert(?TABLE, {{AppName, UserId, SessionId}, LocalState, Events,
                                    erlang:system_time(millisecond)}),
                ok;
            [] ->
                {error, not_found}
        end
    end).

add_event(AppName, UserId, SessionId, Event) ->
    StateDelta = maps:get(<<"state_delta">>, Event#adk_event.actions, #{}),
    with_mutation_locks(AppName, UserId, SessionId, StateDelta, fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events, _Timestamp}] ->
                {LocalState0, LegacyUserState, LegacyAppState} = split_state(StoredState),
                {LocalDelta, UserDelta, AppDelta} = split_state(StateDelta),
                LocalState = maps:merge(LocalState0, LocalDelta),
                update_scope(app_scope_key(AppName), LegacyAppState, AppDelta),
                update_scope(user_scope_key(AppName, UserId), LegacyUserState, UserDelta),
                ets:insert(?TABLE, {{AppName, UserId, SessionId}, LocalState,
                                    [Event | Events], erlang:system_time(millisecond)}),
                ok;
            [] ->
                {error, not_found}
        end
    end).

%% @doc Remove invocation-scoped temp: state after an invocation has completed.
clear_temp_state(AppName, UserId, SessionId) ->
    with_mutation_locks(AppName, UserId, SessionId, #{}, fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events, _Timestamp}] ->
                {LocalState0, LegacyUserState, LegacyAppState} = split_state(StoredState),
                LocalState = maps:filter(
                    fun(Key, _Value) -> state_scope(Key) =/= temp end,
                    LocalState0),
                update_scope(app_scope_key(AppName), LegacyAppState, #{}),
                update_scope(user_scope_key(AppName, UserId), LegacyUserState, #{}),
                ets:insert(?TABLE, {{AppName, UserId, SessionId}, LocalState, Events,
                                    erlang:system_time(millisecond)}),
                ok;
            [] ->
                {error, not_found}
        end
    end).

%% @doc Atomically read and remove one state value.
%% Missing sessions and missing keys both return {error, not_found}.
take_state(AppName, UserId, SessionId, Key) ->
    with_mutation_locks(AppName, UserId, SessionId,
                        #{Key => '$adk_lock_marker'}, fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events, _Timestamp}] ->
                {LocalState, LegacyUserState, LegacyAppState} = split_state(StoredState),
                update_scope(app_scope_key(AppName), LegacyAppState, #{}),
                update_scope(user_scope_key(AppName, UserId), LegacyUserState, #{}),
                Result = case state_scope(Key) of
                    app -> take_scope_value(app_scope_key(AppName), Key);
                    user -> take_scope_value(user_scope_key(AppName, UserId), Key);
                    _ -> take_local_value(Key, LocalState)
                end,
                case Result of
                    {ok, Value, NewLocalState} ->
                        ets:insert(?TABLE, {{AppName, UserId, SessionId}, NewLocalState,
                                            Events, erlang:system_time(millisecond)}),
                        {ok, Value};
                    {ok, Value} ->
                        %% Normalize any legacy scoped keys out of the session record.
                        ets:insert(?TABLE, {{AppName, UserId, SessionId}, LocalState,
                                            Events, erlang:system_time(millisecond)}),
                        {ok, Value};
                    {error, not_found} ->
                        {error, not_found}
                end;
            [] ->
                {error, not_found}
        end
    end).

%% @doc Atomically append Event only while Key still has Expected. This is the
%% compare-and-append primitive used for non-terminal long-running tool
%% progress, so a racing terminal resume either happens wholly before or after
%% the progress event.
add_event_if_state(AppName, UserId, SessionId, Key, Expected, Event)
  when is_record(Event, adk_event) ->
    StateDelta = maps:get(<<"state_delta">>, Event#adk_event.actions, #{}),
    LockDelta = StateDelta#{Key => '$adk_lock_marker'},
    with_mutation_locks(AppName, UserId, SessionId, LockDelta, fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events, _Timestamp}] ->
                {LocalState0, LegacyUserState, LegacyAppState} =
                    split_state(StoredState),
                Current = effective_state(AppName, UserId, StoredState),
                case maps:find(Key, Current) of
                    {ok, Expected} ->
                        {LocalDelta, UserDelta, AppDelta} =
                            split_state(StateDelta),
                        LocalState = maps:merge(LocalState0, LocalDelta),
                        update_scope(app_scope_key(AppName),
                                     LegacyAppState, AppDelta),
                        update_scope(user_scope_key(AppName, UserId),
                                     LegacyUserState, UserDelta),
                        ets:insert(
                          ?TABLE,
                          {{AppName, UserId, SessionId}, LocalState,
                           [Event | Events],
                           erlang:system_time(millisecond)}),
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

%% @doc Atomically replace an exact chronological event prefix with a durable
%% compaction summary. Events appended concurrently after the prefix survive.
compact_events(AppName, UserId, SessionId, ExpectedIds, SummaryEvent)
  when is_list(ExpectedIds), ExpectedIds =/= [],
       is_record(SummaryEvent, adk_event) ->
    with_session_lock(AppName, UserId, SessionId, fun() ->
        case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
            [{{AppName, UserId, SessionId}, StoredState, Events,
              _Timestamp}] ->
                Chronological = lists:reverse(Events),
                case replace_expected_prefix(
                       Chronological, ExpectedIds, SummaryEvent) of
                    {ok, Compacted} ->
                        ets:insert(
                          ?TABLE,
                          {{AppName, UserId, SessionId}, StoredState,
                           lists:reverse(Compacted),
                           erlang:system_time(millisecond)}),
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

session_map(AppName, UserId, SessionId, State, Events, Timestamp) ->
    #{id => SessionId,
      app_name => AppName,
      user_id => UserId,
      state => State,
      events => Events,
      timestamp => Timestamp}.

effective_state(AppName, UserId, StoredState) ->
    {LocalState, LegacyUserState, LegacyAppState} = split_state(StoredState),
    AppState = maps:merge(LegacyAppState, read_scope(app_scope_key(AppName))),
    UserState = maps:merge(LegacyUserState,
                           read_scope(user_scope_key(AppName, UserId))),
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
    {?SCOPE_TAG, app, AppName}.

user_scope_key(AppName, UserId) ->
    {?SCOPE_TAG, user, AppName, UserId}.

read_scope(Key) ->
    case ets:lookup(?TABLE, Key) of
        [{Key, State}] when is_map(State) -> State;
        _ -> #{}
    end.

update_scope(Key, LegacyState, Delta) ->
    CurrentState = read_scope(Key),
    NewState = maps:merge(maps:merge(LegacyState, CurrentState), Delta),
    case map_size(NewState) of
        0 -> ok;
        _ -> ets:insert(?TABLE, {Key, NewState})
    end,
    NewState.

take_local_value(Key, LocalState) ->
    case maps:take(Key, LocalState) of
        {Value, NewLocalState} -> {ok, Value, NewLocalState};
        error -> {error, not_found}
    end.

take_scope_value(ScopeKey, Key) ->
    State = read_scope(ScopeKey),
    case maps:take(Key, State) of
        {Value, NewState} ->
            case map_size(NewState) of
                0 -> ets:delete(?TABLE, ScopeKey);
                _ -> ets:insert(?TABLE, {ScopeKey, NewState})
            end,
            {ok, Value};
        error ->
            {error, not_found}
    end.

%% Local session mutations should not contend merely because they share an
%% application name. App- and user-scoped map merges still need their matching
%% locks to avoid lost updates. Locks are acquired in app -> user -> session
%% order so an operation spanning scopes cannot deadlock another operation.
with_mutation_locks(AppName, UserId, SessionId, Delta, Fun) ->
    {_, DeltaUser, DeltaApp} = split_state(Delta),
    {LegacyUser, LegacyApp} = legacy_scopes(AppName, UserId, SessionId),
    with_scope_locks(AppName, UserId, SessionId,
                     map_size(DeltaApp) > 0 orelse map_size(LegacyApp) > 0,
                     map_size(DeltaUser) > 0 orelse map_size(LegacyUser) > 0,
                     Fun).

legacy_scopes(AppName, UserId, SessionId) ->
    case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
        [{{AppName, UserId, SessionId}, StoredState, _Events, _Timestamp}] ->
            {_Local, User, App} = split_state(StoredState),
            {User, App};
        [] ->
            {#{}, #{}}
    end.

with_scope_locks(AppName, UserId, SessionId, NeedApp, NeedUser, Fun) ->
    WithSession = fun() ->
        with_session_lock(AppName, UserId, SessionId, Fun)
    end,
    WithUser = case NeedUser of
        true -> fun() -> with_user_lock(AppName, UserId, WithSession) end;
        false -> WithSession
    end,
    case NeedApp of
        true -> with_app_scope_lock(AppName, WithUser);
        false -> WithUser()
    end.

with_app_scope_lock(AppName, Fun) ->
    with_lock({?MODULE, app_scope, AppName}, Fun).

with_user_lock(AppName, UserId, Fun) ->
    with_lock({?MODULE, user_scope, AppName, UserId}, Fun).

with_session_lock(AppName, UserId, SessionId, Fun) ->
    with_lock({?MODULE, session, AppName, UserId, SessionId}, Fun).

with_lock(Resource, Fun) ->
    global:trans({Resource, self()}, Fun, [node()], infinity).

generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("sess-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).
