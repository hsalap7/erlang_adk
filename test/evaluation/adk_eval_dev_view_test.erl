-module(adk_eval_dev_view_test).

-include_lib("eunit/include/eunit.hrl").

dev_view_test_() ->
    {setup,
     fun fixtures/0,
     fun(_Fixtures) -> ok end,
     fun({Baseline, Failing, Tolerated}) ->
         [?_test(classify_and_render(Baseline)),
          ?_test(strict_comparison(Baseline, Failing, Tolerated)),
          ?_test(discriminator_errors(Baseline)),
          ?_test(json_and_option_errors(Baseline)),
          ?_test(comparison_errors(Baseline, Failing)),
          ?_test(size_limits(Baseline))]
     end}.

fixtures() ->
    {ok, Set} = adk_eval_set:new(
                  <<"dev-view">>, <<"1">>,
                  [#{id => <<"case">>, input => <<"actual">>,
                     expected => <<"expected">>}]),
    Criteria = [#{id => <<"response">>,
                  criterion => exact_response}],
    {ok, Baseline} = adk_eval_set:run(
                       adapter(echo_expected), Set, Criteria, #{}),
    {ok, Failing} = adk_eval_set:run(
                      adapter(stateful), Set, Criteria, #{}),
    [Metric] = maps:get(<<"metrics">>, Baseline),
    ToleratedMetric = Metric#{<<"average_score">> => 0.9,
                              <<"passed">> => false},
    Tolerated = Baseline#{<<"metrics">> => [ToleratedMetric]},
    {ok, Tolerated} = adk_eval_set:decode_result(Tolerated),
    {Baseline, Failing, Tolerated}.

classify_and_render(Baseline) ->
    ?assertEqual({ok, eval_result, Baseline},
                 adk_eval_dev_view:classify(Baseline)),
    {ok, Json1} = adk_eval_dev_view:render(
                    Baseline, <<"json">>, #{}),
    {ok, Json2} = adk_eval_dev_view:render(
                    Baseline, <<"json">>, #{}),
    ?assertEqual(Json1, Json2),
    ?assertEqual(Baseline, jsx:decode(Json1, [return_maps])),
    {ok, Markdown} = adk_eval_dev_view:render(
                       Baseline, <<"markdown">>, #{}),
    ?assertNotEqual(
       nomatch, binary:match(Markdown, <<"# Evaluation report">>)).

strict_comparison(Baseline, Failing, Tolerated) ->
    {ok, Regression} = adk_eval_dev_view:compare(
                         Baseline, Failing, #{}),
    ?assertEqual(false, maps:get(<<"passed">>, Regression)),
    ?assertMatch({ok, baseline_comparison, Regression},
                 adk_eval_dev_view:classify(Regression)),
    {ok, _} = adk_eval_dev_view:render(
                Regression, <<"markdown">>, #{}),

    Options = #{<<"max_pass_rate_drop">> => 0.0,
                <<"metric_tolerances">> =>
                    #{<<"response">> => 0.2}},
    {ok, Accepted} = adk_eval_dev_view:compare(
                       Baseline, Tolerated, Options),
    ?assertEqual(true, maps:get(<<"passed">>, Accepted)),
    [MetricDiff] = maps:get(<<"metric_diffs">>, Accepted),
    ?assertEqual(0.2, maps:get(<<"tolerance">>, MetricDiff)).

discriminator_errors(Baseline) ->
    Ambiguous = Baseline#{
        <<"report_schema_version">> => 1,
        <<"report_type">> => <<"baseline_comparison">>
    },
    ?assertEqual(
       tagged(ambiguous_report_kind),
       adk_eval_dev_view:classify(Ambiguous)),
    ?assertEqual(
       tagged(unknown_report_kind),
       adk_eval_dev_view:classify(#{<<"module">> => <<"os">>})),
    ?assertEqual(
       tagged(unsupported_report_type),
       adk_eval_dev_view:classify(
         #{<<"report_schema_version">> => 1,
           <<"report_type">> => <<"other">>})),
    ?assertEqual(
       tagged(invalid_baseline_comparison),
       adk_eval_dev_view:classify(
         #{<<"report_schema_version">> => 1})).

json_and_option_errors(Baseline) ->
    ?assertEqual(
       tagged(invalid_json_map),
       adk_eval_dev_view:classify(#{result_schema_version => 2})),
    ?assertEqual(
       tagged(invalid_format),
       adk_eval_dev_view:render(Baseline, json, #{})),
    ?assertEqual(
       tagged(invalid_options),
       adk_eval_dev_view:render(
         Baseline, <<"json">>, #{max_output_bytes => 1000})),
    ?assertEqual(
       tagged(invalid_options),
       adk_eval_dev_view:render(
         Baseline, <<"json">>, #{<<"unknown">> => true})),
    ?assertEqual(
       tagged(invalid_output_limit),
       adk_eval_dev_view:render(
         Baseline, <<"json">>, #{<<"max_output_bytes">> => 0})).

comparison_errors(Baseline, Failing) ->
    ?assertEqual(
       tagged(invalid_comparison_options),
       adk_eval_dev_view:compare(
         Baseline, Failing,
         #{<<"max_pass_rate_drop">> => 1.1})),
    ?assertEqual(
       tagged(invalid_comparison_options),
       adk_eval_dev_view:compare(
         Baseline, Failing,
         #{<<"metric_tolerances">> => #{<<"response">> => -0.1}})),
    Other = Failing#{<<"eval_set_id">> => <<"other-set">>},
    {ok, Other} = adk_eval_set:decode_result(Other),
    ?assertEqual(tagged(eval_set_mismatch),
                 adk_eval_dev_view:compare(Baseline, Other, #{})),
    {ok, Comparison} = adk_eval_dev_view:compare(
                         Baseline, Failing, #{}),
    Forged = Comparison#{<<"passed">> => true},
    ?assertEqual(tagged(invalid_baseline_comparison),
                 adk_eval_dev_view:classify(Forged)),
    ?assertEqual(tagged(baseline_must_be_eval_result),
                 adk_eval_dev_view:compare(Comparison, Failing, #{})).

size_limits(Baseline) ->
    ?assertEqual(
       tagged(output_limit_exceeded),
       adk_eval_dev_view:render(
         Baseline, <<"json">>, #{<<"max_output_bytes">> => 1})),
    Oversized = binary:copy(<<"x">>, 1048577),
    ?assertEqual(tagged(input_limit_exceeded),
                 adk_eval_dev_view:classify(#{<<"value">> => Oversized})),
    ?assertEqual(
       tagged(output_limit_exceeded),
       adk_eval_dev_view:compare(
         Baseline, Baseline, #{<<"max_output_bytes">> => 1})).

adapter(Mode) ->
    #{module => adk_eval_set_test_adapter,
      target => ignored, config => #{mode => Mode}}.

tagged(Code) -> {error, {eval_dev_view, Code}}.
