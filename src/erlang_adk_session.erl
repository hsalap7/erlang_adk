%% @doc erlang_adk_session - ETS-backed implementation of adk_session_service.
-module(erlang_adk_session).
-include("../include/adk_event.hrl").
-behaviour(adk_session_service).

-export([init/0, create_session/3, get_session/3, list_sessions/2, delete_session/3, update_state/4, add_event/4]).
-export([save/2, load/1, delete/1]). %% Legacy API

-define(TABLE, adk_sessions).

%% Legacy Session Structure: {SessionId, Memory}
%% New Session Structure: {{AppName, UserId, SessionId}, StateMap, EventList, Timestamp}

%% @doc Initialize the session storage
init() ->
    case ets:info(adk_sessions) of
        undefined ->
            ets:new(adk_sessions, [set, public, named_table, {read_concurrency, true}, {write_concurrency, true}]);
        _ ->
            ok
    end,
    ok.

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

%% --- New ADK 2.0 Behaviour ---

create_session(AppName, UserId, Opts) ->
    SessionId = maps:get(session_id, Opts, generate_id()),
    State = maps:get(state, Opts, #{}),
    Record = {{AppName, UserId, SessionId}, State, [], erlang:system_time(millisecond)},
    ets:insert(?TABLE, Record),
    {ok, #{id => SessionId, app_name => AppName, user_id => UserId, state => State, events => []}}.

get_session(AppName, UserId, SessionId) ->
    case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
        [{{AppName, UserId, SessionId}, State, Events, _Ts}] ->
            {ok, #{id => SessionId, app_name => AppName, user_id => UserId, state => State, events => lists:reverse(Events)}};
        [] ->
            {error, not_found}
    end.

list_sessions(AppName, UserId) ->
    MatchSpec = [{{{AppName, UserId, '$1'}, '_', '_', '$2'}, [], [#{id => '$1', timestamp => '$2'}]}],
    Sessions = ets:select(?TABLE, MatchSpec),
    {ok, Sessions}.

delete_session(AppName, UserId, SessionId) ->
    ets:delete(?TABLE, {AppName, UserId, SessionId}),
    ok.

update_state(AppName, UserId, SessionId, StateDelta) ->
    case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
        [{{AppName, UserId, SessionId}, State, Events, Ts}] ->
            MergedState = merge_state(State, StateDelta),
            ets:insert(?TABLE, {{AppName, UserId, SessionId}, MergedState, Events, Ts}),
            %% Propagate global states
            update_global_states(AppName, UserId, StateDelta),
            ok;
        [] -> ok
    end.

add_event(AppName, UserId, SessionId, Event) ->
    %% First, apply any state delta from the event
    Delta = maps:get(<<"state_delta">>, Event#adk_event.actions, #{}),
    if map_size(Delta) > 0 ->
        update_state(AppName, UserId, SessionId, Delta);
    true -> ok
    end,
    
    %% Strip temp: keys after applying delta (temp keys are single-turn only)
    strip_temp_keys(AppName, UserId, SessionId),
    
    %% Then append the event
    case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
        [{{AppName, UserId, SessionId}, State, Events, _Ts}] ->
            ets:insert(?TABLE, {{AppName, UserId, SessionId}, State, [Event | Events], erlang:system_time(millisecond)}),
            ok;
        [] -> ok
    end.

%% Internal Functions

generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("sess-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).

merge_state(State, Delta) ->
    maps:merge(State, Delta).

strip_temp_keys(AppName, UserId, SessionId) ->
    case ets:lookup(?TABLE, {AppName, UserId, SessionId}) of
        [{{AppName, UserId, SessionId}, State, Events, Ts}] ->
            Cleaned = maps:filter(fun(K, _) ->
                not (is_binary(K) andalso binary:match(K, <<"temp:">>) =:= {0, 5})
            end, State),
            case map_size(Cleaned) =:= map_size(State) of
                true -> ok;
                false -> ets:insert(?TABLE, {{AppName, UserId, SessionId}, Cleaned, Events, Ts})
            end;
        [] -> ok
    end.

update_global_states(AppName, UserId, Delta) ->
    UserDelta = maps:filter(fun(K, _) -> is_binary(K) andalso binary:match(K, <<"user:">>) =:= {0, 5} end, Delta),
    AppDelta = maps:filter(fun(K, _) -> is_binary(K) andalso binary:match(K, <<"app:">>) =:= {0, 4} end, Delta),
    
    if map_size(UserDelta) > 0 ->
        UserMatch = [{{{AppName, UserId, '_'}, '_', '_', '_'}, [], ['$_']}],
        UserSessions = ets:select(?TABLE, UserMatch),
        lists:foreach(fun({{A, U, S}, State, Events, Ts}) ->
            Merged = merge_state(State, UserDelta),
            ets:insert(?TABLE, {{A, U, S}, Merged, Events, Ts})
        end, UserSessions);
    true -> ok end,
    
    if map_size(AppDelta) > 0 ->
        AppMatch = [{{{AppName, '_', '_'}, '_', '_', '_'}, [], ['$_']}],
        AppSessions = ets:select(?TABLE, AppMatch),
        lists:foreach(fun({{A, U, S}, State, Events, Ts}) ->
            Merged = merge_state(State, AppDelta),
            ets:insert(?TABLE, {{A, U, S}, Merged, Events, Ts})
        end, AppSessions);
    true -> ok end,
    ok.
