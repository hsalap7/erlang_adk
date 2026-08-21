-module(adk_eval_ensemble_test).

-include_lib("eunit/include/eunit.hrl").

weighted_ensemble_and_review_test() ->
    Votes = [#{id => <<"judge-a">>, score => 0.9, weight => 2.0},
             #{id => <<"judge-b">>, score => 0.2, confidence => 0.5}],
    {ok, Result} = adk_eval_ensemble:aggregate(
                     Votes, #{threshold => 0.5,
                              review_disagreement_threshold => 0.6}),
    ?assertEqual(true, maps:get(<<"passed">>, Result)),
    ?assertEqual(true, maps:get(<<"needs_human_review">>, Result)),
    ?assert(maps:get(<<"score">>, Result) > 0.7).

majority_and_minimum_test() ->
    {ok, Result} = adk_eval_ensemble:aggregate(
      [#{id => <<"a">>, score => 1}, #{id => <<"b">>, score => 0}],
      #{strategy => majority, threshold => 0.5, min_judges => 3,
        review_disagreement_threshold => 1.0}),
    ?assertEqual(false, maps:get(<<"passed">>, Result)),
    ?assertEqual(true, maps:get(<<"needs_human_review">>, Result)).

calibration_is_deterministic_test() ->
    Examples = [#{score => 0.1, label => false},
                #{score => 0.4, label => false},
                #{score => 0.7, label => true},
                #{score => 0.9, label => true}],
    {ok, Calibration} = adk_eval_ensemble:calibrate_threshold(Examples, #{}),
    ?assertEqual(0.5, maps:get(<<"threshold">>, Calibration)),
    {ok, Applied} = adk_eval_ensemble:apply_calibration(0.8, Calibration),
    ?assertEqual(true, maps:get(<<"passed">>, Applied)).

strict_bounds_and_duplicates_test() ->
    ?assertMatch({error, {duplicate_eval_judge_id, _}},
                 adk_eval_ensemble:aggregate(
                   [#{id => <<"a">>, score => 1},
                    #{id => <<"a">>, score => 0}], #{})),
    ?assertMatch({error, {unknown_eval_ensemble_options, _}},
                 adk_eval_ensemble:aggregate(
                   [#{id => <<"a">>, score => 1}], #{unsafe => true})),
    ?assertMatch({error, {invalid_eval_calibration_list, _}},
                 adk_eval_ensemble:calibrate_threshold(
                   [#{score => 1, label => true} | bad], #{})).
