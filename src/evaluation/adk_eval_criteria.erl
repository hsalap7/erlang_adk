%% @doc Deterministic full-case evaluation criteria.
%%
%% These criteria deliberately operate on canonical invocation and trajectory
%% facts. They do not call a model and are therefore reproducible in EUnit,
%% CI, and offline conformance runs.
-module(adk_eval_criteria).

-export([score_case/2, validate_config/1]).

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case criterion(Config) of
        exact_response ->
            case response_normalization(Config) of
                invalid -> {error, invalid_response_normalization};
                _ -> ok
            end;
        {trajectory, _Policy} ->
            case args_policy(Config) of
                invalid -> {error, invalid_trajectory_args_policy};
                _ -> ok
            end;
        invalid ->
            {error, invalid_eval_criterion}
    end;
validate_config(_) ->
    {error, invalid_eval_criterion_config}.

-spec score_case(map(), map()) ->
    {ok, number(), map()} | {not_evaluated, map()} | {error, term()}.
score_case(Input, Config) when is_map(Input), is_map(Config) ->
    case validate_config(Config) of
        ok -> score_validated(criterion(Config), Input, Config);
        {error, _} = Error -> Error
    end;
score_case(_, _) ->
    {error, invalid_eval_case_input}.

score_validated(exact_response, Input, Config) ->
    Turns = get(Input, turns, []),
    Case = get(Input, eval_case, #{}),
    Pairs = response_pairs(Case, Turns),
    case Pairs of
        [] ->
            {not_evaluated, #{reason => <<"missing_expected_response">>}};
        _ ->
            Mode = response_normalization(Config),
            Matches = length([ok || {Expected, Actual} <- Pairs,
                                    response_equal(Expected, Actual, Mode)]),
            Total = length(Pairs),
            {ok, Matches / Total,
             #{criterion => <<"exact_response">>,
               normalization => atom_to_binary(Mode, utf8),
               matched_count => Matches, expected_count => Total}}
    end;
score_validated({trajectory, Policy}, Input, Config) ->
    Case = get(Input, eval_case, #{}),
    Turns = get(Input, turns, []),
    Expected0 = expected_trajectory(Case, Turns),
    Actual0 = get(Input, trajectory, []),
    case Expected0 of
        undefined ->
            {not_evaluated, #{reason => <<"missing_expected_trajectory">>}};
        Expected when is_list(Expected), is_list(Actual0) ->
            ArgsPolicy = args_policy(Config),
            Actual = actual_tool_steps(Actual0),
            Passed = trajectory_matches(Policy, Expected, Actual, ArgsPolicy),
            Matched = count_matches(Expected, Actual, ArgsPolicy),
            Score = case Passed of true -> 1.0; false -> 0.0 end,
            {ok, Score,
             #{criterion => <<"tool_trajectory">>,
               match_policy => atom_to_binary(Policy, utf8),
               args_policy => atom_to_binary(ArgsPolicy, utf8),
               expected_count => length(Expected),
               actual_count => length(Actual), matched_count => Matched}}
    end.

response_pairs(Case, Turns) ->
    case find(Case, expected_final_response) of
        {ok, Expected} ->
            case lists:reverse(Turns) of
                [Last | _] -> [{Expected, get(Last, actual, null)}];
                [] -> []
            end;
        error ->
            lists:filtermap(
              fun(Turn) ->
                  Expected0 = get(Turn, expected, undefined),
                  case expected_response(Expected0) of
                      undefined -> false;
                      Expected ->
                          {true, {Expected, get(Turn, actual, null)}}
                  end
              end, Turns)
    end.

expected_response(Expected) when is_map(Expected) ->
    first_value(Expected,
                [response, final_response, expected_response], undefined);
expected_response(undefined) -> undefined;
expected_response(Expected) -> Expected.

response_equal(Expected, Actual, exact) -> Expected =:= Actual;
response_equal(Expected, Actual, trim) ->
    case {text_binary(Expected), text_binary(Actual)} of
        {{ok, E}, {ok, A}} -> string:trim(E) =:= string:trim(A);
        _ -> Expected =:= Actual
    end;
response_equal(Expected, Actual, casefold_trim) ->
    case {text_binary(Expected), text_binary(Actual)} of
        {{ok, E}, {ok, A}} ->
            string:casefold(string:trim(E)) =:=
                string:casefold(string:trim(A));
        _ -> Expected =:= Actual
    end.

text_binary(Value) when is_binary(Value) -> {ok, Value};
text_binary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> error
    catch _:_ -> error
    end;
text_binary(_) -> error.

expected_trajectory(Case, Turns) ->
    case find(Case, expected_trajectory) of
        {ok, Expected} when is_list(Expected) -> Expected;
        {ok, _} -> undefined;
        error ->
            ExpectedByTurn = lists:flatmap(
                               fun(Turn) ->
                                   expected_turn_trajectory(
                                     get(Turn, expected, undefined))
                               end, Turns),
            case ExpectedByTurn of [] -> undefined; _ -> ExpectedByTurn end
    end.

expected_turn_trajectory(Expected) when is_map(Expected) ->
    case first_value(Expected, [trajectory, tool_uses], undefined) of
        Value when is_list(Value) -> Value;
        _ -> []
    end;
expected_turn_trajectory(_) -> [].

actual_tool_steps(Steps) ->
    [Step || Step <- Steps, is_map(Step), is_tool_step(Step)].

is_tool_step(Step) ->
    case get(Step, kind, <<"tool_call">>) of
        <<"tool_call">> -> true;
        tool_call -> true;
        _ -> false
    end.

trajectory_matches(exact, Expected, Actual, ArgsPolicy) ->
    length(Expected) =:= length(Actual) andalso
        lists:all(
          fun({E, A}) -> step_matches(E, A, ArgsPolicy) end,
          lists:zip(Expected, Actual));
trajectory_matches(in_order, Expected, Actual, ArgsPolicy) ->
    ordered_subset(Expected, Actual, ArgsPolicy);
trajectory_matches(any_order, Expected, Actual, ArgsPolicy) ->
    length(Expected) =:= length(Actual) andalso
        multiset_subset(Expected, Actual, ArgsPolicy);
trajectory_matches(subset, Expected, Actual, ArgsPolicy) ->
    multiset_subset(Expected, Actual, ArgsPolicy).

ordered_subset([], _Actual, _ArgsPolicy) -> true;
ordered_subset(_Expected, [], _ArgsPolicy) -> false;
ordered_subset([Expected | ExpectedRest], [Actual | ActualRest], ArgsPolicy) ->
    case step_matches(Expected, Actual, ArgsPolicy) of
        true -> ordered_subset(ExpectedRest, ActualRest, ArgsPolicy);
        false -> ordered_subset([Expected | ExpectedRest], ActualRest,
                                ArgsPolicy)
    end.

multiset_subset([], _Actual, _ArgsPolicy) -> true;
multiset_subset([Expected | Rest], Actual, ArgsPolicy) ->
    case consume_match(Expected, Actual, ArgsPolicy, []) of
        {ok, Remaining} -> multiset_subset(Rest, Remaining, ArgsPolicy);
        not_found -> false
    end.

consume_match(_Expected, [], _ArgsPolicy, _Acc) -> not_found;
consume_match(Expected, [Actual | Rest], ArgsPolicy, Acc) ->
    case step_matches(Expected, Actual, ArgsPolicy) of
        true -> {ok, lists:reverse(Acc, Rest)};
        false -> consume_match(Expected, Rest, ArgsPolicy, [Actual | Acc])
    end.

count_matches(Expected, Actual, ArgsPolicy) ->
    count_matches(Expected, Actual, ArgsPolicy, 0).

count_matches([], _Actual, _ArgsPolicy, Count) -> Count;
count_matches([Expected | Rest], Actual, ArgsPolicy, Count) ->
    case consume_match(Expected, Actual, ArgsPolicy, []) of
        {ok, Remaining} ->
            count_matches(Rest, Remaining, ArgsPolicy, Count + 1);
        not_found ->
            count_matches(Rest, Actual, ArgsPolicy, Count)
    end.

step_matches(Expected, Actual, _ArgsPolicy)
  when is_binary(Expected), is_map(Actual) ->
    Expected =:= tool_name(Actual);
step_matches(Expected, Actual, ArgsPolicy)
  when is_map(Expected), is_map(Actual) ->
    NamesMatch = tool_name(Expected) =:= tool_name(Actual),
    KindsMatch = normalized_kind(Expected) =:= normalized_kind(Actual),
    NamesMatch andalso KindsMatch andalso
        args_match(get(Expected, args, #{}), get(Actual, args, #{}),
                   ArgsPolicy);
step_matches(_, _, _) -> false.

tool_name(Step) -> first_value(Step, [tool, name], undefined).

normalized_kind(Step) ->
    case get(Step, kind, <<"tool_call">>) of
        tool_call -> <<"tool_call">>;
        Value -> Value
    end.

args_match(_Expected, _Actual, ignored) -> true;
args_match(Expected, Actual, exact) -> Expected =:= Actual;
args_match(Expected, Actual, subset) -> json_subset(Expected, Actual).

json_subset(Expected, Actual) when is_map(Expected), is_map(Actual) ->
    lists:all(
      fun({Key, Value}) ->
          case maps:find(Key, Actual) of
              {ok, ActualValue} -> json_subset(Value, ActualValue);
              error -> false
          end
      end, maps:to_list(Expected));
json_subset(Expected, Actual) when is_list(Expected), is_list(Actual) ->
    length(Expected) =< length(Actual) andalso
        lists:all(
          fun({E, A}) -> json_subset(E, A) end,
          lists:zip(Expected, lists:sublist(Actual, length(Expected))));
json_subset(Expected, Actual) -> Expected =:= Actual.

criterion(Config) ->
    case get(Config, criterion, invalid) of
        exact_response -> exact_response;
        <<"exact_response">> -> exact_response;
        trajectory_exact -> {trajectory, exact};
        <<"trajectory_exact">> -> {trajectory, exact};
        trajectory_in_order -> {trajectory, in_order};
        <<"trajectory_in_order">> -> {trajectory, in_order};
        trajectory_any_order -> {trajectory, any_order};
        <<"trajectory_any_order">> -> {trajectory, any_order};
        trajectory_subset -> {trajectory, subset};
        <<"trajectory_subset">> -> {trajectory, subset};
        tool_trajectory -> trajectory_policy(Config);
        <<"tool_trajectory">> -> trajectory_policy(Config);
        _ -> invalid
    end.

trajectory_policy(Config) ->
    case get(Config, match, exact) of
        exact -> {trajectory, exact};
        <<"exact">> -> {trajectory, exact};
        in_order -> {trajectory, in_order};
        <<"in_order">> -> {trajectory, in_order};
        any_order -> {trajectory, any_order};
        <<"any_order">> -> {trajectory, any_order};
        subset -> {trajectory, subset};
        <<"subset">> -> {trajectory, subset};
        _ -> invalid
    end.

args_policy(Config) ->
    case get(Config, args, exact) of
        exact -> exact;
        <<"exact">> -> exact;
        subset -> subset;
        <<"subset">> -> subset;
        ignored -> ignored;
        <<"ignored">> -> ignored;
        ignore -> ignored;
        <<"ignore">> -> ignored;
        _ -> invalid
    end.

response_normalization(Config) ->
    case get(Config, normalization, exact) of
        exact -> exact;
        <<"exact">> -> exact;
        trim -> trim;
        <<"trim">> -> trim;
        casefold_trim -> casefold_trim;
        <<"casefold_trim">> -> casefold_trim;
        _ -> invalid
    end.

first_value(_Map, [], Default) -> Default;
first_value(Map, [Key | Rest], Default) ->
    case find(Map, Key) of
        {ok, Value} -> Value;
        error -> first_value(Map, Rest, Default)
    end.

get(Map, Key, Default) ->
    case find(Map, Key) of
        {ok, Value} -> Value;
        error -> Default
    end.

find(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, _} = Found -> Found;
        error when is_atom(Key) -> maps:find(atom_to_binary(Key, utf8), Map);
        error -> error
    end.
