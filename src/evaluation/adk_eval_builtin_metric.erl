%% @doc First-party operational, safety, cost, and semantic eval metrics.
%%
%% All inputs are bounded before traversal and every result is a normalized
%% 0..1 score with content-free metadata. The metric never calls a provider;
%% LLM-backed semantic judging belongs in `adk_eval_llm_judge' or an ensemble.
-module(adk_eval_builtin_metric).
-behaviour(adk_eval_metric).
-behaviour(adk_eval_case_metric).

-export([score/4, score_case/2, validate_config/1]).

-define(MAX_TEXT_BYTES, 65536).
-define(MAX_TURNS, 10000).

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case metric(Config) of
        latency -> validate_latency(Config);
        cost -> validate_cost(Config);
        safety -> validate_safety(Config);
        semantic_quality -> validate_semantic(Config);
        invalid -> {error, invalid_builtin_eval_metric}
    end;
validate_config(_) -> {error, invalid_builtin_eval_metric_config}.

score(Expected, Actual, Context, Config) when is_map(Context), is_map(Config) ->
    case validate_config(Config) of
        ok -> score_metric(metric(Config), Expected, Actual, Context, Config);
        {error, _} = Error -> Error
    end;
score(_Expected, _Actual, _Context, _Config) ->
    {error, invalid_builtin_eval_metric_input}.

score_case(Input, Config) when is_map(Input), is_map(Config) ->
    case validate_config(Config) of
        ok -> score_case_metric(metric(Config), Input, Config);
        {error, _} = Error -> Error
    end;
score_case(_Input, _Config) -> {error, invalid_builtin_eval_case_input}.

score_metric(latency, _Expected, _Actual, Context, Config) ->
    case latency_from(Context) of
        {ok, Millis} -> latency_score(Millis, Config);
        error -> {not_evaluated, #{<<"reason">> => <<"latency_unavailable">>}}
    end;
score_metric(cost, _Expected, _Actual, Context, Config) ->
    case usage_from(Context) of
        {ok, InputTokens, OutputTokens} ->
            cost_score(InputTokens, OutputTokens, Config);
        error -> {not_evaluated, #{<<"reason">> => <<"usage_unavailable">>}}
    end;
score_metric(safety, _Expected, _Actual, Context, Config) ->
    safety_score(violations_from(Context), Config);
score_metric(semantic_quality, Expected, Actual, _Context, Config) ->
    semantic_score(Expected, Actual, Config).

score_case_metric(Metric, Input, Config) ->
    Turns = maps:get(<<"turns">>, Input, []),
    case proper_list(Turns, ?MAX_TURNS) of
        false -> {error, invalid_builtin_eval_turns};
        true -> score_case_turns(Metric, Input, Turns, Config)
    end.

score_case_turns(latency, _Input, Turns, Config) ->
    Values = [Millis || Turn <- Turns,
                        {ok, Millis} <- [latency_from(Turn)]],
    aggregate_numeric(Values, fun(Value) -> latency_score(Value, Config) end,
                      <<"latency_unavailable">>);
score_case_turns(cost, _Input, Turns, Config) ->
    Usage = [Pair || Turn <- Turns,
                     {ok, _, _} = Pair <- [usage_from(Turn)]],
    case Usage of
        [] -> {not_evaluated, #{<<"reason">> => <<"usage_unavailable">>}};
        _ ->
            InputTokens = lists:sum([I || {ok, I, _} <- Usage]),
            OutputTokens = lists:sum([O || {ok, _, O} <- Usage]),
            cost_score(InputTokens, OutputTokens, Config)
    end;
score_case_turns(safety, _Input, Turns, Config) ->
    Count = lists:sum([violations_from(Turn) || Turn <- Turns]),
    safety_score(Count, Config);
score_case_turns(semantic_quality, Input, Turns, Config) ->
    Case = maps:get(<<"eval_case">>, Input, #{}),
    Expected = maps:get(<<"expected_final_response">>, Case, undefined),
    Actual = case lists:reverse(Turns) of
        [Last | _] -> maps:get(<<"actual">>, Last, undefined);
        [] -> undefined
    end,
    case {Expected, Actual} of
        {undefined, _} ->
            {not_evaluated, #{<<"reason">> => <<"expected_unavailable">>}};
        {_, undefined} ->
            {not_evaluated, #{<<"reason">> => <<"actual_unavailable">>}};
        _ -> semantic_score(Expected, Actual, Config)
    end.

latency_score(Millis, Config) ->
    Target = value(Config, target_ms, 1000),
    Hard = value(Config, hard_limit_ms, erlang:max(Target, Target * 4)),
    Score = case Millis =< Target of
        true -> 1.0;
        false when Hard =:= Target -> 0.0;
        false -> clamp(1.0 - (Millis - Target) / (Hard - Target))
    end,
    {ok, Score, #{<<"latency_ms">> => Millis,
                  <<"target_ms">> => Target,
                  <<"hard_limit_ms">> => Hard}}.

cost_score(InputTokens, OutputTokens, Config) ->
    InputRate = value(Config, input_microunits_per_million, 0),
    OutputRate = value(Config, output_microunits_per_million, 0),
    Maximum = value(Config, max_cost_microunits, 1),
    Cost = (InputTokens * InputRate + OutputTokens * OutputRate) / 1000000,
    Score = case Cost =< Maximum of
        true -> 1.0;
        false -> clamp(Maximum / Cost)
    end,
    {ok, Score, #{<<"input_tokens">> => InputTokens,
                  <<"output_tokens">> => OutputTokens,
                  <<"cost_microunits">> => Cost,
                  <<"max_cost_microunits">> => Maximum}}.

safety_score(Count, Config) ->
    Maximum = value(Config, max_violations, 0),
    Score = case Count =< Maximum of true -> 1.0; false -> 0.0 end,
    {ok, Score, #{<<"violation_count">> => Count,
                  <<"max_violations">> => Maximum}}.

semantic_score(Expected0, Actual0, Config) ->
    case {text(Expected0), text(Actual0)} of
        {{ok, Expected}, {ok, Actual}} ->
            Algorithm = value(Config, algorithm, token_f1),
            Score = case Algorithm of
                exact_normalized ->
                    case normalized(Expected) =:= normalized(Actual) of
                        true -> 1.0;
                        false -> 0.0
                    end;
                token_f1 -> token_f1(Expected, Actual)
            end,
            {ok, Score, #{<<"algorithm">> => atom_to_binary(Algorithm, utf8)}};
        _ -> {not_evaluated, #{<<"reason">> => <<"text_unavailable">>}}
    end.

aggregate_numeric([], _Fun, Reason) ->
    {not_evaluated, #{<<"reason">> => Reason}};
aggregate_numeric(Values, Fun, _Reason) ->
    Scores = [Score || Value <- Values,
                       {ok, Score, _} <- [Fun(Value)]],
    {ok, lists:sum(Scores) / length(Scores),
     #{<<"sample_count">> => length(Scores)}}.

latency_from(Context) ->
    Metadata = metadata_from(Context),
    case lookup_number(Metadata, runtime_latency_ms) of
        Value when is_integer(Value), Value >= 0 -> {ok, Value};
        Value when is_float(Value), Value >= 0.0 -> {ok, Value};
        _ -> error
    end.

usage_from(Context) ->
    Metadata = metadata_from(Context),
    Usage = lookup(Metadata, usage, #{}),
    Input = first_number(Usage, [input_tokens, prompt_tokens]),
    Output = first_number(Usage, [output_tokens, completion_tokens]),
    case {Input, Output} of
        {I, O} when is_integer(I), I >= 0, is_integer(O), O >= 0 ->
            {ok, I, O};
        _ -> error
    end.

violations_from(Context) ->
    Metadata = metadata_from(Context),
    case lookup(Metadata, safety_violations, 0) of
        Count when is_integer(Count), Count >= 0 -> Count;
        List when is_list(List) -> bounded_count(List, 10000, 0);
        _ -> 0
    end.

metadata_from(Context) ->
    case lookup(Context, adapter_metadata, undefined) of
        Map when is_map(Map) -> Map;
        _ -> Context
    end.

validate_latency(Config) ->
    Allowed = [metric, target_ms, hard_limit_ms],
    Target = value(Config, target_ms, 1000),
    Hard = value(Config, hard_limit_ms, erlang:max(Target, Target * 4)),
    case unknown(Config, Allowed) =:= [] andalso positive_bounded(Target) andalso
         positive_bounded(Hard) andalso Hard >= Target of
        true -> ok;
        false -> {error, invalid_latency_metric_config}
    end.

validate_cost(Config) ->
    Allowed = [metric, input_microunits_per_million,
               output_microunits_per_million, max_cost_microunits],
    Values = [value(Config, input_microunits_per_million, 0),
              value(Config, output_microunits_per_million, 0),
              value(Config, max_cost_microunits, 1)],
    case unknown(Config, Allowed) =:= [] andalso
         lists:all(fun nonnegative_bounded/1, Values) andalso
         lists:last(Values) > 0 of
        true -> ok;
        false -> {error, invalid_cost_metric_config}
    end.

validate_safety(Config) ->
    Allowed = [metric, max_violations],
    Maximum = value(Config, max_violations, 0),
    case unknown(Config, Allowed) =:= [] andalso
         is_integer(Maximum) andalso Maximum >= 0 andalso Maximum =< 10000 of
        true -> ok;
        false -> {error, invalid_safety_metric_config}
    end.

validate_semantic(Config) ->
    Allowed = [metric, algorithm],
    Algorithm = value(Config, algorithm, token_f1),
    case unknown(Config, Allowed) =:= [] andalso
         (Algorithm =:= token_f1 orelse Algorithm =:= exact_normalized) of
        true -> ok;
        false -> {error, invalid_semantic_metric_config}
    end.

metric(Config) ->
    case value(Config, metric, invalid) of
        latency -> latency;
        <<"latency">> -> latency;
        cost -> cost;
        <<"cost">> -> cost;
        safety -> safety;
        <<"safety">> -> safety;
        semantic_quality -> semantic_quality;
        <<"semantic_quality">> -> semantic_quality;
        _ -> invalid
    end.

unknown(Config, AllowedAtoms) ->
    Allowed = AllowedAtoms ++ [atom_to_binary(Key, utf8) || Key <- AllowedAtoms],
    maps:keys(maps:without(Allowed, Config)).

value(Map, Key, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

lookup(Map, Key, Default) when is_map(Map) -> value(Map, Key, Default);
lookup(_Map, _Key, Default) -> Default.

lookup_number(Map, Key) -> lookup(Map, Key, undefined).

first_number(_Map, []) -> undefined;
first_number(Map, [Key | Rest]) ->
    case lookup_number(Map, Key) of
        undefined -> first_number(Map, Rest);
        Value -> Value
    end.

text(Value) when is_binary(Value), byte_size(Value) =< ?MAX_TEXT_BYTES ->
    case unicode:characters_to_binary(Value) of
        Value -> {ok, Value};
        _ -> error
    end;
text(#{<<"text">> := Value}) -> text(Value);
text(#{text := Value}) -> text(Value);
text(_) -> error.

normalized(Value) ->
    unicode:characters_to_binary(string:casefold(string:trim(Value))).

token_f1(Expected, Actual) ->
    ExpectedTokens = token_counts(normalized(Expected)),
    ActualTokens = token_counts(normalized(Actual)),
    ExpectedCount = lists:sum(maps:values(ExpectedTokens)),
    ActualCount = lists:sum(maps:values(ActualTokens)),
    Overlap = maps:fold(
                fun(Token, Count, Acc) ->
                    Acc + erlang:min(Count,
                                     maps:get(Token, ActualTokens, 0))
                end, 0, ExpectedTokens),
    case {ExpectedCount, ActualCount} of
        {0, 0} -> 1.0;
        {0, _} -> 0.0;
        {_, 0} -> 0.0;
        _ ->
            Precision = Overlap / ActualCount,
            Recall = Overlap / ExpectedCount,
            case Precision + Recall of
                +0.0 -> 0.0;
                Sum -> 2.0 * Precision * Recall / Sum
            end
    end.

token_counts(Value) ->
    Tokens = re:split(Value, <<"[^\\p{L}\\p{N}_]+">>,
                      [unicode, {return, binary}, trim]),
    lists:foldl(fun(Token, Acc) ->
        Acc#{Token => maps:get(Token, Acc, 0) + 1}
    end, #{}, Tokens).

positive_bounded(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< 3600000.

nonnegative_bounded(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 1000000000000.

proper_list(List, Limit) -> proper_list(List, Limit, 0).
proper_list([], _Limit, _Count) -> true;
proper_list([_ | Rest], Limit, Count) when Count < Limit ->
    proper_list(Rest, Limit, Count + 1);
proper_list(_, _, _) -> false.

bounded_count([], _Limit, Count) -> Count;
bounded_count([_ | Rest], Limit, Count) when Count < Limit ->
    bounded_count(Rest, Limit, Count + 1);
bounded_count(_, _Limit, Count) -> Count.

clamp(Value) when Value < 0.0 -> 0.0;
clamp(Value) when Value > 1.0 -> 1.0;
clamp(Value) -> Value.
