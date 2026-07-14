-module(adk_workflow_graph_test).
-include_lib("eunit/include/eunit.hrl").

-export([execute/2]).

graph_workflow_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun fork_fan_in_is_bounded_and_declared_order_wins/0,
      fun completed_fork_branch_is_skipped_after_resume/0,
      fun committed_node_is_not_replayed_when_routing_resumes/0,
      fun dynamic_branch_and_loop_are_bounded/0,
      fun pause_resume_routes_without_replaying_node/0,
      fun fork_failure_stops_sibling/0,
      fun typed_agent_tool_and_nested_workflow_nodes/0,
      fun invalid_graph_topologies_are_rejected/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_Setup) -> ok.

fork_fan_in_is_bounded_and_declared_order_wins() ->
    Parent = self(),
    Branch = fun(Id) ->
        fun(_State) ->
            Parent ! {fork_started, Id, self()},
            receive release -> {ok, #{<<"winner">> => Id}} end
        end
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"fork">>,
                   [fork_node(<<"fork">>, [<<"left">>, <<"right">>],
                              <<"join">>, ordered_last_wins, 2),
                    action_node(<<"left">>, Branch(<<"left">>)),
                    action_node(<<"right">>, Branch(<<"right">>)),
                    join_node(<<"join">>)],
                   #{<<"left">> => <<"join">>,
                     <<"right">> => <<"join">>,
                     <<"join">> => end_node}, 8)),
    {ok, Ref} = adk_workflow:start(Compiled, #{},
                                    #{max_concurrency => 2,
                                      retention_ms => 1000}),
    Started = collect_started(2, #{}),
    %% Completion order is deliberately the opposite of declaration order.
    maps:get(<<"right">>, Started) ! release,
    maps:get(<<"left">>, Started) ! release,
    {completed, State, _} = adk_workflow:await(Ref, 1000),
    ?assertEqual(<<"right">>, maps:get(<<"winner">>, State)).

completed_fork_branch_is_skipped_after_resume() ->
    Table = ets:new(graph_fork_resume, [set, public]),
    ets:insert(Table, [{left_calls, 0}, {right_calls, 0},
                       {allow_right, false}]),
    Parent = self(),
    Left = fun(_State) ->
        ets:update_counter(Table, left_calls, 1),
        {ok, #{<<"left_done">> => true}}
    end,
    Right = fun(_State) ->
        ets:update_counter(Table, right_calls, 1),
        case ets:lookup_element(Table, allow_right, 2) of
            true -> {ok, #{<<"right_done">> => true}};
            false ->
                Parent ! {right_blocked, self()},
                receive never -> impossible end
        end
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"fork">>,
                   [fork_node(<<"fork">>, [<<"left">>, <<"right">>],
                              <<"join">>, reject_conflicts, 1),
                    action_node(<<"left">>, Left),
                    action_node(<<"right">>, Right),
                    join_node(<<"join">>)],
                   #{<<"left">> => <<"join">>,
                     <<"right">> => <<"join">>,
                     <<"join">> => end_node}, 10)),
    try
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{}, #{max_concurrency => 1,
                                       retention_ms => 2000}),
        receive {right_blocked, _} -> ok after 1000 -> error(timeout) end,
        Checkpoint = wait_for_checkpoint(
                       Ref,
                       fun(CP) ->
                           Cursor = maps:get(<<"cursor">>, CP),
                           maps:get(<<"phase">>, Cursor, undefined)
                               =:= <<"fork">>
                           andalso maps:is_key(
                                     <<"left">>,
                                     maps:get(<<"results">>, Cursor, #{}))
                       end),
        ok = adk_workflow:cancel(Ref, test_resume),
        {cancelled, test_resume, CancelledCP} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(maps:get(<<"cursor">>, Checkpoint),
                     maps:get(<<"cursor">>, CancelledCP)),
        ets:insert(Table, {allow_right, true}),
        {ok, Resumed} = adk_workflow:resume(
                          Compiled, CancelledCP,
                          #{max_concurrency => 1, retention_ms => 1000}),
        {completed, State, _} = adk_workflow:await(Resumed, 1000),
        ?assertEqual(true, maps:get(<<"left_done">>, State)),
        ?assertEqual(true, maps:get(<<"right_done">>, State)),
        ?assertEqual(1, ets:lookup_element(Table, left_calls, 2)),
        %% Only an uncommitted, in-flight branch is at-least-once.
        ?assertEqual(2, ets:lookup_element(Table, right_calls, 2))
    after
        ets:delete(Table)
    end.

committed_node_is_not_replayed_when_routing_resumes() ->
    Table = ets:new(graph_route_resume, [set, public]),
    ets:insert(Table, [{action_calls, 0}, {allow_route, false}]),
    Parent = self(),
    Action = fun(_State) ->
        ets:update_counter(Table, action_calls, 1),
        {ok, #{<<"committed">> => true}}
    end,
    Route = fun(_State) ->
        case ets:lookup_element(Table, allow_route, 2) of
            true -> <<"done">>;
            false ->
                Parent ! {route_blocked, self()},
                receive never -> impossible end
        end
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"action">>,
                   [action_node(<<"action">>, Action),
                    action_node(<<"done">>,
                                fun(_) -> {ok, #{<<"done">> => true}} end)],
                   #{<<"action">> => {route, Route},
                     <<"done">> => end_node}, 6)),
    try
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{}, #{retention_ms => 2000}),
        receive {route_blocked, _} -> ok after 1000 -> error(timeout) end,
        CP = wait_for_checkpoint(
               Ref,
               fun(Value) ->
                   Cursor = maps:get(<<"cursor">>, Value),
                   maps:get(<<"phase">>, Cursor, undefined) =:= <<"routing">>
                   andalso maps:get(<<"committed">>,
                                    maps:get(<<"state">>, Value), false)
               end),
        ok = adk_workflow:cancel(Ref, route_resume),
        {cancelled, route_resume, CancelCP} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(maps:get(<<"cursor">>, CP),
                     maps:get(<<"cursor">>, CancelCP)),
        ets:insert(Table, {allow_route, true}),
        {ok, Resumed} = adk_workflow:resume(Compiled, CancelCP,
                                            #{retention_ms => 1000}),
        {completed, State, _} = adk_workflow:await(Resumed, 1000),
        ?assertEqual(true, maps:get(<<"done">>, State)),
        ?assertEqual(1, ets:lookup_element(Table, action_calls, 2))
    after
        ets:delete(Table)
    end.

dynamic_branch_and_loop_are_bounded() ->
    Choose = fun(State) -> maps:get(<<"choice">>, State) end,
    BranchGraph = compile_ok(
                    graph_spec(
                      <<"choose">>,
                      [#{id => <<"choose">>, type => dynamic,
                         choose => Choose,
                         targets => [<<"left">>, <<"right">>]},
                       action_node(<<"left">>,
                                   fun(_) -> {ok, #{<<"picked">> => <<"left">>}} end),
                       action_node(<<"right">>,
                                   fun(_) -> {ok, #{<<"picked">> => <<"right">>}} end)],
                      #{<<"left">> => end_node,
                        <<"right">> => end_node}, 4)),
    {completed, BranchState, _} =
        adk_workflow:run(BranchGraph, #{<<"choice">> => <<"right">>}),
    ?assertEqual(<<"right">>, maps:get(<<"picked">>, BranchState)),
    {failed, {route_failed, <<"choose">>,
              {target_not_allowed, {adk_failure, TargetFailure}}}, _} =
        adk_workflow:run(BranchGraph, #{<<"choice">> => <<"outside">>}),
    ?assertEqual(binary_failure, maps:get(reason, TargetFailure)),

    Increment = fun(State) ->
        {ok, #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}}
    end,
    LoopNode = #{id => <<"loop">>, type => loop,
                 while => fun(State) -> maps:get(<<"count">>, State) < 3 end,
                 body => <<"body">>, done => <<"done">>,
                 max_iterations => 3},
    LoopGraph = compile_ok(
                  graph_spec(
                    <<"loop">>,
                    [LoopNode, action_node(<<"body">>, Increment),
                     join_node(<<"done">>)],
                    #{<<"body">> => <<"loop">>,
                      <<"done">> => end_node}, 12)),
    {completed, LoopState, _} =
        adk_workflow:run(LoopGraph, #{<<"count">> => 0}),
    ?assertEqual(3, maps:get(<<"count">>, LoopState)),

    BoundGraph = compile_ok(
                   graph_spec(
                     <<"loop">>,
                     [LoopNode#{max_iterations => 2,
                                while => fun(_) -> true end},
                      action_node(<<"body">>, Increment),
                      join_node(<<"done">>)],
                     #{<<"body">> => <<"loop">>,
                       <<"done">> => end_node}, 12)),
    {failed, {budget_exhausted,
              {graph_loop_iterations, <<"loop">>}}, BoundCP} =
        adk_workflow:run(BoundGraph, #{<<"count">> => 0}),
    ?assertEqual(2, maps:get(<<"count">>,
                            maps:get(<<"state">>, BoundCP))).

pause_resume_routes_without_replaying_node() ->
    Table = ets:new(graph_pause_resume, [set, public]),
    ets:insert(Table, {pause_calls, 0}),
    Pause = fun(_State) ->
        ets:update_counter(Table, pause_calls, 1),
        {pause, human_approval, <<"Approve this graph node">>,
         #{<<"approval_requested">> => true}}
    end,
    Route = fun(_State, Context) ->
        case maps:get(<<"approved">>, maps:get(input, Context)) of
            true -> <<"accepted">>;
            false -> <<"rejected">>
        end
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"approval">>,
                   [action_node(<<"approval">>, Pause),
                    action_node(<<"accepted">>,
                                fun(_) -> {ok, #{<<"accepted">> => true}} end),
                    action_node(<<"rejected">>,
                                fun(_) -> {ok, #{<<"accepted">> => false}} end)],
                   #{<<"approval">> => {route, Route},
                     <<"accepted">> => end_node,
                     <<"rejected">> => end_node}, 6)),
    try
        {paused, Details, CP} = adk_workflow:run(Compiled, #{}),
        ?assertEqual(<<"approval">>, maps:get(<<"node_id">>, Details)),
        ?assertEqual(true, maps:get(<<"approval_requested">>,
                                    maps:get(<<"state">>, CP))),
        ?assertEqual({error, resume_input_required},
                     adk_workflow:resume(Compiled, CP)),
        ?assertMatch({error, {invalid_resume_input, _}},
                     adk_workflow:resume(
                       Compiled, CP, #{resume_input => self()})),
        {ok, Ref} = adk_workflow:resume(
                      Compiled, CP,
                      #{resume_input => #{approved => true},
                        retention_ms => 1000}),
        {completed, State, _} = adk_workflow:await(Ref, 1000),
        ?assertEqual(true, maps:get(<<"accepted">>, State)),
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2))
    after
        ets:delete(Table)
    end.

fork_failure_stops_sibling() ->
    Parent = self(),
    Blocking = fun(_State) ->
        Parent ! {fork_sibling, self()},
        receive never -> impossible end
    end,
    Failure = fun(_State) ->
        Parent ! {fork_failure, self()},
        receive release_failure -> {error, expected_failure} end
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"fork">>,
                   [fork_node(<<"fork">>, [<<"blocking">>, <<"failure">>],
                              <<"join">>, reject_conflicts, 2),
                    action_node(<<"blocking">>, Blocking),
                    action_node(<<"failure">>, Failure),
                    join_node(<<"join">>)],
                   #{<<"blocking">> => <<"join">>,
                     <<"failure">> => <<"join">>,
                     <<"join">> => end_node}, 8)),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{max_concurrency => 2,
                                   retention_ms => 1000}),
    Sibling = receive {fork_sibling, Pid} -> Pid
              after 1000 -> error(timeout)
              end,
    Monitor = erlang:monitor(process, Sibling),
    FailurePid = receive {fork_failure, Pid2} -> Pid2
                 after 1000 -> error(timeout)
                 end,
    FailurePid ! release_failure,
    {failed, {fork_branch_failed, <<"failure">>, expected_failure}, _} =
        adk_workflow:await(Ref, 1000),
    receive {'DOWN', Monitor, process, Sibling, killed} -> ok
    after 1000 -> ?assert(false)
    end.

typed_agent_tool_and_nested_workflow_nodes() ->
    AgentName = <<"typed-graph-agent">>,
    ensure_unregistered(AgentName),
    Agent = spawn(fun() -> agent_loop(<<"agent-value">>) end),
    yes = adk_agent_registry:register_name(AgentName, Agent),
    Child = compile_ok(
              #{version => 1, id => <<"typed-child">>, kind => sequential,
                steps => [#{id => <<"child-step">>,
                            run => fun(_) ->
                                {ok, #{<<"child">> => true}}
                            end}],
                max_steps => 2}),
    Compiled = compile_ok(
                 graph_spec(
                   <<"agent">>,
                   [#{id => <<"agent">>, type => agent,
                      agent => AgentName, prompt => <<"hello">>},
                    #{id => <<"tool">>, type => tool,
                      module => ?MODULE,
                      args => #{<<"value">> => 7}},
                    #{id => <<"child">>, type => workflow,
                      workflow => Child},
                    join_node(<<"done">>)],
                   #{<<"agent">> => <<"tool">>,
                     <<"tool">> => <<"child">>,
                     <<"child">> => <<"done">>,
                     <<"done">> => end_node}, 10)),
    try
        {completed, State, _} = adk_workflow:run(Compiled, #{}),
        ?assertEqual(<<"agent-value">>,
                     maps:get(<<"last_response">>, State)),
        ?assertEqual(7, maps:get(<<"tool_value">>, State)),
        ?assertEqual(true, maps:get(<<"child">>, State))
    after
        ensure_unregistered(AgentName),
        exit(Agent, kill)
    end.

invalid_graph_topologies_are_rejected() ->
    UnknownDynamic = graph_spec(
                       <<"choose">>,
                       [#{id => <<"choose">>, type => branch,
                          choose => fun(_) -> <<"missing">> end,
                          targets => [<<"missing">>]}], #{}, 4),
    ?assertEqual(
       {error, {invalid_workflow, [nodes, <<"choose">>, targets],
                unknown_graph_target}},
       adk_workflow:compile(UnknownDynamic)),

    BadFork = graph_spec(
                <<"fork">>,
                [fork_node(<<"fork">>, [<<"branch">>], <<"join">>,
                           reject_conflicts, 1),
                 action_node(<<"branch">>, fun(_) -> {ok, #{}} end),
                 join_node(<<"join">>)],
                #{<<"branch">> => end_node,
                  <<"join">> => end_node}, 4),
    ?assertEqual(
       {error, {invalid_workflow, [nodes, <<"fork">>],
                invalid_fork_topology}},
       adk_workflow:compile(BadFork)).

%% Test tool used by the typed tool-node case.
execute(#{<<"value">> := Value}, _Context) ->
    {ok, #{<<"tool_value">> => Value}}.

graph_spec(Entry, Nodes, Edges, MaxSteps) ->
    #{version => 1, id => <<"graph-extension-test">>, kind => graph,
      entry => Entry, nodes => Nodes, edges => Edges,
      max_steps => MaxSteps}.

action_node(Id, Run) -> #{id => Id, run => Run}.

fork_node(Id, Branches, Join, Merge, MaxConcurrency) ->
    #{id => Id, type => fork, branches => Branches, join => Join,
      merge => Merge, max_concurrency => MaxConcurrency}.

join_node(Id) -> #{id => Id, type => join}.

compile_ok(Spec) ->
    {ok, Compiled} = adk_workflow:compile(Spec),
    Compiled.

collect_started(0, Acc) -> Acc;
collect_started(Count, Acc) ->
    receive
        {fork_started, Id, Pid} ->
            collect_started(Count - 1, Acc#{Id => Pid})
    after 1000 -> error({missing_fork_workers, Count})
    end.

wait_for_checkpoint(Ref, Predicate) ->
    wait_for_checkpoint(Ref, Predicate, 100).

wait_for_checkpoint(_Ref, _Predicate, 0) -> error(checkpoint_not_observed);
wait_for_checkpoint(Ref, Predicate, Attempts) ->
    {ok, CP} = adk_workflow:checkpoint(Ref),
    case Predicate(CP) of
        true -> CP;
        false ->
            receive after 5 -> ok end,
            wait_for_checkpoint(Ref, Predicate, Attempts - 1)
    end.

agent_loop(Response) ->
    receive
        {'$gen_call', From, {prompt, _Prompt}} ->
            gen_server:reply(From, {ok, Response}),
            agent_loop(Response);
        _ -> agent_loop(Response)
    end.

ensure_unregistered(Name) ->
    case adk_agent_registry:lookup(Name) of
        {ok, Pid} ->
            ok = adk_agent_registry:unregister_name(Name),
            exit(Pid, kill),
            ok;
        {error, not_found} -> ok
    end.
