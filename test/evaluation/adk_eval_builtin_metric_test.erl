-module(adk_eval_builtin_metric_test).

-include_lib("eunit/include/eunit.hrl").

latency_metric_test() ->
    Config = #{metric => latency, target_ms => 100, hard_limit_ms => 300},
    ?assertEqual(ok, adk_eval_builtin_metric:validate_config(Config)),
    {ok, 1.0, _} = adk_eval_builtin_metric:score(
                     null, null,
                     #{<<"adapter_metadata">> =>
                           #{<<"runtime_latency_ms">> => 80}}, Config),
    {ok, Score, _} = adk_eval_builtin_metric:score(
                       null, null,
                       #{<<"adapter_metadata">> =>
                             #{<<"runtime_latency_ms">> => 200}}, Config),
    ?assert(abs(Score - 0.5) < 1.0e-12).

cost_and_safety_metric_test() ->
    Cost = #{metric => cost,
             input_microunits_per_million => 1000000,
             output_microunits_per_million => 2000000,
             max_cost_microunits => 100},
    {ok, 1.0, CostMeta} = adk_eval_builtin_metric:score(
                            null, null,
                            #{adapter_metadata =>
                                  #{usage => #{input_tokens => 10,
                                               output_tokens => 20}}}, Cost),
    ?assertEqual(50.0, maps:get(<<"cost_microunits">>, CostMeta)),
    Safety = #{metric => safety, max_violations => 0},
    {ok, +0.0, _} = adk_eval_builtin_metric:score(
                     null, null,
                     #{adapter_metadata => #{safety_violations => [a]}},
                     Safety).

semantic_metric_test() ->
    Config = #{metric => semantic_quality, algorithm => token_f1},
    {ok, 1.0, _} = adk_eval_builtin_metric:score(
                     <<"Hello world">>, <<"hello WORLD">>, #{}, Config),
    {ok, Score, _} = adk_eval_builtin_metric:score(
                       <<"alpha beta">>, <<"alpha gamma">>, #{}, Config),
    ?assert(abs(Score - 0.5) < 1.0e-12).

case_metric_aggregates_runtime_metadata_test() ->
    Input = #{<<"turns">> => [
                 #{<<"adapter_metadata">> =>
                       #{<<"runtime_latency_ms">> => 50}},
                 #{<<"adapter_metadata">> =>
                       #{<<"runtime_latency_ms">> => 150}}]},
    {ok, Score, Meta} = adk_eval_builtin_metric:score_case(
                          Input,
                          #{metric => latency, target_ms => 100,
                            hard_limit_ms => 200}),
    ?assert(abs(Score - 0.75) < 1.0e-12),
    ?assertEqual(2, maps:get(<<"sample_count">>, Meta)).

metric_config_fails_closed_test() ->
    ?assertEqual({error, invalid_latency_metric_config},
                 adk_eval_builtin_metric:validate_config(
                   #{metric => latency, target_ms => 100,
                     hard_limit_ms => 50})),
    ?assertEqual({error, invalid_semantic_metric_config},
                 adk_eval_builtin_metric:validate_config(
                   #{metric => semantic_quality, algorithm => llm})).
