-module(adk_eval_review_test).

-include_lib("eunit/include/eunit.hrl").

quorum_and_terminal_immutability_test() ->
    {ok, Review0} = adk_eval_review:new(
                      <<"review-1">>, #{<<"case_id">> => <<"case-a">>},
                      #{required_reviewers => 2}),
    {ok, Review1} = adk_eval_review:record_decision(
                      Review0, 0, <<"alice">>, approve, #{}),
    ?assertEqual(<<"pending">>, maps:get(<<"phase">>, Review1)),
    {ok, Review2} = adk_eval_review:record_decision(
                      Review1, 1, <<"bob">>, approve, #{}),
    ?assertEqual(<<"approved">>, maps:get(<<"phase">>, Review2)),
    ?assertEqual({error, eval_review_terminal},
                 adk_eval_review:record_decision(
                   Review2, 2, <<"carol">>, reject, #{})).

reject_and_stale_revision_test() ->
    {ok, Review0} = adk_eval_review:new(<<"r">>, #{}, #{}),
    ?assertEqual({error, stale_eval_review_revision},
                 adk_eval_review:record_decision(
                   Review0, 1, <<"alice">>, approve, #{})),
    {ok, Review1} = adk_eval_review:record_decision(
                      Review0, 0, <<"alice">>, reject, #{}),
    ?assertEqual(<<"rejected">>, maps:get(<<"phase">>, Review1)).

expiry_is_revision_guarded_test() ->
    {ok, Review0} = adk_eval_review:new(
                      <<"r">>, #{}, #{expires_at => 10}),
    ?assertEqual({error, eval_review_not_expired},
                 adk_eval_review:expire(Review0, 0, 9)),
    {ok, Review1} = adk_eval_review:expire(Review0, 0, 10),
    ?assertEqual(<<"expired">>, maps:get(<<"phase">>, Review1)).

opaque_terms_are_rejected_test() ->
    ?assertEqual({error, invalid_eval_review},
                 adk_eval_review:new(<<"r">>, #{<<"pid">> => self()}, #{})).
