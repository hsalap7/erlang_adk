%% @doc Bounded, cancellable runtime for explicit plans and replanning.
%%
%% Each planner and executor callback runs in a monitored lightweight process
%% with an absolute deadline, per-callback timeout, and heap limit. Plans and
%% callback values cross JSON-safe, secret-pruned boundaries. A plan action is
%% opaque data: this module never evaluates source code or resolves a module
%% named by model output.
-module(adk_planning_runtime).

-export([run/5,
         start/5,
         await/3,
         cancel/3,
         validate_ref/2,
         result_schema_version/0,
         encode_result/1,
         decode_result/1]).

-define(RESULT_VERSION, 1).
-define(DEFAULT_MAX_STEPS, 16).
-define(DEFAULT_MAX_REPLANS, 3).
-define(DEFAULT_TIMEOUT_MS, 60000).
-define(DEFAULT_CALLBACK_TIMEOUT_MS, 10000).
-define(DEFAULT_MAX_HEAP_WORDS, 500000).
-define(DEFAULT_MAX_PLAN_BYTES, 1048576).
-define(CANCEL_ACK_TIMEOUT_MS, 1000).

-type run_ref() :: reference().
-type result() :: map().
-export_type([run_ref/0, result/0]).

-spec result_schema_version() -> pos_integer().
result_schema_version() -> ?RESULT_VERSION.

%% @doc Run synchronously. Terminal planner, executor, budget, deadline, and
%% cancellation outcomes are returned as a checked result map, not exceptions.
-spec run(map(), map(), term(), map(), map()) ->
    {ok, result()} | {error, term()}.
run(Planner, Executor, Goal, Context, Opts) ->
    case start(Planner, Executor, Goal, Context, Opts) of
        {ok, Pid, Ref} -> await(Pid, Ref, infinity);
        {error, _} = Error -> Error
    end.

%% @doc Start an owner-bound planning process. `await/3' is owner-facing;
%% cancellation may be sent while a planner or executor worker is blocked.
-spec start(map(), map(), term(), map(), map()) ->
    {ok, pid(), run_ref()} | {error, term()}.
start(Planner0, Executor0, Goal0, Context0, Opts0)
  when is_map(Planner0), is_map(Executor0), is_map(Context0),
       is_map(Opts0) ->
    case normalize_start(Planner0, Executor0, Goal0, Context0, Opts0) of
        {ok, Planner, Executor, Goal, Context, Opts} ->
            Owner = self(),
            Ref = make_ref(),
            Started = erlang:monotonic_time(millisecond),
            Deadline = Started + maps:get(timeout_ms, Opts),
            State = #{owner => Owner, ref => Ref,
                      planner => Planner, executor => Executor,
                      goal => Goal, context => Context, options => Opts,
                      deadline => Deadline, started => Started,
                      plan => null, pending => [], observations => [],
                      steps_executed => 0, replans => 0},
            %% A deliberately tiny callback heap is a fault-injection tool and
            %% must not also kill the coordinator that records the failure.
            RuntimeHeap = erlang:max(
                            ?DEFAULT_MAX_HEAP_WORDS,
                            maps:get(max_heap_words, Opts) * 2),
            Pid = spawn_opt(
                    fun() -> runtime_main(State) end,
                    [{max_heap_size,
                      #{size => RuntimeHeap, kill => true,
                        error_logger => false}}]),
            {ok, Pid, Ref};
        {error, _} = Error -> Error
    end;
start(_, _, _, _, _) ->
    {error, invalid_planning_arguments}.

-spec await(pid(), run_ref(), timeout()) ->
    {ok, result()} | {error, term()}.
await(Pid, Ref, Timeout)
  when is_pid(Pid), is_reference(Ref),
       (Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)) ->
    Monitor = erlang:monitor(process, Pid),
    await_result(Pid, Ref, Monitor, Timeout);
await(_, _, _) ->
    {error, invalid_planning_await}.

-spec cancel(pid(), run_ref(), term()) -> ok | {error, term()}.
cancel(Pid, Ref, Reason) when is_pid(Pid), is_reference(Ref) ->
    RequestRef = make_ref(),
    Monitor = erlang:monitor(process, Pid),
    Pid ! {adk_planning_cancel, Ref, Reason, self(), RequestRef},
    receive
        {adk_planning_cancel_reply, RequestRef, Reply} ->
            erlang:demonitor(Monitor, [flush]),
            Reply;
        {'DOWN', Monitor, process, Pid, DownReason} ->
            {error, {planning_process_down, reason_tag(DownReason)}}
    after ?CANCEL_ACK_TIMEOUT_MS ->
        erlang:demonitor(Monitor, [flush]),
        {error, planning_cancel_timeout}
    end;
cancel(_, _, _) ->
    {error, invalid_planning_cancel}.

%% @private Verify a live runtime/correlation pair without changing state.
-spec validate_ref(pid(), run_ref()) -> ok | {error, term()}.
validate_ref(Pid, Ref) when is_pid(Pid), is_reference(Ref) ->
    RequestRef = make_ref(),
    Monitor = erlang:monitor(process, Pid),
    Pid ! {adk_planning_validate_ref, Ref, self(), RequestRef},
    receive
        {adk_planning_validate_reply, RequestRef, Reply} ->
            erlang:demonitor(Monitor, [flush]),
            Reply;
        {'DOWN', Monitor, process, Pid, DownReason} ->
            {error, {planning_process_down, reason_tag(DownReason)}}
    after ?CANCEL_ACK_TIMEOUT_MS ->
        erlang:demonitor(Monitor, [flush]),
        {error, planning_ref_validation_timeout}
    end;
validate_ref(_, _) ->
    {error, invalid_planning_ref}.

-spec encode_result(result()) -> {ok, result()} | {error, term()}.
encode_result(Result) when is_map(Result) ->
    ExpectedKeys = lists:sort(result_keys()),
    case {lists:sort(maps:keys(Result)) =:= ExpectedKeys,
          maps:get(<<"result_schema_version">>, Result, undefined),
          maps:get(<<"status">>, Result, undefined),
          maps:get(<<"plan">>, Result, undefined),
          maps:get(<<"steps_executed">>, Result, undefined),
          maps:get(<<"replans">>, Result, undefined),
          maps:get(<<"duration_ms">>, Result, undefined),
          maps:get(<<"observations">>, Result, undefined),
          maps:get(<<"result">>, Result, undefined),
          maps:get(<<"error">>, Result, undefined),
          maps:get(<<"metadata">>, Result, undefined)} of
        {true, ?RESULT_VERSION, Status, Plan, Steps, Replans, Duration,
         Observations, Value, Error, Metadata}
          when is_binary(Status), is_integer(Steps), Steps >= 0,
               is_integer(Replans), Replans >= 0,
               is_integer(Duration), Duration >= 0,
               is_list(Observations), is_map(Metadata) ->
            case valid_result_status(Status) andalso
                 valid_result_plan(Plan) andalso
                 valid_terminal_fields(Status, Value, Error) of
                true ->
                    case adk_context_guard:sanitize_value(Result) of
                        {ok, Safe} when is_map(Safe) -> {ok, Safe};
                        _ -> {error, invalid_planning_result}
                    end;
                false -> {error, invalid_planning_result}
            end;
        {_, Version, _, _, _, _, _, _, _, _, _}
          when is_integer(Version), Version =/= ?RESULT_VERSION ->
            {error, {unsupported_planning_result_version, Version}};
        _ -> {error, invalid_planning_result}
    end;
encode_result(_) ->
    {error, invalid_planning_result}.

-spec decode_result(map()) -> {ok, result()} | {error, term()}.
decode_result(Result) -> encode_result(Result).

normalize_start(Planner0, Executor0, Goal0, Context0, Opts0) ->
    case {validate_planner(Planner0), validate_executor(Executor0),
          safe_value(Goal0), safe_map(Context0), normalize_options(Opts0)} of
        {{ok, Planner}, {ok, Executor}, {ok, Goal}, {ok, Context},
         {ok, Opts}} ->
            {ok, Planner, Executor, Goal, Context, Opts};
        {{error, _} = Error, _, _, _, _} -> Error;
        {_, {error, _} = Error, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, {error, _} = Error} -> Error
    end.

validate_planner(Descriptor) ->
    validate_descriptor(Descriptor, planner, [{plan, 4}, {review, 6}]).

validate_executor(Descriptor) ->
    validate_descriptor(Descriptor, executor, [{execute, 4}]).

validate_descriptor(Descriptor, Kind, Callbacks) when is_map(Descriptor) ->
    Unknown = maps:without([module, target, config], Descriptor),
    Module = maps:get(module, Descriptor, undefined),
    TargetPresent = maps:is_key(target, Descriptor),
    Target = maps:get(target, Descriptor, undefined),
    Config = maps:get(config, Descriptor, #{}),
    case map_size(Unknown) =:= 0 andalso is_atom(Module)
         andalso TargetPresent andalso is_map(Config) of
        true ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case lists:all(
                           fun({Function, Arity}) ->
                               erlang:function_exported(
                                 Module, Function, Arity)
                           end, Callbacks) of
                        true -> {ok, #{module => Module, target => Target,
                                      config => Config}};
                        false -> {error, {invalid_planning_adapter, Kind,
                                          missing_callback}}
                    end;
                _ -> {error, {invalid_planning_adapter, Kind, unavailable}}
            end;
        false -> {error, {invalid_planning_adapter, Kind}}
    end.

normalize_options(Opts) ->
    Allowed = [max_steps, max_replans, timeout_ms, callback_timeout_ms,
               max_heap_words, max_plan_bytes, result_metadata],
    Unknown = maps:without(Allowed, Opts),
    MaxSteps = maps:get(max_steps, Opts, ?DEFAULT_MAX_STEPS),
    MaxReplans = maps:get(max_replans, Opts, ?DEFAULT_MAX_REPLANS),
    Timeout = maps:get(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
    CallbackTimeout = maps:get(callback_timeout_ms, Opts,
                               ?DEFAULT_CALLBACK_TIMEOUT_MS),
    Heap = maps:get(max_heap_words, Opts, ?DEFAULT_MAX_HEAP_WORDS),
    MaxPlanBytes = maps:get(max_plan_bytes, Opts,
                            ?DEFAULT_MAX_PLAN_BYTES),
    Metadata0 = maps:get(result_metadata, Opts, #{}),
    case {map_size(Unknown) =:= 0,
          is_integer(MaxSteps) andalso MaxSteps > 0,
          is_integer(MaxReplans) andalso MaxReplans >= 0,
          is_integer(Timeout) andalso Timeout > 0,
          is_integer(CallbackTimeout) andalso CallbackTimeout > 0,
          is_integer(Heap) andalso Heap >= 1000,
          is_integer(MaxPlanBytes) andalso MaxPlanBytes > 0,
          safe_map(Metadata0)} of
        {true, true, true, true, true, true, true, {ok, Metadata}} ->
            {ok, #{max_steps => MaxSteps,
                   max_replans => MaxReplans,
                   timeout_ms => Timeout,
                   callback_timeout_ms => CallbackTimeout,
                   max_heap_words => Heap,
                   max_plan_bytes => MaxPlanBytes,
                   result_metadata => Metadata}};
        _ -> {error, invalid_planning_options}
    end.

runtime_main(State0) ->
    Owner = maps:get(owner, State0),
    OwnerMonitor = erlang:monitor(process, Owner),
    State = State0#{owner_monitor => OwnerMonitor},
    case initial_plan(State) of
        {terminal, Result} -> deliver(State, Result);
        owner_down -> ok
    end.

initial_plan(State) ->
    case poll_control(State) of
        continue ->
            Planner = maps:get(planner, State),
            Args = [maps:get(target, Planner), maps:get(goal, State),
                    maps:get(context, State), maps:get(config, Planner)],
            case invoke_callback(State, maps:get(module, Planner),
                                 plan, Args) of
                {ok, {ok, Plan0}} -> accept_initial_plan(State, Plan0);
                {ok, {complete, Value}} -> complete_terminal(State, Value);
                {ok, {error, Reason}} ->
                    fail_terminal(State, planner_failed, Reason);
                {ok, _Other} ->
                    fail_terminal(State, invalid_planner_output);
                {error, deadline_exceeded} ->
                    fail_terminal(State, deadline_exceeded);
                {error, Reason} ->
                    fail_terminal(State, planner_callback_failed, Reason);
                {cancelled, Reason} -> cancel_terminal(State, Reason);
                owner_down -> owner_down
            end;
        {cancelled, Reason} -> cancel_terminal(State, Reason);
        owner_down -> owner_down
    end.

accept_initial_plan(State, Plan0) ->
    case validate_runtime_plan(Plan0, initial, State) of
        {ok, Plan} ->
            execute_plan(State#{plan => Plan,
                                pending => adk_plan:steps(Plan)});
        {error, Reason} ->
            fail_terminal(State, invalid_initial_plan, Reason)
    end.

execute_plan(State) ->
    case poll_control(State) of
        continue -> execute_plan_ready(State);
        {cancelled, Reason} -> cancel_terminal(State, Reason);
        owner_down -> owner_down
    end.

execute_plan_ready(State) ->
    case remaining_ms(State) of
        0 -> fail_terminal(State, deadline_exceeded);
        _ ->
            case maps:get(pending, State) of
                [] -> finish_from_last_observation(State);
                [Step | Rest] -> execute_step(State, Step, Rest)
            end
    end.

execute_step(State, Step, Rest) ->
    StepsExecuted = maps:get(steps_executed, State),
    MaxSteps = maps:get(max_steps, maps:get(options, State)),
    case StepsExecuted >= MaxSteps of
        true -> fail_terminal(State, max_steps_exceeded,
                              #{limit => MaxSteps});
        false ->
            Executor = maps:get(executor, State),
            Args = [maps:get(target, Executor), Step,
                    maps:get(context, State), maps:get(config, Executor)],
            case invoke_callback(State, maps:get(module, Executor),
                                 execute, Args) of
                {ok, Raw} ->
                    Observation = executor_observation(
                                    State, Step,
                                    normalize_executor_result(Raw)),
                    review_step(append_observation(
                                  State#{pending => Rest}, Observation),
                                Step, Observation);
                {error, deadline_exceeded} ->
                    fail_terminal(State, deadline_exceeded);
                {error, Reason} ->
                    Observation = executor_observation(
                                    State, Step,
                                    {error,
                                     failure_map(executor_callback_failed,
                                                 Reason)}),
                    review_step(append_observation(
                                  State#{pending => Rest}, Observation),
                                Step, Observation);
                {cancelled, Reason} -> cancel_terminal(State, Reason);
                owner_down -> owner_down
            end
    end.

append_observation(State, Observation) ->
    State#{observations => [Observation |
                            maps:get(observations, State)],
           steps_executed => maps:get(steps_executed, State) + 1}.

review_step(State, Step, Observation) ->
    Planner = maps:get(planner, State),
    Args = [maps:get(target, Planner), maps:get(plan, State), Step,
            Observation, maps:get(context, State),
            maps:get(config, Planner)],
    case invoke_callback(State, maps:get(module, Planner), review, Args) of
        {ok, Decision} -> apply_decision(State, Observation, Decision);
        {error, deadline_exceeded} ->
            fail_terminal(State, deadline_exceeded);
        {error, Reason} ->
            fail_terminal(State, planner_callback_failed, Reason);
        {cancelled, Reason} -> cancel_terminal(State, Reason);
        owner_down -> owner_down
    end.

apply_decision(State, Observation, continue) ->
    case maps:get(pending, State) of
        [] -> finish_from_observation(State, Observation);
        [_ | _] -> execute_plan(State)
    end;
apply_decision(State, _Observation, {complete, Value}) ->
    complete_terminal(State, Value);
apply_decision(State, _Observation, {fail, Reason}) ->
    fail_terminal(State, planner_failed, Reason);
apply_decision(State, _Observation, {error, Reason}) ->
    fail_terminal(State, planner_failed, Reason);
apply_decision(State, _Observation, {replan, Plan0}) ->
    apply_replan(State, Plan0);
apply_decision(State, _Observation, _Other) ->
    fail_terminal(State, invalid_planner_decision).

apply_replan(State, Plan0) ->
    Replans = maps:get(replans, State),
    MaxReplans = maps:get(max_replans, maps:get(options, State)),
    case Replans >= MaxReplans of
        true -> fail_terminal(State, max_replans_exceeded,
                              #{limit => MaxReplans});
        false ->
            case validate_runtime_plan(Plan0, replan, State) of
                {ok, Plan} ->
                    execute_plan(State#{plan => Plan,
                                        pending => adk_plan:steps(Plan),
                                        replans => Replans + 1});
                {error, Reason} ->
                    fail_terminal(State, invalid_replan, Reason)
            end
    end.

validate_runtime_plan(Plan0, Mode, State) ->
    case adk_plan:validate(Plan0) of
        {ok, Plan} ->
            case valid_plan_identity(Plan, Mode, State) of
                true ->
                    case plan_size(Plan) =< maps:get(
                           max_plan_bytes, maps:get(options, State)) of
                        true -> {ok, Plan};
                        false -> {error, plan_size_limit_exceeded}
                    end;
                false -> {error, invalid_plan_identity}
            end;
        {error, Reason} -> {error, Reason}
    end.

valid_plan_identity(Plan, initial, State) ->
    maps:get(<<"revision">>, Plan) =:= 0 andalso
    maps:get(<<"goal">>, Plan) =:= maps:get(goal, State);
valid_plan_identity(Plan, replan, State) ->
    Current = maps:get(plan, State),
    maps:get(<<"id">>, Plan) =:= maps:get(<<"id">>, Current) andalso
    maps:get(<<"revision">>, Plan) =:=
        maps:get(<<"revision">>, Current) + 1 andalso
    maps:get(<<"goal">>, Plan) =:= maps:get(goal, State).

plan_size(Plan) ->
    try byte_size(jsx:encode(Plan))
    catch _:_ -> 1 bsl 62
    end.

normalize_executor_result({ok, Value}) ->
    case safe_value(Value) of
        {ok, Safe} -> {ok, Safe};
        {error, _} ->
            {error, failure_map(invalid_executor_output)}
    end;
normalize_executor_result({error, Reason}) ->
    {error, failure_map(executor_failed, Reason)};
normalize_executor_result(_Other) ->
    {error, failure_map(invalid_executor_result)}.

executor_observation(State, Step, {ok, Output}) ->
    (observation_base(State, Step))#{
        <<"status">> => <<"ok">>, <<"output">> => Output};
executor_observation(State, Step, {error, Error}) ->
    (observation_base(State, Step))#{
        <<"status">> => <<"error">>, <<"error">> => Error}.

observation_base(State, Step) ->
    Plan = maps:get(plan, State),
    #{<<"plan_id">> => maps:get(<<"id">>, Plan),
      <<"revision">> => maps:get(<<"revision">>, Plan),
      <<"step_id">> => maps:get(<<"id">>, Step),
      <<"attempt">> => maps:get(steps_executed, State) + 1}.

finish_from_last_observation(State) ->
    case maps:get(observations, State) of
        [Observation | _] -> finish_from_observation(State, Observation);
        [] -> fail_terminal(State, empty_plan_execution)
    end.

finish_from_observation(State, Observation) ->
    case maps:get(<<"status">>, Observation) of
        <<"ok">> -> complete_terminal(
                      State, maps:get(<<"output">>, Observation));
        <<"error">> -> fail_terminal(
                         State, step_failed,
                         maps:get(<<"error">>, Observation))
    end.

complete_terminal(State, Value0) ->
    case safe_value(Value0) of
        {ok, Value} ->
            {terminal, build_result(State, <<"completed">>, Value, null)};
        {error, _} -> fail_terminal(State, invalid_planner_result)
    end.

fail_terminal(State, Kind) ->
    {terminal, build_result(State, <<"failed">>, null,
                            failure_map(Kind))}.

fail_terminal(State, Kind, Reason) ->
    {terminal, build_result(State, <<"failed">>, null,
                            failure_map(Kind, Reason))}.

cancel_terminal(State, Reason) ->
    {terminal, build_result(State, <<"cancelled">>, null,
                            failure_map(cancelled, Reason))}.

build_result(State, Status, Value, Error) ->
    #{<<"result_schema_version">> => ?RESULT_VERSION,
      <<"status">> => Status,
      <<"plan">> => maps:get(plan, State),
      <<"steps_executed">> => maps:get(steps_executed, State),
      <<"replans">> => maps:get(replans, State),
      <<"duration_ms">> => elapsed_ms(maps:get(started, State)),
      <<"observations">> => lists:reverse(
                              maps:get(observations, State)),
      <<"result">> => Value,
      <<"error">> => Error,
      <<"metadata">> => maps:get(
                           result_metadata, maps:get(options, State))}.

deliver(State, Result0) ->
    Result = case encode_result(Result0) of
        {ok, Encoded} -> Encoded;
        {error, _} -> fallback_result(State)
    end,
    maps:get(owner, State) !
        {adk_planning_result, maps:get(ref, State), self(), Result},
    ok.

fallback_result(State) ->
    #{<<"result_schema_version">> => ?RESULT_VERSION,
      <<"status">> => <<"failed">>, <<"plan">> => null,
      <<"steps_executed">> => maps:get(steps_executed, State, 0),
      <<"replans">> => maps:get(replans, State, 0),
      <<"duration_ms">> => elapsed_ms(maps:get(started, State)),
      <<"observations">> => [], <<"result">> => null,
      <<"error">> => failure_map(internal_result_validation_failed),
      <<"metadata">> => #{}}.

invoke_callback(State, Module, Function, Args) ->
    Remaining = remaining_ms(State),
    case Remaining of
        0 -> {error, deadline_exceeded};
        _ -> start_callback(State, Module, Function, Args, Remaining)
    end.

start_callback(State, Module, Function, Args, Remaining) ->
    Parent = self(),
    Token = make_ref(),
    Worker = fun() ->
        Reply = try erlang:apply(Module, Function, Args) of
            Value -> {value, Value}
        catch
            Class:Reason ->
                {exception, Class, reason_tag(Reason)}
        end,
        Parent ! {adk_planning_callback, Token, self(), Reply}
    end,
    Heap = maps:get(max_heap_words, maps:get(options, State)),
    {Pid, Monitor} = spawn_opt(
                       Worker,
                       [monitor,
                        {max_heap_size,
                         #{size => Heap, kill => true,
                           error_logger => false}}]),
    CallbackTimeout = maps:get(
                        callback_timeout_ms, maps:get(options, State)),
    Wait = erlang:min(Remaining, CallbackTimeout),
    TimeoutReason = case Remaining =< CallbackTimeout of
        true -> deadline_exceeded;
        false -> callback_timeout
    end,
    WaitDeadline = erlang:monotonic_time(millisecond) + Wait,
    wait_callback(State, Pid, Monitor, Token,
                  WaitDeadline, TimeoutReason).

wait_callback(State, Pid, Monitor, Token,
              WaitDeadline, TimeoutReason) ->
    Ref = maps:get(ref, State),
    OwnerMonitor = maps:get(owner_monitor, State),
    Wait = erlang:max(
             0, WaitDeadline - erlang:monotonic_time(millisecond)),
    receive
        {adk_planning_callback, Token, Pid, {value, Value}} ->
            erlang:demonitor(Monitor, [flush]),
            {ok, Value};
        {adk_planning_callback, Token, Pid,
         {exception, Class, ReasonTag}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, {callback_exception, Class, ReasonTag}};
        {'DOWN', Monitor, process, Pid, _Reason} ->
            flush_callback(Token, Pid),
            {error, callback_worker_down};
        {adk_planning_validate_ref, CandidateRef,
         ReplyTo, RequestRef}
          when is_pid(ReplyTo), is_reference(RequestRef) ->
            Reply = case CandidateRef =:= Ref of
                true -> ok;
                false -> {error, invalid_planning_ref}
            end,
            ReplyTo ! {adk_planning_validate_reply, RequestRef, Reply},
            wait_callback(State, Pid, Monitor, Token,
                          WaitDeadline, TimeoutReason);
        {adk_planning_cancel, CandidateRef, Reason,
         ReplyTo, RequestRef}
          when is_pid(ReplyTo), is_reference(RequestRef) ->
            case CandidateRef =:= Ref of
                true ->
                    ReplyTo ! {adk_planning_cancel_reply, RequestRef, ok},
                    stop_callback(Pid, Monitor),
                    {cancelled, safe_reason(Reason)};
                false ->
                    ReplyTo ! {adk_planning_cancel_reply, RequestRef,
                               {error, invalid_planning_ref}},
                    wait_callback(State, Pid, Monitor, Token,
                                  WaitDeadline, TimeoutReason)
            end;
        {adk_planning_cancel, Ref, Reason} ->
            stop_callback(Pid, Monitor),
            {cancelled, safe_reason(Reason)};
        {'DOWN', OwnerMonitor, process, _Owner, _Reason} ->
            stop_callback(Pid, Monitor),
            owner_down
    after Wait ->
        stop_callback(Pid, Monitor),
        {error, TimeoutReason}
    end.

stop_callback(Pid, Monitor) ->
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 100 ->
        erlang:demonitor(Monitor, [flush])
    end.

flush_callback(Token, Pid) ->
    receive
        {adk_planning_callback, Token, Pid, _} -> ok
    after 0 -> ok
    end.

poll_control(State) ->
    Ref = maps:get(ref, State),
    OwnerMonitor = maps:get(owner_monitor, State),
    receive
        {adk_planning_validate_ref, CandidateRef,
         ReplyTo, RequestRef}
          when is_pid(ReplyTo), is_reference(RequestRef) ->
            Reply = case CandidateRef =:= Ref of
                true -> ok;
                false -> {error, invalid_planning_ref}
            end,
            ReplyTo ! {adk_planning_validate_reply, RequestRef, Reply},
            poll_control(State);
        {adk_planning_cancel, CandidateRef, Reason,
         ReplyTo, RequestRef}
          when is_pid(ReplyTo), is_reference(RequestRef) ->
            case CandidateRef =:= Ref of
                true ->
                    ReplyTo ! {adk_planning_cancel_reply, RequestRef, ok},
                    {cancelled, safe_reason(Reason)};
                false ->
                    ReplyTo ! {adk_planning_cancel_reply, RequestRef,
                               {error, invalid_planning_ref}},
                    poll_control(State)
            end;
        {adk_planning_cancel, Ref, Reason} ->
            {cancelled, safe_reason(Reason)};
        {'DOWN', OwnerMonitor, process, _Owner, _Reason} ->
            owner_down
    after 0 ->
        continue
    end.

await_result(Pid, Ref, Monitor, infinity) ->
    receive
        {adk_planning_result, Ref, Pid, Result} ->
            erlang:demonitor(Monitor, [flush]),
            {ok, Result};
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, {planning_process_down, reason_tag(Reason)}}
    end;
await_result(Pid, Ref, Monitor, Timeout) ->
    receive
        {adk_planning_result, Ref, Pid, Result} ->
            erlang:demonitor(Monitor, [flush]),
            {ok, Result};
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, {planning_process_down, reason_tag(Reason)}}
    after Timeout ->
        erlang:demonitor(Monitor, [flush]),
        {error, planning_await_timeout}
    end.

failure_map(Kind) ->
    #{<<"kind">> => atom_to_binary(Kind, utf8)}.

failure_map(Kind, Reason) ->
    (failure_map(Kind))#{<<"reason">> => safe_reason(Reason)}.

safe_reason(Reason) ->
    Redacted = adk_secret_redactor:redact(Reason),
    case adk_context_guard:sanitize_value(Redacted) of
        {ok, Safe} -> Safe;
        {error, _} -> atom_to_binary(reason_tag(Reason), utf8)
    end.

safe_value(Value) ->
    case adk_context_guard:sanitize_value(Value) of
        {ok, Safe} -> {ok, Safe};
        {error, Reason} -> {error, {invalid_json, reason_tag(Reason)}}
    end.

safe_map(Value) when is_map(Value) ->
    case safe_value(Value) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        _ -> {error, invalid_json_map}
    end;
safe_map(_) ->
    {error, invalid_json_map}.

remaining_ms(State) ->
    erlang:max(0, maps:get(deadline, State) -
                   erlang:monotonic_time(millisecond)).

elapsed_ms(Started) ->
    erlang:max(0, erlang:monotonic_time(millisecond) - Started).

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _, _}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(_) -> planning_failed.

valid_result_status(<<"completed">>) -> true;
valid_result_status(<<"failed">>) -> true;
valid_result_status(<<"cancelled">>) -> true;
valid_result_status(_) -> false.

valid_terminal_fields(<<"completed">>, _Value, null) -> true;
valid_terminal_fields(<<"failed">>, null, Error) when is_map(Error) ->
    valid_failure(Error);
valid_terminal_fields(<<"cancelled">>, null, Error) when is_map(Error) ->
    valid_failure(Error);
valid_terminal_fields(_, _, _) -> false.

valid_failure(#{<<"kind">> := Kind}) when is_binary(Kind),
                                           byte_size(Kind) > 0 ->
    true;
valid_failure(_) -> false.

valid_result_plan(null) -> true;
valid_result_plan(Plan) when is_map(Plan) ->
    case adk_plan:validate(Plan) of
        {ok, Plan} -> true;
        _ -> false
    end;
valid_result_plan(_) -> false.

result_keys() ->
    [<<"result_schema_version">>, <<"status">>, <<"plan">>,
     <<"steps_executed">>, <<"replans">>, <<"duration_ms">>,
     <<"observations">>, <<"result">>, <<"error">>, <<"metadata">>].
