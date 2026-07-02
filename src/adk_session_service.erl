%% @doc adk_session_service - Behaviour for ADK session persistence.
%%
%% Session services store conversations, memory, and state for agents.
-module(adk_session_service).

-type session() :: map().
-type session_meta() :: map().

-export_type([session/0, session_meta/0]).

-callback create_session(AppName :: binary(), UserId :: binary(), Opts :: map()) -> {ok, session()} | {error, term()}.
-callback get_session(AppName :: binary(), UserId :: binary(), SessionId :: binary()) -> {ok, session()} | {error, not_found}.
-callback list_sessions(AppName :: binary(), UserId :: binary()) -> {ok, [session_meta()]}.
-callback delete_session(AppName :: binary(), UserId :: binary(), SessionId :: binary()) -> ok.
-callback update_state(AppName :: binary(), UserId :: binary(), SessionId :: binary(), StateDelta :: map()) -> ok.
-callback add_event(AppName :: binary(), UserId :: binary(), SessionId :: binary(), Event :: adk_event:event()) -> ok.
