%% @doc adk_runner - Execution orchestrator for ADK 2.0.
%%
%% The Runner manages the event loop for an agent, handling session retrieval,
%% event recording, tool execution, and streaming responses back to the caller.
-module(adk_runner).
-include("../include/adk_event.hrl").

-export([new/3, new/4, run/4, run_async/4, resume/4]).

-record(runner, {
    agent        :: pid() | module(),
    app_name     :: binary(),
    session_svc  :: module(),
    memory_svc   :: module() | undefined,
    artifact_svc :: module() | undefined
}).

-type runner() :: #runner{}.
-export_type([runner/0]).

%% @doc Create a new Runner with required services.
-spec new(Agent :: pid() | module(), AppName :: binary(), SessionSvc :: module()) -> runner().
new(Agent, AppName, SessionSvc) ->
    new(Agent, AppName, SessionSvc, #{}).

%% @doc Create a new Runner with optional services (memory_svc, artifact_svc).
-spec new(Agent :: pid() | module(), AppName :: binary(), SessionSvc :: module(), Opts :: map()) -> runner().
new(Agent, AppName, SessionSvc, Opts) ->
    #runner{
        agent = Agent,
        app_name = AppName,
        session_svc = SessionSvc,
        memory_svc = maps:get(memory_svc, Opts, undefined),
        artifact_svc = maps:get(artifact_svc, Opts, undefined)
    }.

%% @doc Execute the agent synchronously, returning the final response text.
%% This blocks until the entire invocation is complete.
-spec run(Runner :: runner(), UserId :: binary(), SessionId :: binary(), Message :: term()) -> {ok, binary()} | {error, term()}.
run(Runner, UserId, SessionId, Message) ->
    {ok, StreamPid} = run_async(Runner, UserId, SessionId, Message),
    collect_events(StreamPid, <<>>).

%% @doc Execute the agent asynchronously, returning a process ID that streams events.
%% The returned PID will send '{adk_event, StreamPid, Event}' and '{adk_done, StreamPid}' messages.
-spec run_async(Runner :: runner(), UserId :: binary(), SessionId :: binary(), Message :: term()) -> {ok, pid()}.
run_async(Runner, UserId, SessionId, Message) ->
    Caller = self(),
    StreamPid = spawn(fun() ->
        try
            %% 1. Ensure session exists
            ensure_session(Runner, UserId, SessionId),
            
            %% 2. Generate invocation ID
            InvId = generate_invocation_id(),
            
            %% 3. Record User message as Event
            UserEvent = adk_event:new(<<"user">>, Message, #{invocation_id => InvId}),
            SessionSvc = Runner#runner.session_svc,
            SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, UserEvent),
            
            %% Send user event to caller
            Caller ! {adk_event, self(), UserEvent},
            
            %% 4. Start internal event loop
            run_loop(Runner, UserId, SessionId, InvId, Caller)
        catch
            E:R:S ->
                io:format("Runner Async Error: ~p:~p~n~p~n", [E, R, S]),
                Caller ! {adk_error, self(), R}
        end
    end),
    {ok, StreamPid}.

%% @doc Resume a paused workflow (Human-in-the-Loop) with a human-provided result.
-spec resume(Runner :: runner(), UserId :: binary(), SessionId :: binary(), ToolResponse :: term()) -> {ok, pid()} | {error, term()}.
resume(Runner, UserId, SessionId, ToolResponse) ->
    %% For HITL resume, we inject the tool response and re-start the loop.
    Caller = self(),
    StreamPid = spawn(fun() ->
        try
            %% Determine InvId from previous state (omitted for brevity, assume new one or loaded)
            InvId = generate_invocation_id(),
            
            %% Record tool response event
            RespEvent = adk_event:new(<<"tool">>, ToolResponse, #{invocation_id => InvId}),
            SessionSvc = Runner#runner.session_svc,
            SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, RespEvent),
            
            Caller ! {adk_event, self(), RespEvent},
            
            run_loop(Runner, UserId, SessionId, InvId, Caller)
        catch
            _E:R:_S ->
                Caller ! {adk_error, self(), R}
        end
    end),
    {ok, StreamPid}.

%% Internal Functions

%% @private Collect streamed events for sync run.
collect_events(StreamPid, Acc) ->
    receive
        {adk_event, StreamPid, Event} ->
            Content = Event#adk_event.content,
            case Event#adk_event.author of
                <<"user">> -> collect_events(StreamPid, Acc);
                <<"tool">> -> collect_events(StreamPid, Acc);
                _AgentName ->
                    %% Only collect agent text responses
                    NewAcc = if
                        is_binary(Content) -> <<Acc/binary, Content/binary>>;
                        is_list(Content) -> <<Acc/binary, (list_to_binary(Content))/binary>>;
                        true -> Acc
                    end,
                    case adk_event:is_final_response(Event) of
                        true -> {ok, NewAcc};
                        false -> collect_events(StreamPid, NewAcc)
                    end
            end;
        {adk_done, StreamPid} ->
            {ok, Acc};
        {adk_error, StreamPid, Reason} ->
            {error, Reason}
    end.

%% @private Ensure session exists or create it.
ensure_session(Runner, UserId, SessionId) ->
    SessionSvc = Runner#runner.session_svc,
    case SessionSvc:get_session(Runner#runner.app_name, UserId, SessionId) of
        {ok, _Session} -> ok;
        {error, not_found} ->
            SessionSvc:create_session(Runner#runner.app_name, UserId, #{session_id => SessionId})
    end.

%% @private Generate unique invocation ID.
generate_invocation_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("inv-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).

%% @private Core execution loop handling agent interaction.
run_loop(Runner, UserId, SessionId, InvId, Caller) ->
    %% 1. Get current session state and history
    SessionSvc = Runner#runner.session_svc,
    {ok, Session} = SessionSvc:get_session(Runner#runner.app_name, UserId, SessionId),
    History = maps:get(events, Session, []),
    
    %% 2. Prompt Agent (Integration point with legacy adk_agent logic for now)
    %% Note: adk_agent will be modified to understand events, but for now we bridge.
    %% This is a simplified bridging mechanism. Real integration will use proper message passing with adk_agent.
    case adk_agent:run_with_events(Runner#runner.agent, History, InvId) of
        {ok, FinalEvent} ->
            SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, FinalEvent),
            Caller ! {adk_event, self(), FinalEvent},
            Caller ! {adk_done, self()};
        {tool_calls, AgentEvent, _ToolCalls} ->
            %% Record Agent's tool call decision
            SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, AgentEvent),
            Caller ! {adk_event, self(), AgentEvent},
            
            %% Execute tools (pseudo-code, delegated to tool runner)
            %% For each tool, we generate a tool response event, save to session, send to caller, and loop.
            %% Tool execution skipped here for brevity, assuming dummy result for now to break loop
            
            %% Loop back
            run_loop(Runner, UserId, SessionId, InvId, Caller);
        {error, Reason} ->
            Caller ! {adk_error, self(), Reason}
    end.
