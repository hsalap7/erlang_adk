%% @doc adk_runner - Event and session execution orchestrator.
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
    artifact_svc :: module() | undefined,
    run_timeout  :: timeout()
}).

-define(DEFAULT_RUN_TIMEOUT, 120000).
-define(PAUSE_STATE_KEY, <<"temp:__adk_runner_pause">>).

-type runner() :: #runner{}.
-export_type([runner/0]).

%% @doc Create a new Runner with required services.
-spec new(Agent :: pid() | module(), AppName :: binary(), SessionSvc :: module()) -> runner().
new(Agent, AppName, SessionSvc) ->
    new(Agent, AppName, SessionSvc, #{}).

%% @doc Create a new Runner with optional services and run_timeout.
-spec new(Agent :: pid() | module(), AppName :: binary(), SessionSvc :: module(), Opts :: map()) -> runner().
new(Agent, AppName, SessionSvc, Opts) ->
    RunTimeout = maps:get(run_timeout, Opts, ?DEFAULT_RUN_TIMEOUT),
    ok = validate_run_timeout(RunTimeout),
    #runner{
        agent = Agent,
        app_name = AppName,
        session_svc = SessionSvc,
        memory_svc = maps:get(memory_svc, Opts, undefined),
        artifact_svc = maps:get(artifact_svc, Opts, undefined),
        run_timeout = RunTimeout
    }.

%% @doc Execute the agent synchronously, returning only after a terminal message.
-spec run(Runner :: runner(), UserId :: binary(), SessionId :: binary(), Message :: term()) ->
    {ok, binary()} | {paused, adk_event:event()} | {error, term()}.
run(Runner, UserId, SessionId, Message) ->
    {ok, StreamPid} = run_async(Runner, UserId, SessionId, Message),
    MonitorRef = erlang:monitor(process, StreamPid),
    Deadline = deadline(Runner#runner.run_timeout),
    Result = collect_events(StreamPid, MonitorRef, <<>>, Deadline),
    case Result of
        {error, _} -> safe_clear_temp_state(Runner, UserId, SessionId);
        _ -> ok
    end,
    Result.

%% @doc Execute the agent asynchronously. The worker emits adk_event messages and
%% exactly one terminal adk_done, adk_paused, or adk_error message.
-spec run_async(Runner :: runner(), UserId :: binary(), SessionId :: binary(), Message :: term()) ->
    {ok, pid()}.
run_async(Runner, UserId, SessionId, Message) ->
    Caller = self(),
    StreamPid = proc_lib:spawn(fun() ->
        run_invocation(Runner, UserId, SessionId, Message, Caller)
    end),
    {ok, StreamPid}.

%% @doc Resume a paused workflow with a human-provided result. The original
%% invocation ID, tool name, and thought signature are retained.
-spec resume(Runner :: runner(), UserId :: binary(), SessionId :: binary(), ToolResponse :: term()) ->
    {ok, pid()} | {error, term()}.
resume(Runner, UserId, SessionId, ToolResponse) ->
    %% Resolve and validate immutable runtime metadata before consuming the
    %% single-use continuation. A busy or unavailable agent therefore cannot
    %% destroy an otherwise resumable approval.
    case fetch_runtime(Runner) of
        {ok, Runtime} ->
            case claim_pause_state(Runner, UserId, SessionId) of
                {ok, PauseState} ->
                    case validate_pause_state(PauseState) of
                        ok ->
                            Caller = self(),
                            StreamPid = proc_lib:spawn(fun() ->
                                resume_with_runtime(
                                  Runner, UserId, SessionId, ToolResponse,
                                  PauseState, Caller, Runtime)
                            end),
                            {ok, StreamPid};
                        {error, _} = Error ->
                            restore_pause_state(
                              Runner, UserId, SessionId, PauseState),
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Internal Functions

%% @private Collect streamed events until a terminal message, using one absolute
%% deadline for the complete invocation rather than resetting per event.
collect_events(StreamPid, MonitorRef, Acc, Deadline) ->
    Remaining = remaining_timeout(Deadline),
    receive
        {adk_event, StreamPid, Event} ->
            Content = Event#adk_event.content,
            case Event#adk_event.author of
                <<"user">> ->
                    collect_events(StreamPid, MonitorRef, Acc, Deadline);
                <<"tool">> ->
                    collect_events(StreamPid, MonitorRef, Acc, Deadline);
                _AgentName ->
                    NewAcc = append_text(Acc, Content),
                    %% Do not return on the final event. adk_done is the terminal
                    %% acknowledgement and consuming it prevents mailbox debris.
                    collect_events(StreamPid, MonitorRef, NewAcc, Deadline)
            end;
        {adk_done, StreamPid} ->
            erlang:demonitor(MonitorRef, [flush]),
            {ok, Acc};
        {adk_paused, StreamPid, PauseEvent} ->
            erlang:demonitor(MonitorRef, [flush]),
            {paused, PauseEvent};
        {adk_error, StreamPid, Reason} ->
            erlang:demonitor(MonitorRef, [flush]),
            {error, Reason};
        {'DOWN', MonitorRef, process, StreamPid, normal} ->
            {error, stream_ended_without_terminal_message};
        {'DOWN', MonitorRef, process, StreamPid, Reason} ->
            {error, {stream_process_down, Reason}}
    after Remaining ->
        exit(StreamPid, kill),
        erlang:demonitor(MonitorRef, [flush]),
        {error, timeout}
    end.

append_text(Acc, Content) when is_binary(Content) ->
    <<Acc/binary, Content/binary>>;
append_text(Acc, Content) when is_list(Content) ->
    ContentBin = unicode:characters_to_binary(Content),
    <<Acc/binary, ContentBin/binary>>;
append_text(Acc, _Content) ->
    Acc.

run_invocation(Runner, UserId, SessionId, Message, Caller) ->
    case fetch_runtime(Runner) of
        {ok, Runtime} ->
            try
                ok = ensure_session(Runner, UserId, SessionId),
                InvId = generate_invocation_id(),
                UserEvent = adk_event:new(<<"user">>, Message,
                                          #{invocation_id => InvId}),
                SessionSvc = Runner#runner.session_svc,
                ok = SessionSvc:add_event(Runner#runner.app_name, UserId,
                                          SessionId, UserEvent),
                Caller ! {adk_event, self(), UserEvent},
                start_agent_lifecycle(Runner, UserId, SessionId, InvId,
                                      Message, Caller, Runtime)
            catch
                E:R:S ->
                    logger:error("Runner Async Error: ~p:~p~n~p", [E, R, S]),
                    finish_error(Runner, UserId, SessionId, R, Caller, Runtime)
            end;
        {error, Reason} ->
            safe_clear_temp_state(Runner, UserId, SessionId),
            Caller ! {adk_error, self(), Reason}
    end.

start_agent_lifecycle(Runner, UserId, SessionId, InvId,
                      Message, Caller, Runtime) ->
    Handlers = runtime_handlers(Runtime),
    AgentName = maps:get(name, Runtime),
    AgentNameBin = maps:get(name_binary, Runtime),
    adk_callbacks:execute(Handlers, on_agent_start, [AgentNameBin, Message]),
    case adk_callbacks:run(Handlers, before_agent, [AgentName, Message]) of
        {halt, Value} ->
            FinalEvent = adk_event:new(AgentNameBin, Value,
                                       #{invocation_id => InvId, is_final => true}),
            finish_final(Runner, UserId, SessionId, FinalEvent, Caller, Runtime);
        {replace, Value} ->
            FinalEvent = adk_event:new(AgentNameBin, Value,
                                       #{invocation_id => InvId, is_final => true}),
            finish_final(Runner, UserId, SessionId, FinalEvent, Caller, Runtime);
        _ ->
            run_loop(Runner, UserId, SessionId, InvId, Caller, Runtime)
    end.

fetch_runtime(Runner) ->
    try adk_agent:get_runtime(Runner#runner.agent) of
        {ok, Name, Config, Tools, SubAgents}
          when is_map(Config), is_list(Tools), is_map(SubAgents) ->
            Handlers = maps:get(callbacks, Config, []),
            true = is_list(Handlers),
            {ok, #{name => Name,
                   name_binary => to_binary(Name),
                   config => Config,
                   tools => Tools,
                   sub_agents => SubAgents}};
        Other ->
            {error, {invalid_agent_runtime, Other}}
    catch
        Class:Reason ->
            {error, {agent_runtime_unavailable, Class, Reason}}
    end.

runtime_handlers(Runtime) ->
    maps:get(callbacks, maps:get(config, Runtime), []).

%% @private Ensure session exists or create it.
ensure_session(Runner, UserId, SessionId) ->
    SessionSvc = Runner#runner.session_svc,
    case SessionSvc:get_session(Runner#runner.app_name, UserId, SessionId) of
        {ok, _Session} ->
            ok;
        {error, not_found} ->
            case SessionSvc:create_session(Runner#runner.app_name, UserId,
                                           #{session_id => SessionId}) of
                {ok, _Session} -> ok;
                ok -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @private Generate unique invocation ID.
generate_invocation_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("inv-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                         [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).

%% @private Core execution loop handling agent interaction.
run_loop(Runner, UserId, SessionId, InvId, Caller, Runtime) ->
    SessionSvc = Runner#runner.session_svc,
    {ok, Session} = SessionSvc:get_session(Runner#runner.app_name, UserId, SessionId),
    History = maps:get(events, Session, []),
    case adk_agent:run_with_events(Runner#runner.agent, History, InvId) of
        {ok, FinalEvent} ->
            finish_final(Runner, UserId, SessionId, FinalEvent, Caller, Runtime);
        {tool_calls, AgentEvent, Calls} ->
            ok = SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, AgentEvent),
            Caller ! {adk_event, self(), AgentEvent},
            case execute_runner_tools(Runner, UserId, SessionId, InvId, Caller,
                                      Calls, Runtime) of
                ok ->
                    run_loop(Runner, UserId, SessionId, InvId, Caller, Runtime);
                {paused, _PauseEvent} ->
                    %% Pauses deliberately preserve invocation temp state.
                    ok
            end;
        {error, Reason} ->
            finish_error(Runner, UserId, SessionId, Reason, Caller, Runtime)
    end.

finish_final(Runner, UserId, SessionId, FinalEvent0, Caller, Runtime) ->
    Handlers = runtime_handlers(Runtime),
    AgentName = maps:get(name, Runtime),
    Content0 = FinalEvent0#adk_event.content,
    Content1 = case adk_callbacks:run(Handlers, after_agent,
                                      [AgentName, Content0]) of
        {replace, Replacement} -> Replacement;
        {halt, Replacement} -> Replacement;
        _ -> Content0
    end,
    Content = runner_text(Content1),
    FinalEvent = FinalEvent0#adk_event{content = Content, is_final = true},
    SessionSvc = Runner#runner.session_svc,
    ok = SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, FinalEvent),
    Caller ! {adk_event, self(), FinalEvent},
    adk_callbacks:execute(Handlers, on_agent_end,
                          [maps:get(name_binary, Runtime), Content]),
    safe_clear_temp_state(Runner, UserId, SessionId),
    Caller ! {adk_done, self()},
    ok.

finish_error(Runner, UserId, SessionId, Reason, Caller, Runtime) ->
    adk_callbacks:execute(runtime_handlers(Runtime), on_error, [Reason]),
    safe_clear_temp_state(Runner, UserId, SessionId),
    Caller ! {adk_error, self(), Reason},
    ok.

%% @private Execute tools in model order. A pause persists the remainder and
%% terminates this invocation worker without reporting an error.
execute_runner_tools(_Runner, _UserId, _SessionId, _InvId, _Caller,
                     [], _Runtime) ->
    ok;
execute_runner_tools(Runner, UserId, SessionId, InvId, Caller,
                     [Call | Rest], Runtime) ->
    {NameBin, ArgsMap, Sig, CallId} = normalize_call(Call),
    Tools = maps:get(tools, Runtime),
    SubAgents = maps:get(sub_agents, Runtime),
    FoundTool = lists:search(
        fun(Mod) ->
            Schema = Mod:schema(),
            maps:get(<<"name">>, Schema, atom_to_binary(Mod, utf8)) == NameBin
        end, Tools),
    Context = tool_context(Runner, UserId, SessionId, InvId, CallId),
    Execution = case FoundTool of
        {value, Mod} ->
            execute_tool_with_callbacks(Mod, NameBin, ArgsMap, Context, Runtime);
        false ->
            execute_sub_agent_with_callbacks(
              NameBin, ArgsMap, Context, SubAgents, Runtime)
    end,
    case Execution of
        {result, Result} ->
            record_tool_response(Runner, UserId, SessionId, InvId, Caller,
                                 NameBin, Result, Sig, CallId),
            execute_runner_tools(Runner, UserId, SessionId, InvId, Caller,
                                 Rest, Runtime);
        {pause, Reason, Summary} ->
            pause_invocation(Runner, UserId, SessionId, InvId, Caller,
                             NameBin, ArgsMap, Sig, CallId, Rest, Reason, Summary)
    end.

normalize_call({Name, Args}) -> {Name, Args, undefined, undefined};
normalize_call({Name, Args, Sig}) -> {Name, Args, Sig, undefined};
normalize_call({Name, Args, Sig, CallId}) -> {Name, Args, Sig, CallId}.

execute_tool_with_callbacks(Mod, NameBin, ArgsMap, Context, Runtime) ->
    Handlers = runtime_handlers(Runtime),
    adk_callbacks:execute(Handlers, on_tool_start, [NameBin, ArgsMap]),
    RawResult = case adk_callbacks:run(Handlers, before_tool,
                                       [NameBin, ArgsMap, Context]) of
        {halt, Replacement} -> {ok, Replacement};
        {replace, Replacement} -> {ok, Replacement};
        _ ->
            try Mod:execute(ArgsMap, Context) of
                ToolResult -> ToolResult
            catch
                throw:{adk_pause, _, _} = Pause -> Pause;
                Class:ToolError:Stack ->
                    logger:error("Runner tool ~p failed: ~p:~p~n~p",
                                 [NameBin, Class, ToolError, Stack]),
                    {error, {Class, ToolError}}
            end
    end,
    case RawResult of
        {adk_pause, PauseReason, Summary} ->
            %% after_tool/on_tool_end run when the correlated human response
            %% completes this suspended tool call.
            {pause, PauseReason, Summary};
        _ ->
            FinalResult = apply_after_tool(Handlers, NameBin, ArgsMap,
                                           Context, RawResult),
            adk_callbacks:execute(Handlers, on_tool_end,
                                  [NameBin, FinalResult]),
            normalize_tool_execution(FinalResult)
    end.

apply_after_tool(Handlers, NameBin, ArgsMap, Context, RawResult) ->
    case adk_callbacks:run(Handlers, after_tool,
                           [NameBin, ArgsMap, Context, RawResult]) of
        {replace, Replacement} -> {ok, Replacement};
        {halt, Replacement} -> {ok, Replacement};
        _ -> RawResult
    end.

normalize_tool_execution({ok, Result}) ->
    {result, #{<<"success">> => true,
               <<"result">> => adk_agent:format_result(Result)}};
normalize_tool_execution({error, Reason}) ->
    {result, #{<<"success">> => false,
               <<"error">> => adk_agent:format_result(Reason)}};
normalize_tool_execution({'EXIT', Reason}) ->
    {result, #{<<"success">> => false,
               <<"error">> => adk_agent:format_result(Reason)}};
normalize_tool_execution({adk_pause, Reason, Summary}) ->
    {pause, Reason, Summary};
normalize_tool_execution(Other) ->
    {result, #{<<"success">> => false,
               <<"error">> => adk_agent:format_result({invalid_tool_result, Other})}}.

execute_sub_agent_with_callbacks(NameBin, ArgsMap, Context,
                                 SubAgents, Runtime) ->
    Handlers = runtime_handlers(Runtime),
    adk_callbacks:execute(Handlers, on_tool_start, [NameBin, ArgsMap]),
    RawResult = case adk_callbacks:run(Handlers, before_tool,
                                       [NameBin, ArgsMap, Context]) of
        {halt, Replacement} -> {ok, Replacement};
        {replace, Replacement} -> {ok, Replacement};
        _ -> execute_sub_agent(NameBin, ArgsMap, SubAgents)
    end,
    FinalResult = apply_after_tool(Handlers, NameBin, ArgsMap,
                                   Context, RawResult),
    adk_callbacks:execute(Handlers, on_tool_end,
                          [NameBin, FinalResult]),
    normalize_tool_execution(FinalResult).

execute_sub_agent(NameBin, ArgsMap, SubAgents) ->
    case maps:find(NameBin, SubAgents) of
        {ok, SubSpec} ->
            SubPrompt = maps:get(<<"prompt">>, ArgsMap, <<>>),
            case resolve_sub_agent(NameBin, SubSpec) of
                {ok, SubPid} ->
                    case safe_sub_agent_prompt(SubPid, SubPrompt) of
                        {ok, SubResult} -> {ok, SubResult};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                error ->
                    {error, invalid_sub_agent_configuration}
            end;
        error ->
            {error, tool_not_found}
    end.

tool_context(Runner, UserId, SessionId, InvId, CallId) ->
    #{app_name => Runner#runner.app_name,
      session_id => SessionId,
      user_id => UserId,
      invocation_id => InvId,
      call_id => CallId,
      state_ref => Runner#runner.session_svc}.

resolve_sub_agent(Name, #{pid := Pid}) ->
    resolve_sub_agent(Name, Pid);
resolve_sub_agent(Name, Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> {ok, Pid};
        false -> lookup_sub_agent(Name)
    end;
resolve_sub_agent(Name, _StaleRef) ->
    lookup_sub_agent(Name).

lookup_sub_agent(Name) ->
    try adk_agent_registry:lookup(Name) of
        {ok, Pid} -> {ok, Pid};
        {error, not_found} -> error
    catch
        _:_ -> error
    end.

safe_sub_agent_prompt(SubPid, Prompt) ->
    try adk_agent:prompt(SubPid, Prompt) of
        Result -> Result
    catch
        Class:Reason -> {error, {sub_agent_unavailable, Class, Reason}}
    end.

%% @private Persist a continuation and notify the caller with a distinct pause.
pause_invocation(Runner, UserId, SessionId, InvId, Caller,
                 NameBin, ArgsMap, Sig, CallId, Rest, Reason, Summary) ->
    PauseState = #{
        <<"invocation_id">> => InvId,
        <<"tool_name">> => NameBin,
        <<"tool_args">> => ArgsMap,
        <<"thought_signature">> => Sig,
        <<"call_id">> => CallId,
        <<"remaining_calls">> => Rest,
        <<"reason">> => Reason,
        <<"summary">> => Summary
    },
    PublicPause = #{
        <<"tool_name">> => NameBin,
        <<"tool_args">> => ArgsMap,
        <<"thought_signature">> => Sig,
        <<"call_id">> => CallId,
        <<"reason">> => format_term(Reason),
        <<"summary">> => Summary
    },
    PauseEvent = adk_event:new(<<"runner">>, Summary, #{
        invocation_id => InvId,
        %% Session backends apply an event's state_delta in the same critical
        %% section/transaction as the event append. This keeps the observable
        %% pause and its resumable continuation atomic.
        actions => #{<<"pause">> => PublicPause,
                     <<"state_delta">> => #{?PAUSE_STATE_KEY => PauseState}}
    }),
    SessionSvc = Runner#runner.session_svc,
    ok = SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, PauseEvent),
    Caller ! {adk_event, self(), PauseEvent},
    Caller ! {adk_paused, self(), PauseEvent},
    {paused, PauseEvent}.

resume_with_runtime(Runner, UserId, SessionId, ToolResponse,
                    PauseState, Caller, Runtime) ->
    try
        InvId = maps:get(<<"invocation_id">>, PauseState),
        NameBin = maps:get(<<"tool_name">>, PauseState),
        ArgsMap = maps:get(<<"tool_args">>, PauseState, #{}),
        Sig = maps:get(<<"thought_signature">>, PauseState, undefined),
        CallId = maps:get(<<"call_id">>, PauseState, undefined),
        Rest = maps:get(<<"remaining_calls">>, PauseState, []),
        Context = tool_context(Runner, UserId, SessionId, InvId, CallId),
        Result = complete_resumed_tool(NameBin, ArgsMap, Context,
                                       ToolResponse, Runtime),
        record_tool_response(Runner, UserId, SessionId, InvId, Caller,
                             NameBin, Result, Sig, CallId),
        case execute_runner_tools(Runner, UserId, SessionId, InvId, Caller,
                                  Rest, Runtime) of
            ok -> run_loop(Runner, UserId, SessionId, InvId, Caller, Runtime);
            {paused, _PauseEvent} -> ok
        end
    catch
        E:R:S ->
            logger:error("Runner Resume Error: ~p:~p~n~p", [E, R, S]),
            finish_error(Runner, UserId, SessionId, R, Caller, Runtime)
    end.

complete_resumed_tool(NameBin, ArgsMap, Context, ToolResponse, Runtime) ->
    Handlers = runtime_handlers(Runtime),
    RawResult = {ok, ToolResponse},
    FinalResult = apply_after_tool(Handlers, NameBin, ArgsMap,
                                   Context, RawResult),
    adk_callbacks:execute(Handlers, on_tool_end, [NameBin, FinalResult]),
    {result, Result} = normalize_tool_execution(FinalResult),
    Result.

record_tool_response(Runner, UserId, SessionId, InvId, Caller,
                     NameBin, Result, Sig, CallId) ->
    Content = case CallId of
        undefined -> {tool_response, NameBin, Result, Sig};
        _ -> {tool_response, NameBin, Result, Sig, CallId}
    end,
    ToolEvent = adk_event:new(<<"tool">>, Content, #{invocation_id => InvId}),
    SessionSvc = Runner#runner.session_svc,
    ok = SessionSvc:add_event(Runner#runner.app_name, UserId, SessionId, ToolEvent),
    Caller ! {adk_event, self(), ToolEvent},
    ok.

%% Atomically consume the continuation. Both missing sessions and absent keys
%% map to the public no_paused_invocation result.
claim_pause_state(Runner, UserId, SessionId) ->
    SessionSvc = Runner#runner.session_svc,
    case SessionSvc:take_state(Runner#runner.app_name, UserId, SessionId,
                               ?PAUSE_STATE_KEY) of
        {ok, PauseState} when is_map(PauseState) -> {ok, PauseState};
        {ok, _MalformedState} -> {error, invalid_pause_state};
        {error, not_found} -> {error, no_paused_invocation};
        {error, _} = Error -> Error
    end.

validate_pause_state(PauseState) ->
    case PauseState of
        #{<<"invocation_id">> := InvId,
          <<"tool_name">> := Name,
          <<"tool_args">> := Args,
          <<"remaining_calls">> := Rest}
          when is_binary(InvId), is_binary(Name), is_map(Args), is_list(Rest) ->
            ok;
        _ ->
            {error, invalid_pause_state}
    end.

restore_pause_state(Runner, UserId, SessionId, PauseState) ->
    SessionSvc = Runner#runner.session_svc,
    _ = SessionSvc:update_state(Runner#runner.app_name, UserId, SessionId,
                                #{?PAUSE_STATE_KEY => PauseState}),
    ok.

%% Temp state belongs to the invocation. It is cleared at final/error terminals,
%% but intentionally retained when an invocation pauses.
safe_clear_temp_state(Runner, UserId, SessionId) ->
    SessionSvc = Runner#runner.session_svc,
    try SessionSvc:clear_temp_state(Runner#runner.app_name, UserId, SessionId) of
        _ -> ok
    catch
        error:undef -> ok;
        E:R:S ->
            logger:error("Failed to clear runner temp state: ~p:~p~n~p", [E, R, S]),
            ok
    end.

format_term(Value) when is_binary(Value) -> Value;
format_term(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
format_term(Value) -> unicode:characters_to_binary(io_lib:format("~p", [Value])).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) -> format_term(Value).

runner_text(Value) when is_binary(Value) -> Value;
runner_text(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
runner_text(Value) -> format_term(Value).

validate_run_timeout(infinity) -> ok;
validate_run_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 -> ok;
validate_run_timeout(Timeout) -> erlang:error({invalid_run_timeout, Timeout}).

deadline(infinity) -> infinity;
deadline(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout.

remaining_timeout(infinity) -> infinity;
remaining_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
