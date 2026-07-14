-module(adk_agent_mailbox_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

agent_mailbox_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun mailbox_stays_responsive_and_stop_cleans_worker/0,
      fun default_turn_timeout_is_finite/0,
      fun invalid_invocation_limit_is_rejected/0,
      fun same_agent_turns_are_fifo/0,
      fun invocation_lanes_overlap_across_sessions/0,
      fun same_session_orders_invoke_and_runner_event/0,
      fun invocation_admission_is_bounded_and_lane_fair/0,
      fun runner_sessions_overlap_on_one_agent/0,
      fun scoped_caller_death_cancels_only_its_lane/0,
      fun stop_cleans_all_scoped_workers/0,
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
                 application:get_env(erlang_adk, agent_turn_timeout)),
    ?assertEqual(
       {ok, 32},
       application:get_env(erlang_adk, max_concurrent_invocations)).

invalid_invocation_limit_is_rejected() ->
    Name = binary_to_list(unique_session(<<"InvalidInvocationLimit">>)),
    Config = #{provider => adk_agent_mailbox_llm,
               observer => self(),
               agent_tag => <<"invalid-limit">>,
               mode => response,
               max_concurrent_invocations => 0},
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Parent ! {Ref, adk_agent:start_link(Name, Config, [])}
    end),
    ?assertEqual(
       {error, {invalid_max_concurrent_invocations,
                expected_positive_integer}},
       receive {Ref, Result} -> Result after 1000 -> timeout end),
    receive
        {'DOWN', Monitor, process, Pid, normal} -> ok
    after 1000 ->
        ?assert(false)
    end.

mailbox_stays_responsive_and_stop_cleans_worker() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(<<"responsive">>, #{}),
    Parent = self(),
    Caller = spawn(fun() ->
        Parent ! {prompt_result, responsive,
                  catch erlang_adk:prompt(Agent, <<"blocked">>)}
    end),
    CallerMonitor = erlang:monitor(process, Caller),
    {Executor, _Prompt} = await_started(<<"responsive">>),
    ExecutorMonitor = erlang:monitor(process, Executor),
    ?assertMatch({ok, [], #{}}, adk_agent:get_tools(Agent)),
    ?assertMatch({ok, _, _, [], #{}}, adk_agent:get_runtime(Agent)),
    AgentMonitor = erlang:monitor(process, Agent),
    ok = erlang_adk:stop_agent(Agent),
    await_down(AgentMonitor, Agent),
    await_down(ExecutorMonitor, Executor),
    await_down(CallerMonitor, Caller),
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

invocation_lanes_overlap_across_sessions() ->
    {ok, Agent} = start_agent(<<"invocation-overlap">>, #{}),
    try
        Parent = self(),
        FirstContext = lane_context(<<"session-a">>),
        SecondContext = lane_context(<<"session-b">>),
        spawn(fun() ->
            Parent ! {prompt_result, invoke_a,
                      adk_agent:invoke(
                        Agent, <<"a">>, FirstContext)}
        end),
        spawn(fun() ->
            Parent ! {prompt_result, invoke_b,
                      adk_agent:invoke(
                        Agent, <<"b">>, SecondContext)}
        end),
        {FirstExecutor, <<"a">>} =
            await_started(<<"invocation-overlap">>),
        {SecondExecutor, <<"b">>} =
            await_started(<<"invocation-overlap">>),
        %% Both scoped turns reached the provider before either was released.
        FirstExecutor ! release,
        SecondExecutor ! release,
        ?assertEqual({ok, <<"a">>}, await_result(invoke_a)),
        ?assertEqual({ok, <<"b">>}, await_result(invoke_b))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

same_session_orders_invoke_and_runner_event() ->
    {ok, Agent} = start_agent(<<"session-fifo">>, #{}),
    try
        Parent = self(),
        Context = lane_context(<<"shared-session">>),
        spawn(fun() ->
            Parent ! {prompt_result, scoped_invoke,
                      adk_agent:invoke(Agent, <<"one">>, Context)}
        end),
        {FirstExecutor, <<"one">>} = await_started(<<"session-fifo">>),
        spawn(fun() ->
            Event = user_event(<<"two">>, <<"inv-two">>),
            Parent ! {prompt_result, scoped_event,
                      adk_agent:run_with_events(
                        Agent, [Event], <<"inv-two">>, Context)}
        end),
        receive
            {agent_mailbox_started, <<"session-fifo">>, <<"two">>, _} ->
                ?assert(false)
        after 75 -> ok
        end,
        FirstExecutor ! release,
        ?assertEqual({ok, <<"one">>}, await_result(scoped_invoke)),
        {SecondExecutor, <<"two">>} = await_started(<<"session-fifo">>),
        SecondExecutor ! release,
        ?assertMatch(
           {ok, #adk_event{content = <<"two">>, is_final = true}},
           await_result(scoped_event))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

invocation_admission_is_bounded_and_lane_fair() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(
                    <<"bounded-fair">>,
                    #{max_concurrent_invocations => 2}),
    try
        %% send_request/2 keeps all four calls owned by this test process, so
        %% their delivery order to the agent is deterministic without blocking
        %% the caller between requests.
        RequestA1 = send_invoke_request(
                      Agent, <<"a1">>, lane_context(<<"fair-a">>)),
        RequestB1 = send_invoke_request(
                      Agent, <<"b1">>, lane_context(<<"fair-b">>)),
        Started = [await_started(<<"bounded-fair">>),
                   await_started(<<"bounded-fair">>)],
        ExecutorA1 = executor_for_prompt(<<"a1">>, Started),
        ExecutorB1 = executor_for_prompt(<<"b1">>, Started),

        %% A's second turn is queued first, but lane A is active. C is the
        %% oldest ready lane and must receive the next free worker.
        RequestA2 = send_invoke_request(
                      Agent, <<"a2">>, lane_context(<<"fair-a">>)),
        RequestC1 = send_invoke_request(
                      Agent, <<"c1">>, lane_context(<<"fair-c">>)),
        assert_no_provider_start(75),
        ?assertEqual(Baseline + 2, active_turns()),

        ExecutorA1 ! release,
        {ExecutorC1, <<"c1">>} = await_started(<<"bounded-fair">>),
        ?assertEqual(Baseline + 2, active_turns()),
        ExecutorB1 ! release,
        {ExecutorA2, <<"a2">>} = await_started(<<"bounded-fair">>),
        ?assertEqual(Baseline + 2, active_turns()),

        ExecutorC1 ! release,
        ExecutorA2 ! release,
        ?assertEqual({reply, {ok, <<"a1">>}},
                     gen_server:wait_response(RequestA1, 2000)),
        ?assertEqual({reply, {ok, <<"b1">>}},
                     gen_server:wait_response(RequestB1, 2000)),
        ?assertEqual({reply, {ok, <<"a2">>}},
                     gen_server:wait_response(RequestA2, 2000)),
        ?assertEqual({reply, {ok, <<"c1">>}},
                     gen_server:wait_response(RequestC1, 2000))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end,
    await_active_turns(Baseline).

runner_sessions_overlap_on_one_agent() ->
    {ok, Agent} = start_agent(<<"runner-overlap">>, #{}),
    App = <<"mailbox_runner_app">>,
    User = <<"mailbox_runner_user">>,
    FirstSession = unique_session(<<"runner-a">>),
    SecondSession = unique_session(<<"runner-b">>),
    Runner = adk_runner:new(
               Agent, App, erlang_adk_session,
               #{run_timeout => 2000}),
    try
        Parent = self(),
        spawn(fun() ->
            Parent ! {runner_result, runner_a,
                      adk_runner:run(
                        Runner, User, FirstSession, <<"runner-a">>)}
        end),
        spawn(fun() ->
            Parent ! {runner_result, runner_b,
                      adk_runner:run(
                        Runner, User, SecondSession, <<"runner-b">>)}
        end),
        {FirstExecutor, FirstPrompt} = await_started(<<"runner-overlap">>),
        {SecondExecutor, SecondPrompt} = await_started(<<"runner-overlap">>),
        ?assertEqual(
           lists:sort([<<"runner-a">>, <<"runner-b">>]),
           lists:sort([FirstPrompt, SecondPrompt])),
        FirstExecutor ! release,
        SecondExecutor ! release,
        ?assertEqual({ok, <<"runner-a">>}, await_runner_result(runner_a)),
        ?assertEqual({ok, <<"runner-b">>}, await_runner_result(runner_b))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = erlang_adk_session:delete_session(App, User, FirstSession),
        _ = erlang_adk_session:delete_session(App, User, SecondSession)
    end.

scoped_caller_death_cancels_only_its_lane() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(<<"scoped-caller-death">>, #{}),
    try
        Parent = self(),
        Context = lane_context(<<"cancelled-session">>),
        Caller = spawn(fun() ->
            _ = adk_agent:invoke(Agent, <<"abandoned">>, Context)
        end),
        {Executor, <<"abandoned">>} =
            await_started(<<"scoped-caller-death">>),
        Monitor = erlang:monitor(process, Executor),
        exit(Caller, kill),
        await_down(Monitor, Executor),
        spawn(fun() ->
            Parent ! {prompt_result, after_cancel,
                      adk_agent:invoke(Agent, <<"after">>, Context)}
        end),
        {RecoveredExecutor, <<"after">>} =
            await_started(<<"scoped-caller-death">>),
        RecoveredExecutor ! release,
        ?assertEqual({ok, <<"after">>}, await_result(after_cancel))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end,
    await_active_turns(Baseline).

stop_cleans_all_scoped_workers() ->
    Baseline = active_turns(),
    {ok, Agent} = start_agent(
                    <<"scoped-stop">>,
                    #{max_concurrent_invocations => 2}),
    Parent = self(),
    FirstCaller = spawn(fun() ->
        Parent ! {prompt_result, scoped_stop_a,
                  catch adk_agent:invoke(
                          Agent, <<"a">>, lane_context(<<"stop-a">>))}
    end),
    SecondCaller = spawn(fun() ->
        Parent ! {prompt_result, scoped_stop_b,
                  catch adk_agent:invoke(
                          Agent, <<"b">>, lane_context(<<"stop-b">>))}
    end),
    ThirdCaller = spawn(fun() ->
        Parent ! {prompt_result, scoped_stop_c,
                  catch adk_agent:invoke(
                          Agent, <<"c">>, lane_context(<<"stop-c">>))}
    end),
    {FirstExecutor, _} = await_started(<<"scoped-stop">>),
    {SecondExecutor, _} = await_started(<<"scoped-stop">>),
    assert_no_provider_start(75),
    ?assertEqual(Baseline + 2, active_turns()),
    FirstMonitor = erlang:monitor(process, FirstExecutor),
    SecondMonitor = erlang:monitor(process, SecondExecutor),
    ok = erlang_adk:stop_agent(Agent),
    await_down(FirstMonitor, FirstExecutor),
    await_down(SecondMonitor, SecondExecutor),
    await_process_exit(FirstCaller),
    await_process_exit(SecondCaller),
    await_process_exit(ThirdCaller),
    await_active_turns(Baseline).

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
    IdentifierTag = binary:replace(Tag, <<"-">>, <<"_">>, [global]),
    Name = binary_to_list(
             <<"Mailbox_", IdentifierTag/binary, "_",
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

assert_no_provider_start(Timeout) ->
    receive
        {agent_mailbox_started, Tag, Prompt, _Executor} ->
            error({unexpected_provider_start, Tag, Prompt})
    after Timeout ->
        ok
    end.

send_invoke_request(Agent, Message, Context) ->
    gen_server:send_request(Agent, {invoke, Message, Context}).

executor_for_prompt(Prompt, Started) ->
    case [Executor || {Executor, SeenPrompt} <- Started,
                      SeenPrompt =:= Prompt] of
        [Executor] -> Executor;
        Other -> error({unexpected_started_turns, Prompt, Other})
    end.

await_result(Label) ->
    receive
        {prompt_result, Label, Result} -> Result
    after 2000 ->
        error({prompt_result_timeout, Label})
    end.

await_runner_result(Label) ->
    receive
        {runner_result, Label, Result} -> Result
    after 2000 ->
        error({runner_result_timeout, Label})
    end.

await_process_exit(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    case is_process_alive(Pid) of
        false ->
            erlang:demonitor(Monitor, [flush]),
            ok;
        true ->
            await_down(Monitor, Pid)
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

lane_context(SessionId) ->
    #{app_name => <<"mailbox_app">>,
      user_id => <<"mailbox_user">>,
      session_id => SessionId,
      state => #{}}.

user_event(Content, InvocationId) ->
    adk_event:new(
      <<"user">>, Content, #{invocation_id => InvocationId}).

unique_session(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.

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
