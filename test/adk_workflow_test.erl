-module(adk_workflow_test).
-include_lib("eunit/include/eunit.hrl").

workflow_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun supervisor_and_public_facade_case/0,
      fun compile_validation_case/0,
      fun sequential_delta_case/0,
      fun cancellation_stops_blocked_worker_case/0,
      fun coordinator_death_stops_blocked_worker_case/0,
      fun absolute_deadline_stops_blocked_worker_case/0,
      fun parallel_is_bounded_and_merge_is_ordered_case/0,
      fun parallel_conflict_is_deterministic_case/0,
      fun parallel_failure_stops_sibling_case/0,
      fun loop_budget_and_completion_case/0,
      fun transfer_state_budget_and_event_case/0,
      fun transfer_resolves_restarted_agent_by_name_case/0,
      fun graph_route_and_step_budget_case/0,
      fun checkpoint_resume_does_not_replay_committed_step_case/0,
      fun public_failures_are_sanitized_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_Setup) -> ok.

supervisor_and_public_facade_case() ->
    ?assert(is_pid(whereis(adk_workflow_sup))),
    {ok, {_Flags, Children}} = erlang_adk_sup:init([]),
    ?assert(lists:any(
              fun(#{id := adk_workflow_sup,
                    type := supervisor}) -> true;
                 (_) -> false
              end, Children)),
    Spec = base_spec(
             sequential,
             #{steps => [step(<<"facade">>,
                              fun(_) ->
                                  {ok, #{<<"facade">> => true}}
                              end)]}),
    {ok, Compiled} = erlang_adk:compile_workflow(Spec),
    {completed, State, _} = erlang_adk:run_workflow(Compiled, #{}),
    ?assertEqual(true, maps:get(<<"facade">>, State)).

compile_validation_case() ->
    Duplicate = base_spec(
                  sequential,
                  #{steps => [step(<<"same">>, ok_action()),
                              step(<<"same">>, ok_action())]}),
    ?assertEqual(
       {error, {invalid_workflow, [steps, 2, id],
                {duplicate_id, <<"same">>}}},
       adk_workflow:compile(Duplicate)),

    MissingEdge = base_spec(
                    graph,
                    #{entry => <<"a">>,
                      nodes => [step(<<"a">>, ok_action())],
                      edges => #{}}),
    ?assertEqual(
       {error, {invalid_workflow, [edges],
                every_node_requires_explicit_edge}},
       adk_workflow:compile(MissingEdge)),

    InvalidMax = base_spec(
                   sequential,
                   #{steps => [step(<<"a">>, ok_action())],
                     max_steps => 0}),
    ?assertEqual(
       {error, {invalid_workflow, [max_steps],
                expected_positive_integer}},
       adk_workflow:compile(InvalidMax)).

sequential_delta_case() ->
    First = fun(State, Context) ->
        ?assertEqual(<<"one">>, maps:get(step_id, Context)),
        {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
    end,
    Second = fun(State) ->
        {complete, <<"finished">>,
         #{<<"count">> => maps:get(<<"count">>, State) + 1,
           <<"done">> => true}}
    end,
    Compiled = compile_ok(
                 base_spec(sequential,
                           #{steps => [step(<<"one">>, First),
                                       step(<<"two">>, Second)],
                             max_steps => 4})),
    {completed, State, Checkpoint} =
        adk_workflow:run(Compiled, #{<<"initial">> => true}),
    ?assertEqual(2, maps:get(<<"count">>, State)),
    ?assertEqual(true, maps:get(<<"done">>, State)),
    ?assertEqual(true, maps:get(<<"completed">>, Checkpoint)),
    ?assertEqual(<<"finished">>, maps:get(<<"output">>, Checkpoint)).

cancellation_stops_blocked_worker_case() ->
    Parent = self(),
    Block = fun(_State) ->
        Parent ! {cancel_worker, self()},
        receive never -> impossible end
    end,
    Compiled = compile_ok(
                 base_spec(sequential,
                           #{steps => [step(<<"block">>, Block)]})),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{timeout => 5000,
                                   retention_ms => 2000}),
    Worker = receive {cancel_worker, Pid} -> Pid after 1000 -> timeout end,
    ?assert(is_pid(Worker)),
    WorkerMonitor = erlang:monitor(process, Worker),
    {ok, Status} = adk_workflow:status(Ref),
    ?assertEqual(running, maps:get(state, Status)),
    ok = adk_workflow:cancel(Ref, test_cancel),
    {cancelled, test_cancel, Checkpoint} = adk_workflow:await(Ref, 1000),
    ?assertEqual(false, maps:get(<<"completed">>, Checkpoint)),
    receive
        {'DOWN', WorkerMonitor, process, Worker, killed} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertEqual({error, already_terminal},
                 adk_workflow:cancel(Ref, second_cancel)).

coordinator_death_stops_blocked_worker_case() ->
    Parent = self(),
    Block = fun(_State) ->
        Parent ! {orphan_check_worker, self()},
        receive never -> impossible end
    end,
    Compiled = compile_ok(
                 base_spec(sequential,
                           #{steps => [step(<<"block">>, Block)]})),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{timeout => 5000}),
    Worker = receive
        {orphan_check_worker, Pid} -> Pid
    after 1000 -> timeout
    end,
    ?assert(is_pid(Worker)),
    WorkerMonitor = erlang:monitor(process, Worker),
    exit(Ref, kill),
    receive
        {'DOWN', WorkerMonitor, process, Worker, _Reason} -> ok
    after 1000 -> ?assert(false)
    end.

absolute_deadline_stops_blocked_worker_case() ->
    Parent = self(),
    Block = fun(_State) ->
        Parent ! {deadline_worker, self()},
        receive never -> impossible end
    end,
    Compiled = compile_ok(
                 base_spec(sequential,
                           #{steps => [step(<<"block">>, Block)]})),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{timeout => 30,
                                   retention_ms => 2000}),
    Worker = receive {deadline_worker, Pid} -> Pid after 1000 -> timeout end,
    ?assert(is_pid(Worker)),
    WorkerMonitor = erlang:monitor(process, Worker),
    {timed_out, _Checkpoint} = adk_workflow:await(Ref, 1000),
    receive
        {'DOWN', WorkerMonitor, process, Worker, killed} -> ok
    after 1000 -> ?assert(false)
    end,

    ExpiredAction = fun(_State) ->
        Parent ! expired_action_was_started,
        {ok, #{}}
    end,
    ExpiredCompiled = compile_ok(
                        base_spec(sequential,
                                  #{steps => [step(<<"expired">>,
                                                   ExpiredAction)]})),
    PastDeadline = erlang:monotonic_time(millisecond) - 1,
    {timed_out, _} = adk_workflow:run(
                       ExpiredCompiled, #{},
                       #{deadline => PastDeadline}),
    receive expired_action_was_started -> ?assert(false)
    after 20 -> ok
    end.

parallel_is_bounded_and_merge_is_ordered_case() ->
    Parent = self(),
    Branch = fun(Id) ->
        fun(_State) ->
            Parent ! {parallel_started, Id, self()},
            receive release -> {ok, #{<<"winner">> => Id}} end
        end
    end,
    Branches = [step(integer_to_binary(Id), Branch(Id))
                || Id <- [1, 2, 3]],
    Compiled = compile_ok(
                 base_spec(parallel,
                           #{branches => Branches,
                             merge => ordered_last_wins,
                             max_concurrency => 2,
                             max_steps => 3})),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{retention_ms => 2000}),
    Started0 = collect_parallel_started(2, #{}),
    receive
        {parallel_started, 3, _} -> ?assert(false)
    after 25 -> ok
    end,
    maps:get(2, Started0) ! release,
    Started = collect_parallel_started(1, Started0),
    maps:get(1, Started) ! release,
    maps:get(3, Started) ! release,
    {completed, State, _Checkpoint} = adk_workflow:await(Ref, 1000),
    %% Branch 2 completed before branches 1 and 3, but merge order remains
    %% the declared branch order.
    ?assertEqual(3, maps:get(<<"winner">>, State)).

parallel_conflict_is_deterministic_case() ->
    Branches = [step(<<"left">>,
                     fun(_) -> {ok, #{<<"shared">> => 1}} end),
                step(<<"right">>,
                     fun(_) -> {ok, #{<<"shared">> => 2}} end)],
    Compiled = compile_ok(
                 base_spec(parallel,
                           #{branches => Branches,
                             merge => reject_conflicts,
                             max_concurrency => 2})),
    {failed, {state_conflict, {adk_failure, Conflict},
              [<<"left">>, <<"right">>]}, Checkpoint} =
        adk_workflow:run(Compiled, #{}),
    ?assertEqual(state_conflict, maps:get(operation, Conflict)),
    ?assertEqual(#{}, maps:get(<<"state">>, Checkpoint)).

parallel_failure_stops_sibling_case() ->
    Parent = self(),
    Blocking = fun(_State) ->
        Parent ! {parallel_sibling, self()},
        receive never -> impossible end
    end,
    Failure = fun(_State) ->
        Parent ! {parallel_failure, self()},
        receive release_failure -> {error, expected_failure} end
    end,
    Compiled = compile_ok(
                 base_spec(parallel,
                           #{branches =>
                                 [step(<<"blocking">>, Blocking),
                                  step(<<"failure">>, Failure)],
                             max_concurrency => 2})),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{retention_ms => 2000}),
    Sibling = receive {parallel_sibling, SiblingPid} -> SiblingPid
              after 1000 -> timeout
              end,
    ?assert(is_pid(Sibling)),
    SiblingMonitor = erlang:monitor(process, Sibling),
    FailurePid = receive {parallel_failure, FailureProcess} -> FailureProcess
                 after 1000 -> timeout
                 end,
    ?assert(is_pid(FailurePid)),
    {ok, Status} = adk_workflow:status(Ref),
    ?assertEqual(running, maps:get(state, Status)),
    FailurePid ! release_failure,
    {failed, {branch_failed, <<"failure">>, expected_failure}, _} =
        adk_workflow:await(Ref, 1000),
    receive
        {'DOWN', SiblingMonitor, process, Sibling, killed} -> ok
    after 1000 -> ?assert(false)
    end.

loop_budget_and_completion_case() ->
    Body = fun(State) ->
        {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
    end,
    Until = fun(State) -> maps:get(<<"count">>, State) >= 3 end,
    Completed = compile_ok(
                  base_spec(loop,
                            #{body => Body, until => Until,
                              max_iterations => 3,
                              max_steps => 4})),
    {completed, State, _} =
        adk_workflow:run(Completed, #{<<"count">> => 0}),
    ?assertEqual(3, maps:get(<<"count">>, State)),

    Exhausted = compile_ok(
                  base_spec(loop,
                            #{body => Body, until => fun(_) -> false end,
                              max_iterations => 2,
                              max_steps => 4})),
    {failed, {budget_exhausted, iterations}, CP} =
        adk_workflow:run(Exhausted, #{<<"count">> => 0}),
    ?assertEqual(2, maps:get(<<"count">>, maps:get(<<"state">>, CP))),
    ?assertEqual(2, maps:get(<<"iteration">>,
                            maps:get(<<"cursor">>, CP))).

transfer_state_budget_and_event_case() ->
    A = fun(_State, _Context) ->
        {transfer, <<"b">>, <<"handoff-input">>, #{<<"a">> => 1}}
    end,
    B = fun(State, Context) ->
        ?assertEqual(1, maps:get(<<"a">>, State)),
        ?assertEqual(<<"handoff-input">>, maps:get(input, Context)),
        {complete, <<"done">>, #{<<"b_saw_a">> => true}}
    end,
    Spec = base_spec(
             transfer,
             #{entry => <<"a">>,
               members => #{<<"a">> => #{run => A},
                            <<"b">> => #{run => B}},
               max_transfers => 1,
               max_steps => 3}),
    Compiled = compile_ok(Spec),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{event_receiver => self(),
                                   retention_ms => 2000}),
    {completed, State, _CP} = adk_workflow:await(Ref, 1000),
    ?assertEqual(true, maps:get(<<"b_saw_a">>, State)),
    Event = receive
        {adk_workflow_event, Ref, Value} -> Value
    after 1000 -> timeout
    end,
    {ok, EventMap} = adk_event:encode(Event),
    Actions = maps:get(<<"actions">>, EventMap),
    ?assertEqual(<<"b">>, maps:get(<<"transfer_to_agent">>, Actions)),
    ?assertEqual(1, maps:get(<<"transfer_index">>,
                            maps:get(<<"workflow">>, Actions))),

    NoTransfers = compile_ok(Spec#{max_transfers => 0}),
    {failed, {budget_exhausted, transfers}, BudgetCP} =
        adk_workflow:run(NoTransfers, #{}),
    %% The source member completed its state update even though its requested
    %% handoff exceeded the transfer budget.
    ?assertEqual(1, maps:get(<<"a">>,
                            maps:get(<<"state">>, BudgetCP))).

transfer_resolves_restarted_agent_by_name_case() ->
    AName = <<"workflow-registry-a">>,
    BName = <<"workflow-registry-b">>,
    ensure_unregistered(AName),
    ensure_unregistered(BName),
    AAgent = spawn(fun() -> dummy_agent(<<"a-response">>) end),
    OldB = spawn(fun() -> dummy_agent(<<"old-b">>) end),
    yes = adk_agent_registry:register_name(AName, AAgent),
    yes = adk_agent_registry:register_name(BName, OldB),
    Parent = self(),
    DecideA = fun(_Response, _State, _Context) ->
        Parent ! {a_deciding, self()},
        receive continue_transfer -> ok end,
        {transfer, <<"b">>, <<"from-a">>, #{}}
    end,
    Spec = base_spec(
             transfer,
             #{entry => <<"a">>,
               members =>
                   #{<<"a">> =>
                         #{run => {agent, AName, <<"prompt-a">>, DecideA}},
                     <<"b">> =>
                         #{run => {agent, BName, <<"prompt-b">>}}},
               max_transfers => 1,
               max_steps => 3}),
    Compiled = compile_ok(Spec),
    try
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{}, #{retention_ms => 2000}),
        DecisionWorker = receive
            {a_deciding, Pid} -> Pid
        after 1000 -> timeout
        end,
        ?assert(is_pid(DecisionWorker)),
        ok = adk_agent_registry:unregister_name(BName),
        exit(OldB, kill),
        NewB = spawn(fun() -> dummy_agent(<<"new-b">>) end),
        yes = adk_agent_registry:register_name(BName, NewB),
        DecisionWorker ! continue_transfer,
        {completed, State, _} = adk_workflow:await(Ref, 1000),
        ?assertEqual(<<"new-b">>, maps:get(<<"last_response">>, State)),
        exit(NewB, kill)
    after
        ensure_unregistered(AName),
        ensure_unregistered(BName),
        exit(AAgent, kill),
        _ = catch exit(OldB, kill)
    end.

graph_route_and_step_budget_case() ->
    Increment = fun(State) ->
        {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
    end,
    Finish = fun(State) ->
        ?assertEqual(1, maps:get(<<"count">>, State)),
        {ok, #{<<"finished">> => true}}
    end,
    Route = fun(State) ->
        case maps:get(<<"count">>, State) of
            1 -> <<"finish">>;
            _ -> <<"missing">>
        end
    end,
    Compiled = compile_ok(
                 base_spec(graph,
                           #{entry => <<"increment">>,
                             nodes => [step(<<"increment">>, Increment),
                                       step(<<"finish">>, Finish)],
                             edges => #{<<"increment">> => {route, Route},
                                        <<"finish">> => end_node},
                             max_steps => 3})),
    {completed, State, _} =
        adk_workflow:run(Compiled, #{<<"count">> => 0}),
    ?assertEqual(true, maps:get(<<"finished">>, State)),

    Cycle = compile_ok(
              base_spec(graph,
                        #{entry => <<"cycle">>,
                          nodes => [step(<<"cycle">>, Increment)],
                          edges => #{<<"cycle">> => <<"cycle">>},
                          max_steps => 3})),
    {failed, {budget_exhausted, steps}, CycleCP} =
        adk_workflow:run(Cycle, #{<<"count">> => 0}),
    ?assertEqual(3, maps:get(<<"count">>,
                            maps:get(<<"state">>, CycleCP))).

checkpoint_resume_does_not_replay_committed_step_case() ->
    Table = ets:new(workflow_resume_test, [set, public]),
    ets:insert(Table, [{first_calls, 0}, {allow_second, false}]),
    Parent = self(),
    First = fun(_State) ->
        ets:update_counter(Table, first_calls, 1),
        {ok, #{<<"first_committed">> => true}}
    end,
    Second = fun(_State) ->
        case ets:lookup_element(Table, allow_second, 2) of
            true -> {ok, #{<<"second_committed">> => true}};
            false ->
                Parent ! {resume_second_blocked, self()},
                receive never -> impossible end
        end
    end,
    Compiled = compile_ok(
                 base_spec(sequential,
                           #{steps => [step(<<"first">>, First),
                                       step(<<"second">>, Second)],
                             max_steps => 4})),
    try
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{}, #{retention_ms => 3000}),
        receive {resume_second_blocked, _Pid} -> ok
        after 1000 -> ?assert(false)
        end,
        CP0 = wait_for_checkpoint(Ref, fun(CP) ->
            Cursor = maps:get(<<"cursor">>, CP),
            maps:get(<<"next_index">>, Cursor, 0) =:= 2
            andalso maps:get(<<"first_committed">>,
                             maps:get(<<"state">>, CP), false)
        end),
        ok = adk_workflow:cancel(Ref, checkpoint_test),
        {cancelled, checkpoint_test, CancelCP} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(maps:get(<<"state">>, CP0),
                     maps:get(<<"state">>, CancelCP)),
        ets:insert(Table, {allow_second, true}),
        {ok, ResumedRef} = adk_workflow:resume(
                            Compiled, CancelCP,
                            #{retention_ms => 2000}),
        {completed, State, CompleteCP} =
            adk_workflow:await(ResumedRef, 1000),
        ?assertEqual(true, maps:get(<<"second_committed">>, State)),
        ?assertEqual(1, ets:lookup_element(Table, first_calls, 2)),
        ?assertEqual({error, checkpoint_complete},
                     adk_workflow:resume(Compiled, CompleteCP))
    after
        ets:delete(Table)
    end.

public_failures_are_sanitized_case() ->
    Parent = self(),
    Crash = fun(_State) -> erlang:error({seeded_secret, Parent}) end,
    Compiled = compile_ok(
                 base_spec(sequential,
                           #{steps => [step(<<"crash">>, Crash)]})),
    {failed, Reason, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(false, contains_unsafe_term(Reason)),
    ?assertEqual(false, contains_unsafe_term(Checkpoint)),
    {step_failed, <<"crash">>,
     {action_exception, {adk_failure, Failure}}} = Reason,
    ?assertEqual(adk_workflow_action, maps:get(component, Failure)),
    ?assertEqual(error, maps:get(class, Failure)),
    ?assertEqual(seeded_secret, maps:get(reason, Failure)).

%% Helpers

base_spec(Kind, Extra) ->
    maps:merge(#{version => 1,
                 id => <<"workflow-test">>,
                 kind => Kind}, Extra).

step(Id, Action) -> #{id => Id, run => Action}.

ok_action() -> fun(_) -> {ok, #{}} end.

compile_ok(Spec) ->
    {ok, Compiled} = adk_workflow:compile(Spec),
    Compiled.

collect_parallel_started(0, Acc) -> Acc;
collect_parallel_started(Count, Acc) ->
    receive
        {parallel_started, Id, Pid} ->
            collect_parallel_started(Count - 1, Acc#{Id => Pid})
    after 1000 ->
        erlang:error({missing_parallel_workers, Count})
    end.

wait_for_checkpoint(Ref, Predicate) ->
    wait_for_checkpoint(Ref, Predicate, 100).

wait_for_checkpoint(_Ref, _Predicate, 0) ->
    erlang:error(checkpoint_not_observed);
wait_for_checkpoint(Ref, Predicate, Attempts) ->
    {ok, CP} = adk_workflow:checkpoint(Ref),
    case Predicate(CP) of
        true -> CP;
        false ->
            receive after 5 -> ok end,
            wait_for_checkpoint(Ref, Predicate, Attempts - 1)
    end.

dummy_agent(Response) ->
    receive
        {'$gen_call', From, {prompt, _Prompt}} ->
            gen_server:reply(From, {ok, Response}),
            dummy_agent(Response);
        stop -> ok;
        _ -> dummy_agent(Response)
    end.

ensure_unregistered(Name) ->
    case adk_agent_registry:lookup(Name) of
        {ok, Pid} ->
            ok = adk_agent_registry:unregister_name(Name),
            exit(Pid, kill),
            ok;
        {error, not_found} -> ok
    end.

contains_unsafe_term(Value) when is_pid(Value); is_reference(Value);
                                      is_port(Value); is_function(Value) -> true;
contains_unsafe_term(Value) when is_tuple(Value) ->
    lists:any(fun contains_unsafe_term/1, tuple_to_list(Value));
contains_unsafe_term(Value) when is_list(Value) ->
    lists:any(fun contains_unsafe_term/1, Value);
contains_unsafe_term(Value) when is_map(Value) ->
    lists:any(fun({Key, Item}) ->
                      contains_unsafe_term(Key)
                      orelse contains_unsafe_term(Item)
              end, maps:to_list(Value));
contains_unsafe_term(_) -> false.
