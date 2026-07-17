%% @doc Deterministic evaluation reports and baseline regression comparison.
-module(adk_eval_report).

-export([compare/3, render/2, validate_comparison/1]).

-define(REPORT_VERSION, 1).

-spec compare(map(), map(), map()) -> {ok, map()} | {error, term()}.
compare(Baseline0, Current0, Opts) when is_map(Opts) ->
    case {adk_eval_set:encode_result(Baseline0),
          adk_eval_set:encode_result(Current0),
          validate_options(Opts)} of
        {{ok, Baseline}, {ok, Current}, {ok, ValidOpts}} ->
            compare_valid(Baseline, Current, ValidOpts);
        {{error, Reason}, _, _} ->
            {error, {invalid_baseline, reason_tag(Reason)}};
        {_, {error, Reason}, _} ->
            {error, {invalid_current_result, reason_tag(Reason)}};
        {_, _, {error, _} = Error} -> Error
    end;
compare(_, _, _) ->
    {error, invalid_eval_comparison_arguments}.

-spec render(map(), json | markdown) -> {ok, binary()} | {error, term()}.
render(Value, json) when is_map(Value) ->
    case checked_report(Value) of
        {ok, Safe} ->
            try jsx:encode(Safe) of
                Encoded when is_binary(Encoded) -> {ok, Encoded}
            catch
                _:_ -> {error, invalid_eval_report}
            end;
        {error, _} = Error -> Error
    end;
render(Value, markdown) when is_map(Value) ->
    case checked_report(Value) of
        {ok, Safe} -> {ok, markdown(Safe)};
        {error, _} = Error -> Error
    end;
render(_, _) ->
    {error, invalid_eval_report_format}.

%% @doc Validate the canonical baseline-comparison schema without rendering.
%%
%% This is shared by the public report API and the developer UI boundary so a
%% malformed nested diff is rejected before any formatter can dereference it.
-spec validate_comparison(map()) -> ok | {error, term()}.
validate_comparison(Value) when is_map(Value) ->
    case checked_comparison(Value) of
        {ok, _Safe} -> ok;
        {error, _} = Error -> Error
    end;
validate_comparison(_) ->
    {error, invalid_eval_comparison}.

compare_valid(Baseline, Current, Opts) ->
    BaselineId = maps:get(<<"eval_set_id">>, Baseline),
    CurrentId = maps:get(<<"eval_set_id">>, Current),
    case BaselineId =:= CurrentId of
        false -> {error, eval_set_mismatch};
        true ->
            BaselineRate = number(maps:get(<<"pass_rate">>, Baseline, 0.0)),
            CurrentRate = number(maps:get(<<"pass_rate">>, Current, 0.0)),
            RateDrop = erlang:max(0.0, BaselineRate - CurrentRate),
            MetricDiffs = metric_diffs(
                            maps:get(<<"metrics">>, Baseline, []),
                            maps:get(<<"metrics">>, Current, []), Opts),
            CaseDiffs = case_diffs(
                          maps:get(<<"cases">>, Baseline, []),
                          maps:get(<<"cases">>, Current, [])),
            RateRegression =
                RateDrop > maps:get(max_pass_rate_drop, Opts),
            MetricRegression =
                lists:any(fun(Diff) ->
                    maps:get(<<"regression">>, Diff)
                end, MetricDiffs),
            CaseRegression =
                lists:any(fun(Diff) ->
                    maps:get(<<"regression">>, Diff)
                end, CaseDiffs),
            Passed = not (RateRegression orelse MetricRegression
                          orelse CaseRegression),
            Report = #{
                <<"report_schema_version">> => ?REPORT_VERSION,
                <<"report_type">> => <<"baseline_comparison">>,
                <<"eval_set_id">> => BaselineId,
                <<"baseline_version">> =>
                    maps:get(<<"eval_set_version">>, Baseline),
                <<"current_version">> =>
                    maps:get(<<"eval_set_version">>, Current),
                <<"passed">> => Passed,
                <<"baseline_pass_rate">> => BaselineRate,
                <<"current_pass_rate">> => CurrentRate,
                <<"pass_rate_drop">> => RateDrop,
                <<"max_pass_rate_drop">> =>
                    maps:get(max_pass_rate_drop, Opts),
                <<"metric_diffs">> => MetricDiffs,
                <<"case_diffs">> => CaseDiffs
            },
            checked_comparison(Report)
    end.

metric_diffs(Baseline, Current, Opts) ->
    BaselineMap = maps:from_list(
                    [{maps:get(<<"metric_id">>, M), M} || M <- Baseline]),
    CurrentMap = maps:from_list(
                   [{maps:get(<<"metric_id">>, M), M} || M <- Current]),
    Ids = lists:sort(maps:keys(BaselineMap)),
    [metric_diff(Id, maps:get(Id, BaselineMap),
                 maps:get(Id, CurrentMap, missing), Opts)
     || Id <- Ids].

metric_diff(Id, Baseline, missing, Opts) ->
    #{<<"metric_id">> => Id,
      <<"baseline_score">> =>
          number(maps:get(<<"average_score">>, Baseline, 0.0)),
      <<"current_score">> => 0.0,
      <<"score_drop">> =>
          number(maps:get(<<"average_score">>, Baseline, 0.0)),
      <<"tolerance">> => metric_tolerance(Id, Opts),
      <<"regression">> => true,
      <<"reason">> => <<"missing_current_metric">>};
metric_diff(Id, Baseline, Current, Opts) ->
    BaselineScore =
        number(maps:get(<<"average_score">>, Baseline, 0.0)),
    CurrentScore = number(maps:get(<<"average_score">>, Current, 0.0)),
    Drop = erlang:max(0.0, BaselineScore - CurrentScore),
    Tolerance = metric_tolerance(Id, Opts),
    #{<<"metric_id">> => Id,
      <<"baseline_score">> => BaselineScore,
      <<"current_score">> => CurrentScore,
      <<"score_drop">> => Drop,
      <<"tolerance">> => Tolerance,
      <<"regression">> => Drop > Tolerance,
      <<"reason">> => case Drop > Tolerance of
          true -> <<"score_drop">>;
          false -> <<"none">>
      end}.

case_diffs(Baseline, Current) ->
    BaselineMap = maps:from_list(
                    [{maps:get(<<"case_id">>, C), C} || C <- Baseline]),
    CurrentMap = maps:from_list(
                   [{maps:get(<<"case_id">>, C), C} || C <- Current]),
    Ids = lists:sort(maps:keys(BaselineMap)),
    [case_diff(Id, maps:get(Id, BaselineMap),
               maps:get(Id, CurrentMap, missing))
     || Id <- Ids].

case_diff(Id, Baseline, missing) ->
    #{<<"case_id">> => Id,
      <<"baseline_status">> => maps:get(<<"status">>, Baseline),
      <<"current_status">> => <<"missing">>,
      <<"trajectory_changed">> => true,
      <<"regression">> => true,
      <<"reason">> => <<"missing_current_case">>};
case_diff(Id, Baseline, Current) ->
    BaselinePassed = maps:get(<<"passed">>, Baseline, false),
    CurrentPassed = maps:get(<<"passed">>, Current, false),
    TrajectoryChanged =
        maps:get(<<"trajectory">>, Baseline, []) =/=
            maps:get(<<"trajectory">>, Current, []),
    Regression = BaselinePassed andalso not CurrentPassed,
    #{<<"case_id">> => Id,
      <<"baseline_status">> => maps:get(<<"status">>, Baseline),
      <<"current_status">> => maps:get(<<"status">>, Current),
      <<"trajectory_changed">> => TrajectoryChanged,
      <<"regression">> => Regression,
      <<"reason">> => case Regression of
          true -> <<"case_no_longer_passes">>;
          false -> <<"none">>
      end}.

validate_options(Opts) ->
    MaxDrop = get(Opts, max_pass_rate_drop, 0.0),
    Tolerances = get(Opts, metric_tolerances, #{}),
    case {valid_fraction(MaxDrop), is_map(Tolerances),
          valid_tolerances(Tolerances)} of
        {true, true, true} ->
            {ok, #{max_pass_rate_drop => MaxDrop,
                   metric_tolerances => Tolerances}};
        _ -> {error, invalid_eval_comparison_options}
    end.

valid_tolerances(Tolerances) ->
    lists:all(
      fun({Id, Value}) ->
          is_binary(Id) andalso byte_size(Id) > 0 andalso
              valid_fraction(Value)
      end, maps:to_list(Tolerances)).

metric_tolerance(Id, Opts) ->
    maps:get(Id, maps:get(metric_tolerances, Opts), 0.0).

checked_report(#{<<"report_type">> := <<"baseline_comparison">>} = Value) ->
    checked_comparison(Value);
checked_report(Value) ->
    adk_eval_set:encode_result(Value).

checked_comparison(Value) ->
    case adk_eval_limits:check(Value) of
        ok ->
            case adk_context_guard:sanitize_value(Value) of
                {ok, Safe} when is_map(Safe) ->
                    case valid_comparison(Safe) of
                        true -> {ok, Safe};
                        false -> {error, invalid_eval_comparison}
                    end;
                _ -> {error, invalid_eval_comparison}
            end;
        {error, Reason} ->
            {error, {invalid_eval_comparison, reason_tag(Reason)}}
    end.

valid_comparison(Report) ->
    Keys = [<<"report_schema_version">>, <<"report_type">>,
            <<"eval_set_id">>, <<"baseline_version">>,
            <<"current_version">>, <<"passed">>,
            <<"baseline_pass_rate">>, <<"current_pass_rate">>,
            <<"pass_rate_drop">>, <<"max_pass_rate_drop">>,
            <<"metric_diffs">>, <<"case_diffs">>],
    exact_keys(Report, Keys) andalso valid_comparison_fields(Report).

valid_comparison_fields(Report) ->
    BaselineRate = maps:get(<<"baseline_pass_rate">>, Report),
    CurrentRate = maps:get(<<"current_pass_rate">>, Report),
    Drop = maps:get(<<"pass_rate_drop">>, Report),
    MaxDrop = maps:get(<<"max_pass_rate_drop">>, Report),
    MetricDiffs = maps:get(<<"metric_diffs">>, Report),
    CaseDiffs = maps:get(<<"case_diffs">>, Report),
    Basic = maps:get(<<"report_schema_version">>, Report) =:=
                ?REPORT_VERSION
        andalso maps:get(<<"report_type">>, Report) =:=
                    <<"baseline_comparison">>
        andalso valid_id(maps:get(<<"eval_set_id">>, Report))
        andalso valid_id(maps:get(<<"baseline_version">>, Report))
        andalso valid_id(maps:get(<<"current_version">>, Report))
        andalso is_boolean(maps:get(<<"passed">>, Report))
        andalso valid_fraction(BaselineRate)
        andalso valid_fraction(CurrentRate)
        andalso valid_fraction(Drop)
        andalso valid_fraction(MaxDrop)
        andalso is_list(MetricDiffs)
        andalso is_list(CaseDiffs),
    Basic andalso near(Drop, erlang:max(0.0,
                                        BaselineRate - CurrentRate))
        andalso valid_metric_diffs(MetricDiffs)
        andalso valid_case_diffs(CaseDiffs)
        andalso comparison_pass_is_consistent(Report, Drop, MaxDrop,
                                               MetricDiffs, CaseDiffs).

comparison_pass_is_consistent(Report, Drop, MaxDrop,
                              MetricDiffs, CaseDiffs) ->
    Regression = Drop > MaxDrop
        orelse any_regression(MetricDiffs)
        orelse any_regression(CaseDiffs),
    maps:get(<<"passed">>, Report) =:= not Regression.

valid_metric_diffs(Diffs) ->
    unique_ids(Diffs, <<"metric_id">>) andalso
        lists:all(fun valid_metric_diff/1, Diffs).

valid_metric_diff(Diff) when is_map(Diff) ->
    Keys = [<<"metric_id">>, <<"baseline_score">>,
            <<"current_score">>, <<"score_drop">>,
            <<"tolerance">>, <<"regression">>, <<"reason">>],
    case exact_keys(Diff, Keys) of
        false -> false;
        true ->
            Baseline = maps:get(<<"baseline_score">>, Diff),
            Current = maps:get(<<"current_score">>, Diff),
            Drop = maps:get(<<"score_drop">>, Diff),
            Tolerance = maps:get(<<"tolerance">>, Diff),
            Regression = maps:get(<<"regression">>, Diff),
            Reason = maps:get(<<"reason">>, Diff),
            valid_id(maps:get(<<"metric_id">>, Diff))
                andalso valid_fraction(Baseline)
                andalso valid_fraction(Current)
                andalso valid_fraction(Drop)
                andalso valid_fraction(Tolerance)
                andalso is_boolean(Regression)
                andalso near(Drop, erlang:max(0.0, Baseline - Current))
                andalso valid_metric_reason(
                          Reason, Baseline, Current, Drop,
                          Tolerance, Regression)
    end;
valid_metric_diff(_) -> false.

valid_metric_reason(<<"missing_current_metric">>, Baseline, Current,
                    Drop, _Tolerance, Regression) ->
    Regression andalso near(Current, 0.0) andalso near(Drop, Baseline);
valid_metric_reason(<<"score_drop">>, _Baseline, _Current,
                    Drop, Tolerance, Regression) ->
    Regression andalso Drop > Tolerance;
valid_metric_reason(<<"none">>, _Baseline, _Current,
                    Drop, Tolerance, Regression) ->
    not Regression andalso Drop =< Tolerance;
valid_metric_reason(_, _, _, _, _, _) -> false.

valid_case_diffs(Diffs) ->
    unique_ids(Diffs, <<"case_id">>) andalso
        lists:all(fun valid_case_diff/1, Diffs).

valid_case_diff(Diff) when is_map(Diff) ->
    Keys = [<<"case_id">>, <<"baseline_status">>,
            <<"current_status">>, <<"trajectory_changed">>,
            <<"regression">>, <<"reason">>],
    case exact_keys(Diff, Keys) of
        false -> false;
        true ->
            Baseline = maps:get(<<"baseline_status">>, Diff),
            Current = maps:get(<<"current_status">>, Diff),
            Changed = maps:get(<<"trajectory_changed">>, Diff),
            Regression = maps:get(<<"regression">>, Diff),
            Reason = maps:get(<<"reason">>, Diff),
            valid_id(maps:get(<<"case_id">>, Diff))
                andalso valid_case_status(Baseline)
                andalso valid_current_status(Current)
                andalso is_boolean(Changed)
                andalso is_boolean(Regression)
                andalso valid_case_reason(
                          Reason, Baseline, Current, Changed, Regression)
    end;
valid_case_diff(_) -> false.

valid_case_reason(<<"missing_current_case">>, _Baseline, <<"missing">>,
                  true, true) -> true;
valid_case_reason(<<"case_no_longer_passes">>, <<"passed">>, Current,
                  _Changed, true) ->
    Current =/= <<"passed">> andalso Current =/= <<"missing">>;
valid_case_reason(<<"none">>, _Baseline, _Current, _Changed, false) -> true;
valid_case_reason(_, _, _, _, _) -> false.

valid_case_status(<<"passed">>) -> true;
valid_case_status(<<"failed">>) -> true;
valid_case_status(<<"partial">>) -> true;
valid_case_status(<<"error">>) -> true;
valid_case_status(_) -> false.

valid_current_status(<<"missing">>) -> true;
valid_current_status(Status) -> valid_case_status(Status).

any_regression(Diffs) ->
    lists:any(fun(Diff) -> maps:get(<<"regression">>, Diff) end, Diffs).

unique_ids(Values, Key) ->
    Ids = [maps:get(Key, Value, undefined) || Value <- Values,
                                             is_map(Value)],
    length(Ids) =:= length(Values)
        andalso length(Ids) =:= length(lists:usort(Ids)).

exact_keys(Map, Required) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Required).

valid_id(Value) when is_binary(Value), byte_size(Value) > 0 ->
    try unicode:characters_to_binary(Value) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end;
valid_id(_) -> false.

near(A, B) when is_number(A), is_number(B) -> abs(A - B) =< 1.0e-12;
near(_, _) -> false.

markdown(#{<<"report_type">> := <<"baseline_comparison">>} = Report) ->
    Status = pass_word(maps:get(<<"passed">>, Report)),
    MetricLines =
        [io_lib:format("| ~ts | ~.4f | ~.4f | ~.4f | ~ts |~n",
                       [maps:get(<<"metric_id">>, Diff),
                        maps:get(<<"baseline_score">>, Diff),
                        maps:get(<<"current_score">>, Diff),
                        maps:get(<<"score_drop">>, Diff),
                        pass_word(not maps:get(<<"regression">>, Diff))])
         || Diff <- maps:get(<<"metric_diffs">>, Report)],
    CaseLines =
        [io_lib:format("| ~ts | ~ts | ~ts | ~ts |~n",
                       [maps:get(<<"case_id">>, Diff),
                        maps:get(<<"baseline_status">>, Diff),
                        maps:get(<<"current_status">>, Diff),
                        pass_word(not maps:get(<<"regression">>, Diff))])
         || Diff <- maps:get(<<"case_diffs">>, Report)],
    iolist_to_binary([
      <<"# Evaluation baseline comparison\n\n">>,
      <<"Status: **">>, Status, <<"**\n\n">>,
      io_lib:format("Pass rate: ~.4f -> ~.4f (drop ~.4f)~n~n",
                    [maps:get(<<"baseline_pass_rate">>, Report),
                     maps:get(<<"current_pass_rate">>, Report),
                     maps:get(<<"pass_rate_drop">>, Report)]),
      <<"## Metrics\n\n| Metric | Baseline | Current | Drop | Status |\n">>,
      <<"|---|---:|---:|---:|---|\n">>, MetricLines,
      <<"\n## Cases\n\n| Case | Baseline | Current | Status |\n">>,
      <<"|---|---|---|---|\n">>, CaseLines
    ]);
markdown(#{<<"result_schema_version">> := 1} = Result) ->
    %% Version 1 deliberately had a small saved-result contract.  Do not
    %% assume v2 aggregate or per-case fields while preserving its supported
    %% read/render path.
    Status = pass_word(maps:get(<<"passed">>, Result)),
    iolist_to_binary([
      <<"# Evaluation report (legacy schema v1)\n\n">>,
      <<"Status: **">>, Status, <<"**\n\n">>,
      <<"Evaluation set: `">>, maps:get(<<"eval_set_id">>, Result),
      <<"` (version `">>, maps:get(<<"eval_set_version">>, Result),
      <<"`)\n\n">>,
      io_lib:format("Cases: ~B~n", [length(maps:get(<<"cases">>, Result))])
    ]);
markdown(Result) ->
    Status = pass_word(maps:get(<<"passed">>, Result)),
    MetricLines =
        [io_lib:format("| ~ts | ~ts | ~.4f | ~ts |~n",
                       [maps:get(<<"metric_id">>, Metric),
                        maps:get(<<"scope">>, Metric, <<"turn">>),
                        maps:get(<<"average_score">>, Metric),
                        pass_word(maps:get(<<"passed">>, Metric))])
         || Metric <- maps:get(<<"metrics">>, Result, [])],
    CaseLines =
        [io_lib:format("| ~ts | ~ts | ~B | ~B |~n",
                       [maps:get(<<"case_id">>, Case),
                        maps:get(<<"status">>, Case),
                        maps:get(<<"passed_sample_count">>, Case, 0),
                        maps:get(<<"sample_count">>, Case, 0)])
         || Case <- maps:get(<<"cases">>, Result, [])],
    iolist_to_binary([
      <<"# Evaluation report\n\n">>,
      <<"Status: **">>, Status, <<"**\n\n">>,
      io_lib:format("Pass rate: ~.4f (~B/~B cases)~n~n",
                    [maps:get(<<"pass_rate">>, Result),
                     maps:get(<<"passed_case_count">>, Result),
                     maps:get(<<"case_count">>, Result)]),
      <<"## Metrics\n\n| Metric | Scope | Average | Status |\n">>,
      <<"|---|---|---:|---|\n">>, MetricLines,
      <<"\n## Cases\n\n| Case | Status | Passed samples | Samples |\n">>,
      <<"|---|---|---:|---:|\n">>, CaseLines
    ]).

pass_word(true) -> <<"PASS">>;
pass_word(false) -> <<"FAIL">>.

number(Value) when is_integer(Value) -> float(Value);
number(Value) when is_float(Value) -> Value;
number(_) -> 0.0.

valid_fraction(Value) when is_integer(Value) ->
    Value >= 0 andalso Value =< 1;
valid_fraction(Value) when is_float(Value) ->
    Value =:= Value andalso Value >= 0.0 andalso Value =< 1.0;
valid_fraction(_) -> false.

get(Map, Key, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(_) -> evaluation_failed.
