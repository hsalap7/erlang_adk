-module(adk_task_test).
-include_lib("eunit/include/eunit.hrl").

adk_task_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun absolute_deadline_stops_execution_case/0,
      fun cancellation_commits_one_outcome_case/0,
      fun crashing_work_is_isolated_case/0,
      fun starter_death_does_not_orphan_task_case/0,
      fun owner_death_cancels_owned_task_case/0,
      fun serial_tools_preserve_order_case/0,
      fun parallel_tools_are_bounded_and_ordered_case/0,
      fun tool_crash_is_per_call_case/0,
      fun tool_pause_is_explicit_case/0,
      fun tool_timeout_is_per_call_case/0,
      fun cancelling_batch_stops_tool_processes_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = ensure_started(adk_task_registry,
                        fun adk_task_registry:start_link/0),
    ok = ensure_started(adk_task_sup,
                        fun adk_task_sup:start_link/0),
    ok.

cleanup(_Setup) ->
    ok.

absolute_deadline_stops_execution_case() ->
    Parent = self(),
    Work = fun() ->
        Parent ! {deadline_execution, self()},
        receive never -> impossible end
    end,
    Deadline = erlang:monotonic_time(millisecond) + 30,
    {ok, TaskRef} = adk_task:start(
                      Work, #{deadline => Deadline,
                              retention_ms => 1000}),
    Execution = receive
        {deadline_execution, Pid} -> Pid
    after 1000 ->
        ?assert(false)
    end,
    ExecutionRef = erlang:monitor(process, Execution),
    ?assertEqual({timed_out, deadline_exceeded},
                 adk_task:await(TaskRef, 1000)),
    receive
        {'DOWN', ExecutionRef, process, Execution, killed} -> ok
    after 1000 ->
        ?assert(false)
    end.

cancellation_commits_one_outcome_case() ->
    Parent = self(),
    Work = fun() ->
        Parent ! {cancel_execution, self()},
        receive never -> impossible end
    end,
    {ok, TaskRef} = adk_task:start(
                      Work, #{timeout => 5000,
                              retention_ms => 1000,
                              notify => self()}),
    Execution = receive
        {cancel_execution, Pid} -> Pid
    after 1000 ->
        ?assert(false)
    end,
    ExecutionRef = erlang:monitor(process, Execution),
    ok = adk_task:cancel(TaskRef, test_cancel),
    Outcome = {cancelled,
               {adk_failure,
                #{component => adk_task, operation => cancel,
                  class => external, reason => test_cancel}}},
    ?assertEqual(Outcome, adk_task:await(TaskRef, 1000)),
    receive
        {adk_task_terminal, TaskRef, Outcome} -> ok
    after 1000 ->
        ?assert(false)
    end,
    receive
        {'DOWN', ExecutionRef, process, Execution, killed} -> ok
    after 1000 ->
        ?assert(false)
    end,
    assert_no_second_terminal(TaskRef).

crashing_work_is_isolated_case() ->
    {ok, TaskRef} = adk_task:start(
                      fun() -> erlang:error(test_boom) end,
                      #{retention_ms => 1000}),
    Outcome = adk_task:await(TaskRef, 1000),
    ?assertEqual(
       {failed,
        {adk_failure,
         #{component => adk_task, operation => execute,
           class => error, reason => test_boom}}},
       Outcome),
    ?assert(is_process_alive(whereis(adk_task_sup))).

starter_death_does_not_orphan_task_case() ->
    Parent = self(),
    Work = fun() ->
        Parent ! {detached_execution, self()},
        receive after 40 -> ok end,
        detached_result
    end,
    {Starter, StarterMonitor} =
        spawn_monitor(
          fun() ->
              Result = adk_task:start(
                         Work, #{retention_ms => 1000}),
              Parent ! {detached_start, self(), Result}
          end),
    TaskRef = receive
        {detached_start, Starter, {ok, Ref}} -> Ref
    after 1000 ->
        ?assert(false)
    end,
    receive
        {'DOWN', StarterMonitor, process, Starter, normal} -> ok
    after 1000 ->
        ?assert(false)
    end,
    Execution = receive
        {detached_execution, Pid} -> Pid
    after 1000 ->
        ?assert(false)
    end,
    ExecutionMonitor = erlang:monitor(process, Execution),
    ?assertEqual({completed, detached_result},
                 adk_task:await(TaskRef, 1000)),
    receive
        {'DOWN', ExecutionMonitor, process, Execution, normal} -> ok
    after 1000 ->
        ?assert(false)
    end.

owner_death_cancels_owned_task_case() ->
    Parent = self(),
    Owner = spawn(fun() -> receive stop -> ok end end),
    Work = fun() ->
        Parent ! {owned_execution, self()},
        receive never -> impossible end
    end,
    {ok, TaskRef} = adk_task:start(
                      Work,
                      #{timeout => 5000,
                        retention_ms => 1000,
                        owner => Owner,
                        cancel_on_owner_down => true}),
    Execution = receive
        {owned_execution, Pid} -> Pid
    after 1000 ->
        ?assert(false)
    end,
    ExecutionRef = erlang:monitor(process, Execution),
    exit(Owner, kill),
    ?assertEqual({cancelled,
                  {adk_failure,
                   #{component => adk_task, operation => owner_down,
                     class => external, reason => killed}}},
                 adk_task:await(TaskRef, 1000)),
    receive
        {'DOWN', ExecutionRef, process, Execution, killed} -> ok
    after 1000 ->
        ?assert(false)
    end.

serial_tools_preserve_order_case() ->
    Table = new_metrics_table(),
    try
        Calls = [tool_call(Id, Table, Delay)
                 || {Id, Delay} <- [{1, 30}, {2, 5}, {3, 1}]],
        {ok, Results} = adk_tool_executor:execute(
                          Calls, #{timeout => 2000}),
        ?assertEqual([1, 2, 3], result_values(Results)),
        ?assertEqual(1, max_seen(Table))
    after
        ets:delete(Table)
    end.

parallel_tools_are_bounded_and_ordered_case() ->
    Table = new_metrics_table(),
    try
        Calls = [tool_call(Id, Table, Delay)
                 || {Id, Delay} <- [{1, 80}, {2, 10},
                                    {3, 20}, {4, 1}]],
        {ok, Results} = adk_tool_executor:execute(
                          Calls,
                          #{mode => parallel,
                            max_concurrency => 2,
                            timeout => 2000}),
        %% Completion order differs, but correlation order is stable.
        ?assertEqual([1, 2, 3, 4], result_values(Results)),
        ?assertEqual([1, 2, 3, 4],
                     [maps:get(index, Result) || Result <- Results]),
        ?assertEqual([<<"call-1">>, <<"call-2">>,
                      <<"call-3">>, <<"call-4">>],
                     [maps:get(call_id, Result) || Result <- Results]),
        ?assertEqual(2, max_seen(Table))
    after
        ets:delete(Table)
    end.

tool_crash_is_per_call_case() ->
    Calls = [
        (base_call(1))#{args => #{id => 1, mode => crash}},
        (base_call(2))#{args => #{id => 2, mode => success}}
    ],
    {ok, [Crashed, Succeeded]} =
        adk_tool_executor:execute(
          Calls, #{mode => parallel, max_concurrency => 2,
                   timeout => 1000}),
    ?assertEqual(
       {error,
        {adk_failure,
         #{component => adk_task, operation => execute,
           class => error, reason => tool_crash}}},
       maps:get(outcome, Crashed)),
    ?assertEqual({ok, 2}, maps:get(outcome, Succeeded)).

tool_pause_is_explicit_case() ->
    Call = (base_call(7))#{args => #{id => 7, mode => pause}},
    {ok, [Result]} = adk_tool_executor:execute(
                       [Call], #{timeout => 1000}),
    ?assertEqual(
       {paused, approval_required, {call, 7}},
       maps:get(outcome, Result)).

tool_timeout_is_per_call_case() ->
    Parent = self(),
    Calls = [
        (base_call(1))#{args => #{id => 1, mode => block,
                                  notify => Parent},
                        timeout => 25},
        (base_call(2))#{args => #{id => 2, mode => success}}
    ],
    {ok, [TimedOut, Succeeded]} =
        adk_tool_executor:execute(
          Calls, #{timeout => 1000, tool_timeout => 500}),
    ?assertEqual({error, timeout}, maps:get(outcome, TimedOut)),
    ?assertEqual({ok, 2}, maps:get(outcome, Succeeded)),
    TimedOutPid = receive
        {tool_started, 1, Pid} -> Pid
    after 1000 ->
        ?assert(false)
    end,
    TimedOutRef = erlang:monitor(process, TimedOutPid),
    receive
        {'DOWN', TimedOutRef, process, TimedOutPid, _Reason} -> ok
    after 1000 ->
        ?assert(false)
    end.

cancelling_batch_stops_tool_processes_case() ->
    Parent = self(),
    Calls = [
        (base_call(1))#{args => #{id => 1, mode => block,
                                  notify => Parent}},
        (base_call(2))#{args => #{id => 2, mode => block,
                                  notify => Parent}}
    ],
    {ok, TaskRef} = adk_tool_executor:start(
                      Calls,
                      #{mode => parallel,
                        max_concurrency => 2,
                        timeout => 5000}),
    Pids = collect_started_pids(2, []),
    Monitors = [{Pid, erlang:monitor(process, Pid)} || Pid <- Pids],
    ok = adk_tool_executor:cancel(TaskRef, batch_cancel),
    ?assertEqual({error,
                  {adk_failure,
                   #{component => adk_task, operation => cancel,
                     class => external, reason => batch_cancel}}},
                 adk_tool_executor:await(TaskRef, 1000)),
    lists:foreach(
      fun({Pid, Ref}) ->
          receive
              {'DOWN', Ref, process, Pid, _Reason} -> ok
          after 1000 ->
              ?assert(false)
          end
      end, Monitors).

base_call(Id) ->
    #{module => adk_tool_executor_test_tool,
      name => <<"executor_test_tool">>,
      args => #{id => Id},
      thought_signature => {signature, Id},
      call_id => <<"call-", (integer_to_binary(Id))/binary>>}.

tool_call(Id, Table, Delay) ->
    Call = base_call(Id),
    Call#{args => #{id => Id, table => Table, delay => Delay}}.

result_values(Results) ->
    [Value || #{outcome := {ok, Value}} <- Results].

new_metrics_table() ->
    ets:new(adk_tool_executor_metrics,
            [set, public, {write_concurrency, true}]).

max_seen(Table) ->
    Values = [Value || {{seen, _Ref}, Value} <- ets:tab2list(Table)],
    lists:max(Values).

collect_started_pids(0, Acc) ->
    lists:reverse(Acc);
collect_started_pids(Remaining, Acc) ->
    receive
        {tool_started, _Id, Pid} ->
            collect_started_pids(Remaining - 1, [Pid | Acc])
    after 1000 ->
        ?assert(false)
    end.

assert_no_second_terminal(TaskRef) ->
    receive
        {adk_task_terminal, TaskRef, _Outcome} ->
            ?assert(false)
    after 50 ->
        ok
    end.

ensure_started(Name, StartFun) ->
    case whereis(Name) of
        undefined ->
            case StartFun() of
                {ok, Pid} ->
                    unlink(Pid),
                    ok;
                {error, {already_started, _Pid}} ->
                    ok
            end;
        _Pid ->
            ok
    end.
