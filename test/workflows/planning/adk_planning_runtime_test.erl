-module(adk_planning_runtime_test).
-include_lib("eunit/include/eunit.hrl").

plan_codec_roundtrip_and_secret_pruning_test() ->
    {ok, Step} = adk_plan:step(
                   <<"lookup">>, <<"Look up a value">>,
                   #{kind => <<"tool">>, api_key => <<"hidden">>},
                   #{password => <<"hidden">>, safe => true}),
    ?assertNot(maps:is_key(<<"api_key">>, maps:get(<<"action">>, Step))),
    ?assertNot(maps:is_key(<<"password">>,
                           maps:get(<<"metadata">>, Step))),
    {ok, Plan} = adk_plan:new(
                   <<"plan-1">>, 0,
                   #{task => <<"inspect">>, access_token => <<"hidden">>},
                   [Step], #{build => <<"abc">>, secret => <<"hidden">>}),
    ?assertNot(maps:is_key(<<"access_token">>,
                           maps:get(<<"goal">>, Plan))),
    ?assertNot(maps:is_key(<<"secret">>,
                           maps:get(<<"metadata">>, Plan))),
    Json = jsx:encode(Plan),
    ?assertEqual({ok, Plan},
                 adk_plan:decode(jsx:decode(Json, [return_maps]))).

plan_rejects_opaque_code_and_ambiguous_shapes_test() ->
    ?assertMatch(
       {error, _},
       adk_plan:step(<<"code">>, <<"Never execute code">>,
                     #{source => fun() -> unsafe end})),
    {ok, Step} = adk_plan:step(
                   <<"same">>, <<"A">>, #{kind => <<"noop">>}),
    ?assertEqual(
       {error, {duplicate_plan_step_id, <<"same">>}},
       adk_plan:new(<<"duplicates">>, 0, <<"goal">>, [Step, Step])),
    ?assertMatch(
       {error, {unknown_plan_step_fields, 0, _}},
       adk_plan:new(
         <<"unknown">>, 0, <<"goal">>,
         [Step#{unexpected => true}])),
    ?assertMatch(
       {error, {duplicate_plan_field, id}},
       adk_plan:validate(
         #{id => <<"one">>, <<"id">> => <<"two">>, revision => 0,
           goal => <<"goal">>, steps => [Step]})).

simple_plan_completes_with_json_safe_history_test() ->
    {ok, Result} = run(normal, echo, #{}),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Result)),
    ?assertEqual(1, maps:get(<<"result">>, Result)),
    ?assertEqual(1, maps:get(<<"steps_executed">>, Result)),
    ?assertEqual(0, maps:get(<<"replans">>, Result)),
    [Observation] = maps:get(<<"observations">>, Result),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Observation)),
    Encoded = jsx:encode(Result),
    ?assertEqual(nomatch, binary:match(Encoded, <<"must-be-pruned">>)),
    ?assertEqual(
       {ok, Result},
       adk_planning_runtime:decode_result(
         jsx:decode(Encoded, [return_maps]))).

model_supplied_code_is_only_opaque_action_data_test() ->
    Goal = <<"do not execute source">>,
    {ok, Step} = adk_plan:step(
                   <<"opaque">>, <<"Treat source as data">>,
                   #{<<"mode">> => <<"echo">>, <<"value">> => 7,
                     <<"module">> => <<"os">>,
                     <<"source">> => <<"halt().">>}),
    {ok, Plan} = adk_plan:new(<<"opaque-plan">>, 0, Goal, [Step]),
    Planner = (planner(normal))#{config => #{mode => configured_plan,
                                             plan => Plan}},
    %% The codec accepts strings as ordinary data; executor selection remains
    %% the trusted descriptor module and cannot be changed by this action.
    ?assertEqual(<<"os">>,
                 maps:get(<<"module">>, maps:get(<<"action">>, Step))),
    ?assertMatch({ok, _}, adk_plan:validate(Plan)),
    {ok, Result} = adk_planning_runtime:run(
                     Planner, executor(echo), Goal, #{}, #{}),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Result)),
    ?assertEqual(7, maps:get(<<"result">>, Result)).

replanning_recovers_from_step_failure_test() ->
    {ok, Result} = run(replan_once, from_action, #{}),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Result)),
    ?assertEqual(42, maps:get(<<"result">>, Result)),
    ?assertEqual(2, maps:get(<<"steps_executed">>, Result)),
    ?assertEqual(1, maps:get(<<"replans">>, Result)),
    ?assertEqual(1, maps:get(
                      <<"revision">>, maps:get(<<"plan">>, Result))),
    [Failed, Recovered] = maps:get(<<"observations">>, Result),
    ?assertEqual(<<"error">>, maps:get(<<"status">>, Failed)),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Recovered)).

max_steps_is_total_across_plan_test() ->
    Planner = (planner(normal))#{config => #{mode => normal,
                                             step_count => 3}},
    {ok, Result} = adk_planning_runtime:run(
                     Planner, executor(echo), goal(), context(),
                     #{max_steps => 2}),
    assert_failed_kind(Result, <<"max_steps_exceeded">>),
    ?assertEqual(2, maps:get(<<"steps_executed">>, Result)),
    ?assertEqual(2, length(maps:get(<<"observations">>, Result))).

max_replans_is_enforced_test() ->
    {ok, Result} = run(replan_forever, from_action,
                       #{max_replans => 1, max_steps => 10}),
    assert_failed_kind(Result, <<"max_replans_exceeded">>),
    ?assertEqual(1, maps:get(<<"replans">>, Result)),
    ?assertEqual(2, maps:get(<<"steps_executed">>, Result)).

absolute_deadline_is_a_failure_value_test() ->
    Started = erlang:monotonic_time(millisecond),
    {ok, Result} = run(normal, timeout,
                       #{timeout_ms => 25,
                         callback_timeout_ms => 1000}),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    assert_failed_kind(Result, <<"deadline_exceeded">>),
    ?assertEqual(0, maps:get(<<"steps_executed">>, Result)).

callback_timeout_is_reviewable_step_failure_test() ->
    {ok, Result} = run(normal, timeout,
                       #{timeout_ms => 1000,
                         callback_timeout_ms => 20}),
    assert_failed_kind(Result, <<"step_failed">>),
    [Observation] = maps:get(<<"observations">>, Result),
    Error = maps:get(<<"error">>, Observation),
    ?assertEqual(<<"executor_callback_failed">>,
                 maps:get(<<"kind">>, Error)),
    ?assertEqual(<<"callback_timeout">>, maps:get(<<"reason">>, Error)).

planner_crash_timeout_and_invalid_plan_are_values_test() ->
    {ok, Crashed} = run(plan_crash, echo, #{}),
    assert_failed_kind(Crashed, <<"planner_callback_failed">>),
    {ok, TimedOut} = run(plan_timeout, echo,
                         #{timeout_ms => 1000,
                           callback_timeout_ms => 20}),
    assert_failed_kind(TimedOut, <<"planner_callback_failed">>),
    {ok, Invalid} = run(invalid_plan, echo, #{}),
    assert_failed_kind(Invalid, <<"invalid_initial_plan">>).

executor_crash_invalid_and_opaque_output_are_values_test() ->
    {ok, Crashed} = run(normal, crash, #{}),
    assert_observation_kind(Crashed, <<"executor_callback_failed">>),
    {ok, Invalid} = run(normal, invalid, #{}),
    assert_observation_kind(Invalid, <<"invalid_executor_result">>),
    {ok, Opaque} = run(normal, opaque, #{}),
    assert_observation_kind(Opaque, <<"invalid_executor_output">>).

planner_review_crash_and_invalid_decision_are_values_test() ->
    {ok, Crashed} = run(review_crash, echo, #{}),
    assert_failed_kind(Crashed, <<"planner_callback_failed">>),
    {ok, Invalid} = run(invalid_review, echo, #{}),
    assert_failed_kind(Invalid, <<"invalid_planner_decision">>).

replan_identity_is_strict_test() ->
    {ok, Result} = run(bad_replan, echo, #{}),
    assert_failed_kind(Result, <<"invalid_replan">>),
    ?assertEqual(0, maps:get(<<"replans">>, Result)).

plan_size_budget_is_checked_test() ->
    {ok, Result} = run(normal, echo, #{max_plan_bytes => 32}),
    assert_failed_kind(Result, <<"invalid_initial_plan">>),
    Error = maps:get(<<"error">>, Result),
    ?assertEqual(<<"plan_size_limit_exceeded">>,
                 maps:get(<<"reason">>, Error)).

heap_exhaustion_is_isolated_test() ->
    {ok, Result} = run(normal, heap,
                       #{max_heap_words => 10000,
                         callback_timeout_ms => 1000}),
    assert_observation_kind(Result, <<"executor_callback_failed">>).

cancellation_kills_active_worker_and_redacts_reason_test() ->
    Planner = planner(normal),
    Executor = (executor(timeout))#{config =>
                                      #{mode => timeout,
                                        delay_ms => 5000}},
    {ok, Runtime, Ref} = adk_planning_runtime:start(
                           Planner, Executor, goal(), context(),
                           #{timeout_ms => 10000,
                             callback_timeout_ms => 9000}),
    Worker = receive
        {executor_started, Pid, <<"1">>} -> Pid
    after 1000 -> erlang:error(executor_not_started)
    end,
    WorkerMonitor = erlang:monitor(process, Worker),
    ok = adk_planning_runtime:cancel(
           Runtime, Ref,
           #{reason => user_requested,
             access_token => <<"must-not-leak">>}),
    {ok, Result} = adk_planning_runtime:await(Runtime, Ref, 1000),
    ?assertEqual(<<"cancelled">>, maps:get(<<"status">>, Result)),
    ?assertEqual(0, maps:get(<<"steps_executed">>, Result)),
    receive
        {'DOWN', WorkerMonitor, process, Worker, _TerminationReason} -> ok
    after 1000 -> erlang:error(executor_not_cancelled)
    end,
    ?assertNot(erlang:is_process_alive(Worker)),
    Encoded = jsx:encode(Result),
    ?assertEqual(nomatch, binary:match(Encoded, <<"must-not-leak">>)),
    CancelError = maps:get(<<"error">>, Result),
    CancelReason = maps:get(<<"reason">>, CancelError),
    ?assertEqual(<<"user_requested">>,
                 maps:get(<<"reason">>, CancelReason)),
    ?assertNot(maps:is_key(<<"access_token">>, CancelReason)).

mismatched_cancel_ref_is_rejected_without_stopping_runtime_test() ->
    Planner = planner(normal),
    Executor = (executor(timeout))#{config =>
                                      #{mode => timeout,
                                        delay_ms => 5000}},
    {ok, Runtime, Ref} = adk_planning_runtime:start(
                           Planner, Executor, goal(), context(),
                           #{timeout_ms => 10000,
                             callback_timeout_ms => 9000}),
    _Worker = receive
        {executor_started, Pid, <<"1">>} -> Pid
    after 1000 -> erlang:error(executor_not_started)
    end,
    ?assertEqual(ok, adk_planning_runtime:validate_ref(Runtime, Ref)),
    ?assertEqual({error, invalid_planning_ref},
                 adk_planning_runtime:validate_ref(Runtime, make_ref())),
    ?assertEqual({error, invalid_planning_ref},
                 adk_planning_runtime:cancel(
                   Runtime, make_ref(), wrong_run)),
    ?assert(erlang:is_process_alive(Runtime)),
    ok = adk_planning_runtime:cancel(Runtime, Ref, correct_run),
    {ok, Result} = adk_planning_runtime:await(Runtime, Ref, 1000),
    ?assertEqual(<<"cancelled">>, maps:get(<<"status">>, Result)).

untrusted_module_name_does_not_create_atom_test() ->
    Before = erlang:system_info(atom_count),
    BadPlanner = #{module => <<"untrusted.planner.module">>,
                   target => ignored, config => #{}},
    ?assertMatch(
       {error, {invalid_planning_adapter, planner}},
       adk_planning_runtime:start(
         BadPlanner, executor(echo), goal(), context(), #{})),
    ?assertEqual(Before, erlang:system_info(atom_count)).

result_codec_rejects_unknown_fields_and_versions_test() ->
    {ok, Result} = run(normal, echo, #{}),
    ?assertMatch(
       {error, {unsupported_planning_result_version, 99}},
       adk_planning_runtime:decode_result(
         Result#{<<"result_schema_version">> => 99})),
    ?assertEqual(
       {error, invalid_planning_result},
       adk_planning_runtime:decode_result(
         Result#{<<"unexpected">> => true})),
    ?assertEqual(
       {error, invalid_planning_result},
       adk_planning_runtime:decode_result(
         maps:remove(<<"result">>, Result))),
    ?assertEqual(
       {error, invalid_planning_result},
       adk_planning_runtime:decode_result(
         Result#{<<"error">> => #{<<"kind">> => <<"impossible">>}})).

run(PlannerMode, ExecutorMode, ExtraOptions) ->
    adk_planning_runtime:run(
      planner(PlannerMode), executor(ExecutorMode), goal(), context(),
      maps:merge(#{result_metadata =>
                       #{build => <<"test">>,
                         client_secret => <<"hidden">>}},
                 ExtraOptions)).

planner(Mode) ->
    #{module => adk_planning_test_planner,
      target => self(), config => #{mode => Mode}}.

executor(Mode) ->
    #{module => adk_planning_test_executor,
      target => self(), config => #{mode => Mode}}.

goal() -> #{<<"task">> => <<"deterministic planning">>}.

context() ->
    #{<<"invocation_id">> => <<"planning-test">>,
      <<"authorization">> => <<"must-not-leak">>}.

assert_failed_kind(Result, Kind) ->
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Result)),
    ?assertEqual(Kind,
                 maps:get(<<"kind">>, maps:get(<<"error">>, Result))).

assert_observation_kind(Result, Kind) ->
    assert_failed_kind(Result, <<"step_failed">>),
    [Observation] = maps:get(<<"observations">>, Result),
    ?assertEqual(Kind,
                 maps:get(<<"kind">>, maps:get(<<"error">>, Observation))).
