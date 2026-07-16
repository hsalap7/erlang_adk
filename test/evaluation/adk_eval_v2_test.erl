-module(adk_eval_v2_test).
-include_lib("eunit/include/eunit.hrl").

v1_set_and_result_remain_readable_test() ->
    {ok, V1} = adk_eval_set:validate(
                 #{schema_version => 1, id => <<"legacy">>,
                   version => <<"1">>,
                   cases => [#{id => <<"case">>, input => <<"x">>,
                               expected => <<"x">>}]}),
    ?assertEqual(1, maps:get(<<"schema_version">>, V1)),
    LegacyResult = #{<<"result_schema_version">> => 1,
                     <<"eval_set_id">> => <<"legacy">>,
                     <<"eval_set_version">> => <<"1">>,
                     <<"cases">> => [], <<"passed">> => true},
    ?assertEqual({ok, LegacyResult},
                 adk_eval_set:decode_result(LegacyResult)).

empty_criteria_requires_explicit_policy_test() ->
    {ok, Set} = one_turn_set(),
    Adapter = adapter(#{mode => echo_expected}),
    ?assertEqual({error, empty_eval_criteria},
                 adk_eval_set:run(Adapter, Set, [], #{})),
    {ok, Result} =
        adk_eval_set:run(
          Adapter, Set, [], #{empty_criteria => pass}),
    ?assertEqual(true, maps:get(<<"passed">>, Result)).

full_case_builtins_and_repeated_samples_test() ->
    {ok, Set} = trajectory_set(),
    Adapter = adapter(#{mode => echo_expected,
                        lifecycle_pid => self()}),
    Criteria = builtin_criteria(),
    Options = #{sample_count => 3, concurrency => 3,
                sample_concurrency => 2,
                capture_events => false,
                sample_pass_rate_threshold => 1.0},
    {ok, Result1} = adk_eval_set:run(
                      Adapter, Set, Criteria, Options),
    ?assertEqual(2, maps:get(<<"result_schema_version">>, Result1)),
    ?assertEqual(true, maps:get(<<"passed">>, Result1)),
    [Case1] = maps:get(<<"cases">>, Result1),
    ?assertEqual(3, maps:get(<<"sample_count">>, Case1)),
    ?assertEqual(3, maps:get(<<"successful_sample_count">>, Case1)),
    ?assertEqual(3, maps:get(<<"passed_sample_count">>, Case1)),
    ?assertEqual(1.0, maps:get(<<"sample_pass_rate">>, Case1)),
    Samples1 = maps:get(<<"samples">>, Case1),
    Ids1 = [maps:get(<<"sample_id">>, S) || S <- Samples1],
    ?assertEqual(3, length(lists:usort(Ids1))),
    ?assert(lists:all(
              fun(Sample) ->
                  [Response, Trajectory] =
                      maps:get(<<"criteria">>, Sample),
                  maps:get(<<"passed">>, Response)
                      andalso maps:get(<<"passed">>, Trajectory)
              end, Samples1)),
    receive_lifecycle(3, 3),
    {ok, Result2} = adk_eval_set:run(
                      adapter(#{mode => echo_expected}),
                      Set, Criteria, Options),
    [Case2] = maps:get(<<"cases">>, Result2),
    Ids2 = [maps:get(<<"sample_id">>, S)
            || S <- maps:get(<<"samples">>, Case2)],
    ?assertEqual(Ids1, Ids2).

custom_full_case_metric_and_error_accounting_test() ->
    {ok, Set} = trajectory_set(),
    Metric = #{id => <<"full-case">>,
               module => adk_eval_case_metric_probe,
               scope => 'case', threshold => 0.5,
               config => #{action => score, score => 0.75}},
    {ok, Passing} = adk_eval_set:run(
                      adapter(#{mode => echo_expected}), Set,
                      [Metric], #{}),
    [PassingCase] = maps:get(<<"cases">>, Passing),
    [PassingSample] = maps:get(<<"samples">>, PassingCase),
    [MetricResult] = maps:get(<<"criteria">>, PassingSample),
    ?assertEqual(0.75, maps:get(<<"score">>, MetricResult)),
    ?assertEqual(2, maps:get(
                      <<"trajectory_count">>,
                      maps:get(<<"metadata">>, MetricResult))),
    Broken = Metric#{config => #{action => error}},
    {ok, Failing} = adk_eval_set:run(
                      adapter(#{mode => echo_expected}), Set,
                      [Broken], #{}),
    ?assertEqual(false, maps:get(<<"passed">>, Failing)),
    [Summary] = maps:get(<<"metrics">>, Failing),
    ?assertEqual(1, maps:get(<<"error_count">>, Summary)),
    ?assertEqual(false, maps:get(<<"passed">>, Summary)).

strict_result_count_validation_test() ->
    {ok, Set} = one_turn_set(),
    {ok, Result} = adk_eval_set:run(
                     adapter(#{mode => echo_expected}), Set,
                     [#{id => <<"response">>,
                        criterion => exact_response}], #{}),
    Forged = Result#{<<"case_count">> => 99},
    ?assertEqual({error, invalid_eval_result},
                 adk_eval_set:decode_result(Forged)).

bounded_set_validation_test() ->
    Deep = lists:foldl(fun(_, Acc) -> [Acc] end, <<"x">>,
                       lists:seq(1, 70)),
    ?assertEqual(
       {error, {invalid_eval_set, eval_data_depth_exceeded}},
       adk_eval_set:validate(
         #{id => <<"deep">>, version => <<"1">>,
           cases => [#{id => <<"case">>, input => Deep,
                       expected => <<"x">>}]})).

baseline_and_stable_reports_test() ->
    {ok, Set} = one_turn_set(),
    Criteria = [#{id => <<"response">>,
                  criterion => exact_response}],
    {ok, Baseline} = adk_eval_set:run(
                       adapter(#{mode => echo_expected}),
                       Set, Criteria, #{}),
    {ok, Current} = adk_eval_set:run(
                      adapter(#{mode => stateful}),
                      Set, Criteria, #{}),
    {ok, Comparison} =
        adk_eval_set:compare(Baseline, Current, #{}),
    ?assertEqual(false, maps:get(<<"passed">>, Comparison)),
    {ok, Json1} = adk_eval_set:report(Baseline, json),
    {ok, Json2} = adk_eval_set:report(Baseline, json),
    ?assertEqual(Json1, Json2),
    ?assertMatch(#{<<"result_schema_version">> := 2},
                 jsx:decode(Json1, [return_maps])),
    {ok, Markdown} = adk_eval_set:report(Comparison, markdown),
    ?assertNotEqual(nomatch,
                    binary:match(Markdown,
                                 <<"Evaluation baseline comparison">>)).

owner_death_stops_case_worker_test() ->
    TestPid = self(),
    Caller = spawn(
               fun() ->
                   {ok, Set} = one_turn_set(),
                   _ = adk_eval_set:run(
                         adapter(#{mode => echo_expected,
                                   delay_ms => 5000,
                                   lifecycle_pid => TestPid}),
                         Set,
                         [#{id => <<"response">>,
                            criterion => exact_response}],
                         #{timeout_ms => 10000,
                           case_timeout_ms => 9000})
               end),
    Worker = receive
        {eval_adapter_init, Pid, <<"case">>, _SampleId} -> Pid
    after 2000 ->
        erlang:error(eval_worker_not_started)
    end,
    Monitor = erlang:monitor(process, Worker),
    exit(Caller, kill),
    receive
        {'DOWN', Monitor, process, Worker, _} -> ok
    after 2000 ->
        erlang:error(eval_worker_orphaned)
    end.

hard_concurrency_and_fanout_limits_test() ->
    {ok, Set} = one_turn_set(),
    Criterion = [#{id => <<"response">>, criterion => exact_response}],
    ?assertEqual(
       {error, invalid_eval_options},
       adk_eval_set:run(
         adapter(#{mode => echo_expected}), Set, Criterion,
         #{concurrency => 257})),
    ?assertEqual(
       {error, invalid_eval_options},
       adk_eval_set:run(
         adapter(#{mode => echo_expected}), Set, Criterion,
         #{sample_concurrency => 257})),
    ?assertEqual(
       {error, invalid_eval_options},
       adk_eval_set:run(
         adapter(#{mode => echo_expected}), Set, Criterion,
         #{timeout_ms => 3600001})),
    ?assertEqual(
       {error, invalid_eval_options},
       adk_eval_set:run(
         adapter(#{mode => echo_expected}), Set, Criterion,
         #{max_heap_words => 20000001})),
    Cases = [#{id => <<"case-", (integer_to_binary(N))/binary>>,
               input => <<"x">>, expected => <<"x">>}
             || N <- lists:seq(1, 101)],
    {ok, LargeSet} = adk_eval_set:new(
                       <<"fanout">>, <<"1">>, Cases),
    ?assertEqual(
       {error, {eval_sample_limit_exceeded, 10100, 10000}},
       adk_eval_set:run(
         adapter(#{mode => echo_expected}), LargeSet, Criterion,
         #{sample_count => 100})).

incremental_report_budget_stops_new_samples_test() ->
    {ok, Set} = one_turn_set(),
    Criterion = [#{id => <<"response">>, criterion => exact_response}],
    ?assertEqual(
       {error, eval_report_budget_exceeded},
       adk_eval_set:run(
         adapter(#{mode => echo_expected, lifecycle_pid => self()}),
         Set, Criterion,
         #{sample_count => 10, concurrency => 1,
           sample_concurrency => 1, capture_events => false,
           max_report_bytes => 12000})),
    receive
        {eval_adapter_init, _Pid, <<"case">>, _SampleId} -> ok
    after 1000 -> erlang:error(first_budgeted_sample_not_started)
    end,
    Additional = drain_sample_starts(0),
    ?assert(Additional < 9).

sample_heap_limit_isolated_as_error_test() ->
    {ok, Set} = one_turn_set(),
    {ok, Result} = adk_eval_set:run(
                     adapter(#{mode => heap}), Set,
                     [#{id => <<"response">>,
                        criterion => exact_response}],
                     #{max_heap_words => 1000}),
    [Case] = maps:get(<<"cases">>, Result),
    [Sample] = maps:get(<<"samples">>, Case),
    ?assertEqual(<<"error">>, maps:get(<<"status">>, Sample)),
    ?assertEqual(false, maps:get(<<"passed">>, Result)).

one_turn_set() ->
    adk_eval_set:new(
      <<"single">>, <<"1">>,
      [#{id => <<"case">>, input => <<"actual">>,
         expected => <<"expected">>}]).

trajectory_set() ->
    adk_eval_set:validate(
      #{schema_version => 2,
        id => <<"trajectory">>, version => <<"1">>,
        cases => [
          #{id => <<"case">>,
            expected_trajectory =>
                [#{kind => tool_call, tool => <<"memory">>,
                   args => #{value => <<"hello">>}}],
            turns => [
              #{id => <<"turn">>, input => <<"hello">>,
                expected => <<"hello">>}
            ]}
        ]}).

builtin_criteria() ->
    [#{id => <<"response">>, criterion => exact_response,
       threshold => 1.0},
     #{id => <<"trajectory">>, criterion => trajectory_exact,
       threshold => 1.0, config => #{args => subset}}].

adapter(Config) ->
    #{module => adk_eval_set_test_adapter,
      target => ignored, config => Config}.

receive_lifecycle(0, 0) -> ok;
receive_lifecycle(Inits, Terminates) ->
    receive
        {eval_adapter_init, _Pid, <<"case">>, _SampleId} ->
            receive_lifecycle(Inits - 1, Terminates);
        {eval_adapter_terminate, _Pid, _State} ->
            receive_lifecycle(Inits, Terminates - 1)
    after 2000 ->
        erlang:error({missing_lifecycle_events, Inits, Terminates})
    end.

drain_sample_starts(Count) ->
    receive
        {eval_adapter_init, _Pid, <<"case">>, _SampleId} ->
            drain_sample_starts(Count + 1)
    after 100 -> Count
    end.
