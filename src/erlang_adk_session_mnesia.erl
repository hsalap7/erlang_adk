%% @doc erlang_adk_session_mnesia - Mnesia-backed implementation of adk_session_service.
-module(erlang_adk_session_mnesia).
-include("../include/adk_event.hrl").
-behaviour(adk_session_service).

-export([init/0, create_session/3, get_session/3, list_sessions/2, delete_session/3, update_state/4, add_event/4]).
-export([save/2, load/1, delete/1]). %% Legacy API

-record(adk_sessions_mnesia, {id, memory}).
-record(adk_session_v2, {key, state, events, last_update}). %% key = {AppName, UserId, SessionId}

%% @doc Initialize the Mnesia table. Call this if you intend to use Mnesia sessions.
init() ->
    application:ensure_all_started(mnesia),
    %% Try to change node to disc schema on the fly if it's currently ram
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    
    mnesia:create_table(adk_sessions_mnesia, [
        {attributes, record_info(fields, adk_sessions_mnesia)},
        {disc_copies, [node()]}
    ]),
    mnesia:create_table(adk_session_v2, [
        {attributes, record_info(fields, adk_session_v2)},
        {disc_copies, [node()]}
    ]),
    mnesia:wait_for_tables([adk_sessions_mnesia, adk_session_v2], 5000).

%% --- Legacy API for backward compatibility ---
save(SessionId, Memory) ->
    F = fun() ->
        mnesia:write(#adk_sessions_mnesia{id = SessionId, memory = Memory})
    end,
    {atomic, _} = mnesia:transaction(F),
    ok.

load(SessionId) ->
    F = fun() ->
        mnesia:read({adk_sessions_mnesia, SessionId})
    end,
    case mnesia:transaction(F) of
        {atomic, [#adk_sessions_mnesia{memory = Memory}]} -> Memory;
        {atomic, []} -> [];
        _ -> []
    end.

delete(SessionId) ->
    F = fun() ->
        mnesia:delete({adk_sessions_mnesia, SessionId})
    end,
    {atomic, _} = mnesia:transaction(F),
    ok.

%% --- New ADK 2.0 Behaviour ---

create_session(AppName, UserId, Opts) ->
    SessionId = maps:get(session_id, Opts, generate_id()),
    State = maps:get(state, Opts, #{}),
    Record = #adk_session_v2{key = {AppName, UserId, SessionId}, state = State, events = [], last_update = erlang:system_time(millisecond)},
    F = fun() -> mnesia:write(Record) end,
    {atomic, ok} = mnesia:transaction(F),
    {ok, #{id => SessionId, app_name => AppName, user_id => UserId, state => State, events => []}}.

get_session(AppName, UserId, SessionId) ->
    F = fun() -> mnesia:read({adk_session_v2, {AppName, UserId, SessionId}}) end,
    case mnesia:transaction(F) of
        {atomic, [#adk_session_v2{state = State, events = Events}]} ->
            {ok, #{id => SessionId, app_name => AppName, user_id => UserId, state => State, events => lists:reverse(Events)}};
        {atomic, []} ->
            {error, not_found}
    end.

list_sessions(AppName, UserId) ->
    %% Simplified listing using QLC could be done, or match object
    F = fun() ->
        mnesia:match_object(#adk_session_v2{key = {AppName, UserId, '_'}, _ = '_'})
    end,
    case mnesia:transaction(F) of
        {atomic, Records} ->
            Sessions = [#{id => SessionId, timestamp => Ts} || 
                        #adk_session_v2{key = {_, _, SessionId}, last_update = Ts} <- Records],
            {ok, Sessions};
        _ ->
            {error, db_error}
    end.

delete_session(AppName, UserId, SessionId) ->
    F = fun() -> mnesia:delete({adk_session_v2, {AppName, UserId, SessionId}}) end,
    {atomic, ok} = mnesia:transaction(F),
    ok.

update_state(AppName, UserId, SessionId, StateDelta) ->
    F = fun() ->
        case mnesia:read({adk_session_v2, {AppName, UserId, SessionId}}) of
            [Record = #adk_session_v2{state = State}] ->
                MergedState = maps:merge(State, StateDelta),
                mnesia:write(Record#adk_session_v2{state = MergedState});
            [] -> ok
        end
    end,
    {atomic, _} = mnesia:transaction(F),
    ok.

add_event(AppName, UserId, SessionId, Event) ->
    Delta = maps:get(<<"state_delta">>, Event#adk_event.actions, #{}),
    F = fun() ->
        case mnesia:read({adk_session_v2, {AppName, UserId, SessionId}}) of
            [Record = #adk_session_v2{state = State, events = Events}] ->
                State1 = if map_size(Delta) > 0 -> maps:merge(State, Delta); true -> State end,
                mnesia:write(Record#adk_session_v2{
                    state = State1, 
                    events = [Event | Events], 
                    last_update = erlang:system_time(millisecond)
                });
            [] -> ok
        end
    end,
    {atomic, _} = mnesia:transaction(F),
    ok.

%% Internal Functions
generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("sess-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).
