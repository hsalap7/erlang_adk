-module(adk_eval_report_legacy_test).

-include_lib("eunit/include/eunit.hrl").

legacy_result_markdown_uses_only_v1_fields_test() ->
    Legacy = #{<<"result_schema_version">> => 1,
               <<"eval_set_id">> => <<"legacy-set">>,
               <<"eval_set_version">> => <<"1">>,
               <<"cases">> => [],
               <<"passed">> => true},
    {ok, Markdown} = adk_eval_set:report(Legacy, markdown),
    ?assertNotEqual(
       nomatch,
       binary:match(Markdown, <<"Evaluation report (legacy schema v1)">>)),
    ?assertNotEqual(nomatch, binary:match(Markdown, <<"legacy-set">>)),
    ?assertNotEqual(nomatch, binary:match(Markdown, <<"Status: **PASS**">>)).

malformed_nested_comparison_is_rejected_without_crashing_test() ->
    Base = #{<<"report_schema_version">> => 1,
             <<"report_type">> => <<"baseline_comparison">>,
             <<"eval_set_id">> => <<"set">>,
             <<"baseline_version">> => <<"1">>,
             <<"current_version">> => <<"2">>,
             <<"passed">> => true,
             <<"baseline_pass_rate">> => 1.0,
             <<"current_pass_rate">> => 1.0,
             <<"pass_rate_drop">> => 0.0,
             <<"max_pass_rate_drop">> => 0.0,
             <<"metric_diffs">> => [#{}],
             <<"case_diffs">> => []},
    ?assertEqual({error, invalid_eval_comparison},
                 adk_eval_set:report(Base, markdown)),
    ?assertEqual({error, invalid_eval_comparison},
                 adk_eval_set:report(Base, json)),
    BadCase = Base#{<<"metric_diffs">> => [],
                    <<"case_diffs">> => [#{}]},
    ?assertEqual({error, invalid_eval_comparison},
                 adk_eval_set:report(BadCase, markdown)).
