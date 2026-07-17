-module(adk_eval_agent_adapter_test).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

agent_adapter_test_() ->
    {setup,
     fun setup/0,
     fun(_State) -> ok end,
     [fun successful_agent_turn_is_isolated_and_cleaned_up/0,
      fun provider_failure_is_reduced_to_runner_failed/0,
      fun paused_agent_turn_is_rejected/0,
      fun owner_death_cleans_up_an_active_turn/0,
      fun init_timeout_does_not_orphan_a_late_agent/0,
      fun init_case_validation_and_start_failure/0,
      fun run_turn_protocol_and_validation/0,
      fun terminate_case_protocol_and_validation/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

successful_agent_turn_is_isolated_and_cleaned_up() ->
    Target = target(response, []),
    {ok, CaseTarget = #{guard := Guard}, 0} =
        adk_eval_agent_adapter:init_case(
          Target, #{}, #{<<"sample_id">> => <<"successful">>},
          #{init_timeout_ms => invalid, run_timeout_ms => invalid}),
    GuardMonitor = erlang:monitor(process, Guard),
    {ok, TurnResult} = adk_eval_agent_adapter:run_turn(
                         CaseTarget, #{<<"input">> => <<"evaluate me">>},
                         0, #{}, #{}),
    ?assertEqual(<<"evaluated">>, maps:get(output, TurnResult)),
    ?assertEqual(1, maps:get(state, TurnResult)),
    ?assertEqual(#{}, maps:get(metadata, TurnResult)),
    Events = maps:get(events, TurnResult),
    ?assertMatch([_ | _], Events),
    ?assert(lists:any(
              fun(#adk_event{is_final = true,
                             content = <<"evaluated">>}) -> true;
                 (_) -> false
              end,
              Events)),
    ok = adk_eval_agent_adapter:terminate_case(
           CaseTarget, maps:get(state, TurnResult),
           #{stop_timeout_ms => invalid}),
    receive
        {'DOWN', GuardMonitor, process, Guard, normal} -> ok
    after 1000 ->
        erlang:error(eval_agent_guard_not_stopped)
    end.

provider_failure_is_reduced_to_runner_failed() ->
    {ok, CaseTarget, 0} = init_target(target(error, []), <<"error">>),
    try
        ?assertEqual(
           {error, runner_failed},
           adk_eval_agent_adapter:run_turn(
             CaseTarget, #{<<"input">> => <<"fail">>}, 0, #{}, #{}))
    after
        ok = adk_eval_agent_adapter:terminate_case(CaseTarget, 0, #{})
    end.

paused_agent_turn_is_rejected() ->
    {ok, CaseTarget, 0} =
        init_target(target(pause, [adk_long_running_tool]), <<"pause">>),
    try
        ?assertEqual(
           {error, evaluation_paused},
           adk_eval_agent_adapter:run_turn(
             CaseTarget, #{<<"input">> => <<"pause">>}, 0, #{}, #{}))
    after
        ok = adk_eval_agent_adapter:terminate_case(CaseTarget, 0, #{})
    end.

owner_death_cleans_up_an_active_turn() ->
    Parent = self(),
    Owner = spawn(
              fun() ->
                  BaseTarget = target(block, []),
                  BaseConfig = maps:get(config, BaseTarget),
                  BlockingTarget = BaseTarget#{
                    config := BaseConfig#{
                      test_pid => Parent, block_ms => 5000}},
                  {ok, CaseTarget = #{guard := Guard}, 0} =
                      init_target(BlockingTarget, <<"owner-death">>),
                  Parent ! {eval_case_ready, self(), Guard},
                  Result = adk_eval_agent_adapter:run_turn(
                             CaseTarget,
                             #{<<"input">> => <<"block">>},
                             0, #{}, #{}),
                  Parent ! {unexpected_eval_turn_result, Result}
              end),
    Guard = receive
        {eval_case_ready, Owner, ReadyGuard} -> ReadyGuard
    after 1000 ->
        erlang:error(eval_agent_guard_not_ready)
    end,
    ProviderWorker = receive
        {eval_agent_provider_called, WorkerPid} -> WorkerPid
    after 1000 ->
        erlang:error(eval_agent_provider_not_called)
    end,
    OwnerMonitor = erlang:monitor(process, Owner),
    GuardMonitor = erlang:monitor(process, Guard),
    ProviderMonitor = erlang:monitor(process, ProviderWorker),
    exit(Owner, kill),
    assert_down(OwnerMonitor, Owner),
    assert_down(GuardMonitor, Guard),
    assert_down(ProviderMonitor, ProviderWorker),
    receive
        {unexpected_eval_turn_result, Result} ->
            erlang:error({turn_survived_owner, Result})
    after 0 ->
        ok
    end.

init_timeout_does_not_orphan_a_late_agent() ->
    Parent = self(),
    Caller = spawn(
               fun() ->
                   BaseTarget = target(response, []),
                   BaseConfig = maps:get(config, BaseTarget),
                   SlowTarget = BaseTarget#{
                     config := BaseConfig#{
                       init_test_pid => Parent, init_delay_ms => 50}},
                   Result = adk_eval_agent_adapter:init_case(
                              SlowTarget, #{},
                              #{<<"sample_id">> => <<"init-timeout">>},
                              #{init_timeout_ms => 1}),
                   Parent ! {eval_init_timeout_result, self(), Result}
               end),
    AgentPid = receive
        {eval_agent_provider_validating, ValidatingPid} -> ValidatingPid
    after 1000 ->
        erlang:error(eval_agent_validation_not_started)
    end,
    AgentMonitor = erlang:monitor(process, AgentPid),
    CallerMonitor = erlang:monitor(process, Caller),
    receive
        {eval_init_timeout_result, Caller,
         {error, agent_guard_start_timeout}} -> ok
    after 1000 ->
        erlang:error(eval_agent_init_did_not_time_out)
    end,
    assert_down(CallerMonitor, Caller),
    assert_down(AgentMonitor, AgentPid).

init_case_validation_and_start_failure() ->
    ?assertEqual(
       {error, invalid_agent_eval_target},
       adk_eval_agent_adapter:init_case(invalid, #{}, #{}, #{})),
    ?assertEqual(
       {error, invalid_agent_eval_target},
       adk_eval_agent_adapter:init_case(#{}, #{}, #{}, #{})),
    ?assertEqual(
       {error, invalid_agent_runner_options},
       adk_eval_agent_adapter:init_case(
         (target(response, []))#{runner_options => invalid},
         #{}, #{<<"sample_id">> => <<"invalid-runner-options">>}, #{})),
    Broken = (target(response, []))#{
               config := #{provider => adk_eval_missing_provider}},
    ?assertEqual(
       {error, agent_start_failed},
       adk_eval_agent_adapter:init_case(
         Broken, #{}, #{<<"sample_id">> => <<"start-failure">>}, #{})).

run_turn_protocol_and_validation() ->
    ?assertEqual(
       {error, missing_eval_turn_input},
       adk_eval_agent_adapter:run_turn(
         #{guard => self()}, #{}, 0, #{}, #{})),
    ?assertEqual(
       {error, invalid_agent_eval_case_target},
       adk_eval_agent_adapter:run_turn(
         #{guard => invalid}, #{<<"input">> => <<"x">>},
         0, #{}, #{})),

    Partial = event(<<"partial">>, false),
    Final = event(<<"final">>, true),
    EventGuard = run_guard(
                   fun(Alias, _Input) ->
                       Alias ! {adk_eval_agent_event, Alias, Partial},
                       Alias ! {adk_eval_agent_event, Alias, Final},
                       Alias ! {adk_eval_agent_terminal, Alias, ok}
                   end),
    {ok, EventResult} = adk_eval_agent_adapter:run_turn(
                          #{guard => EventGuard},
                          #{<<"input">> => <<"events">>}, 7, #{}, #{}),
    ?assertEqual(<<"final">>, maps:get(output, EventResult)),
    ?assertEqual([Partial, Final], maps:get(events, EventResult)),
    ?assertEqual(8, maps:get(state, EventResult)),
    stop_guard(EventGuard),

    EmptyGuard = run_guard(
                   fun(Alias, _Input) ->
                       Alias ! {adk_eval_agent_terminal, Alias, ok}
                   end),
    {ok, EmptyResult} = adk_eval_agent_adapter:run_turn(
                          #{guard => EmptyGuard},
                          #{<<"input">> => <<"empty">>}, invalid, #{}, #{}),
    ?assertEqual(<<>>, maps:get(output, EmptyResult)),
    ?assertEqual(1, maps:get(state, EmptyResult)),
    stop_guard(EmptyGuard),

    ErrorGuard = run_guard(
                   fun(Alias, _Input) ->
                       Alias ! {adk_eval_agent_terminal, Alias,
                                {error, fixture_failure}}
                   end),
    ?assertEqual(
       {error, fixture_failure},
       adk_eval_agent_adapter:run_turn(
         #{guard => ErrorGuard}, #{<<"input">> => <<"error">>},
         0, #{}, #{})),
    stop_guard(ErrorGuard),

    DownGuard = spawn(
                  fun() ->
                      receive
                          {adk_eval_agent_run, _Owner, _Alias, _Input} ->
                              exit(fixture_guard_failure)
                      end
                  end),
    ?assertEqual(
       {error, agent_guard_down},
       adk_eval_agent_adapter:run_turn(
         #{guard => DownGuard}, #{<<"input">> => <<"down">>},
         0, #{}, #{})).

terminate_case_protocol_and_validation() ->
    ?assertEqual(
       {error, invalid_agent_eval_case_target},
       adk_eval_agent_adapter:terminate_case(
         #{guard => invalid}, 0, #{})),

    AckGuard = stop_guard_fixture(ack),
    ?assertEqual(ok,
                 adk_eval_agent_adapter:terminate_case(
                   #{guard => AckGuard}, 0,
                   #{stop_timeout_ms => invalid})),
    stop_guard(AckGuard),

    NormalGuard = stop_guard_fixture(normal),
    ?assertEqual(ok,
                 adk_eval_agent_adapter:terminate_case(
                   #{guard => NormalGuard}, 0, #{})),

    FailedGuard = stop_guard_fixture(failed),
    ?assertEqual(
       {error, agent_guard_stopped_unexpectedly},
       adk_eval_agent_adapter:terminate_case(
         #{guard => FailedGuard}, 0, #{})),

    IgnoringGuard = stop_guard_fixture(ignore),
    ?assertEqual(
       {error, agent_guard_stop_timeout},
       adk_eval_agent_adapter:terminate_case(
         #{guard => IgnoringGuard}, 0, #{stop_timeout_ms => 1})),
    stop_guard(IgnoringGuard).

target(Mode, Tools) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    #{name => <<"EvalAdapterTest", Suffix/binary>>,
      config => #{provider => adk_eval_agent_test_provider,
                  mode => Mode},
      tools => Tools,
      runner_options => #{}}.

init_target(Target, SampleId) ->
    adk_eval_agent_adapter:init_case(
      Target, #{}, #{<<"sample_id">> => SampleId},
      #{run_timeout_ms => 2000}).

event(Content, IsFinal) ->
    #adk_event{id = <<"event">>, invocation_id = <<"invocation">>,
               author = <<"agent">>, content = Content, actions = #{},
               timestamp = 0, partial = not IsFinal,
               is_final = IsFinal}.

run_guard(Handler) ->
    spawn(
      fun Loop() ->
          receive
              {adk_eval_agent_run, _Owner, Alias, Input} ->
                  Handler(Alias, Input),
                  Loop();
              stop ->
                  ok
          end
      end).

stop_guard_fixture(Mode) ->
    spawn(
      fun Loop() ->
          receive
              {adk_eval_agent_stop, _Owner, Alias} ->
                  case Mode of
                      ack ->
                          Alias ! {adk_eval_agent_stopped, Alias},
                          Loop();
                      normal ->
                          exit(normal);
                      failed ->
                          exit(fixture_stop_failure);
                      ignore ->
                          Loop()
                  end;
              stop ->
                  ok
          end
      end).

stop_guard(Guard) ->
    Guard ! stop,
    ok.

assert_down(Monitor, Pid) ->
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 2000 ->
        erlang:error({process_not_stopped, Pid})
    end.
