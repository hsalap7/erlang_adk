%% Fault-injection wrapper used to exercise Runner persistence boundaries.
-module(adk_fault_session_service).
-behaviour(adk_session_service).

-export([set_update_state_fault/2, clear_update_state_fault/1]).
-export([create_session/3, get_session/3, list_sessions/2,
         delete_session/3, update_state/4, add_event/4,
         clear_temp_state/3, take_state/4, add_event_if_state/6]).

set_update_state_fault(SessionId, Fault) when is_binary(SessionId) ->
    persistent_term:put({?MODULE, SessionId}, Fault),
    ok.

clear_update_state_fault(SessionId) when is_binary(SessionId) ->
    persistent_term:erase({?MODULE, SessionId}),
    ok.

create_session(AppName, UserId, Opts) ->
    erlang_adk_session:create_session(AppName, UserId, Opts).

get_session(AppName, UserId, SessionId) ->
    erlang_adk_session:get_session(AppName, UserId, SessionId).

list_sessions(AppName, UserId) ->
    erlang_adk_session:list_sessions(AppName, UserId).

delete_session(AppName, UserId, SessionId) ->
    erlang_adk_session:delete_session(AppName, UserId, SessionId).

update_state(AppName, UserId, SessionId, Delta) ->
    case persistent_term:get({?MODULE, SessionId}, pass) of
        pass ->
            erlang_adk_session:update_state(
              AppName, UserId, SessionId, Delta);
        {error, Reason} ->
            {error, Reason};
        {invalid, Reply} ->
            Reply;
        {raise, Reason} ->
            erlang:error(Reason)
    end.

add_event(AppName, UserId, SessionId, Event) ->
    erlang_adk_session:add_event(AppName, UserId, SessionId, Event).

clear_temp_state(AppName, UserId, SessionId) ->
    erlang_adk_session:clear_temp_state(AppName, UserId, SessionId).

take_state(AppName, UserId, SessionId, Key) ->
    erlang_adk_session:take_state(AppName, UserId, SessionId, Key).

add_event_if_state(AppName, UserId, SessionId, Key, Expected, Event) ->
    erlang_adk_session:add_event_if_state(
      AppName, UserId, SessionId, Key, Expected, Event).
