%% @doc Deterministic judge ensembles and threshold calibration.
%%
%% This module aggregates only already-bounded judge scores. It deliberately
%% contains no provider lookup or model invocation, making an ensemble result
%% reproducible from a persisted set of votes.
-module(adk_eval_ensemble).

-export([aggregate/2, calibrate_threshold/2, apply_calibration/2]).

-define(MAX_JUDGES, 128).
-define(MAX_CALIBRATION_EXAMPLES, 100000).

-spec aggregate([map()], map()) -> {ok, map()} | {error, term()}.
aggregate(Votes0, Options0) when is_map(Options0) ->
    case {normalize_options(Options0), normalize_votes(Votes0)} of
        {{ok, Options}, {ok, Votes}} -> aggregate_votes(Votes, Options);
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
aggregate(_Votes, _Options) ->
    {error, invalid_eval_ensemble_options}.

-spec calibrate_threshold([map()], map()) -> {ok, map()} | {error, term()}.
calibrate_threshold(Examples0, Options) when is_map(Options) ->
    Allowed = [default_threshold],
    Unknown = maps:keys(maps:without(Allowed, Options)),
    Default = maps:get(default_threshold, Options, 0.5),
    case {Unknown, fraction(Default), normalize_examples(Examples0)} of
        {[], true, {ok, [_ | _] = Examples}} ->
            Candidates = candidate_thresholds(Examples, Default),
            {Threshold, Correct} = best_threshold(Candidates, Examples),
            Total = length(Examples),
            {ok, #{<<"calibration_type">> => <<"classification_threshold">>,
                   <<"threshold">> => Threshold,
                   <<"example_count">> => Total,
                   <<"correct_count">> => Correct,
                   <<"accuracy">> => Correct / Total}};
        {[_ | _], _, _} ->
            {error, {unknown_eval_calibration_options, lists:sort(Unknown)}};
        {_, false, _} -> {error, invalid_eval_calibration_threshold};
        {_, _, {ok, []}} -> {error, empty_eval_calibration_examples};
        {_, _, {error, _} = Error} -> Error
    end;
calibrate_threshold(_Examples, _Options) ->
    {error, invalid_eval_calibration_options}.

-spec apply_calibration(number(), map()) ->
    {ok, map()} | {error, term()}.
apply_calibration(Score, #{<<"calibration_type">> :=
                               <<"classification_threshold">>,
                           <<"threshold">> := Threshold}) ->
    case {fraction(Score), fraction(Threshold)} of
        {true, true} ->
            Value = float(Score),
            {ok, #{<<"score">> => Value,
                   <<"threshold">> => float(Threshold),
                   <<"passed">> => Value >= Threshold}};
        _ -> {error, invalid_eval_calibration}
    end;
apply_calibration(_Score, _Calibration) ->
    {error, invalid_eval_calibration}.

normalize_options(Options) ->
    Allowed = [strategy, threshold, min_judges,
               review_disagreement_threshold],
    Unknown = maps:keys(maps:without(Allowed, Options)),
    Strategy = maps:get(strategy, Options, weighted_mean),
    Threshold = maps:get(threshold, Options, 0.5),
    Minimum = maps:get(min_judges, Options, 1),
    Review = maps:get(review_disagreement_threshold, Options, 0.5),
    case {Unknown, lists:member(Strategy, [weighted_mean, majority]),
          fraction(Threshold), is_integer(Minimum), Minimum > 0,
          Minimum =< ?MAX_JUDGES, fraction(Review)} of
        {[], true, true, true, true, true, true} ->
            {ok, #{strategy => Strategy, threshold => float(Threshold),
                   min_judges => Minimum,
                   review_disagreement_threshold => float(Review)}};
        {[_ | _], _, _, _, _, _, _} ->
            {error, {unknown_eval_ensemble_options, lists:sort(Unknown)}};
        _ -> {error, invalid_eval_ensemble_options}
    end.

normalize_votes(Votes) -> normalize_votes(Votes, 0, [], #{}).

normalize_votes([], _Count, Acc, _Ids) -> {ok, lists:reverse(Acc)};
normalize_votes([Vote | Rest], Count, Acc, Ids)
  when Count < ?MAX_JUDGES, is_map(Vote) ->
    Id = maps:get(id, Vote, undefined),
    Score = maps:get(score, Vote, undefined),
    Weight = maps:get(weight, Vote, 1.0),
    Confidence = maps:get(confidence, Vote, 1.0),
    Unknown = maps:keys(maps:without([id, score, weight, confidence], Vote)),
    case {Unknown, text_id(Id), maps:is_key(Id, Ids), fraction(Score),
          positive_weight(Weight), fraction(Confidence)} of
        {[], true, false, true, true, true} ->
            Safe = #{id => Id, score => float(Score),
                     weight => float(Weight), confidence => float(Confidence)},
            normalize_votes(Rest, Count + 1, [Safe | Acc], Ids#{Id => true});
        {[_ | _], _, _, _, _, _} ->
            {error, {unknown_eval_judge_vote_fields, Count,
                     lists:sort(Unknown)}};
        {_, false, _, _, _, _} -> {error, {invalid_eval_judge_id, Count}};
        {_, _, true, _, _, _} -> {error, {duplicate_eval_judge_id, Id}};
        _ -> {error, {invalid_eval_judge_vote, Count}}
    end;
normalize_votes([_ | _], ?MAX_JUDGES, _Acc, _Ids) ->
    {error, eval_judge_limit_exceeded};
normalize_votes([_ | _], Count, _Acc, _Ids) ->
    {error, {invalid_eval_judge_vote, Count}};
normalize_votes(_Improper, Count, _Acc, _Ids) ->
    {error, {invalid_eval_judge_vote_list, Count}}.

aggregate_votes([], _Options) -> {error, empty_eval_judge_ensemble};
aggregate_votes(Votes, Options) ->
    Threshold = maps:get(threshold, Options),
    Scores = [maps:get(score, Vote) || Vote <- Votes],
    Final = case maps:get(strategy, Options) of
        weighted_mean -> weighted_score(Votes);
        majority ->
            length([ok || Score <- Scores, Score >= Threshold]) /
                length(Scores)
    end,
    Disagreement = lists:max(Scores) - lists:min(Scores),
    Enough = length(Votes) >= maps:get(min_judges, Options),
    Review = (not Enough) orelse
             Disagreement >= maps:get(review_disagreement_threshold, Options),
    PublicVotes = [#{<<"judge_id">> => maps:get(id, Vote),
                     <<"score">> => maps:get(score, Vote),
                     <<"weight">> => maps:get(weight, Vote),
                     <<"confidence">> => maps:get(confidence, Vote)}
                   || Vote <- Votes],
    {ok, #{<<"ensemble_type">> => atom_to_binary(
                                      maps:get(strategy, Options)),
           <<"score">> => Final,
           <<"threshold">> => Threshold,
           <<"passed">> => Enough andalso Final >= Threshold,
           <<"judge_count">> => length(Votes),
           <<"minimum_judges">> => maps:get(min_judges, Options),
           <<"disagreement">> => Disagreement,
           <<"needs_human_review">> => Review,
           <<"votes">> => PublicVotes}}.

weighted_score(Votes) ->
    Pairs = [{maps:get(score, Vote),
              maps:get(weight, Vote) * maps:get(confidence, Vote)}
             || Vote <- Votes],
    Weight = lists:sum([W || {_Score, W} <- Pairs]),
    case Weight > 0.0 of
        true -> lists:sum([Score * W || {Score, W} <- Pairs]) / Weight;
        false -> 0.0
    end.

normalize_examples(Examples) -> normalize_examples(Examples, 0, []).

normalize_examples([], _Count, Acc) -> {ok, lists:reverse(Acc)};
normalize_examples([#{score := Score, label := Label} = Example | Rest],
                   Count, Acc)
  when Count < ?MAX_CALIBRATION_EXAMPLES ->
    Unknown = maps:keys(maps:without([score, label], Example)),
    case {Unknown, fraction(Score), is_boolean(Label)} of
        {[], true, true} ->
            normalize_examples(Rest, Count + 1,
                               [{float(Score), Label} | Acc]);
        {[_ | _], _, _} ->
            {error, {unknown_eval_calibration_fields, Count,
                     lists:sort(Unknown)}};
        _ -> {error, {invalid_eval_calibration_example, Count}}
    end;
normalize_examples([_ | _], ?MAX_CALIBRATION_EXAMPLES, _Acc) ->
    {error, eval_calibration_example_limit_exceeded};
normalize_examples([_ | _], Count, _Acc) ->
    {error, {invalid_eval_calibration_example, Count}};
normalize_examples(_Improper, Count, _Acc) ->
    {error, {invalid_eval_calibration_list, Count}}.

candidate_thresholds(Examples, Default) ->
    lists:usort([0.0, 1.0, float(Default) |
                 [Score || {Score, _} <- Examples]]).

best_threshold([First | Rest], Examples) ->
    Initial = {First, correct(First, Examples)},
    lists:foldl(
      fun(Threshold, {BestThreshold, BestCorrect}) ->
          Count = correct(Threshold, Examples),
          case Count > BestCorrect orelse
               (Count =:= BestCorrect andalso Threshold < BestThreshold) of
              true -> {Threshold, Count};
              false -> {BestThreshold, BestCorrect}
          end
      end, Initial, Rest).

correct(Threshold, Examples) ->
    length([ok || {Score, Label} <- Examples,
                  (Score >= Threshold) =:= Label]).

fraction(Value) when is_integer(Value), Value >= 0, Value =< 1 -> true;
fraction(Value) when is_float(Value), Value =:= Value,
                     Value >= 0.0, Value =< 1.0 -> true;
fraction(_) -> false.

positive_weight(Value) when is_integer(Value), Value > 0, Value =< 100 -> true;
positive_weight(Value) when is_float(Value), Value =:= Value,
                            Value > 0.0, Value =< 100.0 -> true;
positive_weight(_) -> false.

text_id(Value) when is_binary(Value), byte_size(Value) > 0,
                    byte_size(Value) =< 256 ->
    try unicode:characters_to_binary(Value) of Value -> true; _ -> false
    catch _:_ -> false end;
text_id(_) -> false.
