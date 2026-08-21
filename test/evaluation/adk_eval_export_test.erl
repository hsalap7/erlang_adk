-module(adk_eval_export_test).

-include_lib("eunit/include/eunit.hrl").

junit_sarif_and_annotations_test() ->
    Result = result_fixture(),
    {ok, Xml} = adk_eval_export:junit(Result, #{suite_name => <<"safe&suite">>}),
    ?assertMatch({_, _}, binary:match(Xml, <<"safe&amp;suite">>)),
    ?assertMatch({_, _}, binary:match(Xml, <<"fail&lt;case">>)),
    ?assertEqual(nomatch, binary:match(Xml, <<"secret-output">>)),
    {ok, Sarif} = adk_eval_export:sarif(Result, #{}),
    Decoded = jsx:decode(Sarif, [return_maps]),
    ?assertEqual(<<"2.1.0">>, maps:get(<<"version">>, Decoded)),
    ?assertEqual(nomatch, binary:match(Sarif, <<"secret-output">>)),
    {ok, [Annotation]} = adk_eval_export:annotations(Result, #{}),
    ?assertEqual(<<"fail<case">>, maps:get(<<"case_id">>, Annotation)).

export_bounds_test() ->
    ?assertEqual({error, eval_export_byte_limit_exceeded},
                 adk_eval_export:junit(result_fixture(), #{max_bytes => 10})),
    ?assertMatch({error, {unknown_eval_export_options, _}},
                 adk_eval_export:sarif(result_fixture(), #{unknown => true})).

result_fixture() ->
    #{<<"result_schema_version">> => 2,
      <<"eval_set_schema_version">> => 2,
      <<"eval_set_id">> => <<"suite">>,
      <<"eval_set_version">> => <<"v1">>,
      <<"passed">> => false,
      <<"pass_rate">> => 0.5,
      <<"pass_rate_threshold">> => 1.0,
      <<"case_count">> => 2,
      <<"passed_case_count">> => 1,
      <<"error_case_count">> => 0,
      <<"partial_case_count">> => 0,
      <<"sample_count">> => 1,
      <<"duration_ms">> => 50,
      <<"metrics">> => [],
      <<"cases">> => [case_fixture(<<"pass">>, true, <<"passed">>),
                       case_fixture(<<"fail<case">>, false, <<"failed">>)],
      <<"metadata">> => #{<<"private">> => <<"secret-output">>}}.

case_fixture(Id, Passed, Status) ->
    #{<<"case_id">> => Id,
      <<"status">> => Status,
      <<"passed">> => Passed,
      <<"duration_ms">> => 25,
      <<"turns">> => [],
      <<"trajectory">> => [],
      <<"criteria">> => [],
      <<"sample_count">> => 1,
      <<"successful_sample_count">> => 1,
      <<"passed_sample_count">> => case Passed of true -> 1; false -> 0 end,
      <<"error_sample_count">> => 0,
      <<"sample_pass_rate">> => case Passed of true -> 1.0; false -> 0.0 end,
      <<"sample_pass_rate_threshold">> => 1.0,
      <<"min_successful_samples">> => 1,
      <<"sample_statistics">> =>
          #{<<"count">> => 1,
            <<"mean">> => case Passed of true -> 1.0; false -> 0.0 end,
            <<"minimum">> => case Passed of true -> 1.0; false -> 0.0 end,
            <<"maximum">> => case Passed of true -> 1.0; false -> 0.0 end,
            <<"standard_deviation">> => 0.0},
      <<"samples">> => [#{<<"sample_id">> => <<Id/binary, "-sample-1">>,
                           <<"sample_index">> => 0,
                           <<"case_id">> => Id,
                           <<"status">> => Status,
                           <<"passed">> => Passed,
                           <<"duration_ms">> => 25,
                           <<"turns">> => [],
                           <<"trajectory">> => [],
                           <<"criteria">> => [],
                           <<"metadata">> => #{}}],
      <<"metadata">> => #{}}.
