-module(adk_agent_mailbox_test).
-include_lib("eunit/include/eunit.hrl").

agent_mailbox_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun mailbox_stays_responsive_and_stop_cleans_worker/0,
      fun default_turn_timeout_is_finite/0,
      fun same_agent_turns_are_fifo/0,
      fun independent_agents_overlap/0,
      fun executor_crash_is_structural_and_queue_recovers/0,
      fun turn_timeout_is_structural_and_cleans_executor/0,
      fun caller_death_cancels_active_turn/0,
      fun supervisor_and_status_never_expose_agent_secret/0]}.

setup() ->
    application:ensure_all_started(erlang_adk).

cleanup(_Started) ->
    flush_mailbox(),
    ok.

default_turn_timeout_is_finite() ->
    ?assertEqual({ok, 60000},
                 application:get_env(erlang_adk, agent_turn_timeout)).

mailbox_stays_responsive_and_stop_cleans_worker() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(<<"responsive">>, #{}),
    Parent = self(),
    Caller = spawn(fun() ->
        Parent ! {prompt_result, responsive,
                  catch erlang_adk:prompt(Agent, <<"blocked">>)}
    end),
    {Executor, _Prompt} = await_started(<<"responsive">>),
    ExecutorMonitor = erlang:monitor(process, Executor),
    ?assertMatch({ok, [], #{}}, adk_agent:get_tools(Agent)),
    ?assertMatch({ok, _, _, [], #{}}, adk_agent:get_runtime(Agent)),
    AgentMonitor = erlang:monitor(process, Agent),
    ok = erlang_adk:stop_agent(Agent),
    await_down(AgentMonitor, Agent),
    await_down(ExecutorMonitor, Executor),
    ?assertNot(is_process_alive(Caller)),
    await_active_turns(Baseline).

same_agent_turns_are_fifo() ->
    {ok, Agent} = start_agent(<<"fifo">>, #{}),
    try
        Parent = self(),
        spawn(fun() -> Parent ! {prompt_result, one,
                                erlang_adk:prompt(Agent, <<"one">>)} end),
        {FirstExecutor, <<"one">>} = await_started(<<"fifo">>),
        spawn(fun() -> Parent ! {prompt_result, two,
                                erlang_adk:prompt(Agent, <<"two">>)} end),
        receive
            {agent_mailbox_started, <<"fifo">>, <<"two">>, _} ->
                ?assert(false)
        after 75 -> ok
        end,
        FirstExecutor ! release,
        ?assertEqual({ok, <<"one">>}, await_result(one)),
        {SecondExecutor, <<"two">>} = await_started(<<"fifo">>),
        SecondExecutor ! release,
        ?assertEqual({ok, <<"two">>}, await_result(two))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

independent_agents_overlap() ->
    {ok, First} = start_agent(<<"parallel-a">>, #{}),
    {ok, Second} = start_agent(<<"parallel-b">>, #{}),
    try
        Parent = self(),
        spawn(fun() -> Parent ! {prompt_result, parallel_a,
                                erlang_adk:prompt(First, <<"a">>)} end),
        spawn(fun() -> Parent ! {prompt_result, parallel_b,
                                erlang_adk:prompt(Second, <<"b">>)} end),
        {FirstExecutor, <<"a">>} = await_started(<<"parallel-a">>),
        {SecondExecutor, <<"b">>} = await_started(<<"parallel-b">>),
        %% Both provider workers reached their blocking point before either was
        %% released; independent agents therefore overlap on BEAM schedulers.
        FirstExecutor ! release,
        SecondExecutor ! release,
        ?assertEqual({ok, <<"a">>}, await_result(parallel_a)),
        ?assertEqual({ok, <<"b">>}, await_result(parallel_b))
    after
        _ = catch erlang_adk:stop_agent(First),
        _ = catch erlang_adk:stop_agent(Second)
    end.

executor_crash_is_structural_and_queue_recovers() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(<<"crash">>, #{}),
    try
        Parent = self(),
        spawn(fun() -> Parent ! {prompt_result, crashed,
                                erlang_adk:prompt(Agent, <<"crash">>)} end),
        {Executor, <<"crash">>} = await_started(<<"crash">>),
        exit(Executor, kill),
        ?assertMatch(
           {error, {adk_failure,
                    #{component := agent,
                      operation := turn_worker_exit,
                      class := external,
                      reason := killed}}},
           await_result(crashed)),
        ?assert(is_process_alive(Agent)),
        spawn(fun() -> Parent ! {prompt_result, recovered,
                                erlang_adk:prompt(Agent, <<"recover">>)} end),
        {RecoveredExecutor, <<"recover">>} = await_started(<<"crash">>),
        RecoveredExecutor ! release,
        ?assertEqual({ok, <<"recover">>}, await_result(recovered))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end,
    await_active_turns(Baseline).

turn_timeout_is_structural_and_cleans_executor() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(
                    <<"timeout">>, #{agent_turn_timeout => 30}),
    try
        Parent = self(),
        spawn(fun() -> Parent ! {prompt_result, timed_out,
                                erlang_adk:prompt(Agent, <<"wait">>)} end),
        {Executor, <<"wait">>} = await_started(<<"timeout">>),
        Monitor = erlang:monitor(process, Executor),
        ?assertMatch(
           {error, {adk_failure,
                    #{component := agent,
                      operation := turn_timeout,
                      class := external,
                      reason := timeout}}},
           await_result(timed_out)),
        await_down(Monitor, Executor),
        ?assert(is_process_alive(Agent))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end,
    await_active_turns(Baseline).

caller_death_cancels_active_turn() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(<<"caller-death">>, #{}),
    try
        Caller = spawn(fun() ->
            _ = erlang_adk:prompt(Agent, <<"abandoned">>)
        end),
        {Executor, <<"abandoned">>} = await_started(<<"caller-death">>),
        Monitor = erlang:monitor(process, Executor),
        exit(Caller, kill),
        await_down(Monitor, Executor),
        await_active_turns(Baseline),
        ?assert(is_process_alive(Agent))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

supervisor_and_status_never_expose_agent_secret() ->
    Secret = <<"ERLANG_ADK_AGENT_SECRET_7f523ace">>,
    HandlerId = adk_agent_mailbox_capture,
    _ = logger:remove_handler(HandlerId),
    ok = logger:add_handler(
           HandlerId, adk_agent_mailbox_log_handler,
           #{level => all, config => #{test_pid => self()}}),
    {ok, Agent0} = start_agent(
                     <<"secret-status">>, #{api_key => Secret}),
    {ok, AgentName0, RuntimeConfig0, [], #{}} =
        adk_agent:get_runtime(Agent0),
    AgentName = unicode:characters_to_binary(AgentName0),
    assert_secret_absent(Secret, RuntimeConfig0),
    ?assertNot(maps:is_key(api_key, RuntimeConfig0)),
    try
        assert_secret_absent(Secret, sys:get_status(Agent0)),
        assert_secret_absent(Secret, sys:get_status(adk_agent_sup)),
        assert_secret_absent(Secret,
                             sys:get_status(adk_agent_config_store)),
        OldMonitor = erlang:monitor(process, Agent0),
        exit(Agent0, kill),
        await_down(OldMonitor, Agent0),
        Agent1 = await_restarted(AgentName, Agent0),
        Logs = collect_logs(250, []),
        assert_secret_absent(Secret, Logs),
        assert_secret_absent(Secret, sys:get_status(adk_agent_sup)),
        Parent = self(),
        spawn(fun() -> Parent ! {prompt_result, coordinator_killed,
                                erlang_adk:prompt(Agent1, <<"after">>)} end),
        {Executor, <<"after">>} = await_started(<<"secret-status">>),
        assert_secret_absent(Secret,
                             sys:get_status(adk_agent_turn_sup)),
        [{_TurnRef, TurnWorker, worker, [adk_agent_turn_worker]}] =
            [Child || Child = {_Id, Pid, worker, _Modules} <-
                          supervisor:which_children(adk_agent_turn_sup),
                      is_pid(Pid)],
        assert_secret_absent(Secret, sys:get_status(TurnWorker)),
        ExecutorMonitor = erlang:monitor(process, Executor),
        exit(TurnWorker, kill),
        ?assertMatch(
           {error, {adk_failure,
                    #{component := agent,
                      operation := turn_worker_exit,
                      class := external,
                      reason := killed}}},
           await_result(coordinator_killed)),
        await_down(ExecutorMonitor, Executor),
        TurnLogs = collect_logs(100, []),
        assert_secret_absent(Secret, TurnLogs),
        spawn(fun() -> Parent ! {prompt_result, restarted,
                                erlang_adk:prompt(Agent1, <<"again">>)} end),
        {RecoveredExecutor, <<"again">>} =
            await_started(<<"secret-status">>),
        RecoveredExecutor ! release,
        ?assertEqual({ok, <<"again">>}, await_result(restarted)),
        ok = erlang_adk:stop_agent(Agent1)
    after
        _ = logger:remove_handler(HandlerId),
        case adk_agent_registry:lookup(AgentName) of
            {ok, Pid} -> _ = catch erlang_adk:stop_agent(Pid);
            _ -> ok
        end
    end.

start_agent(Tag, Extra) ->
    Name = binary_to_list(
             <<"Mailbox-", Tag/binary, "-",
               (integer_to_binary(erlang:unique_integer([positive])))/binary>>),
    Config = maps:merge(
               #{provider => adk_agent_mailbox_llm,
                 observer => self(),
                 agent_tag => Tag,
                 mode => block}, Extra),
    erlang_adk:spawn_agent(Name, Config, []).

await_started(Tag) ->
    receive
        {agent_mailbox_started, Tag, Prompt, Executor} ->
            {Executor, Prompt}
    after 2000 ->
        error({agent_mailbox_start_timeout, Tag})
    end.

await_result(Label) ->
    receive
        {prompt_result, Label, Result} -> Result
    after 2000 ->
        error({prompt_result_timeout, Label})
    end.

await_down(Monitor, Pid) ->
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 2000 ->
        error({process_down_timeout, Pid})
    end.

active_turns() ->
    proplists:get_value(
      active, supervisor:count_children(adk_agent_turn_sup), 0).

await_active_turns(Expected) ->
    await_active_turns(Expected, 100).

await_active_turns(Expected, 0) ->
    ?assertEqual(Expected, active_turns());
await_active_turns(Expected, Remaining) ->
    case active_turns() of
        Expected -> ok;
        _ -> timer:sleep(10), await_active_turns(Expected, Remaining - 1)
    end.

await_restarted(Name, OldPid) ->
    await_restarted(Name, OldPid, 100).

await_restarted(Name, OldPid, 0) ->
    error({agent_restart_timeout, Name, OldPid});
await_restarted(Name, OldPid, Remaining) ->
    case adk_agent_registry:lookup(Name) of
        {ok, NewPid} when NewPid =/= OldPid -> NewPid;
        _ -> timer:sleep(10), await_restarted(Name, OldPid, Remaining - 1)
    end.

collect_logs(QuietMs, Acc) ->
    receive
        {agent_mailbox_log, Event} -> collect_logs(QuietMs, [Event | Acc])
    after QuietMs ->
        lists:reverse(Acc)
    end.

assert_secret_absent(Secret, Term) ->
    Rendered = iolist_to_binary(io_lib:format("~p", [Term])),
    ?assertEqual(nomatch, binary:match(Rendered, Secret)).

flush_mailbox() ->
    receive _ -> flush_mailbox() after 0 -> ok end.
