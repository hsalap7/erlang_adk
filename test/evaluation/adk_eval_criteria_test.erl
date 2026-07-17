-module(adk_eval_criteria_test).
-include_lib("eunit/include/eunit.hrl").

exact_response_and_normalization_test() ->
    Input = eval_input(
              [#{<<"expected">> => <<"ERLANG">>,
                 <<"actual">> => <<"ERLANG">>}], []),
    ?assertMatch(
       {ok, 1.0, _},
       adk_eval_criteria:score_case(
         Input, #{criterion => exact_response})),
    Trimmed = eval_input(
                [#{<<"expected">> => <<" Erlang ">>,
                   <<"actual">> => <<"Erlang">>}], []),
    ?assertMatch(
       {ok, 1.0, _},
       adk_eval_criteria:score_case(
         Trimmed,
         #{criterion => exact_response, normalization => trim})).

trajectory_policy_matrix_test() ->
    A = step(<<"a">>, #{<<"x">> => 1}),
    B = step(<<"b">>, #{<<"x">> => 2}),
    Extra = step(<<"extra">>, #{}),
    ?assertEqual(1.0, trajectory_score(exact, [A, B], [A, B], exact)),
    ?assertEqual(0.0,
                 trajectory_score(exact, [A, B], [A, Extra, B], exact)),
    ?assertEqual(1.0,
                 trajectory_score(in_order, [A, B],
                                  [Extra, A, Extra, B], exact)),
    ?assertEqual(1.0,
                 trajectory_score(any_order, [A, B], [B, A], exact)),
    ?assertEqual(0.0,
                 trajectory_score(any_order, [A], [A, B], exact)),
    ?assertEqual(1.0,
                 trajectory_score(subset, [B], [A, B, Extra], exact)).

trajectory_argument_policies_test() ->
    Expected = step(<<"weather">>, #{<<"city">> => <<"Pune">>}),
    Actual = step(
               <<"weather">>,
               #{<<"city">> => <<"Pune">>, <<"units">> => <<"metric">>}),
    ?assertEqual(0.0,
                 trajectory_score(exact, [Expected], [Actual], exact)),
    ?assertEqual(1.0,
                 trajectory_score(exact, [Expected], [Actual], subset)),
    Different = step(<<"weather">>, #{<<"city">> => <<"Delhi">>}),
    ?assertEqual(1.0,
                 trajectory_score(exact, [Expected], [Different], ignored)).

duplicate_steps_are_multiset_matched_test() ->
    A = step(<<"a">>, #{}),
    ?assertEqual(0.0,
                 trajectory_score(subset, [A, A], [A], ignored)),
    ?assertEqual(1.0,
                 trajectory_score(any_order, [A, A], [A, A], ignored)).

missing_expectation_is_not_evaluated_test() ->
    ?assertMatch(
       {not_evaluated, _},
       adk_eval_criteria:score_case(
         eval_input([], []), #{criterion => exact_response})),
    ?assertMatch(
       {not_evaluated, _},
       adk_eval_criteria:score_case(
         eval_input([], []), #{criterion => trajectory_exact})).

trajectory_score(Match, Expected, Actual, Args) ->
    Input = #{<<"eval_case">> =>
                  #{<<"expected_trajectory">> => Expected},
              <<"turns">> => [],
              <<"trajectory">> => Actual},
    {ok, Score, _} =
        adk_eval_criteria:score_case(
          Input, #{criterion => tool_trajectory,
                   match => Match, args => Args}),
    Score.

eval_input(Turns, Trajectory) ->
    #{<<"eval_case">> => #{},
      <<"turns">> => Turns,
      <<"trajectory">> => Trajectory}.

step(Name, Args) ->
    #{<<"kind">> => <<"tool_call">>,
      <<"tool">> => Name,
      <<"args">> => Args}.
