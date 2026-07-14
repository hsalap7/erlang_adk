-module(adk_agent).
-behaviour(gen_server).

-export([start_link/1, start_link/3, stop/1, prompt/2, prompt/3, invoke/3,
         delegate/2, delegate/3, delegate/4,
         run_with_events/3, run_with_events/4,
         stream_with_events/6,
         finalize_output/3, get_tools/1, get_runtime/1, format_result/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {
    name :: string(),
    llm_config :: map(),
    tools :: [module() | adk_toolset:descriptor()],
    session_id :: term(),
    session_store :: module(),
    memory :: list(),
    sub_agents :: map(),
    agent_spec :: adk_agent_spec:spec(),
    config_ref = undefined :: undefined | binary(),
    turn_timeout = infinity :: infinity | non_neg_integer(),
    max_concurrent_invocations = 32 :: pos_integer(),
    pending = undefined :: undefined | queue:queue(map()),
    active = undefined :: undefined | map(),
    lane_pending = #{} :: map(),
    lane_active = #{} :: map(),
    ready_lanes = undefined :: undefined | queue:queue(term()),
    ready_lane_set = #{} :: map()
}).

-define(DEFAULT_CALL_TIMEOUT, 60000).
-define(DEFAULT_TURN_TIMEOUT, 60000).
-define(DEFAULT_MAX_CONCURRENT_INVOCATIONS, 32).
-define(MAX_DELEGATION_DEPTH, 64).
-define(DEFAULT_MAX_STREAM_OUTPUT_BYTES, 16777216).
-define(MAX_STREAM_OUTPUT_BYTES_CEILING, 67108864).

%% API
%% Production starts use only this opaque argument so supervisor reports never
%% retain the provider config, credentials, tools, or agent name in child MFA.
start_link(ConfigRef) when is_binary(ConfigRef) ->
    case adk_agent_config_store:get_for_start(ConfigRef) of
        {ok, Name, LLMConfig, Tools} ->
            case gen_server:start_link(
                   {via, adk_agent_registry, Name}, ?MODULE,
                   [{stored_config, ConfigRef, Name, LLMConfig, Tools}], []) of
                {ok, Pid} = Started ->
                    case adk_agent_config_store:claim(ConfigRef, Pid) of
                        ok -> Started;
                        {error, Reason} ->
                            _ = catch gen_server:stop(Pid, normal, 5000),
                            {error, adk_failure:external(
                                      agent, config_claim, Reason)}
                    end;
                {error, _Reason} = Error -> Error;
                ignore -> ignore
            end;
        {error, _Reason} = Error -> Error
    end.

%% Kept for direct embedding/backward compatibility. The supervised public
%% erlang_adk:spawn_agent/3 path always uses start_link/1 above.
start_link(Name, LLMConfig, Tools) ->
    gen_server:start_link({via, adk_agent_registry, Name}, ?MODULE,
                          [Name, LLMConfig, Tools], []).

stop(Pid) ->
    gen_server:stop(Pid, normal, 5000).

prompt(Pid, Message) ->
    %% Preserve the original gen_server request shape for compatible agent
    %% processes and test doubles which implement only prompt/2.
    gen_server:call(Pid, {prompt, Message}, agent_call_timeout()).

%% @doc Prompt with an invocation-scoped context. This is used by the
%% delegation runtime to carry a root global_instruction across process
%% boundaries; callers should normally use prompt/2.
prompt(Pid, Message, Context) when is_map(Context) ->
    gen_server:call(Pid, {prompt, Message, Context}, agent_call_timeout()).

%% @doc Run one invocation-scoped prompt without reading or mutating the
%% compatibility prompt history stored by the agent process. Runner sessions,
%% AgentTool calls, and collaboration branches must use this entry point so a
%% reusable agent specification cannot leak conversation history between
%% users or sessions.
-spec invoke(pid(), term(), map()) -> {ok, term()} | {error, term()}.
invoke(Pid, Message, Context) when is_pid(Pid), is_map(Context) ->
    gen_server:call(Pid, {invoke, Message, Context}, agent_call_timeout()).

delegate(Pid, Message) ->
    gen_server:cast(Pid, {delegate, Message, undefined}).

delegate(Pid, Message, ReplyToPid) ->
    gen_server:cast(Pid, {delegate, Message, ReplyToPid}).

%% @doc Delegate with an explicit caller-supplied correlation reference.
delegate(Pid, Message, ReplyToPid, Ref) ->
    gen_server:cast(Pid, {delegate, Message, {ReplyToPid, Ref}}).

%% @doc Run the agent using the new Event-based architecture.
run_with_events(Pid, HistoryEvents, InvocationId) ->
    gen_server:call(Pid,
                    {run_with_events, HistoryEvents, InvocationId},
                    ?DEFAULT_CALL_TIMEOUT).

%% @doc Run from event history with a sanitized invocation context used by
%% dynamic instructions, state templates, and exact-scope artifact templates.
-spec run_with_events(pid(), [adk_event:event()], binary(), map()) ->
    {ok, adk_event:event()}
    | {tool_calls, adk_event:event(), list()}
    | {error, term()}.
run_with_events(Pid, HistoryEvents, InvocationId, Context) when is_map(Context) ->
    gen_server:call(Pid,
                    {run_with_events, HistoryEvents, InvocationId, Context},
                    agent_call_timeout()).

%% @doc Prepare briefly in the agent mailbox, then execute provider streaming
%% in the independently supervised Runner invocation process. EventCallback is
%% synchronous and receives correlated partial events in provider order.
-spec stream_with_events(
        pid(), [adk_event:event()], binary(), map(), text | content,
        fun((adk_event:event()) ->
                ok | {ok, adk_event:event()} | {error, term()})) ->
    {ok, adk_event:event()}
    | {tool_calls, adk_event:event(), list()}
    | {error, term()}.
stream_with_events(Pid, HistoryEvents, InvocationId, Context, Mode,
                   EventCallback)
  when is_map(Context),
       (Mode =:= text orelse Mode =:= content),
       is_function(EventCallback, 1) ->
    case gen_server:call(
           Pid, {prepare_stream, HistoryEvents, InvocationId, Context},
           agent_call_timeout()) of
        {ok, Prepared} ->
            execute_prepared_stream(
              Pid, InvocationId, Prepared, Mode, EventCallback);
        {error, _} = Error -> Error
    end;
stream_with_events(_Pid, _HistoryEvents, _InvocationId, _Context,
                   Mode, _EventCallback) ->
    {error, {invalid_stream_mode, Mode}}.

%% @doc Apply the immutable output contract without committing any state. The
%% Runner uses this after global callbacks so a replacement cannot bypass the
%% output schema or leave an output_key delta inconsistent with the event.
-spec finalize_output(pid(), term(), binary()) ->
    {ok, adk_event:event()} | {error, term()}.
finalize_output(Pid, Output, InvocationId) ->
    gen_server:call(Pid, {finalize_output, Output, InvocationId},
                    agent_call_timeout()).

%% @doc Get the tools and sub-agents registered with this agent.
-spec get_tools(Pid :: pid()) ->
    {ok, [module() | adk_toolset:descriptor()], map()}.
get_tools(Pid) ->
    gen_server:call(Pid, get_tools, 5000).

%% @doc Return the immutable runtime configuration needed by Runner lifecycle
%% hooks. Kept separate from get_tools/1 for backward compatibility.
get_runtime(Pid) ->
    gen_server:call(Pid, get_runtime, 5000).

agent_call_timeout() ->
    case application:get_env(erlang_adk, agent_call_timeout,
                             ?DEFAULT_CALL_TIMEOUT) of
        infinity -> infinity;
        Timeout when is_integer(Timeout), Timeout >= 0 -> Timeout;
        Invalid -> erlang:error({invalid_agent_call_timeout, Invalid})
    end.

%% Gen Server Callbacks
init([{stored_config, ConfigRef, Name, LLMConfig, Tools}]) ->
    init_agent(Name, LLMConfig, Tools, ConfigRef);
init([Name, LLMConfig, Tools]) ->
    init_agent(Name, LLMConfig, Tools, undefined).

init_agent(Name, LLMConfig, Tools, ConfigRef) ->
    case resolve_turn_timeout(LLMConfig) of
        {ok, TurnTimeout} ->
            case resolve_max_concurrent_invocations(LLMConfig) of
                {ok, MaxConcurrentInvocations} ->
                    init_agent_with_timeout(
                      Name, LLMConfig, Tools, ConfigRef, TurnTimeout,
                      MaxConcurrentInvocations);
                {error, Reason} ->
                    {stop, {invalid_max_concurrent_invocations, Reason}}
            end;
        {error, Reason} ->
            {stop, {invalid_agent_turn_timeout, Reason}}
    end.

init_agent_with_timeout(Name, LLMConfig, Tools, ConfigRef, TurnTimeout,
                        MaxConcurrentInvocations) ->
    case adk_llm:capabilities(LLMConfig) of
        {ok, Capabilities} ->
            case adk_agent_spec:from_config(LLMConfig, Capabilities) of
                {ok, AgentSpec} ->
                    case adk_llm:validate_config(LLMConfig) of
                        ok ->
                            init_validated_agent(
                              Name, LLMConfig, Tools, AgentSpec,
                              ConfigRef, TurnTimeout,
                              MaxConcurrentInvocations);
                        {error, Reason} ->
                            {stop, {invalid_llm_config, Reason}}
                    end;
                {error, Reason} ->
                    {stop, {invalid_agent_spec, Reason}}
            end;
        {error, Reason} ->
            {stop, {invalid_llm_config, Reason}}
    end.

init_validated_agent(Name, LLMConfig, Tools, AgentSpec,
                     ConfigRef, TurnTimeout, MaxConcurrentInvocations) ->
    SubAgents = maps:get(sub_agents, LLMConfig, #{}),
    case model_tools(Tools, SubAgents) of
        {ok, _ModelTools} ->
            init_validated_tools(Name, LLMConfig, Tools, AgentSpec,
                                 ConfigRef, TurnTimeout,
                                 MaxConcurrentInvocations);
        {error, Reason} ->
            {stop, {invalid_tools, Reason}}
    end.

init_validated_tools(Name, LLMConfig, Tools, AgentSpec,
                     ConfigRef, TurnTimeout, MaxConcurrentInvocations) ->
    SessionId = maps:get(session_id, LLMConfig, undefined),
    SessionStore = maps:get(session_store, LLMConfig, erlang_adk_session),
    ok = ensure_session_store(SessionStore),
    
    Memory = case SessionId of
        undefined -> adk_memory:new();
        Id -> 
            case SessionStore:load(Id) of
                [] -> adk_memory:new();
                Loaded -> Loaded
            end
    end,
    
    %% A restored legacy session may predate system-message persistence. Always
    %% make sure configured instructions are present, even when history exists.
    Memory1 = ensure_system_instruction(Memory, LLMConfig),
    
    if SessionId =/= undefined -> SessionStore:save(SessionId, Memory1); true -> ok end,

    SubAgents = maps:get(sub_agents, LLMConfig, #{}),
    {ok, #state{name = Name, llm_config = LLMConfig, tools = Tools,
                session_id = SessionId, session_store = SessionStore,
                memory = Memory1, sub_agents = SubAgents,
                agent_spec = AgentSpec, config_ref = ConfigRef,
                turn_timeout = TurnTimeout,
                max_concurrent_invocations = MaxConcurrentInvocations,
                pending = queue:new(), ready_lanes = queue:new()}}.

handle_call({prompt, Message}, From, State) ->
    handle_call({prompt, Message, #{}}, From, State);
handle_call({prompt, Message, InvocationContext}, From, State)
  when is_map(InvocationContext) ->
    Turn = new_sync_turn(prompt, From,
                         #{message => Message,
                           context => InvocationContext}),
    {noreply, enqueue_turn(Turn, State)};

handle_call({invoke, Message, InvocationContext}, From, State)
  when is_map(InvocationContext) ->
    Turn = new_sync_turn(invoke, From,
                         #{message => Message,
                           context => InvocationContext,
                           schedule_key =>
                               invocation_lane(InvocationContext)}),
    {noreply, enqueue_turn(Turn, State)};

handle_call({run_with_events, HistoryEvents, InvocationId}, From, State) ->
    %% The context-free compatibility API stays on the legacy FIFO. Only the
    %% scoped API below is eligible for per-session concurrency.
    Turn = new_sync_turn(
             run_with_events, From,
             #{history_events => HistoryEvents,
               invocation_id => InvocationId,
               context => #{}}),
    {noreply, enqueue_turn(Turn, State)};
handle_call({run_with_events, HistoryEvents, InvocationId, Context},
            From, State) when is_map(Context) ->
    Turn = new_sync_turn(
             run_with_events, From,
             #{history_events => HistoryEvents,
               invocation_id => InvocationId,
               context => Context,
               schedule_key => invocation_lane(Context)}),
    {noreply, enqueue_turn(Turn, State)};

handle_call({prepare_stream, HistoryEvents, _InvocationId, Context},
            _From, State) when is_map(Context) ->
    {reply, prepare_event_model(State, HistoryEvents, Context), State};

handle_call({finalize_output, Output, InvocationId}, _From, State) ->
    {reply, finalize_model_output(State, Output, InvocationId), State};

handle_call(get_tools, _From, State) ->
    {reply, {ok, State#state.tools, State#state.sub_agents}, State};

handle_call(get_runtime, _From, State) ->
    RuntimeConfig = (adk_callback_view:runtime_config(
                       State#state.llm_config))#{
                      '$adk_invocation_context_api' => 1},
    {reply, {ok, State#state.name, RuntimeConfig,
             State#state.tools, State#state.sub_agents}, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({delegate, Message, ReplyToPid}, State) ->
    Turn = #{turn_ref => make_ref(),
             kind => delegate,
             message => Message,
             reply_to => ReplyToPid,
             caller_monitor => undefined},
    {noreply, enqueue_turn(Turn, State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({agent_turn_result, TurnRef, WorkerPid, Result}, State) ->
    case locate_active(TurnRef, WorkerPid, State) of
        legacy -> {noreply, complete_turn(Result, State)};
        {lane, Lane} ->
            {noreply, complete_lane_turn(Lane, Result, State)};
        not_found -> {noreply, State}
    end;
handle_info({agent_turn_failure, TurnRef, WorkerPid, Failure}, State) ->
    Reason = turn_failure_reason(Failure),
    case locate_active(TurnRef, WorkerPid, State) of
        legacy -> {noreply, fail_turn(Reason, State)};
        {lane, Lane} -> {noreply, fail_lane_turn(Lane, Reason, State)};
        not_found -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _Pid, Reason}, State) ->
    {noreply, handle_turn_down(Monitor, Reason, State)};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    cancel_active_worker(State#state.active),
    cancel_lane_workers(State#state.lane_active),
    demonitor_pending(State#state.pending),
    demonitor_lane_pending(State#state.lane_pending),
    maybe_delete_config_ref(Reason, State#state.config_ref),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Provider config, queued messages, worker closures/results, and crash reasons
%% can contain credentials or user data. Status exposes only bounded lifecycle
%% information needed for operations.
format_status(Status) ->
    maps:map(
      fun(state, State = #state{}) ->
              ActiveTurns = active_turn_count(State),
              #{session_configured =>
                    State#state.session_id =/= undefined,
                queued_turns => queued_turn_count(State),
                active_turn => ActiveTurns > 0,
                active_turns => ActiveTurns,
                max_concurrent_invocations =>
                    State#state.max_concurrent_invocations};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

%% Internal Functions
resolve_turn_timeout(Config) ->
    Timeout = maps:get(
                agent_turn_timeout, Config,
                application:get_env(erlang_adk, agent_turn_timeout,
                                    ?DEFAULT_TURN_TIMEOUT)),
    case Timeout of
        infinity -> {ok, infinity};
        Value when is_integer(Value), Value >= 0 -> {ok, Value};
        Invalid -> {error, Invalid}
    end.

resolve_max_concurrent_invocations(Config) ->
    Value = maps:get(
              max_concurrent_invocations, Config,
              application:get_env(
                erlang_adk, max_concurrent_invocations,
                ?DEFAULT_MAX_CONCURRENT_INVOCATIONS)),
    case Value of
        Max when is_integer(Max), Max > 0 -> {ok, Max};
        _Invalid -> {error, expected_positive_integer}
    end.

new_sync_turn(Kind, From, Payload) ->
    Caller = caller_pid(From),
    Monitor = erlang:monitor(process, Caller),
    maps:merge(
      Payload,
      #{turn_ref => make_ref(),
        kind => Kind,
        from => From,
        caller => Caller,
        caller_monitor => Monitor}).

caller_pid({Pid, _Tag}) when is_pid(Pid) -> Pid.

enqueue_turn(Turn, State0) ->
    case maps:get(schedule_key, Turn, legacy) of
        legacy -> enqueue_legacy_turn(Turn, State0);
        Lane -> enqueue_lane_turn(Lane, Turn, State0)
    end.

enqueue_legacy_turn(Turn, State0) ->
    Pending0 = ensure_queue(State0#state.pending),
    dispatch_next(State0#state{pending = queue:in(Turn, Pending0)}).

enqueue_lane_turn(Lane, Turn, State0) ->
    PendingByLane0 = State0#state.lane_pending,
    Pending0 = maps:get(Lane, PendingByLane0, queue:new()),
    PendingByLane1 = PendingByLane0#{Lane => queue:in(Turn, Pending0)},
    dispatch_lane(Lane, State0#state{lane_pending = PendingByLane1}).

dispatch_next(State = #state{active = Active}) when is_map(Active) ->
    State;
dispatch_next(State0) ->
    Pending0 = ensure_queue(State0#state.pending),
    case queue:out(Pending0) of
        {empty, _} -> State0#state{pending = Pending0};
        {{value, Turn}, Pending1} ->
            State1 = State0#state{pending = Pending1},
            case turn_caller_alive(Turn) of
                false ->
                    demonitor_ref(maps:get(caller_monitor, Turn, undefined)),
                    dispatch_next(State1);
                true ->
                    start_turn(Turn, State1)
            end
    end.

dispatch_lane(Lane, State = #state{lane_active = ActiveByLane}) ->
    State1 = case maps:is_key(Lane, ActiveByLane) of
        true -> State;
        false -> mark_lane_ready(Lane, State)
    end,
    dispatch_ready_lanes(State1).

mark_lane_ready(Lane, State0) ->
    PendingByLane0 = State0#state.lane_pending,
    Pending0 = maps:get(Lane, PendingByLane0, queue:new()),
    ReadySet0 = State0#state.ready_lane_set,
    case queue:is_empty(Pending0) orelse maps:is_key(Lane, ReadySet0) of
        true -> State0;
        false ->
            Ready0 = ensure_queue(State0#state.ready_lanes),
            State0#state{
              ready_lanes = queue:in(Lane, Ready0),
              ready_lane_set = ReadySet0#{Lane => true}}
    end.

dispatch_ready_lanes(
  State = #state{lane_active = ActiveByLane,
                 max_concurrent_invocations = Max}) ->
    case maps:size(ActiveByLane) >= Max of
        true -> State;
        false -> dispatch_next_ready_lane(State)
    end.

dispatch_next_ready_lane(State0) ->
    Ready0 = ensure_queue(State0#state.ready_lanes),
    case queue:out(Ready0) of
        {empty, _} ->
            State0#state{ready_lanes = Ready0,
                         ready_lane_set = #{}};
        {{value, Lane}, Ready1} ->
            ReadySet1 = maps:remove(Lane, State0#state.ready_lane_set),
            State1 = State0#state{ready_lanes = Ready1,
                                  ready_lane_set = ReadySet1},
            case maps:is_key(Lane, State1#state.lane_active) of
                true -> dispatch_ready_lanes(State1);
                false -> dispatch_ready_lane_turn(Lane, State1)
            end
    end.

dispatch_ready_lane_turn(Lane, State0) ->
    case take_live_lane_turn(Lane, State0) of
        {none, State1} -> dispatch_ready_lanes(State1);
        {turn, Turn, State1} ->
            dispatch_ready_lanes(start_lane_turn(Lane, Turn, State1))
    end.

take_live_lane_turn(Lane, State0) ->
    PendingByLane0 = State0#state.lane_pending,
    Pending0 = maps:get(Lane, PendingByLane0, queue:new()),
    case queue:out(Pending0) of
        {empty, _} ->
            {none,
             State0#state{
               lane_pending = maps:remove(Lane, PendingByLane0)}};
        {{value, Turn}, Pending1} ->
            PendingByLane1 = put_lane_queue(
                               Lane, Pending1, PendingByLane0),
            State1 = State0#state{lane_pending = PendingByLane1},
            case turn_caller_alive(Turn) of
                true -> {turn, Turn, State1};
                false ->
                    demonitor_ref(
                      maps:get(caller_monitor, Turn, undefined)),
                    take_live_lane_turn(Lane, State1)
            end
    end.

turn_caller_alive(#{caller := Caller})
  when is_pid(Caller), node(Caller) =:= node() ->
    is_process_alive(Caller);
turn_caller_alive(#{caller := Caller}) when is_pid(Caller) ->
    %% A remote monitor is the authority for distributed callers; the local
    %% is_process_alive/1 BIF cannot establish their liveness.
    true;
turn_caller_alive(_Turn) -> true.

start_turn(Turn, State0) ->
    TurnRef = maps:get(turn_ref, Turn),
    ExecutionTurn = maps:without(
                      [from, caller, caller_monitor, reply_to], Turn),
    ExecutionState = execution_state(State0),
    Owner = self(),
    Work = fun() ->
        execute_agent_turn(ExecutionTurn, ExecutionState, Owner)
    end,
    State1 = State0#state{active = Turn},
    case adk_agent_turn_sup:start_turn(
           Owner, TurnRef, Work, State0#state.turn_timeout) of
        {ok, WorkerPid} ->
            WorkerMonitor = erlang:monitor(process, WorkerPid),
            Active = Turn#{worker_pid => WorkerPid,
                           worker_monitor => WorkerMonitor,
                           abandoned => false},
            ok = adk_agent_turn_worker:begin_work(WorkerPid),
            State1#state{active = Active};
        {ok, WorkerPid, _Info} ->
            WorkerMonitor = erlang:monitor(process, WorkerPid),
            Active = Turn#{worker_pid => WorkerPid,
                           worker_monitor => WorkerMonitor,
                           abandoned => false},
            ok = adk_agent_turn_worker:begin_work(WorkerPid),
            State1#state{active = Active};
        {error, Reason} ->
            fail_turn(
              adk_failure:external(
                agent, turn_worker_start, Reason), State1)
    end.

start_lane_turn(Lane, Turn, State0) ->
    TurnRef = maps:get(turn_ref, Turn),
    ExecutionTurn = maps:without(
                      [from, caller, caller_monitor, reply_to,
                       schedule_key], Turn),
    ExecutionState = execution_state(State0),
    Owner = self(),
    Work = fun() ->
        execute_agent_turn(ExecutionTurn, ExecutionState, Owner)
    end,
    ActiveByLane0 = State0#state.lane_active,
    State1 = State0#state{
               lane_active = ActiveByLane0#{Lane => Turn}},
    case adk_agent_turn_sup:start_turn(
           Owner, TurnRef, Work, State0#state.turn_timeout) of
        {ok, WorkerPid} ->
            activate_lane_worker(Lane, Turn, WorkerPid, State1);
        {ok, WorkerPid, _Info} ->
            activate_lane_worker(Lane, Turn, WorkerPid, State1);
        {error, Reason} ->
            fail_lane_turn(
              Lane,
              adk_failure:external(
                agent, turn_worker_start, Reason), State1)
    end.

activate_lane_worker(Lane, Turn, WorkerPid, State0) ->
    WorkerMonitor = erlang:monitor(process, WorkerPid),
    Active = Turn#{worker_pid => WorkerPid,
                   worker_monitor => WorkerMonitor,
                   abandoned => false},
    ActiveByLane = (State0#state.lane_active)#{Lane => Active},
    ok = adk_agent_turn_worker:begin_work(WorkerPid),
    State0#state{lane_active = ActiveByLane}.

execution_state(State) ->
    %% A worker closure must retain only immutable agent runtime state and the
    %% one turn it executes, never other queued callers' prompts or contexts.
    State#state{pending = queue:new(),
                active = undefined,
                lane_pending = #{},
                lane_active = #{},
                ready_lanes = queue:new(),
                ready_lane_set = #{}}.

invocation_lane(#{app_name := App,
                  user_id := User,
                  session_id := Session})
  when App =/= undefined, User =/= undefined, Session =/= undefined ->
    {session, App, User, Session};
invocation_lane(_Context) ->
    %% Scoped calls without an exact Runner session remain isolated from the
    %% legacy history lane, but serialize with one another deterministically.
    unscoped_invocations.

execute_agent_turn(#{kind := prompt,
                     message := Message,
                     context := InvocationContext}, State, Owner) ->
    put('$adk_agent_owner', Owner),
    execute_prompt_like(prompt, Message, InvocationContext, State);
execute_agent_turn(#{kind := invoke,
                     message := Message,
                     context := InvocationContext}, State, Owner) ->
    put('$adk_agent_owner', Owner),
    execute_invocation_prompt(Message, InvocationContext, State);
execute_agent_turn(#{kind := delegate, message := Message}, State, Owner) ->
    put('$adk_agent_owner', Owner),
    execute_prompt_like(delegate, Message, direct_context(State), State);
execute_agent_turn(#{kind := run_with_events,
                     history_events := HistoryEvents,
                     invocation_id := InvocationId,
                     context := Context}, State, Owner) ->
    put('$adk_agent_owner', Owner),
    execute_event_turn(HistoryEvents, InvocationId, Context, State).

execute_prompt_like(Kind, Message, InvocationContext, State) ->
    telemetry:execute([erlang_adk, agent, Kind, start], #{},
                      #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),
    Memory1 = adk_memory:add_message(State#state.memory, user, Message),
    RunResult = case prepare_agent_turn(
                       State, Message, Memory1, InvocationContext) of
        {ok, EffectiveConfig, PreparedMemory, PreparedContext} ->
            run_agent_invocation(
              State, Message, PreparedMemory, EffectiveConfig,
              PreparedContext);
        {error, PrepareReason} ->
            {error, PrepareReason, Memory1}
    end,
    {Reply, Memory2} = case RunResult of
        {ok, Response, UpdatedMemory} ->
            {{ok, Response}, UpdatedMemory};
        {error, Reason, UpdatedMemory} ->
            {{error, Reason}, UpdatedMemory}
    end,
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, Kind, stop],
                      #{duration => Duration},
                      #{agent => State#state.name}),
    save_direct_memory(State, Memory2),
    {Reply, Memory2}.

execute_invocation_prompt(Message, InvocationContext, State) ->
    telemetry:execute([erlang_adk, agent, invoke, start], #{},
                      #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),
    FreshMemory = ensure_system_instruction(
                    adk_memory:new(), State#state.llm_config),
    Memory1 = adk_memory:add_message(FreshMemory, user, Message),
    RunResult = case prepare_agent_turn(
                       State, Message, Memory1, InvocationContext) of
        {ok, EffectiveConfig, PreparedMemory, PreparedContext} ->
            run_agent_invocation(
              State, Message, PreparedMemory, EffectiveConfig,
              PreparedContext);
        {error, PrepareReason} ->
            {error, PrepareReason, Memory1}
    end,
    {Reply, Memory2} = case RunResult of
        {ok, Response, UpdatedMemory} ->
            {{ok, Response}, UpdatedMemory};
        {error, Reason, UpdatedMemory} ->
            {{error, Reason}, UpdatedMemory}
    end,
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, invoke, stop],
                      #{duration => Duration},
                      #{agent => State#state.name}),
    {Reply, Memory2}.

execute_event_turn(HistoryEvents, InvocationId, Context, State) ->
    telemetry:execute([erlang_adk, agent, run_with_events, start], #{},
                      #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),
    Result = case prepare_event_model(State, HistoryEvents, Context) of
        {ok, Prepared} ->
            Config = maps:get(config, Prepared),
            History = maps:get(memory, Prepared),
            ModelTools = maps:get(model_tools, Prepared),
            PluginRuntime = maps:get(plugin_runtime, Prepared),
            model_result_to_event(
              State,
              generate_with_callbacks(
                Config, History, ModelTools, PluginRuntime),
              InvocationId);
        {error, _} = Error -> Error
    end,
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, run_with_events, stop],
                      #{duration => Duration},
                      #{agent => State#state.name}),
    Result.

save_direct_memory(#state{session_id = undefined}, _Memory) -> ok;
save_direct_memory(#state{session_id = SessionId,
                          session_store = Store}, Memory) ->
    Store:save(SessionId, Memory).

active_matches(TurnRef, WorkerPid, Active) ->
    maps:get(turn_ref, Active) =:= TurnRef andalso
        maps:get(worker_pid, Active, undefined) =:= WorkerPid.

locate_active(TurnRef, WorkerPid,
              #state{active = Active, lane_active = ActiveByLane}) ->
    case is_map(Active) andalso
         active_matches(TurnRef, WorkerPid, Active) of
        true -> legacy;
        false -> locate_lane_active(TurnRef, WorkerPid, ActiveByLane)
    end.

locate_lane_active(TurnRef, WorkerPid, ActiveByLane) ->
    case [Lane || {Lane, Active} <- maps:to_list(ActiveByLane),
                  active_matches(TurnRef, WorkerPid, Active)] of
        [Lane | _] -> {lane, Lane};
        [] -> not_found
    end.

complete_turn(_Result, State = #state{active = #{abandoned := true}}) ->
    dispatch_next(clear_active(State));
complete_turn(Result, State = #state{active = Active}) ->
    case {maps:get(kind, Active), Result} of
        {prompt, {{ok, _Value} = Reply, Memory}} when is_list(Memory) ->
            gen_server:reply(maps:get(from, Active), Reply),
            dispatch_next(
              (clear_active(State))#state{memory = Memory});
        {prompt, {{error, _Reason} = Reply, Memory}} when is_list(Memory) ->
            gen_server:reply(maps:get(from, Active), Reply),
            dispatch_next(
              (clear_active(State))#state{memory = Memory});
        {invoke, {{ok, _Value} = Reply, Memory}} when is_list(Memory) ->
            gen_server:reply(maps:get(from, Active), Reply),
            dispatch_next(clear_active(State));
        {invoke, {{error, _Reason} = Reply, Memory}} when is_list(Memory) ->
            gen_server:reply(maps:get(from, Active), Reply),
            dispatch_next(clear_active(State));
        {delegate, {{ok, _Value} = Reply, Memory}} when is_list(Memory) ->
            notify_delegate(maps:get(reply_to, Active), Reply),
            dispatch_next(
              (clear_active(State))#state{memory = Memory});
        {delegate, {{error, _Reason} = Reply, Memory}} when is_list(Memory) ->
            notify_delegate(maps:get(reply_to, Active), Reply),
            dispatch_next(
              (clear_active(State))#state{memory = Memory});
        {run_with_events, {ok, _Event} = Reply} ->
            gen_server:reply(maps:get(from, Active), Reply),
            dispatch_next(clear_active(State));
        {run_with_events, {tool_calls, _Event, _Calls} = Reply} ->
            gen_server:reply(maps:get(from, Active), Reply),
            dispatch_next(clear_active(State));
        {run_with_events, {error, _Reason} = Reply} ->
            gen_server:reply(maps:get(from, Active), Reply),
            dispatch_next(clear_active(State));
        {Kind, _Invalid} ->
            fail_turn({invalid_agent_turn_result, Kind}, State)
    end.

complete_lane_turn(Lane, Result, State) ->
    Active = maps:get(Lane, State#state.lane_active),
    case maps:get(abandoned, Active, false) of
        true ->
            dispatch_lane(Lane, clear_lane_active(Lane, State));
        false ->
            complete_live_lane_turn(Lane, Active, Result, State)
    end.

complete_live_lane_turn(Lane, Active, Result, State) ->
    case {maps:get(kind, Active), Result} of
        {invoke, {{ok, _Value} = Reply, Memory}} when is_list(Memory) ->
            reply_and_dispatch_lane(Lane, Active, Reply, State);
        {invoke, {{error, _Reason} = Reply, Memory}} when is_list(Memory) ->
            reply_and_dispatch_lane(Lane, Active, Reply, State);
        {run_with_events, {ok, _Event} = Reply} ->
            reply_and_dispatch_lane(Lane, Active, Reply, State);
        {run_with_events, {tool_calls, _Event, _Calls} = Reply} ->
            reply_and_dispatch_lane(Lane, Active, Reply, State);
        {run_with_events, {error, _Reason} = Reply} ->
            reply_and_dispatch_lane(Lane, Active, Reply, State);
        {Kind, _Invalid} ->
            fail_lane_turn(
              Lane, {invalid_agent_turn_result, Kind}, State)
    end.

reply_and_dispatch_lane(Lane, Active, Reply, State) ->
    gen_server:reply(maps:get(from, Active), Reply),
    dispatch_lane(Lane, clear_lane_active(Lane, State)).

fail_turn(_Reason, State = #state{active = #{abandoned := true}}) ->
    dispatch_next(clear_active(State));
fail_turn(Reason, State = #state{active = Active}) ->
    case maps:get(kind, Active) of
        prompt -> gen_server:reply(maps:get(from, Active), {error, Reason});
        invoke -> gen_server:reply(maps:get(from, Active), {error, Reason});
        run_with_events ->
            gen_server:reply(maps:get(from, Active), {error, Reason});
        delegate ->
            notify_delegate(maps:get(reply_to, Active), {error, Reason})
    end,
    dispatch_next(clear_active(State)).

fail_lane_turn(Lane, Reason, State) ->
    Active = maps:get(Lane, State#state.lane_active),
    case maps:get(abandoned, Active, false) of
        true -> ok;
        false ->
            case maps:get(kind, Active) of
                invoke ->
                    gen_server:reply(
                      maps:get(from, Active), {error, Reason});
                run_with_events ->
                    gen_server:reply(
                      maps:get(from, Active), {error, Reason})
            end
    end,
    dispatch_lane(Lane, clear_lane_active(Lane, State)).

clear_active(State = #state{active = Active}) when is_map(Active) ->
    demonitor_ref(maps:get(worker_monitor, Active, undefined)),
    demonitor_ref(maps:get(caller_monitor, Active, undefined)),
    State#state{active = undefined}.

clear_lane_active(Lane, State0) ->
    ActiveByLane0 = State0#state.lane_active,
    Active = maps:get(Lane, ActiveByLane0),
    demonitor_ref(maps:get(worker_monitor, Active, undefined)),
    demonitor_ref(maps:get(caller_monitor, Active, undefined)),
    State0#state{lane_active = maps:remove(Lane, ActiveByLane0)}.

turn_failure_reason({timeout, Timeout}) ->
    adk_failure:external(agent, turn_timeout, {timeout, Timeout});
turn_failure_reason({crashed, Details}) ->
    adk_failure:external(agent, turn_worker_crash, Details);
turn_failure_reason({worker_exited, Reason}) ->
    adk_failure:external(agent, turn_worker_exit, Reason);
turn_failure_reason(Other) ->
    adk_failure:external(agent, turn_worker_failure, Other).

handle_turn_down(Monitor, Reason, State) ->
    case locate_active_monitor(Monitor, State) of
        {legacy, worker, Active} ->
            case maps:get(abandoned, Active, false) of
                true -> dispatch_next(clear_active(State));
                false ->
                    fail_turn(
                      adk_failure:external(
                        agent, turn_worker_exit, Reason), State)
            end;
        {legacy, caller, Active} ->
            cancel_active_worker(Active),
            State#state{active = Active#{abandoned => true,
                                        caller_monitor => undefined}};
        {lane, Lane, worker, Active} ->
            case maps:get(abandoned, Active, false) of
                true ->
                    dispatch_lane(
                      Lane, clear_lane_active(Lane, State));
                false ->
                    fail_lane_turn(
                      Lane,
                      adk_failure:external(
                        agent, turn_worker_exit, Reason), State)
            end;
        {lane, Lane, caller, Active} ->
            cancel_active_worker(Active),
            ActiveByLane = (State#state.lane_active)#{
                Lane => Active#{abandoned => true,
                                caller_monitor => undefined}},
            State#state{lane_active = ActiveByLane};
        not_found ->
            remove_queued_monitor(Monitor, State)
    end.

locate_active_monitor(Monitor,
                      #state{active = Active,
                             lane_active = ActiveByLane}) ->
    case active_monitor_kind(Monitor, Active) of
        worker -> {legacy, worker, Active};
        caller -> {legacy, caller, Active};
        not_found -> locate_lane_active_monitor(Monitor, ActiveByLane)
    end.

locate_lane_active_monitor(Monitor, ActiveByLane) ->
    Matches = [{Lane, Kind, Active}
               || {Lane, Active} <- maps:to_list(ActiveByLane),
                  Kind <- [active_monitor_kind(Monitor, Active)],
                  Kind =/= not_found],
    case Matches of
        [{Lane, Kind, Active} | _] -> {lane, Lane, Kind, Active};
        [] -> not_found
    end.

active_monitor_kind(_Monitor, Active) when not is_map(Active) ->
    not_found;
active_monitor_kind(Monitor, Active) ->
    case {maps:get(worker_monitor, Active, undefined),
          maps:get(caller_monitor, Active, undefined)} of
        {Monitor, _} -> worker;
        {_, Monitor} -> caller;
        _ -> not_found
    end.

remove_queued_monitor(Monitor, State0) ->
    Pending0 = ensure_queue(State0#state.pending),
    Pending1 = queue:from_list(
                 [Turn || Turn <- queue:to_list(Pending0),
                          maps:get(caller_monitor, Turn, undefined)
                              =/= Monitor]),
    PendingByLane1 = maps:fold(
                       fun(Lane, Pending, Acc) ->
                           Filtered = queue:from_list(
                                        [Turn || Turn <- queue:to_list(Pending),
                                         maps:get(caller_monitor, Turn,
                                                  undefined) =/= Monitor]),
                           put_lane_queue(Lane, Filtered, Acc)
                       end, #{}, State0#state.lane_pending),
    State0#state{pending = Pending1,
                 lane_pending = PendingByLane1}.

notify_delegate(undefined, _Response) -> ok;
notify_delegate({TargetPid, Ref}, Response) when is_pid(TargetPid) ->
    TargetPid ! {agent_response, Ref, self(), Response},
    ok;
notify_delegate(TargetPid, Response) when is_pid(TargetPid) ->
    TargetPid ! {agent_response, self(), unwrap_response(Response)},
    ok.

cancel_active_worker(Active) when is_map(Active) ->
    case maps:get(worker_pid, Active, undefined) of
        Pid when is_pid(Pid) -> adk_agent_turn_worker:cancel(Pid);
        _ -> ok
    end;
cancel_active_worker(_Active) -> ok.

cancel_lane_workers(ActiveByLane) ->
    lists:foreach(
      fun cancel_active_worker/1, maps:values(ActiveByLane)),
    ok.

demonitor_pending(undefined) -> ok;
demonitor_pending(Pending) ->
    lists:foreach(
      fun(Turn) ->
          demonitor_ref(maps:get(caller_monitor, Turn, undefined))
      end, queue:to_list(Pending)),
    ok.

demonitor_lane_pending(PendingByLane) ->
    lists:foreach(
      fun demonitor_pending/1, maps:values(PendingByLane)),
    ok.

maybe_delete_config_ref(normal, ConfigRef) ->
    delete_config_ref(ConfigRef);
maybe_delete_config_ref(shutdown, ConfigRef) ->
    delete_config_ref(ConfigRef);
maybe_delete_config_ref({shutdown, _}, ConfigRef) ->
    delete_config_ref(ConfigRef);
maybe_delete_config_ref(_AbnormalReason, _ConfigRef) -> ok.

delete_config_ref(undefined) -> ok;
delete_config_ref(ConfigRef) ->
    _ = catch adk_agent_config_store:delete(ConfigRef),
    ok.

safe_queue_len(undefined) -> 0;
safe_queue_len(Pending) -> queue:len(Pending).

queued_turn_count(State) ->
    safe_queue_len(State#state.pending) +
        lists:sum([queue:len(Pending)
                   || Pending <- maps:values(State#state.lane_pending)]).

active_turn_count(State) ->
    Legacy = case is_map(State#state.active) of
        true -> 1;
        false -> 0
    end,
    Legacy + maps:size(State#state.lane_active).

put_lane_queue(Lane, Pending, PendingByLane) ->
    case queue:is_empty(Pending) of
        true -> maps:remove(Lane, PendingByLane);
        false -> PendingByLane#{Lane => Pending}
    end.

ensure_queue(undefined) -> queue:new();
ensure_queue(Pending) -> Pending.

demonitor_ref(undefined) -> ok;
demonitor_ref(Monitor) ->
    _ = erlang:demonitor(Monitor, [flush]),
    ok.

run_agent_loop(Config, Memory, Tools, State, InvocationContext, Round) ->
    MaxRounds = maps:get(max_tool_rounds, Config, 16),
    case Round >= MaxRounds of
        true ->
            {error, {max_tool_rounds_exceeded, MaxRounds}, Memory};
        false ->
            case model_tools(Tools, State#state.sub_agents) of
                {ok, ModelTools} ->
                    ModelResult = generate_with_callbacks(
                                    Config, Memory, ModelTools),
                    case direct_model_result(ModelResult) of
                        {ok, ModelOutput} ->
                            ResponseText = output_value(ModelOutput),
                            Memory1 = adk_memory:add_message(
                                        Memory, agent, ResponseText),
                            {ok, ResponseText, Memory1};
                        {tool_calls, Calls} ->
                            case adk_tool_call:validate_list(Calls) of
                                ok ->
                                    Memory1 = adk_memory:add_message(
                                                Memory, agent,
                                                {tool_calls, Calls}),
                                    Memory2 = execute_tools(
                                                Calls, Tools, Memory1, State,
                                                Config, InvocationContext),
                                    run_agent_loop(
                                      Config, Memory2, Tools, State,
                                      InvocationContext, Round + 1);
                                {error, Reason} ->
                                    {error, adk_failure:external(
                                              agent_model,
                                              invalid_tool_calls, Reason),
                                     Memory}
                            end;
                        {error, Reason} ->
                            {error, Reason, Memory};
                        Other ->
                            {error, adk_failure:external(
                                      agent_model, invalid_result, Other),
                             Memory}
                    end;
                {error, Reason} ->
                    {error, adk_failure:external(
                              agent, toolset_prepare, Reason), Memory}
            end
    end.

execute_tools([], _ToolsList, MemoryAcc, _State, _Config,
              _InvocationContext) ->
    MemoryAcc;
execute_tools([{NameBin, ArgsMap} | Rest], ToolsList, MemoryAcc, State,
              Config, InvocationContext) ->
    execute_tools_inner(NameBin, ArgsMap, undefined, undefined, Rest,
                        ToolsList, MemoryAcc, State, Config,
                        InvocationContext);
execute_tools([{NameBin, ArgsMap, Sig} | Rest], ToolsList, MemoryAcc, State,
              Config, InvocationContext) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, undefined, Rest,
                        ToolsList, MemoryAcc, State, Config,
                        InvocationContext);
execute_tools([{NameBin, ArgsMap, Sig, CallId} | Rest], ToolsList,
              MemoryAcc, State, Config, InvocationContext) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, CallId, Rest,
                        ToolsList, MemoryAcc, State, Config,
                        InvocationContext).

execute_tools_inner(NameBin, ArgsMap, Sig, CallId, Rest, ToolsList,
                    MemoryAcc, State, Config, InvocationContext) ->
    ScopedInvocation = maps:with(
                         [state, app_name, user_id, session_id,
                          invocation_id, artifact_service, artifact_scope,
                          state_ref, memory_service], InvocationContext),
    Context0 = maps:merge(
                 direct_context(State),
                 ScopedInvocation),
    Context = Context0#{
                invocation_id => maps:get(invocation_id, Context0, undefined),
                call_id => CallId,
                state_ref => State#state.session_store},
    LocalContext = copy_agent_path(InvocationContext, Context),
    Handlers = maps:get(callbacks, State#state.llm_config, []),
    Result = case adk_toolset:resolve(
                    ToolsList, NameBin, ArgsMap, Context) of
        {ok, {module, Mod}} ->
            execute_direct_module_tool(
              Mod, NameBin, ArgsMap, LocalContext, Handlers);
        {ok, {resolved, ResolvedCall}} ->
            ResolvedContext = resolved_execution_context(
                                ResolvedCall, Context, LocalContext),
            execute_direct_resolved_tool(
              ResolvedCall, NameBin, ArgsMap,
              ResolvedContext, Handlers);
        {error, not_found} ->
            case validate_sub_agent_arguments(
                   NameBin, ArgsMap, State#state.sub_agents) of
                ok ->
                    execute_sub_agent_with_callbacks(
                      NameBin, ArgsMap, LocalContext, LocalContext,
                      State#state.sub_agents, Handlers, Config);
                {error, {invalid_tool_arguments, _} = Reason} ->
                    adk_toolset:invalid_arguments_response(Reason);
                {error, not_found} ->
                    execute_sub_agent_with_callbacks(
                      NameBin, ArgsMap, LocalContext, LocalContext,
                      State#state.sub_agents, Handlers, Config)
            end;
        {error, {invalid_tool_arguments, _} = Reason} ->
            adk_toolset:invalid_arguments_response(Reason);
        {error, Reason} ->
            execute_failed_tool_with_callbacks(
              Reason, NameBin, ArgsMap, Context, Handlers)
    end,
    Memory1 = adk_memory:add_message(
                MemoryAcc, tool,
                tool_response(NameBin, Result, Sig, CallId)),
    execute_tools(Rest, ToolsList, Memory1, State, Config,
                  InvocationContext).

execute_direct_module_tool(Mod, NameBin, ArgsMap, Context, Handlers) ->
    case adk_tool_confirmation:module_requirement(Mod, ArgsMap, Context) of
        {ok, Requirement} ->
            case adk_tool_confirmation:is_required(Requirement) of
                true -> direct_confirmation_required(Requirement);
                false ->
                    execute_tool_with_callbacks(
                      Mod, NameBin, ArgsMap, Context, Handlers)
            end;
        {error, Reason} -> direct_confirmation_error(Reason)
    end.

execute_direct_resolved_tool(ResolvedCall, NameBin, ArgsMap,
                             Context, Handlers) ->
    case adk_tool_confirmation:resolved_requirement(
           ResolvedCall, ArgsMap, Context) of
        {ok, Requirement} ->
            case adk_tool_confirmation:is_required(Requirement) of
                true -> direct_confirmation_required(Requirement);
                false ->
                    execute_resolved_tool_with_callbacks(
                      ResolvedCall, NameBin, ArgsMap, Context, Handlers)
            end;
        {error, Reason} -> direct_confirmation_error(Reason)
    end.

%% A dynamic resolver never receives private ancestry. If it explicitly
%% returns a local module executor, that trusted module gets the same private
%% execution context as a directly configured module. Opaque execute closures
%% retain the minimal resolver context and cannot observe the path.
resolved_execution_context(#{module := Module}, _Context, LocalContext)
  when is_atom(Module) ->
    LocalContext;
resolved_execution_context(_ResolvedCall, Context, _LocalContext) ->
    Context.

direct_confirmation_required(Requirement) ->
    Error0 = #{<<"kind">> => <<"tool_confirmation_requires_runner">>},
    Error = case maps:find(hint, Requirement) of
        {ok, Hint} -> Error0#{<<"hint">> => Hint};
        error -> Error0
    end,
    #{<<"success">> => false, <<"error">> => Error}.

direct_confirmation_error(Reason) ->
    #{<<"success">> => false,
      <<"error">> => adk_failure:model_response(
                        tool_confirmation, evaluate, Reason)}.

tool_response(Name, Result, Sig, undefined) ->
    {tool_response, Name, Result, Sig};
tool_response(Name, Result, Sig, CallId) ->
    {tool_response, Name, Result, Sig, CallId}.

%% @doc Format a tool execution result into a standard map.
-spec format_result(Res :: term()) -> map().
format_result(Res) ->
    case adk_json:normalize(Res) of
        {ok, JsonMap} when is_map(JsonMap) ->
            JsonMap;
        {ok, JsonValue} ->
            #{<<"result">> => JsonValue};
        {error, Reason} ->
            %% The reason contains only a structural path and a term type; it
            %% deliberately excludes the unsupported value itself.
            #{<<"serialization_error">> =>
                  #{<<"reason">> => safe_json_error(Reason)}}
    end.

safe_json_error({unsupported_json_term, Path, Type}) ->
    #{<<"kind">> => <<"unsupported_json_term">>,
      <<"path">> => normalize_json_path(Path),
      <<"type">> => atom_to_binary(Type, utf8)};
safe_json_error({invalid_utf8, Path}) ->
    #{<<"kind">> => <<"invalid_utf8">>,
      <<"path">> => normalize_json_path(Path)};
safe_json_error({invalid_map_key, Path, Type}) ->
    #{<<"kind">> => <<"invalid_map_key">>,
      <<"path">> => normalize_json_path(Path),
      <<"type">> => atom_to_binary(Type, utf8)};
safe_json_error({duplicate_map_key, Path, Key}) ->
    #{<<"kind">> => <<"duplicate_map_key">>,
      <<"path">> => normalize_json_path(Path),
      <<"key">> => Key}.

normalize_json_path(Path) ->
    [case Part of
         Value when is_binary(Value) -> Value;
         Value when is_integer(Value) -> Value
     end || Part <- Path].

execute_tool_with_callbacks(Mod, NameBin, ArgsMap, Context, Handlers) ->
    Execute = fun() ->
        try Mod:execute(ArgsMap, Context) of
            ToolResult -> ToolResult
        catch
            Class:ToolFailure:_Stack ->
                Failure = adk_failure:exception(
                            agent_tool, execute, Class, ToolFailure),
                logger:error("Agent tool failed: ~p", [Failure]),
                {error, Failure}
        end
    end,
    execute_tool_operation_with_callbacks(
      Execute, NameBin, ArgsMap, Context, Handlers).

execute_resolved_tool_with_callbacks(ResolvedCall, NameBin, ArgsMap,
                                     Context, Handlers) ->
    Execute = fun() ->
        execute_resolved_call(ResolvedCall, NameBin, ArgsMap, Context)
    end,
    execute_tool_operation_with_callbacks(
      Execute, NameBin, ArgsMap, Context, Handlers).

execute_failed_tool_with_callbacks(Reason, NameBin, ArgsMap, Context,
                                   Handlers) ->
    Execute = fun() -> {error, Reason} end,
    execute_tool_operation_with_callbacks(
      Execute, NameBin, ArgsMap, Context, Handlers).

execute_tool_operation_with_callbacks(Execute, NameBin, ArgsMap, Context,
                                      Handlers) ->
    adk_callbacks:execute(Handlers, on_tool_start, [NameBin, ArgsMap]),
    RawResult = case adk_callbacks:run(Handlers, before_tool,
                                       [NameBin, ArgsMap, Context]) of
        {halt, Replacement} -> {ok, Replacement};
        {replace, Replacement} -> {ok, Replacement};
        _ -> Execute()
    end,
    FinalResult = case adk_callbacks:run(Handlers, after_tool,
                                         [NameBin, ArgsMap, Context, RawResult]) of
        {replace, ReplacementResult} -> {ok, ReplacementResult};
        {halt, ReplacementResult} -> {ok, ReplacementResult};
        _ -> RawResult
    end,
    adk_callbacks:execute(Handlers, on_tool_end, [NameBin, FinalResult]),
    case FinalResult of
        {ok, Res} -> #{<<"success">> => true, <<"result">> => format_result(Res)};
        {error, ToolError} ->
            #{<<"success">> => false,
              <<"error">> => adk_failure:model_response(
                                agent_tool, execute, ToolError)};
        Other ->
            #{<<"success">> => false,
              <<"error">> => adk_failure:model_response(
                                agent_tool, invalid_result, Other)}
    end.

execute_resolved_call(ResolvedCall, NameBin, ArgsMap, Context) ->
    Base = #{name => NameBin, args => ArgsMap, context => Context},
    ExecutorCall = maps:merge(ResolvedCall, Base),
    case adk_tool_executor:execute(
           [ExecutorCall], #{mode => serial, timeout => infinity}) of
        {ok, [#{outcome := {ok, Result}}]} -> {ok, Result};
        {ok, [#{outcome := {error, Reason}}]} -> {error, Reason};
        {ok, [#{outcome := {paused, Reason, Summary}}]} ->
            {error, {tool_paused, Reason, Summary}};
        {ok, Other} ->
            {error, adk_failure:external(
                      agent_tool, invalid_executor_result, Other)};
        {error, Reason} -> {error, Reason}
    end.

execute_sub_agent_with_callbacks(NameBin, ArgsMap, Context,
                                 DelegationContext, SubAgents,
                                 Handlers, Config) ->
    adk_callbacks:execute(Handlers, on_tool_start, [NameBin, ArgsMap]),
    RawResult = case adk_callbacks:run(Handlers, before_tool,
                                       [NameBin, ArgsMap, Context]) of
        {halt, Replacement} -> {ok, Replacement};
        {replace, Replacement} -> {ok, Replacement};
        _ -> execute_sub_agent(
               NameBin, ArgsMap, SubAgents, DelegationContext, Config)
    end,
    FinalResult = case adk_callbacks:run(
                         Handlers, after_tool,
                         [NameBin, ArgsMap, Context, RawResult]) of
        {replace, ReplacementResult} -> {ok, ReplacementResult};
        {halt, ReplacementResult} -> {ok, ReplacementResult};
        _ -> RawResult
    end,
    adk_callbacks:execute(Handlers, on_tool_end,
                          [NameBin, FinalResult]),
    case FinalResult of
        {ok, SubResult} ->
            #{<<"success">> => true,
              <<"result">> => format_result(SubResult)};
        {error, SubError} ->
            #{<<"success">> => false,
              <<"error">> => adk_failure:model_response(
                                sub_agent, execute, SubError)}
    end.

copy_agent_path(Source, Target) ->
    case maps:find('$adk_agent_path', Source) of
        {ok, Path} -> Target#{'$adk_agent_path' => Path};
        error -> Target
    end.

execute_sub_agent(NameBin, ArgsMap, SubAgents, Context, Config) ->
    case maps:find(NameBin, SubAgents) of
        {ok, SubSpec} ->
            SubPrompt = maps:get(<<"prompt">>, ArgsMap, <<>>),
            case sub_agent_pid(NameBin, SubSpec) of
                {ok, SubPid} ->
                    safe_sub_agent_prompt(
                      SubPid, SubPrompt,
                      delegation_context(Config, Context));
                error -> {error, invalid_sub_agent_configuration}
            end;
        error ->
            {error, tool_not_found}
    end.

safe_generate(Config, History, Tools) ->
    try adk_llm:generate(Config, History, Tools) of
        Result -> Result
    catch
        Class:Reason:_Stack ->
            Failure = adk_failure:exception(
                        agent_model, generate, Class, Reason),
            logger:error("LLM provider failed: ~p", [Failure]),
            {error, Failure}
    end.

generate_with_callbacks(Config, Memory, ModelTools) ->
    generate_with_callbacks(Config, Memory, ModelTools, disabled).

generate_with_callbacks(Config, Memory, ModelTools, PluginRuntime) ->
    Handlers = maps:get(callbacks, Config, []),
    ModelRequest = #{config => Config, memory => Memory,
                     tools => ModelTools},
    case run_model_plugin(PluginRuntime, before_model, ModelRequest) of
        {continue, _ObservedRequest} ->
            RawResult = case adk_callbacks:run(
                               Handlers, before_model,
                               [Config, Memory, ModelTools]) of
                {halt, Replacement} -> Replacement;
                {replace, Replacement} -> Replacement;
                _ -> safe_generate(
                       Config, adk_memory:get_history(Memory), ModelTools)
            end,
            finish_model_plugins(
              Config, Handlers, PluginRuntime, RawResult);
        {intervened, Replacement} ->
            finish_model_plugins(
              Config, Handlers, PluginRuntime, Replacement);
        {halt, Replacement} ->
            finish_model_plugins(
              Config, Handlers, PluginRuntime, Replacement);
        {error, Reason} -> {error, Reason}
    end.

execute_prepared_stream(Pid, InvocationId, Prepared, Mode, EventCallback) ->
    Config = maps:get(config, Prepared),
    Memory = maps:get(memory, Prepared),
    ModelTools = maps:get(model_tools, Prepared),
    PluginRuntime = maps:get(plugin_runtime, Prepared),
    Author = maps:get(author, Prepared),
    MaxBytes = maps:get(max_stream_output_bytes, Prepared),
    Limits = stream_content_limits(Config),
    AccRef = {?MODULE, stream_accumulator, make_ref()},
    put(AccRef, new_stream_accumulator(Mode, MaxBytes, Limits)),
    PartialCallback = fun(Delta) ->
        case accumulate_stream_delta(AccRef, Delta) of
            no_event -> ok;
            {event, EventContent} ->
                Event = adk_event:new(
                          Author, EventContent,
                          #{invocation_id => InvocationId,
                            partial => true}),
                case EventCallback(Event) of
                    ok -> ok;
                    {ok, _PublishedEvent} -> ok;
                    {error, Reason} ->
                        throw({stream_event_failed, Reason});
                    Other ->
                        throw({invalid_stream_event_callback, Other})
                end
        end
    end,
    try
        ModelResult = stream_with_callbacks(
                        Config, Memory, ModelTools, PluginRuntime,
                        Mode, PartialCallback, AccRef),
        case ModelResult of
            {ok, ModelOutput} ->
                finalize_output(Pid, ModelOutput, InvocationId);
            {tool_calls, Calls} ->
                AgentEvent = adk_event:new(
                               Author, {tool_calls, Calls},
                               #{invocation_id => InvocationId}),
                {tool_calls, AgentEvent, Calls};
            {provider_result, _} = ProviderResult ->
                finish_stream_provider_result(
                  Pid, InvocationId, Author, ProviderResult);
            {error, _} = Error -> Error;
            Other ->
                {error, adk_failure:external(
                          agent_model, invalid_stream_result, Other)}
        end
    after
        erase(AccRef)
    end.

stream_with_callbacks(Config, Memory, ModelTools, PluginRuntime,
                      Mode, PartialCallback, AccRef) ->
    Handlers = maps:get(callbacks, Config, []),
    ModelRequest = #{config => Config, memory => Memory,
                     tools => ModelTools, streaming => Mode},
    case run_model_plugin(PluginRuntime, before_model, ModelRequest) of
        {continue, _ObservedRequest} ->
            RawResult = case adk_callbacks:run(
                               Handlers, before_model,
                               [Config, Memory, ModelTools]) of
                {halt, Replacement} -> Replacement;
                {replace, Replacement} -> Replacement;
                _ -> safe_stream_generate(
                       Config, adk_memory:get_history(Memory), ModelTools,
                       Mode, PartialCallback, AccRef)
            end,
            finish_model_plugins(
              Config, Handlers, PluginRuntime, RawResult);
        {intervened, Replacement} ->
            finish_model_plugins(
              Config, Handlers, PluginRuntime, Replacement);
        {halt, Replacement} ->
            finish_model_plugins(
              Config, Handlers, PluginRuntime, Replacement);
        {error, Reason} -> {error, Reason}
    end.

safe_stream_generate(Config, History, ModelTools, Mode,
                     PartialCallback, AccRef) ->
    Result = try
        case Mode of
            text -> adk_llm:stream(
                      Config, History, ModelTools, PartialCallback);
            content -> adk_llm:stream_content(
                         Config, History, ModelTools, PartialCallback)
        end
    catch
        Class:Reason:_Stack ->
            Failure = adk_failure:exception(
                        agent_model, stream, Class, Reason),
            logger:error("LLM stream provider failed: ~p", [Failure]),
            {error, Failure}
    end,
    case Result of
        ok -> stream_accumulator_output(AccRef);
        {tool_calls, _Calls} = ToolCalls -> ToolCalls;
        {provider_result, _} = ProviderResult ->
            materialize_stream_provider_result(
              ProviderResult, AccRef);
        {error, _} = Error -> Error;
        Other ->
            {error, adk_failure:external(
                      agent_model, invalid_stream_result, Other)}
    end.

materialize_stream_provider_result(ProviderResult, AccRef) ->
    case adk_provider_result:decode(ProviderResult) of
        {ok, streamed, ProviderMetadata} ->
            case stream_accumulator_output(AccRef) of
                {ok, Output} ->
                    new_provider_result_from_metadata(
                      {ok, Output}, ProviderMetadata);
                {error, _} = Error -> Error
            end;
        {ok, {tool_calls, _Calls}, _ProviderMetadata} ->
            ProviderResult;
        {ok, {ok, _Output}, _ProviderMetadata} ->
            {error, {invalid_stream_provider_outcome, complete_output}};
        {error, _} = Error -> Error;
        not_provider_result ->
            {error, invalid_stream_provider_result}
    end.

new_provider_result_from_metadata(Outcome, ProviderMetadata) ->
    case adk_provider_result:new(
           maps:get(<<"provider">>, ProviderMetadata),
           maps:get(<<"type">>, ProviderMetadata),
           Outcome,
           maps:get(<<"metadata">>, ProviderMetadata)) of
        {ok, ProviderResult} -> ProviderResult;
        {error, Reason} ->
            {error, adk_failure:external(
                      agent_model, invalid_provider_result, Reason)}
    end.

new_stream_accumulator(text, MaxBytes, Limits) ->
    #{mode => text, max_bytes => MaxBytes, bytes => 0,
      value => <<>>, content_limits => Limits};
new_stream_accumulator(content, MaxBytes, Limits) ->
    #{mode => content, max_bytes => MaxBytes, bytes => 0,
      value => [], content_limits => Limits}.

accumulate_stream_delta(AccRef, Delta) ->
    case get(AccRef) of
        #{mode := text} = Acc ->
            accumulate_text_delta(AccRef, Delta, Acc);
        #{mode := content} = Acc ->
            accumulate_content_delta(AccRef, Delta, Acc);
        undefined ->
            erlang:error(asynchronous_stream_callback_not_supported)
    end.

accumulate_text_delta(_AccRef, <<>>, _Acc) -> no_event;
accumulate_text_delta(AccRef, Delta,
                      Acc = #{value := Value, bytes := Bytes,
                              max_bytes := Max}) when is_binary(Delta) ->
    case valid_utf8(Delta) of
        false -> throw({invalid_stream_delta, invalid_utf8});
        true ->
            NewBytes = Bytes + byte_size(Delta),
            ensure_stream_size(NewBytes, Max),
            put(AccRef, Acc#{value => <<Value/binary, Delta/binary>>,
                             bytes => NewBytes}),
            {event, Delta}
    end;
accumulate_text_delta(_AccRef, Delta, _Acc) ->
    throw({invalid_stream_delta, {expected_binary, Delta}}).

accumulate_content_delta(AccRef, Delta,
                         Acc = #{value := ReversedParts,
                                 bytes := Bytes, max_bytes := Max,
                                 content_limits := Limits}) ->
    case adk_content:validate(Delta, Limits) of
        {ok, Canonical} ->
            Parts = adk_content:parts(Canonical),
            case stream_display_parts(Parts, []) of
                {ok, []} -> no_event;
                {ok, DisplayParts} ->
                    {ok, DisplayContent} = adk_content:new(
                                             DisplayParts, Limits),
                    DeltaBytes = byte_size(jsx:encode(DisplayContent)),
                    NewBytes = Bytes + DeltaBytes,
                    ensure_stream_size(NewBytes, Max),
                    NewReversed = append_stream_parts(
                                    DisplayParts, ReversedParts),
                    %% Validate the coalesced aggregate on every callback so
                    %% total inline bytes and part count are bounded early.
                    {ok, _} = adk_content:new(
                                lists:reverse(NewReversed), Limits),
                    put(AccRef, Acc#{value => NewReversed,
                                     bytes => NewBytes}),
                    {event, DisplayContent};
                {error, Reason} -> throw({invalid_stream_delta, Reason})
            end;
        {error, Reason} -> throw({invalid_stream_delta, Reason})
    end.

stream_display_parts([], Acc) -> {ok, lists:reverse(Acc)};
stream_display_parts([Part | Rest], Acc) ->
    case maps:get(<<"type">>, Part) of
        <<"function_call">> -> stream_display_parts(Rest, Acc);
        <<"function_response">> ->
            {error, function_response_from_model};
        _ -> stream_display_parts(Rest, [Part | Acc])
    end.

append_stream_parts(Parts, ReversedAcc) ->
    lists:foldl(fun append_stream_part/2, ReversedAcc, Parts).

append_stream_part(#{<<"type">> := <<"text">>,
                     <<"text">> := Text} = Part,
                   [#{<<"type">> := <<"text">>,
                      <<"text">> := PreviousText} = Previous | Rest]) ->
    PartMetadata = maps:remove(<<"text">>, Part),
    PreviousMetadata = maps:remove(<<"text">>, Previous),
    case PartMetadata =:= PreviousMetadata of
        true -> [Previous#{<<"text">> =>
                      <<PreviousText/binary, Text/binary>>} | Rest];
        false -> [Part, Previous | Rest]
    end;
append_stream_part(Part, ReversedAcc) -> [Part | ReversedAcc].

ensure_stream_size(Bytes, Max) when Bytes =< Max -> ok;
ensure_stream_size(Bytes, Max) ->
    throw({stream_output_limit_exceeded, Bytes, Max}).

stream_accumulator_output(AccRef) ->
    case get(AccRef) of
        #{mode := text, value := <<>>} -> {error, empty_stream_response};
        #{mode := text, value := Value} -> {ok, Value};
        #{mode := content, value := []} -> {error, empty_stream_response};
        #{mode := content, value := Reversed,
          content_limits := Limits} ->
            adk_content:new(lists:reverse(Reversed), Limits)
    end.

stream_content_limits(Config) ->
    case adk_content:normalize_limits(
           maps:get(content_limits, Config, #{})) of
        {ok, Limits} -> Limits;
        {error, _} -> adk_content:default_limits()
    end.

finish_model_plugins(Config, Handlers, PluginRuntime, {error, _} = Error0) ->
    case run_model_plugin(PluginRuntime, on_model_error, Error0) of
        {continue, Error} -> Error;
        {intervened, Replacement} ->
            apply_after_model_plugins(
              Config, Handlers, PluginRuntime, Replacement);
        {halt, Replacement} ->
            apply_after_model_plugins(
              Config, Handlers, PluginRuntime, Replacement);
        {error, Reason} -> {error, Reason}
    end;
finish_model_plugins(Config, Handlers, PluginRuntime, RawResult) ->
    apply_after_model_plugins(Config, Handlers, PluginRuntime, RawResult).

apply_after_model_plugins(Config, Handlers, PluginRuntime, RawResult) ->
    case run_model_plugin(PluginRuntime, after_model, RawResult) of
        {continue, PluginResult} ->
            case adk_callbacks:run(
                   Handlers, after_model, [Config, PluginResult]) of
                {replace, ReplacementResult} -> ReplacementResult;
                {halt, ReplacementResult} -> ReplacementResult;
                _ -> PluginResult
            end;
        {intervened, ReplacementResult} -> ReplacementResult;
        {halt, ReplacementResult} -> ReplacementResult;
        {error, Reason} -> {error, Reason}
    end.

model_plugin_runtime(Context) ->
    Pipeline = maps:get('$adk_plugin_pipeline', Context, disabled),
    PluginContext = maps:get('$adk_plugin_context', Context, #{}),
    Observation = maps:get(
                    '$adk_observability', Context,
                    #{config => disabled, context => undefined}),
    case {Pipeline, maps:get(config, Observation, disabled)} of
        {disabled, disabled} -> disabled;
        _ -> #{pipeline => Pipeline, plugin_context => PluginContext,
               observability => Observation}
    end.

run_model_plugin(disabled, _Hook, Value) -> {continue, Value};
run_model_plugin(Runtime, Hook, Value) ->
    Started = erlang:monotonic_time(millisecond),
    Context = (maps:get(plugin_context, Runtime, #{}))#{phase => model},
    RawOutcome = case maps:get(pipeline, Runtime, disabled) of
        disabled -> {continue, Value, []};
        Pipeline ->
            case adk_plugin_pipeline:run(Pipeline, Hook, Context, Value) of
                {ok, NewValue, Trace} ->
                    case model_plugin_replaced(Trace) of
                        true -> {intervened, NewValue, Trace};
                        false -> {continue, NewValue, Trace}
                    end;
                {halt, NewValue, Trace} -> {halt, NewValue, Trace};
                {error, PipelineReason, Trace} ->
                    {error, PipelineReason, Trace}
            end
    end,
    Duration = erlang:max(
                 0, erlang:monotonic_time(millisecond) - Started),
    case emit_model_lifecycle(Runtime, Hook, Duration, Value, RawOutcome) of
        ok -> strip_model_plugin_trace(RawOutcome);
        {error, ObservationReason} ->
            {error, {observability_failed, ObservationReason}}
    end.

model_plugin_replaced(Trace) ->
    lists:any(
      fun(Entry) -> maps:get(<<"outcome">>, Entry, <<>>) =:= <<"replaced">> end,
      Trace).

strip_model_plugin_trace({continue, Value, _}) -> {continue, Value};
strip_model_plugin_trace({intervened, Value, _}) -> {intervened, Value};
strip_model_plugin_trace({halt, Value, _}) -> {halt, Value};
strip_model_plugin_trace({error, Reason, _}) -> {error, Reason}.

emit_model_lifecycle(#{observability := #{config := disabled}},
                     _Hook, _Duration, _Value, _Outcome) -> ok;
emit_model_lifecycle(Runtime, Hook, Duration, Value, Outcome) ->
    Observation = maps:get(observability, Runtime),
    Config = maps:get(config, Observation),
    Parent = maps:get(context, Observation),
    OutcomeTag = model_plugin_outcome_tag(Outcome),
    case adk_observability:child_context(
           Parent, #{phase => <<"model">>,
                     hook => atom_to_binary(Hook, utf8),
                     outcome => OutcomeTag}) of
        {ok, Child} ->
            Opts = #{capture_content => maps:get(capture_content, Config),
                     content => Value,
                     attributes => #{
                         phase => <<"model">>,
                         hook => atom_to_binary(Hook, utf8),
                         outcome => OutcomeTag,
                         plugin_trace => model_plugin_trace(Outcome)}},
            case adk_observability:emit(
                   [erlang_adk, lifecycle, Hook],
                   #{duration_ms => Duration}, Child, Opts) of
                {ok, Envelope} ->
                    case adk_observability:export(
                           Envelope, maps:get(exporters, Config)) of
                        {ok, _} -> ok;
                        {error, Reason, _} -> {error, Reason};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

model_plugin_outcome_tag({continue, _, _}) -> <<"continue">>;
model_plugin_outcome_tag({intervened, _, _}) -> <<"intervened">>;
model_plugin_outcome_tag({halt, _, _}) -> <<"halt">>;
model_plugin_outcome_tag({error, _, _}) -> <<"error">>.

model_plugin_trace({_Tag, _Value, Trace}) when is_list(Trace) -> Trace.

run_agent_invocation(State, Message, Memory, Config, InvocationContext) ->
    Handlers = maps:get(callbacks, Config, []),
    AgentName = State#state.name,
    adk_callbacks:execute(Handlers, on_agent_start,
                          [to_binary(AgentName), Message]),
    Result0 = case adk_callbacks:run(Handlers, before_agent,
                                     [AgentName, Message]) of
        {halt, Value} -> {ok, Value, Memory};
        {replace, Value} -> {ok, Value, Memory};
        _ -> run_agent_loop(
               Config, Memory, State#state.tools, State,
               InvocationContext, 0)
    end,
    case Result0 of
        {ok, Response0, UpdatedMemory} ->
            Response0a = case adk_callbacks:run(Handlers, after_agent,
                                                [AgentName, Response0]) of
                {replace, Replacement} -> Replacement;
                {halt, Replacement} -> Replacement;
                _ -> Response0
            end,
            %% Text remains a UTF-8 binary. Canonical multimodal content stays
            %% structured instead of being coerced to JSON text.
            case adk_agent_spec:finalize(
                   State#state.agent_spec, Response0a) of
                {ok, CanonicalOutput, StateDelta} ->
                    Response = output_value(CanonicalOutput),
                    FinalMemory = persist_agent_response(
                                    Memory, UpdatedMemory,
                                    Response0, Response),
                    case apply_direct_state_delta(
                           State, InvocationContext, StateDelta) of
                        ok ->
                            adk_callbacks:execute(
                              Handlers, on_agent_end,
                              [to_binary(AgentName), Response]),
                            {ok, Response, FinalMemory};
                        {error, Reason} ->
                            adk_callbacks:execute(
                              Handlers, on_error, [Reason]),
                            {error, Reason, FinalMemory}
                    end;
                {error, Reason} ->
                    adk_callbacks:execute(Handlers, on_error, [Reason]),
                    {error, Reason, UpdatedMemory}
            end;
        {error, Reason, UpdatedMemory} ->
            adk_callbacks:execute(Handlers, on_error, [Reason]),
            {error, Reason, UpdatedMemory}
    end.

%% Keep the conversation visible to the next model turn identical to the
%% response returned to the caller. A before_agent short-circuit has not yet
%% added an agent message; an after_agent replacement updates the final one.
persist_agent_response(InputMemory, InputMemory, _Original, Response) ->
    adk_memory:add_message(InputMemory, agent, Response);
persist_agent_response(_InputMemory, UpdatedMemory, Response, Response) ->
    UpdatedMemory;
persist_agent_response(_InputMemory, UpdatedMemory, _Original, Response) ->
    replace_latest_agent_response(UpdatedMemory, Response).

replace_latest_agent_response([#{role := agent} = Message | Rest], Response) ->
    [Message#{content => Response} | Rest];
replace_latest_agent_response([Message | Rest], Response) ->
    [Message | replace_latest_agent_response(Rest, Response)];
replace_latest_agent_response([], Response) ->
    adk_memory:add_message([], agent, Response).

%% Resolve one immutable agent spec against invocation-scoped data. Stored
%% history is newest-first; providers receive chronological history after
%% generate_with_callbacks/3 reverses it.
prepare_agent_turn(State, Input0, Memory, Context0) ->
    Input = case Input0 of undefined -> <<>>; _ -> Input0 end,
    Context1 = maps:merge(direct_context(State), Context0),
    case enter_agent_context(State#state.name, Context1) of
        {ok, Context} ->
            prepare_agent_turn_with_context(
              State, Input, Memory, Context);
        {error, _} = Error -> Error
    end.

prepare_agent_turn_with_context(State, Input, Memory, Context) ->
    Chronological0 = adk_memory:get_history(Memory),
    Chronological = [Message || Message <- Chronological0,
                                maps:get(role, Message, undefined) =/= system],
    {Prior, Current, After} = split_latest_user(Chronological, Input),
    case adk_agent_spec:prepare(
           State#state.agent_spec, Input, Prior, Context) of
        {ok, Prepared} ->
            prepare_effective_agent_turn(
              State, Prepared, Current, After, Context);
        {error, _} = Error -> Error
    end.

prepare_effective_agent_turn(State, Prepared, Current, After, Context) ->
    case effective_global_instruction(State, Prepared, Context) of
        {ok, GlobalInstruction, GlobalSource} ->
            CanonicalInput = model_input_value(maps:get(input, Prepared)),
            Current1 = Current#{role => user, content => CanonicalInput},
            LocalInstruction = maps:get(instructions, Prepared),
            Instructions0 = combine_instructions(
                              GlobalInstruction, LocalInstruction),
            Instructions = append_additional_instructions(
                             Instructions0,
                             maps:get(additional_instructions,
                                      Context, undefined)),
            System = #{role => system, content => Instructions,
                       timestamp => erlang:system_time(millisecond)},
            ProviderHistory = [System |
                               maps:get(history, Prepared) ++
                               [Current1 | After]],
            EffectiveConfig = effective_model_config(
                                State#state.llm_config,
                                Instructions, Prepared, GlobalSource),
            {ok, EffectiveConfig, lists:reverse(ProviderHistory), Context};
        {error, _} = Error -> Error
    end.

%% The path contains ancestors only when an invocation crosses an agent
%% boundary.  Entering the target appends its normalized name.  It is private
%% runtime metadata: it is never copied into provider configuration or model
%% history, but it follows model-visible sub-agent calls so a dynamically
%% resolved/restarted graph cannot deadlock on A -> B -> A.
enter_agent_context(Name, Context) ->
    case adk_agent_tree:validate_name(Name) of
        {ok, NameBin} ->
            case normalize_agent_path(
                   maps:get('$adk_agent_path', Context, []), [], 0) of
                {ok, Path, Depth} when Depth < ?MAX_DELEGATION_DEPTH ->
                    case lists:member(NameBin, Path) of
                        true -> {error, {delegation_cycle_detected, NameBin}};
                        false ->
                            {ok, Context#{'$adk_agent_path' =>
                                              Path ++ [NameBin]}}
                    end;
                {ok, _Path, _Depth} ->
                    {error, {delegation_depth_exceeded,
                             ?MAX_DELEGATION_DEPTH}};
                {error, _} = Error -> Error
            end;
        {error, _} ->
            {error, invalid_agent_runtime_name}
    end.

normalize_agent_path([], Acc, Depth) ->
    {ok, lists:reverse(Acc), Depth};
normalize_agent_path(_Path, _Acc, Depth)
  when Depth >= ?MAX_DELEGATION_DEPTH ->
    {error, {delegation_depth_exceeded, ?MAX_DELEGATION_DEPTH}};
normalize_agent_path([Name | Rest], Acc, Depth) ->
    case adk_agent_tree:validate_name(Name) of
        {ok, NameBin} ->
            case lists:member(NameBin, Acc) of
                true -> {error, invalid_delegation_path};
                false ->
                    normalize_agent_path(
                      Rest, [NameBin | Acc], Depth + 1)
            end;
        {error, _} ->
            {error, invalid_delegation_path}
    end;
normalize_agent_path(_Improper, _Acc, _Depth) ->
    {error, invalid_delegation_path}.

split_latest_user(Chronological, Input) ->
    split_latest_user_rev(lists:reverse(Chronological), [], Input,
                          Chronological).

split_latest_user_rev([#{role := user} = Current | EarlierRev],
                      After, _Input, _All) ->
    {lists:reverse(EarlierRev), Current, After};
split_latest_user_rev([Message | EarlierRev], After, Input, All) ->
    split_latest_user_rev(EarlierRev, [Message | After], Input, All);
split_latest_user_rev([], _After, Input, All) ->
    {All,
     #{role => user, content => model_input_value(Input),
       timestamp => erlang:system_time(millisecond)},
     []}.

effective_model_config(Config0, Instructions, Prepared, GlobalSource) ->
    Generation = maps:get(generation_config, Prepared, #{}),
    %% max_output_tokens is an agent-facing alias. Providers receive the
    %% normalized max_tokens key and never see an ambiguous pair.
    Config = maps:remove(max_output_tokens, Config0),
    Config1 = maps:merge(Config, Generation),
    Config2 = put_global_source(
                Config1#{instructions => Instructions}, GlobalSource),
    case maps:get(output_schema, Prepared, undefined) of
        undefined -> Config2;
        Schema ->
            Config2#{response_schema => Schema,
                     response_mime_type =>
                         maps:get(response_mime_type, Config2,
                                  <<"application/json">>)}
    end.

effective_global_instruction(State, Prepared, Context) ->
    case maps:find('$adk_inherited_global_instruction', Context) of
        error ->
            {ok, maps:get(global_instruction, Prepared, <<>>),
             maps:get(global_instruction, State#state.llm_config,
                      <<>>)};
        {ok, Source} ->
            resolve_inherited_global_instruction(
              Source, Context, State#state.llm_config)
    end.

resolve_inherited_global_instruction(Source, Context, Config) ->
    MaxBytes = maps:get(max_instruction_bytes, Config, 65536),
    Options = #{timeout_ms => maps:get(instruction_timeout_ms,
                                      Config, 5000),
                artifact_timeout_ms => maps:get(artifact_timeout_ms,
                                                Config, 2000),
                max_bytes => MaxBytes},
    case adk_agent_instruction:compile(Source, MaxBytes) of
        {ok, Compiled} ->
            case adk_agent_instruction:resolve(Compiled, Context, Options) of
                {ok, Resolved} -> {ok, Resolved, Source};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

put_global_source(Config, undefined) ->
    maps:remove('$adk_inherited_global_instruction', Config);
put_global_source(Config, Source) ->
    Config#{'$adk_inherited_global_instruction' => Source}.

combine_instructions(<<>>, Local) -> Local;
combine_instructions(Global, <<>>) -> Global;
combine_instructions(Global, Local) ->
    <<Global/binary, "\n\n", Local/binary>>.

append_additional_instructions(Instructions, undefined) -> Instructions;
append_additional_instructions(Instructions, <<>>) -> Instructions;
append_additional_instructions(Instructions, Additional)
  when is_binary(Additional) ->
    <<Instructions/binary, "\n\n", Additional/binary>>;
append_additional_instructions(Instructions, _Unsupported) -> Instructions.

latest_user_input(Memory) ->
    case lists:dropwhile(
           fun(Message) -> maps:get(role, Message, undefined) =/= user end,
           Memory) of
        [#{content := Content} | _] -> Content;
        [] -> <<>>
    end.

prepare_event_model(State, HistoryEvents, Context)
  when is_list(HistoryEvents), is_map(Context) ->
    LegacyHistory0 = adk_memory:from_events(HistoryEvents),
    Input = latest_user_input(LegacyHistory0),
    PluginRuntime = model_plugin_runtime(Context),
    MaxStreamBytes = maps:get(
                       '$adk_stream_max_bytes', Context,
                       ?DEFAULT_MAX_STREAM_OUTPUT_BYTES),
    AgentContext = maps:without(
                     ['$adk_plugin_pipeline', '$adk_plugin_context',
                      '$adk_observability', '$adk_stream_max_bytes'], Context),
    case valid_max_stream_bytes(MaxStreamBytes) of
        false -> {error, {invalid_max_stream_output_bytes, MaxStreamBytes}};
        true ->
            case prepare_agent_turn(
                   State, Input, LegacyHistory0, AgentContext) of
                {ok, EffectiveConfig, PreparedHistory, _PreparedContext} ->
                    case model_tools(State#state.tools,
                                     State#state.sub_agents) of
                        {ok, ModelTools} ->
                            {ok, #{config => EffectiveConfig,
                                   memory => PreparedHistory,
                                   model_tools => ModelTools,
                                   plugin_runtime => PluginRuntime,
                                   author => to_binary(State#state.name),
                                   max_stream_output_bytes =>
                                       MaxStreamBytes}};
                        {error, Reason} ->
                            {error, adk_failure:external(
                                      agent, toolset_prepare, Reason)}
                    end;
                {error, _} = Error -> Error
            end
    end;
prepare_event_model(_State, _HistoryEvents, _Context) ->
    {error, invalid_stream_history}.

valid_max_stream_bytes(Value) ->
    is_integer(Value) andalso Value > 0 andalso
        Value =< ?MAX_STREAM_OUTPUT_BYTES_CEILING.

direct_model_result({provider_result, _} = ProviderResult) ->
    case adk_provider_result:decode(ProviderResult) of
        {ok, {ok, Output}, _ProviderMetadata} -> {ok, Output};
        {ok, {tool_calls, Calls}, _ProviderMetadata} ->
            {tool_calls, Calls};
        {ok, streamed, _ProviderMetadata} ->
            {error, invalid_nonstream_provider_outcome};
        {error, _} = Error -> Error;
        not_provider_result -> {error, invalid_provider_result}
    end;
direct_model_result(Result) ->
    Result.

finish_stream_provider_result(Pid, InvocationId, Author, ProviderResult) ->
    case adk_provider_result:decode(ProviderResult) of
        {ok, {ok, _Output}, _ProviderMetadata} ->
            finalize_output(Pid, ProviderResult, InvocationId);
        {ok, {tool_calls, Calls}, ProviderMetadata} ->
            tool_calls_event(
              Author, Calls, InvocationId,
              provider_actions(ProviderMetadata));
        {ok, streamed, _ProviderMetadata} ->
            {error, unmaterialized_stream_provider_result};
        {error, _} = Error -> Error;
        not_provider_result -> {error, invalid_stream_provider_result}
    end.

model_result_to_event(State, {provider_result, _} = ProviderResult,
                      InvocationId) ->
    case adk_provider_result:decode(ProviderResult) of
        {ok, {ok, ModelOutput}, ProviderMetadata} ->
            finalize_event_output(
              State, ModelOutput, InvocationId, ProviderMetadata);
        {ok, {tool_calls, Calls}, ProviderMetadata} ->
            tool_calls_event(
              to_binary(State#state.name), Calls, InvocationId,
              provider_actions(ProviderMetadata));
        {ok, streamed, _ProviderMetadata} ->
            {error, invalid_nonstream_provider_outcome};
        {error, _} = Error -> Error;
        not_provider_result -> {error, invalid_provider_result}
    end;
model_result_to_event(State, {ok, ModelOutput}, InvocationId) ->
    finalize_event_output(State, ModelOutput, InvocationId);
model_result_to_event(State, {tool_calls, Calls}, InvocationId) ->
    tool_calls_event(
      to_binary(State#state.name), Calls, InvocationId, #{});
model_result_to_event(_State, {error, Reason}, _InvocationId) ->
    {error, Reason};
model_result_to_event(_State, Other, _InvocationId) ->
    {error, adk_failure:external(
              agent_model, invalid_result, Other)}.

tool_calls_event(Author, Calls, InvocationId, Actions) ->
    case adk_tool_call:validate_list(Calls) of
        ok ->
            AgentEvent = adk_event:new(
                           Author, {tool_calls, Calls},
                           #{invocation_id => InvocationId,
                             actions => Actions}),
            {tool_calls, AgentEvent, Calls};
        {error, Reason} ->
            {error, adk_failure:external(
                      agent_model, invalid_tool_calls, Reason)}
    end.

finalize_model_output(State, {provider_result, _} = ProviderResult,
                      InvocationId) ->
    case adk_provider_result:decode(ProviderResult) of
        {ok, {ok, ModelOutput}, ProviderMetadata} ->
            finalize_event_output(
              State, ModelOutput, InvocationId, ProviderMetadata);
        {ok, _OtherOutcome, _ProviderMetadata} ->
            {error, invalid_provider_output_outcome};
        {error, _} = Error -> Error;
        not_provider_result -> {error, invalid_provider_result}
    end;
finalize_model_output(State, ModelOutput, InvocationId) ->
    finalize_event_output(State, ModelOutput, InvocationId).

finalize_event_output(State, ModelOutput, InvocationId) ->
    finalize_event_output(State, ModelOutput, InvocationId, undefined).

finalize_event_output(State, ModelOutput, InvocationId, ProviderMetadata) ->
    case adk_agent_spec:finalize(State#state.agent_spec, ModelOutput) of
        {ok, CanonicalOutput, StateDelta} ->
            StateActions = case map_size(StateDelta) of
                0 -> #{};
                _ -> #{<<"state_delta">> => StateDelta}
            end,
            Actions = maps:merge(
                        StateActions,
                        provider_actions(ProviderMetadata)),
            FinalEvent = adk_event:new(
                           to_binary(State#state.name),
                           output_value(CanonicalOutput),
                           #{invocation_id => InvocationId,
                             is_final => true,
                             actions => Actions}),
            {ok, FinalEvent};
        {error, Reason} -> {error, Reason}
    end.

provider_actions(undefined) -> #{};
provider_actions(ProviderMetadata) when is_map(ProviderMetadata) ->
    #{<<"provider_metadata">> => ProviderMetadata}.

output_binary(Value) when is_binary(Value) -> Value;
output_binary(Value) when is_list(Value) ->
    case adk_json:normalize(Value) of
        {ok, Canonical} when is_binary(Canonical) -> Canonical;
        {ok, Canonical} -> jsx:encode(Canonical);
        {error, _} -> unicode:characters_to_binary(Value)
    end;
output_binary(Value) ->
    case adk_json:normalize(Value) of
        {ok, Canonical} -> jsx:encode(Canonical);
        {error, _} -> <<>>
    end.

output_value(Value) when is_map(Value) ->
    case adk_content:validate(Value, adk_content:safety_limits()) of
        {ok, Content} -> Content;
        {error, _} -> output_binary(Value)
    end;
output_value(Value) ->
    output_binary(Value).

model_input_value(Value) when is_map(Value) ->
    case adk_content:validate(Value, adk_content:safety_limits()) of
        {ok, Content} -> Content;
        {error, _} -> output_binary(Value)
    end;
model_input_value(Value) ->
    output_binary(Value).

valid_utf8(Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

direct_context(State) ->
    Config = State#state.llm_config,
    App = maps:get(app_name, Config, undefined),
    User = maps:get(user_id, Config, undefined),
    Session = State#state.session_id,
    ScopedState = direct_state_snapshot(
                    State#state.session_store, App, User, Session),
    Base = #{state => ScopedState,
             app_name => App,
             user_id => User,
             session_id => Session,
             state_ref => State#state.session_store},
    case direct_artifact_service(Config) of
        undefined -> Base;
        ArtifactService when is_binary(App), is_binary(User),
                             is_binary(Session) ->
            Base#{artifact_service => ArtifactService,
                  artifact_scope => {session, App, User, Session}};
        _ -> Base
    end.

direct_state_snapshot(Store, App, User, Session)
  when is_binary(App), is_binary(User), is_binary(Session) ->
    case erlang:function_exported(Store, get_session, 3) of
        false -> #{};
        true ->
            try Store:get_session(App, User, Session) of
                {ok, #{state := ScopedState}} when is_map(ScopedState) ->
                    ScopedState;
                _ -> #{}
            catch
                _:_ -> #{}
            end
    end;
direct_state_snapshot(_Store, _App, _User, _Session) ->
    #{}.

direct_artifact_service(Config) ->
    maps:get(artifact_svc, Config,
             maps:get(artifact_service, Config, undefined)).

apply_direct_state_delta(_State, _Context, Delta)
  when map_size(Delta) =:= 0 -> ok;
apply_direct_state_delta(State, Context, Delta) ->
    Config = State#state.llm_config,
    App = maps:get(app_name, Context,
                   maps:get(app_name, Config, undefined)),
    User = maps:get(user_id, Context,
                    maps:get(user_id, Config, undefined)),
    Session = maps:get(session_id, Context, State#state.session_id),
    Store = maps:get(state_ref, Context, State#state.session_store),
    case is_binary(App) andalso is_binary(User) andalso
         is_binary(Session) andalso
         is_atom(Store) andalso
         erlang:function_exported(Store, update_state, 4) of
        false -> {error, output_key_requires_runner_or_scoped_session};
        true ->
            try Store:update_state(App, User, Session, Delta) of
                ok -> ok;
                {error, Reason} ->
                    {error, adk_failure:external(
                              agent, output_state_update, Reason)};
                _ -> {error, output_state_update_failed}
            catch
                _:_ -> {error, output_state_update_failed}
            end
    end.

ensure_system_instruction(Memory, Config) ->
    case lists:any(fun(#{role := system}) -> true; (_) -> false end, Memory) of
        true -> Memory;
        false ->
            Instructions = maps:get(instructions, Config,
                                    "You are a helpful assistant."),
            SystemMessage = #{role => system, content => Instructions,
                              timestamp => erlang:system_time(millisecond)},
            %% Memory is stored newest-first, so append the oldest system item.
            Memory ++ [SystemMessage]
    end.

model_tools(Tools, SubAgents) ->
    case adk_toolset:expand_tools(Tools) of
        {ok, Expanded} ->
            SubSchemas = [sub_agent_schema(Name, Spec)
                          || {Name, Spec} <- maps:to_list(SubAgents)],
            case unique_model_tool_names(Expanded ++ SubSchemas, #{}) of
                ok -> {ok, Expanded ++ SubSchemas};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

unique_model_tool_names([], _Names) -> ok;
unique_model_tool_names([Tool | Rest], Names) ->
    case model_tool_name(Tool) of
        {ok, Name} ->
            case maps:is_key(Name, Names) of
                true -> {error, {duplicate_tool_name, Name}};
                false -> unique_model_tool_names(Rest, Names#{Name => true})
            end;
        {error, _} = Error -> Error
    end.

model_tool_name(#{<<"name">> := Name}) when is_binary(Name) ->
    {ok, Name};
model_tool_name(_Tool) -> {error, invalid_tool_schema}.

sub_agent_schema(Name, Spec) ->
    Description = case Spec of
        #{description := Desc} -> Desc;
        _ -> <<"Delegate a task to this specialist agent.">>
    end,
    adk_agent_tool:schema(#{name => to_binary(Name),
                            description => to_binary(Description)}).

validate_sub_agent_arguments(Name, Args, SubAgents) ->
    case maps:find(Name, SubAgents) of
        {ok, Spec} ->
            Schema = sub_agent_schema(Name, Spec),
            case adk_toolset:validate_arguments(Schema, Args) of
                {ok, _CanonicalArgs} -> ok;
                {error, _} = Error -> Error
            end;
        error -> {error, not_found}
    end.

sub_agent_pid(Name, #{pid := Pid}) ->
    resolve_sub_agent(Name, Pid);
sub_agent_pid(Name, Pid) ->
    resolve_sub_agent(Name, Pid).

resolve_sub_agent(Name, Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> {ok, Pid};
        false -> lookup_sub_agent(Name)
    end;
resolve_sub_agent(Name, _StaleRef) ->
    lookup_sub_agent(Name).

lookup_sub_agent(Name) ->
    case adk_agent_registry:lookup(Name) of
        {ok, Pid} -> {ok, Pid};
        {error, not_found} -> error
    end.

safe_sub_agent_prompt(SubPid, SubPrompt, Context) ->
    case get('$adk_agent_owner') of
        SubPid ->
            {error, self_delegation_not_allowed};
        _OtherAgent ->
            try invoke(SubPid, SubPrompt, Context) of
                Result -> Result
            catch
                Class:Reason ->
                    {error, adk_failure:exception(
                              sub_agent, prompt, Class, Reason)}
            end
    end.

delegation_context(Config, Context) ->
    Base = maps:with(
             [state, app_name, user_id, session_id, invocation_id,
              state_ref, artifact_service, artifact_scope,
              '$adk_agent_path'], Context),
    Source = maps:get(
               '$adk_inherited_global_instruction', Config,
               maps:get(global_instruction, Config, <<>>)),
    case Source of
        undefined -> Base;
        _ -> Base#{'$adk_inherited_global_instruction' => Source}
    end.

unwrap_response({ok, Value}) -> Value;
unwrap_response({error, Reason}) -> {error, Reason}.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

ensure_session_store(Store) ->
    case code:ensure_loaded(Store) of
        {module, Store} ->
            case erlang:function_exported(Store, init, 0) of
                true ->
                    case Store:init() of
                        ok -> ok;
                        {atomic, ok} -> ok;
                        {error, Reason} -> exit({session_store_init_failed, Reason});
                        _ -> ok
                    end;
                false -> ok
            end;
        {error, Reason} -> exit({session_store_unavailable, Store, Reason})
    end.
