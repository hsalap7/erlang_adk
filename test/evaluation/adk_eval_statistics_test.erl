-module(adk_eval_statistics_test).

-include_lib("eunit/include/eunit.hrl").

summary_and_confidence_test() ->
    {ok, Summary} = adk_eval_statistics:summary([0.0, 0.5, 1.0]),
    ?assertEqual(3, maps:get(<<"count">>, Summary)),
    ?assert(abs(maps:get(<<"mean">>, Summary) - 0.5) < 1.0e-12),
    {ok, Confidence} = adk_eval_statistics:confidence_interval(
                         [0.0, 0.5, 1.0],
                         #{confidence_level => 0.95}),
    ?assert(maps:get(<<"lower">>, Confidence) =< 0.5),
    ?assert(maps:get(<<"upper">>, Confidence) >= 0.5).

wilson_interval_test() ->
    {ok, Interval} = adk_eval_statistics:pass_rate_interval(
                       80, 100, #{confidence_level => 0.95}),
    ?assertEqual(0.8, maps:get(<<"rate">>, Interval)),
    ?assert(maps:get(<<"lower">>, Interval) < 0.8),
    ?assert(maps:get(<<"upper">>, Interval) > 0.8).

longitudinal_gate_test() ->
    {ok, Failed} = adk_eval_statistics:longitudinal_gate(
                     lists:duplicate(30, 1.0),
                     lists:duplicate(30, 0.5),
                     #{max_mean_drop => 0.1}),
    ?assertEqual(true, maps:get(<<"regression">>, Failed)),
    {ok, Passed} = adk_eval_statistics:longitudinal_gate(
                     lists:duplicate(30, 0.8),
                     lists:duplicate(30, 0.75),
                     #{max_mean_drop => 0.1}),
    ?assertEqual(true, maps:get(<<"passed">>, Passed)).

bounded_validation_test() ->
    ?assertEqual({error, {invalid_evaluation_sample, 1}},
                 adk_eval_statistics:summary([0.5, 2.0])),
    ?assertEqual({error, invalid_confidence_level},
                 adk_eval_statistics:confidence_interval(
                   [0.5], #{confidence_level => 0.975})),
    ?assertMatch({error, {unknown_evaluation_statistics_options, _}},
                 adk_eval_statistics:longitudinal_gate(
                   [0.5], [0.5], #{unknown => true})).
