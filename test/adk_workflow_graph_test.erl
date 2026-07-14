-module(adk_workflow_graph_test).
-include_lib("eunit/include/eunit.hrl").

-export([execute/2]).

graph_workflow_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun fork_fan_in_is_bounded_and_declared_order_wins/0,
      fun completed_fork_branch_is_skipped_after_resume/0,
      fun fork_pause_replays_uncommitted_sibling_at_least_once/0,
      fun fork_resume_input_becomes_paused_branch_output/0,
      fun committed_node_is_not_replayed_when_routing_resumes/0,
      fun dynamic_branch_and_loop_are_bounded/0,
      fun output_continues_and_stop_terminates_graph/0,
      fun pause_resume_routes_without_replaying_node/0,
      fun fork_failure_stops_sibling/0,
      fun typed_adapters_continue_in_sequential_workflow/0,
      fun typed_agent_tool_and_nested_workflow_nodes/0,
      fun workflow_agent_invocations_are_fresh_and_receive_context/0,
      fun workflow_agent_registry_alias_mismatch_fails_closed/0,
      fun confirmation_required_workflow_tool_fails_closed/0,
      fun conditional_false_workflow_tool_executes/0,
      fun confirmation_evaluation_failure_fails_closed/0,
      fun node_retry_succeeds_and_exposes_attempt_context/0,
      fun node_timeout_retries_and_kills_each_attempt/0,
      fun cancellation_interrupts_retry_backoff_without_orphans/0,
      fun nested_workflow_pause_resumes_child_without_replay/0,
      fun fork_nested_workflow_pause_resumes_child_without_replay/0,
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
            receive release ->
                {output, #{<<"branch">> => Id},
                 #{<<"winner">> => Id}}
            end
        end
    end,
    Join = fun(_State, Context) ->
        Inputs = maps:get(input, Context),
        ?assertEqual(
           #{<<"branch">> => <<"left">>},
           maps:get(<<"left">>, Inputs)),
        ?assertEqual(
           #{<<"branch">> => <<"right">>},
           maps:get(<<"right">>, Inputs)),
        {output, Inputs, #{<<"join_saw_outputs">> => true}}
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"fork">>,
                   [fork_node(<<"fork">>, [<<"left">>, <<"right">>],
                              <<"join">>, ordered_last_wins, 2),
                    action_node(<<"left">>, Branch(<<"left">>)),
                    action_node(<<"right">>, Branch(<<"right">>)),
                    #{id => <<"join">>, type => join, run => Join}],
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
    {completed, State, Checkpoint} = adk_workflow:await(Ref, 1000),
    ?assertEqual(<<"right">>, maps:get(<<"winner">>, State)),
    ?assertEqual(true, maps:get(<<"join_saw_outputs">>, State)),
    ?assertEqual(
       #{<<"left">> => #{<<"branch">> => <<"left">>},
         <<"right">> => #{<<"branch">> => <<"right">>}},
       maps:get(<<"output">>, Checkpoint)).

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

fork_pause_replays_uncommitted_sibling_at_least_once() ->
    Table = ets:new(graph_fork_pause_sibling_replay, [set, public]),
    ets:insert(Table, [{sibling_calls, 0}, {sibling_started, false}]),
    Parent = self(),
    Sibling = fun(_State) ->
        case ets:update_counter(Table, sibling_calls, 1) of
            1 ->
                %% This observable work has happened, but the branch has not
                %% returned a result that the fork can checkpoint yet.
                ets:insert(Table, {sibling_started, true}),
                Parent ! {uncommitted_fork_sibling, self()},
                receive never -> impossible end;
            2 ->
                {output, <<"sibling-output">>,
                 #{<<"sibling_done">> => true}}
        end
    end,
    Pause = fun(_State) ->
        ok = wait_for_ets_value(Table, sibling_started, true, 1000),
        {pause, approval, <<"Approve fork branch">>,
         #{<<"pause_started">> => true}}
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"fork">>,
                   [fork_node(<<"fork">>, [<<"pause">>, <<"sibling">>],
                              <<"join">>, reject_conflicts, 2),
                    action_node(<<"pause">>, Pause),
                    action_node(<<"sibling">>, Sibling),
                    join_node(<<"join">>)],
                   #{<<"pause">> => <<"join">>,
                     <<"sibling">> => <<"join">>,
                     <<"join">> => end_node}, 8)),
    try
        {paused, _Details, Checkpoint} =
            adk_workflow:run(
              Compiled, #{}, #{max_concurrency => 2}),
        FirstSibling = receive
            {uncommitted_fork_sibling, Pid} -> Pid
        after 1000 -> error(missing_uncommitted_fork_sibling)
        end,
        ?assertNot(is_process_alive(FirstSibling)),
        Cursor = maps:get(<<"cursor">>, Checkpoint),
        Results = maps:get(<<"fork_results">>, Cursor),
        ?assertEqual(false, maps:is_key(<<"sibling">>, Results)),
        ?assertEqual(1, ets:lookup_element(Table, sibling_calls, 2)),

        {ok, Ref} = adk_workflow:resume(
                      Compiled, Checkpoint,
                      #{resume_input => #{approved => true},
                        max_concurrency => 2,
                        retention_ms => 1000}),
        {completed, State, _CompleteCheckpoint} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(true, maps:get(<<"pause_started">>, State)),
        ?assertEqual(true, maps:get(<<"sibling_done">>, State)),
        %% A sibling without a committed result is restarted from its action
        %% boundary after resume, so its pre-result effects are at-least-once.
        ?assertEqual(2, ets:lookup_element(Table, sibling_calls, 2))
    after
        ets:delete(Table)
    end.

fork_resume_input_becomes_paused_branch_output() ->
    Table = ets:new(graph_fork_pause_resume, [set, public]),
    ets:insert(Table, [{pause_calls, 0}, {other_calls, 0}]),
    Pause = fun(_State) ->
        ets:update_counter(Table, pause_calls, 1),
        {pause, approval, <<"Approve fork branch">>,
         #{<<"pause_delta">> => true}}
    end,
    Other = fun(_State) ->
        ets:update_counter(Table, other_calls, 1),
        {output, <<"other-output">>, #{<<"other_delta">> => true}}
    end,
    Join = fun(_State, Context) ->
        Inputs = maps:get(input, Context),
        ?assertEqual(
           #{<<"approved">> => true}, maps:get(<<"pause">>, Inputs)),
        ?assertEqual(
           <<"other-output">>, maps:get(<<"other">>, Inputs)),
        {output, Inputs, #{<<"joined">> => true}}
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"fork">>,
                   [fork_node(<<"fork">>, [<<"pause">>, <<"other">>],
                              <<"join">>, reject_conflicts, 1),
                    action_node(<<"pause">>, Pause),
                    action_node(<<"other">>, Other),
                    #{id => <<"join">>, type => join, run => Join}],
                   #{<<"pause">> => <<"join">>,
                     <<"other">> => <<"join">>,
                     <<"join">> => end_node}, 8)),
    try
        {paused, Details, Checkpoint} =
            adk_workflow:run(
              Compiled, #{}, #{max_concurrency => 1}),
        ?assertEqual(<<"pause">>, maps:get(<<"node_id">>, Details)),
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
        ?assertEqual(0, ets:lookup_element(Table, other_calls, 2)),
        {ok, Ref} = adk_workflow:resume(
                      Compiled, Checkpoint,
                      #{resume_input => #{approved => true},
                        max_concurrency => 1,
                        retention_ms => 1000}),
        {completed, State, CompleteCheckpoint} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(true, maps:get(<<"pause_delta">>, State)),
        ?assertEqual(true, maps:get(<<"other_delta">>, State)),
        ?assertEqual(true, maps:get(<<"joined">>, State)),
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, other_calls, 2)),
        ?assertEqual(
           #{<<"pause">> => #{<<"approved">> => true},
             <<"other">> => <<"other-output">>},
           maps:get(<<"output">>, CompleteCheckpoint))
    after
        ets:delete(Table)
    end.

committed_node_is_not_replayed_when_routing_resumes() ->
    Table = ets:new(graph_route_resume, [set, public]),
    ets:insert(Table, [{action_calls, 0}, {allow_route, false}]),
    Parent = self(),
    Action = fun(_State) ->
        ets:update_counter(Table, action_calls, 1),
        {output, <<"route-input">>, #{<<"committed">> => true}}
    end,
    Route = fun(_State, Context) ->
        ?assertEqual(<<"route-input">>, maps:get(input, Context)),
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
                                fun(_State, Context) ->
                                    ?assertEqual(
                                       <<"route-input">>,
                                       maps:get(input, Context)),
                                    {ok, #{<<"done">> => true}}
                                end)],
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
        ?assertEqual(
           <<"route-input">>,
           maps:get(<<"node_output">>,
                    maps:get(<<"cursor">>, CancelCP))),
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
    {completed, BoundState, BoundCP} =
        adk_workflow:run(BoundGraph, #{<<"count">> => 0}),
    ?assertEqual(2, maps:get(<<"count">>, BoundState)),
    ?assertEqual(true, maps:get(<<"completed">>, BoundCP)).

output_continues_and_stop_terminates_graph() ->
    Parent = self(),
    Compiled = compile_ok(
                 graph_spec(
                   <<"first">>,
                   [action_node(
                      <<"first">>,
                      fun(_) ->
                          {output, <<"intermediate">>,
                           #{<<"first">> => true}}
                      end),
                    action_node(
                      <<"stop">>,
                      fun(State) ->
                          ?assertEqual(true, maps:get(<<"first">>, State)),
                          {stop, <<"graph-stopped">>,
                           #{<<"stopped">> => true}}
                      end),
                    action_node(
                      <<"never">>,
                      fun(_) ->
                          Parent ! unexpected_graph_node,
                          {ok, #{<<"never">> => true}}
                      end)],
                   #{<<"first">> => <<"stop">>,
                     <<"stop">> => <<"never">>,
                     <<"never">> => end_node}, 4)),
    {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(true, maps:get(<<"first">>, State)),
    ?assertEqual(true, maps:get(<<"stopped">>, State)),
    ?assertEqual(false, maps:is_key(<<"never">>, State)),
    ?assertEqual(<<"graph-stopped">>,
                 maps:get(<<"output">>, Checkpoint)),
    receive unexpected_graph_node -> ?assert(false)
    after 0 -> ok
    end.

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

typed_adapters_continue_in_sequential_workflow() ->
    AgentName = <<"typed_sequential_agent">>,
    ensure_unregistered(AgentName),
    Agent = spawn(fun() ->
                          %% Runtime names use the same canonical comparison
                          %% even when the agent reports an accepted atom form.
                          agent_loop(typed_sequential_agent,
                                     <<"agent-output">>)
                  end),
    yes = adk_agent_registry:register_name(AgentName, Agent),
    Child = compile_ok(
              #{version => 1, id => <<"typed-sequential-child">>,
                kind => sequential,
                steps => [#{id => <<"child-step">>,
                            run => fun(_) ->
                                {output, <<"child-output">>,
                                 #{<<"child">> => true}}
                            end}],
                max_steps => 2}),
    Final = fun(State) ->
        ?assertEqual(<<"agent-output">>,
                     maps:get(<<"last_response">>, State)),
        ?assertEqual(9, maps:get(<<"tool_value">>, State)),
        ?assertEqual(true, maps:get(<<"child">>, State)),
        {output, <<"pipeline-output">>, #{<<"final">> => true}}
    end,
    Compiled = compile_ok(
                 #{version => 1, id => <<"typed-sequential-parent">>,
                   kind => sequential, max_steps => 5,
                   steps =>
                       [#{id => <<"agent">>,
                          run => {agent, AgentName, <<"hello">>}},
                        #{id => <<"tool">>,
                          run => {tool, ?MODULE,
                                  #{<<"value">> => 9}, undefined}},
                        #{id => <<"workflow">>,
                          run => {workflow, Child, #{}}},
                        #{id => <<"final">>, run => Final}]}),
    try
        {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
        ?assertEqual(true, maps:get(<<"final">>, State)),
        ?assertEqual(<<"pipeline-output">>,
                     maps:get(<<"output">>, Checkpoint))
    after
        ensure_unregistered(AgentName),
        exit(Agent, kill)
    end.

typed_agent_tool_and_nested_workflow_nodes() ->
    AgentName = <<"typed_graph_agent">>,
    ensure_unregistered(AgentName),
    Agent = spawn(fun() -> agent_loop(AgentName, <<"agent-value">>) end),
    yes = adk_agent_registry:register_name(AgentName, Agent),
    Child = compile_ok(
              #{version => 1, id => <<"typed-child">>, kind => sequential,
                steps => [#{id => <<"child-step">>,
                            run => fun(_) ->
                                {output, <<"child-value">>,
                                 #{<<"child">> => true}}
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
        {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
        ?assertEqual(<<"agent-value">>,
                     maps:get(<<"last_response">>, State)),
        ?assertEqual(7, maps:get(<<"tool_value">>, State)),
        ?assertEqual(true, maps:get(<<"child">>, State)),
        ?assertEqual(<<"child-value">>,
                     maps:get(<<"output">>, Checkpoint))
    after
        ensure_unregistered(AgentName),
        exit(Agent, kill)
    end.

workflow_agent_invocations_are_fresh_and_receive_context() ->
    RealName = <<"workflow_agent_isolation">>,
    ensure_unregistered(RealName),
    {ok, RealAgent} = erlang_adk:spawn_agent(
                        RealName,
                        #{provider => adk_llm_probe,
                          response => <<"isolated">>,
                          test_pid => self()}, []),
    IsolatedWorkflow = compile_ok(
                         graph_spec(
                           <<"agent">>,
                           [#{id => <<"agent">>, type => agent,
                              agent => RealName, prompt => <<"same">>}],
                           #{<<"agent">> => end_node}, 2)),
    try
        {completed, _, _} = adk_workflow:run(IsolatedWorkflow, #{}),
        FirstHistory = receive_probe_history(),
        {completed, _, _} = adk_workflow:run(IsolatedWorkflow, #{}),
        SecondHistory = receive_probe_history(),
        ?assertEqual([<<"same">>], user_history(FirstHistory)),
        ?assertEqual([<<"same">>], user_history(SecondHistory))
    after
        _ = catch erlang_adk:stop_agent(RealAgent)
    end,

    ContextName = <<"workflow_agent_context">>,
    ensure_unregistered(ContextName),
    Parent = self(),
    ContextAgent = spawn(fun() ->
                                 agent_context_loop(ContextName, Parent)
                         end),
    yes = adk_agent_registry:register_name(ContextName, ContextAgent),
    ContextWorkflow = compile_ok(
                        graph_spec(
                          <<"agent-step">>,
                          [#{id => <<"agent-step">>, type => agent,
                             agent => ContextName,
                             prompt => <<"context">>}],
                          #{<<"agent-step">> => end_node}, 2)),
    try
        {completed, _, _} = adk_workflow:run(ContextWorkflow, #{}),
        Context = receive
            {workflow_agent_context, Value} -> Value
        after 1000 -> error(missing_workflow_agent_context)
        end,
        ?assertEqual(<<"graph-extension-test">>,
                     maps:get(workflow_id, Context)),
        ?assertEqual(graph, maps:get(kind, Context)),
        ?assertEqual(<<"agent-step">>, maps:get(step_id, Context)),
        ?assertEqual(<<"erlang_adk_workflow">>,
                     maps:get(app_name, Context)),
        ?assertEqual(<<"graph-extension-test">>,
                     maps:get(user_id, Context)),
        ?assert(is_binary(maps:get(session_id, Context))),
        ?assertEqual(#{}, maps:get(state, Context)),
        ?assert(maps:is_key(deadline, Context)),
        ?assert(maps:is_key(budgets, Context))
    after
        ensure_unregistered(ContextName),
        exit(ContextAgent, kill)
    end.

workflow_agent_registry_alias_mismatch_fails_closed() ->
    Alias = <<"workflow_agent_alias">>,
    RuntimeName = <<"workflow_agent_actual">>,
    ensure_unregistered(Alias),
    Parent = self(),
    Agent = spawn(fun() ->
                          agent_identity_probe_loop(RuntimeName, Parent)
                  end),
    yes = adk_agent_registry:register_name(Alias, Agent),
    Compiled = compile_ok(
                 graph_spec(
                   <<"agent">>,
                   [#{id => <<"agent">>, type => agent,
                      agent => Alias, prompt => <<"must-not-run">>}],
                   #{<<"agent">> => end_node}, 2)),
    try
        {failed, {node_failed, <<"agent">>, Failure}, _Checkpoint} =
            adk_workflow:run(Compiled, #{}),
        ?assert(adk_failure:is_failure(Failure)),
        ?assertEqual(
           agent_identity_mismatch,
           maps:get(reason,
                    adk_failure:log_metadata(
                      adk_workflow_agent, identity, Failure))),
        receive
            {workflow_alias_invoked, Agent} ->
                error(registry_alias_dispatched_to_wrong_agent)
        after 0 ->
            ok
        end
    after
        ensure_unregistered(Alias),
        exit(Agent, kill)
    end.

confirmation_required_workflow_tool_fails_closed() ->
    enable_confirmation_probes(),
    Id = <<"workflow-static-side-effect">>,
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"workflow-static-confirmation">>,
                   kind => sequential,
                   max_steps => 1,
                   steps =>
                       [#{id => <<"protected-tool">>,
                          run =>
                              {tool, adk_static_confirmation_tool,
                               #{<<"id">> => Id}, <<"tool_result">>},
                          retry => #{max_attempts => 3}}]}),
    try
        {failed,
         {step_failed, <<"protected-tool">>, Failure}, _Checkpoint} =
            adk_workflow:run(Compiled, #{}),
        ?assert(adk_failure:is_failure(Failure)),
        ?assertEqual(
           tool_confirmation_requires_runner,
           maps:get(reason,
                    adk_failure:log_metadata(
                      adk_workflow_tool, confirmation, Failure))),
        assert_no_confirmation_execution(Id)
    after
        disable_confirmation_probes()
    end.

conditional_false_workflow_tool_executes() ->
    enable_confirmation_probes(),
    Id = <<"workflow-read-only-tool">>,
    WorkflowId = <<"workflow-conditional-confirmation">>,
    Compiled = compile_ok(
                 #{version => 1,
                   id => WorkflowId,
                   kind => sequential,
                   max_steps => 1,
                   steps =>
                       [#{id => <<"read-only-tool">>,
                          run =>
                              {tool, adk_conditional_confirmation_tool,
                               #{<<"id">> => Id,
                                 <<"confirm">> => false,
                                 <<"mode">> => <<"success">>},
                               <<"tool_result">>}}]}),
    try
        {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
        Result = #{<<"id">> => Id, <<"kind">> => <<"conditional">>},
        ?assertEqual(Result, maps:get(<<"tool_result">>, State)),
        ?assertEqual(Result, maps:get(<<"output">>, Checkpoint)),
        receive
            {confirmation_checked, Id, CheckContext} ->
                ?assertEqual(WorkflowId,
                             maps:get(workflow_id, CheckContext)),
                ?assertEqual(<<"read-only-tool">>,
                             maps:get(step_id, CheckContext))
        after 1000 ->
            error(confirmation_not_evaluated)
        end,
        receive
            {confirmation_tool_executed, conditional, Id,
             _ToolPid, ExecuteContext} ->
                ?assertEqual(WorkflowId,
                             maps:get(workflow_id, ExecuteContext))
        after 1000 ->
            error(workflow_tool_not_executed)
        end
    after
        disable_confirmation_probes()
    end.

confirmation_evaluation_failure_fails_closed() ->
    MissingModule = adk_missing_workflow_confirmation_tool,
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"workflow-confirmation-evaluation-failure">>,
                   kind => sequential,
                   max_steps => 1,
                   steps =>
                       [#{id => <<"missing-tool">>,
                          run =>
                              {tool, MissingModule, #{},
                               <<"tool_result">>},
                          retry => #{max_attempts => 3}}]}),
    {failed, {step_failed, <<"missing-tool">>, Failure}, _Checkpoint} =
        adk_workflow:run(Compiled, #{}),
    ?assert(adk_failure:is_failure(Failure)),
    ?assertEqual(
       tool_confirmation_evaluation_failed,
       maps:get(reason,
                adk_failure:log_metadata(
                  adk_workflow_tool, confirmation, Failure))).

node_retry_succeeds_and_exposes_attempt_context() ->
    Table = ets:new(workflow_node_retry, [set, public]),
    ets:insert(Table, {calls, 0}),
    Action = fun(_State, Context) ->
        Count = ets:update_counter(Table, calls, 1),
        ?assertEqual(Count, maps:get(attempt, Context)),
        case Count of
            3 -> {output, <<"retried-output">>,
                  #{<<"retried">> => true}};
            _ -> {error, transient}
        end
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"retry">>,
                   [#{id => <<"retry">>, run => Action,
                      retry => #{max_attempts => 3, backoff_ms => 0}}],
                   #{<<"retry">> => end_node}, 2)),
    try
        {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
        ?assertEqual(true, maps:get(<<"retried">>, State)),
        ?assertEqual(<<"retried-output">>,
                     maps:get(<<"output">>, Checkpoint)),
        ?assertEqual(3, ets:lookup_element(Table, calls, 2))
    after
        ets:delete(Table)
    end.

node_timeout_retries_and_kills_each_attempt() ->
    Parent = self(),
    Blocking = fun(_State, Context) ->
        Parent ! {timed_attempt, maps:get(attempt, Context), self()},
        receive never -> impossible end
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"timeout">>,
                   [#{id => <<"timeout">>, run => Blocking,
                      timeout => 25,
                      retry => #{max_attempts => 2, backoff_ms => 0}}],
                   #{<<"timeout">> => end_node}, 2)),
    {failed,
     {node_failed, <<"timeout">>,
      {retry_exhausted, 2, {action_timed_out, 25}}}, _} =
        adk_workflow:run(Compiled, #{}, #{timeout => 1000}),
    First = receive {timed_attempt, 1, Pid1} -> Pid1
            after 1000 -> error(missing_first_timed_attempt)
            end,
    Second = receive {timed_attempt, 2, Pid2} -> Pid2
             after 1000 -> error(missing_second_timed_attempt)
             end,
    ?assertNot(is_process_alive(First)),
    ?assertNot(is_process_alive(Second)).

cancellation_interrupts_retry_backoff_without_orphans() ->
    Parent = self(),
    Failure = fun(_State, Context) ->
        {links, Links} = process_info(self(), links),
        [PolicyWorker | _] = Links,
        Parent ! {backoff_attempt, maps:get(attempt, Context),
                  self(), PolicyWorker},
        {error, retry_me}
    end,
    Compiled = compile_ok(
                 graph_spec(
                   <<"retry">>,
                   [#{id => <<"retry">>, run => Failure,
                      retry => #{max_attempts => 3,
                                 backoff_ms => 5000}}],
                   #{<<"retry">> => end_node}, 2)),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{}, #{timeout => 10000,
                                   retention_ms => 1000}),
    {Attempt, PolicyWorker} = receive
        {backoff_attempt, 1, AttemptPid, WorkerPid} ->
            {AttemptPid, WorkerPid}
    after 1000 -> error(missing_backoff_attempt)
    end,
    WorkerMonitor = erlang:monitor(process, PolicyWorker),
    ok = adk_workflow:cancel(Ref, cancel_backoff),
    {cancelled, cancel_backoff, _} = adk_workflow:await(Ref, 1000),
    receive {'DOWN', WorkerMonitor, process, PolicyWorker, _} -> ok
    after 1000 -> error(retry_worker_not_stopped)
    end,
    ?assertNot(is_process_alive(Attempt)),
    receive
        {backoff_attempt, AttemptNo, _, _} when AttemptNo > 1 ->
            error(retry_continued_after_cancel)
    after 75 -> ok
    end.

nested_workflow_pause_resumes_child_without_replay() ->
    Table = ets:new(nested_workflow_pause_resume, [set, public]),
    ets:insert(Table, [{first_calls, 0}, {pause_calls, 0},
                       {after_calls, 0}]),
    First = fun(_State) ->
        ets:update_counter(Table, first_calls, 1),
        {output, <<"child-intermediate">>,
         #{<<"child_first">> => true}}
    end,
    Pause = fun(State) ->
        ets:update_counter(Table, pause_calls, 1),
        ?assertEqual(true, maps:get(<<"child_first">>, State)),
        {pause, approval, <<"Approve nested child">>,
         #{<<"child_requested">> => true}}
    end,
    After = fun(State, Context) ->
        ets:update_counter(Table, after_calls, 1),
        ?assertEqual(true, maps:get(<<"child_requested">>, State)),
        ?assertEqual(#{<<"approved">> => true},
                     maps:get(input, Context)),
        {output, <<"child-final">>, #{<<"child_done">> => true}}
    end,
    Child = compile_ok(
              graph_spec(
                <<"first">>,
                [action_node(<<"first">>, First),
                 action_node(<<"approval">>, Pause),
                 action_node(<<"after">>, After)],
                #{<<"first">> => <<"approval">>,
                  <<"approval">> => <<"after">>,
                  <<"after">> => end_node}, 6)),
    ParentAfter = fun(State, Context) ->
        ?assertEqual(true, maps:get(<<"child_done">>, State)),
        ?assertEqual(<<"child-final">>, maps:get(input, Context)),
        {output, <<"parent-final">>, #{<<"parent_done">> => true}}
    end,
    Parent = compile_ok(
               graph_spec(
                 <<"child">>,
                 [#{id => <<"child">>, type => workflow,
                    workflow => Child},
                  action_node(<<"parent-after">>, ParentAfter)],
                 #{<<"child">> => <<"parent-after">>,
                   <<"parent-after">> => end_node}, 4)),
    try
        {paused, Details, Checkpoint} = adk_workflow:run(Parent, #{}),
        ?assertEqual(<<"child">>, maps:get(<<"node_id">>, Details)),
        ?assertEqual(<<"approval">>,
                     maps:get(<<"nested_node_id">>, Details)),
        Cursor = maps:get(<<"cursor">>, Checkpoint),
        ?assertEqual(<<"nested_workflow">>,
                     maps:get(<<"resume_kind">>, Cursor)),
        ChildCheckpoint = maps:get(<<"nested_checkpoint">>, Cursor),
        ?assertEqual(<<"child-intermediate">>,
                     maps:get(<<"output">>, ChildCheckpoint)),
        ?assertEqual(1, ets:lookup_element(Table, first_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
        ?assertEqual(0, ets:lookup_element(Table, after_calls, 2)),

        {ok, Ref} = adk_workflow:resume(
                      Parent, Checkpoint,
                      #{resume_input => #{approved => true},
                        retention_ms => 1000}),
        {completed, State, CompleteCheckpoint} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(true, maps:get(<<"child_first">>, State)),
        ?assertEqual(true, maps:get(<<"child_requested">>, State)),
        ?assertEqual(true, maps:get(<<"child_done">>, State)),
        ?assertEqual(true, maps:get(<<"parent_done">>, State)),
        ?assertEqual(<<"parent-final">>,
                     maps:get(<<"output">>, CompleteCheckpoint)),
        ?assertEqual(1, ets:lookup_element(Table, first_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, after_calls, 2))
    after
        ets:delete(Table)
    end.

fork_nested_workflow_pause_resumes_child_without_replay() ->
    Table = ets:new(fork_nested_workflow_pause_resume, [set, public]),
    ets:insert(Table, [{before_calls, 0}, {pause_calls, 0},
                       {after_calls, 0}, {other_calls, 0}]),
    Child = compile_ok(
              graph_spec(
                <<"before">>,
                [action_node(
                   <<"before">>,
                   fun(_State) ->
                       ets:update_counter(Table, before_calls, 1),
                       {output, <<"before-output">>,
                        #{<<"before_done">> => true}}
                   end),
                 action_node(
                   <<"approval">>,
                   fun(_State) ->
                       ets:update_counter(Table, pause_calls, 1),
                       {pause, approval, <<"Approve fork child">>, #{}}
                   end),
                 action_node(
                   <<"after">>,
                   fun(_State, Context) ->
                       ets:update_counter(Table, after_calls, 1),
                       ?assertEqual(<<"yes">>, maps:get(input, Context)),
                       {output, <<"nested-output">>,
                        #{<<"nested_done">> => true}}
                   end)],
                #{<<"before">> => <<"approval">>,
                  <<"approval">> => <<"after">>,
                  <<"after">> => end_node}, 6)),
    Other = fun(_State) ->
        ets:update_counter(Table, other_calls, 1),
        {output, <<"other-output">>, #{<<"other_done">> => true}}
    end,
    Join = fun(_State, Context) ->
        Inputs = maps:get(input, Context),
        ?assertEqual(<<"nested-output">>, maps:get(<<"nested">>, Inputs)),
        ?assertEqual(<<"other-output">>, maps:get(<<"other">>, Inputs)),
        {output, Inputs, #{<<"joined">> => true}}
    end,
    Parent = compile_ok(
               graph_spec(
                 <<"fork">>,
                 [fork_node(<<"fork">>, [<<"nested">>, <<"other">>],
                            <<"join">>, reject_conflicts, 1),
                  #{id => <<"nested">>, type => workflow,
                    workflow => Child},
                  action_node(<<"other">>, Other),
                  #{id => <<"join">>, type => join, run => Join}],
                 #{<<"nested">> => <<"join">>,
                   <<"other">> => <<"join">>,
                   <<"join">> => end_node}, 8)),
    try
        {paused, Details, Checkpoint} =
            adk_workflow:run(Parent, #{}, #{max_concurrency => 1}),
        ?assertEqual(<<"fork">>, maps:get(<<"fork_id">>, Details)),
        ?assertEqual(<<"nested">>, maps:get(<<"node_id">>, Details)),
        ?assertEqual(<<"approval">>,
                     maps:get(<<"nested_node_id">>, Details)),
        ?assertEqual(1, ets:lookup_element(Table, before_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
        ?assertEqual(0, ets:lookup_element(Table, after_calls, 2)),
        ?assertEqual(0, ets:lookup_element(Table, other_calls, 2)),

        {ok, Ref} = adk_workflow:resume(
                      Parent, Checkpoint,
                      #{resume_input => <<"yes">>, max_concurrency => 1,
                        retention_ms => 1000}),
        {completed, State, CompleteCheckpoint} =
            adk_workflow:await(Ref, 1000),
        ?assertEqual(true, maps:get(<<"nested_done">>, State)),
        ?assertEqual(true, maps:get(<<"other_done">>, State)),
        ?assertEqual(true, maps:get(<<"joined">>, State)),
        ?assertEqual(
           #{<<"nested">> => <<"nested-output">>,
             <<"other">> => <<"other-output">>},
           maps:get(<<"output">>, CompleteCheckpoint)),
        ?assertEqual(1, ets:lookup_element(Table, before_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, pause_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, after_calls, 2)),
        ?assertEqual(1, ets:lookup_element(Table, other_calls, 2))
    after
        ets:delete(Table)
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
       adk_workflow:compile(BadFork)),

    InvalidRetry = graph_spec(
                     <<"retry">>,
                     [#{id => <<"retry">>, run => fun(_) -> {ok, #{}} end,
                        retry => #{max_attempts => 0}}],
                     #{<<"retry">> => end_node}, 2),
    ?assertEqual(
       {error, {invalid_workflow, [nodes, 1, policy],
                invalid_retry_max_attempts}},
       adk_workflow:compile(InvalidRetry)),

    InvalidTimeout = graph_spec(
                       <<"timeout">>,
                       [#{id => <<"timeout">>,
                          run => fun(_) -> {ok, #{}} end,
                          timeout => -1}],
                       #{<<"timeout">> => end_node}, 2),
    ?assertEqual(
       {error, {invalid_workflow, [nodes, 1, policy], invalid_timeout}},
       adk_workflow:compile(InvalidTimeout)).

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

agent_loop(Name, Response) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, #{}, [], #{}}),
            agent_loop(Name, Response);
        {'$gen_call', From, {prompt, _Prompt}} ->
            gen_server:reply(From, {ok, Response}),
            agent_loop(Name, Response);
        {'$gen_call', From, {invoke, _Prompt, _Context}} ->
            gen_server:reply(From, {ok, Response}),
            agent_loop(Name, Response);
        _ -> agent_loop(Name, Response)
    end.

agent_context_loop(Name, Parent) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, #{}, [], #{}}),
            agent_context_loop(Name, Parent);
        {'$gen_call', From, {invoke, _Prompt, Context}} ->
            Parent ! {workflow_agent_context, Context},
            gen_server:reply(From, {ok, <<"context-ok">>}),
            agent_context_loop(Name, Parent);
        _ -> agent_context_loop(Name, Parent)
    end.

agent_identity_probe_loop(Name, Parent) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, #{}, [], #{}}),
            agent_identity_probe_loop(Name, Parent);
        {'$gen_call', From, {invoke, _Prompt, _Context}} ->
            Parent ! {workflow_alias_invoked, self()},
            gen_server:reply(From, {ok, <<"wrong-agent">>}),
            agent_identity_probe_loop(Name, Parent);
        _ -> agent_identity_probe_loop(Name, Parent)
    end.

wait_for_ets_value(_Table, _Key, _Expected, 0) ->
    error(ets_value_timeout);
wait_for_ets_value(Table, Key, Expected, Attempts) ->
    case ets:lookup(Table, Key) of
        [{Key, Expected}] -> ok;
        _ ->
            receive after 1 -> ok end,
            wait_for_ets_value(Table, Key, Expected, Attempts - 1)
    end.

receive_probe_history() ->
    receive
        {probe_generate, History, _Tools} -> History
    after 1000 -> error(missing_probe_history)
    end.

user_history(History) ->
    [maps:get(content, Message) || Message <- History,
                                  maps:get(role, Message) =:= user].

ensure_unregistered(Name) ->
    case adk_agent_registry:lookup(Name) of
        {ok, Pid} ->
            ok = adk_agent_registry:unregister_name(Name),
            exit(Pid, kill),
            ok;
        {error, not_found} -> ok
    end.

enable_confirmation_probes() ->
    flush_confirmation_messages(),
    persistent_term:put({adk_tool_confirmation_test, target}, self()).

disable_confirmation_probes() ->
    persistent_term:erase({adk_tool_confirmation_test, target}),
    flush_confirmation_messages().

assert_no_confirmation_execution(Id) ->
    receive
        {confirmation_tool_executed, _Kind, Id, _Pid, _Context} ->
            error(confirmation_protected_workflow_tool_executed)
    after 50 ->
        ok
    end.

flush_confirmation_messages() ->
    receive
        {confirmation_checked, _Id, _Context} ->
            flush_confirmation_messages();
        {confirmation_tool_executed, _Kind, _Id, _Pid, _Context} ->
            flush_confirmation_messages()
    after 0 ->
        ok
    end.
