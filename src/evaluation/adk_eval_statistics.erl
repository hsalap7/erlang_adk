%% @doc Deterministic confidence and longitudinal regression helpers.
%%
%% The module deliberately implements a small, auditable statistical surface:
%% Wilson intervals for pass rates and a normal-approximation interval for the
%% difference between two bounded score series. It never samples randomness,
%% so the same stored evaluation results produce byte-stable gate decisions.
-module(adk_eval_statistics).

-export([summary/1, confidence_interval/2, pass_rate_interval/3,
         longitudinal_gate/3]).

-define(MAX_SAMPLES, 100000).

-spec summary([number()]) -> {ok, map()} | {error, term()}.
summary(Samples) ->
    case normalize_samples(Samples) of
        {ok, Values} -> {ok, summary_values(Values)};
        {error, _} = Error -> Error
    end.

-spec confidence_interval([number()], map()) ->
    {ok, map()} | {error, term()}.
confidence_interval(Samples, Options) when is_map(Options) ->
    case {normalize_samples(Samples), normalize_options(Options)} of
        {{ok, []}, {ok, _}} -> {error, empty_evaluation_samples};
        {{ok, Values}, {ok, #{z := Z, confidence := Confidence}}} ->
            Stats = summary_values(Values),
            Count = maps:get(<<"count">>, Stats),
            Mean = maps:get(<<"mean">>, Stats),
            Stddev = maps:get(<<"standard_deviation">>, Stats),
            Margin = Z * Stddev / math:sqrt(Count),
            {ok, Stats#{<<"confidence_level">> => Confidence,
                        <<"lower">> => clamp(Mean - Margin),
                        <<"upper">> => clamp(Mean + Margin),
                        <<"margin">> => Margin}};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
confidence_interval(_Samples, _Options) ->
    {error, invalid_evaluation_statistics_options}.

-spec pass_rate_interval(non_neg_integer(), non_neg_integer(), map()) ->
    {ok, map()} | {error, term()}.
pass_rate_interval(Passed, Total, Options)
  when is_integer(Passed), is_integer(Total), Passed >= 0, Total > 0,
       Passed =< Total, Total =< ?MAX_SAMPLES, is_map(Options) ->
    case normalize_options(Options) of
        {ok, #{z := Z, confidence := Confidence}} ->
            N = float(Total),
            Rate = Passed / N,
            Z2 = Z * Z,
            Denominator = 1.0 + Z2 / N,
            Centre = (Rate + Z2 / (2.0 * N)) / Denominator,
            Half = Z * math:sqrt(
                         Rate * (1.0 - Rate) / N +
                         Z2 / (4.0 * N * N)) / Denominator,
            {ok, #{<<"passed">> => Passed,
                   <<"total">> => Total,
                   <<"rate">> => Rate,
                   <<"confidence_level">> => Confidence,
                   <<"lower">> => clamp(Centre - Half),
                   <<"upper">> => clamp(Centre + Half)}};
        {error, _} = Error -> Error
    end;
pass_rate_interval(_Passed, _Total, _Options) ->
    {error, invalid_pass_rate_samples}.

%% @doc Compare two bounded score series.
%%
%% Options:
%%  * `confidence_level' - 0.90, 0.95 (default), or 0.99
%%  * `max_mean_drop' - tolerated baseline minus current mean, 0..1
%%  * `require_significance' - when true (default), a regression is reported
%%    only when the one-sided confidence bound also exceeds the tolerance.
-spec longitudinal_gate([number()], [number()], map()) ->
    {ok, map()} | {error, term()}.
longitudinal_gate(Baseline0, Current0, Options) when is_map(Options) ->
    Allowed = [confidence_level, max_mean_drop, require_significance],
    Unknown = maps:keys(maps:without(Allowed, Options)),
    MaxDrop = maps:get(max_mean_drop, Options, 0.0),
    Significant = maps:get(require_significance, Options, true),
    case {Unknown, valid_fraction(MaxDrop), is_boolean(Significant),
          normalize_samples(Baseline0), normalize_samples(Current0),
          normalize_options(maps:with([confidence_level], Options))} of
        {[], true, true, {ok, [_ | _] = Baseline},
         {ok, [_ | _] = Current},
         {ok, #{z := Z, confidence := Confidence}}} ->
            B = summary_values(Baseline),
            C = summary_values(Current),
            BaselineMean = maps:get(<<"mean">>, B),
            CurrentMean = maps:get(<<"mean">>, C),
            Drop = erlang:max(0.0, BaselineMean - CurrentMean),
            Variance = sample_variance(Baseline) / length(Baseline) +
                       sample_variance(Current) / length(Current),
            Margin = Z * math:sqrt(Variance),
            LowerDrop = erlang:max(0.0, Drop - Margin),
            Regression = case Significant of
                true -> LowerDrop > MaxDrop;
                false -> Drop > MaxDrop
            end,
            {ok, #{<<"report_type">> => <<"longitudinal_regression">>,
                   <<"confidence_level">> => Confidence,
                   <<"baseline">> => B,
                   <<"current">> => C,
                   <<"mean_drop">> => Drop,
                   <<"mean_drop_lower_bound">> => LowerDrop,
                   <<"mean_drop_margin">> => Margin,
                   <<"max_mean_drop">> => MaxDrop,
                   <<"require_significance">> => Significant,
                   <<"regression">> => Regression,
                   <<"passed">> => not Regression}};
        {[_ | _], _, _, _, _, _} ->
            {error, {unknown_evaluation_statistics_options,
                     lists:sort(Unknown)}};
        {_, false, _, _, _, _} -> {error, invalid_max_mean_drop};
        {_, _, false, _, _, _} -> {error, invalid_significance_option};
        {_, _, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, _, {error, _} = Error} -> Error;
        _ -> {error, empty_evaluation_samples}
    end;
longitudinal_gate(_Baseline, _Current, _Options) ->
    {error, invalid_evaluation_statistics_options}.

normalize_options(Options) ->
    Allowed = [confidence_level],
    case maps:keys(maps:without(Allowed, Options)) of
        [] ->
            Confidence = maps:get(confidence_level, Options, 0.95),
            case z_score(Confidence) of
                {ok, Z} -> {ok, #{confidence => Confidence, z => Z}};
                error -> {error, invalid_confidence_level}
            end;
        Unknown ->
            {error, {unknown_evaluation_statistics_options,
                     lists:sort(Unknown)}}
    end.

z_score(0.90) -> {ok, 1.6448536269514722};
z_score(0.95) -> {ok, 1.959963984540054};
z_score(0.99) -> {ok, 2.5758293035489004};
z_score(_) -> error.

normalize_samples(Samples) ->
    normalize_samples(Samples, 0, []).

normalize_samples([], _Count, Acc) -> {ok, lists:reverse(Acc)};
normalize_samples([Value | Rest], Count, Acc)
  when Count < ?MAX_SAMPLES ->
    case valid_fraction(Value) of
        true -> normalize_samples(Rest, Count + 1, [float(Value) | Acc]);
        false -> {error, {invalid_evaluation_sample, Count}}
    end;
normalize_samples([_ | _], ?MAX_SAMPLES, _Acc) ->
    {error, evaluation_sample_limit_exceeded};
normalize_samples(_Improper, Count, _Acc) ->
    {error, {invalid_evaluation_sample_list, Count}}.

summary_values([]) ->
    #{<<"count">> => 0, <<"mean">> => 0.0,
      <<"minimum">> => 0.0, <<"maximum">> => 0.0,
      <<"standard_deviation">> => 0.0};
summary_values(Values) ->
    Mean = lists:sum(Values) / length(Values),
    #{<<"count">> => length(Values),
      <<"mean">> => Mean,
      <<"minimum">> => lists:min(Values),
      <<"maximum">> => lists:max(Values),
      <<"standard_deviation">> => math:sqrt(sample_variance(Values))}.

sample_variance([_]) -> 0.0;
sample_variance(Values) ->
    Mean = lists:sum(Values) / length(Values),
    lists:sum([math:pow(Value - Mean, 2) || Value <- Values]) /
        (length(Values) - 1).

valid_fraction(Value) when is_integer(Value), Value >= 0, Value =< 1 -> true;
valid_fraction(Value) when is_float(Value), Value >= 0.0, Value =< 1.0 ->
    Value =:= Value;
valid_fraction(_) -> false.

clamp(Value) when Value < 0.0 -> 0.0;
clamp(Value) when Value > 1.0 -> 1.0;
clamp(Value) -> Value.
