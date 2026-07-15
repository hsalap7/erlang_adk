%% @doc Pure, bounded evaluation-report boundary for developer tooling.
%%
%% Inputs are already-decoded JSON maps. This module never loads files,
%% resolves modules, starts agents, or converts input strings to atoms. It
%% classifies checked persisted results and canonical baseline comparisons,
%% then delegates rendering and comparison to the evaluation APIs.
-module(adk_eval_dev_view).
-compile({no_auto_import, [error/1]}).

-export([classify/1, render/3, compare/3]).

-define(DEFAULT_MAX_OUTPUT_BYTES, 1048576).
-define(MAX_OUTPUT_BYTES, 16777216).
-define(MAX_TOLERANCES, 1000).

-type kind() :: eval_result | baseline_comparison.
-type tagged_error() :: {error, {eval_dev_view, atom()}}.
-export_type([kind/0, tagged_error/0]).

-spec classify(map()) -> {ok, kind(), map()} | tagged_error().
classify(Value) when is_map(Value) ->
    case bounded_json(Value) of
        ok -> classify_json(Value);
        {error, limit} -> error(input_limit_exceeded);
        {error, shape} -> error(invalid_json_map)
    end;
classify(_) ->
    error(invalid_json_map).

-spec render(map(), binary(), map()) -> {ok, binary()} | tagged_error().
render(Value, FormatInput, Options) ->
    case classify(Value) of
        {error, _} = Error -> Error;
        {ok, _Kind, Canonical} ->
            case {render_format(FormatInput), render_options(Options)} of
                {{ok, Format}, {ok, MaxBytes}} ->
                    case adk_eval_set:report(Canonical, Format) of
                        {ok, Output} when byte_size(Output) =< MaxBytes ->
                            {ok, Output};
                        {ok, _Output} -> error(output_limit_exceeded);
                        {error, _} -> error(render_failed)
                    end;
                {{error, _} = Error, _} -> Error;
                {_, {error, _} = Error} -> Error
            end
    end.

-spec compare(map(), map(), map()) -> {ok, map()} | tagged_error().
compare(Baseline0, Current0, Options) ->
    case {classify(Baseline0), classify(Current0),
          comparison_options(Options)} of
        {{ok, eval_result, Baseline}, {ok, eval_result, Current},
         {ok, CompareOptions, MaxBytes}} ->
            compare_checked(Baseline, Current, CompareOptions, MaxBytes);
        {{ok, baseline_comparison, _}, _, _} ->
            error(baseline_must_be_eval_result);
        {_, {ok, baseline_comparison, _}, _} ->
            error(current_must_be_eval_result);
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

compare_checked(Baseline, Current, Options, MaxBytes) ->
    case adk_eval_set:compare(Baseline, Current, Options) of
        {ok, Comparison} ->
            case strict_comparison(Comparison) of
                ok ->
                    case adk_eval_set:report(Comparison, json) of
                        {ok, Encoded} when byte_size(Encoded) =< MaxBytes ->
                            {ok, Comparison};
                        {ok, _Encoded} -> error(output_limit_exceeded);
                        {error, _} -> error(comparison_failed)
                    end;
                error -> error(comparison_failed)
            end;
        {error, eval_set_mismatch} -> error(eval_set_mismatch);
        {error, _} -> error(comparison_failed)
    end.

classify_json(Value) ->
    HasResult = maps:is_key(<<"result_schema_version">>, Value),
    HasReport = maps:is_key(<<"report_schema_version">>, Value)
        orelse maps:is_key(<<"report_type">>, Value),
    case {HasResult, HasReport} of
        {true, true} -> error(ambiguous_report_kind);
        {true, false} -> classify_result(Value);
        {false, true} -> classify_comparison(Value);
        {false, false} -> error(unknown_report_kind)
    end.

classify_result(Value) ->
    case adk_eval_set:decode_result(Value) of
        {ok, Canonical} -> {ok, eval_result, Canonical};
        {error, _} -> error(invalid_eval_result)
    end.

classify_comparison(#{<<"report_type">> := <<"baseline_comparison">>}
                    = Value) ->
    case strict_comparison(Value) of
        ok -> {ok, baseline_comparison, Value};
        error -> error(invalid_baseline_comparison)
    end;
classify_comparison(#{<<"report_type">> := _}) ->
    error(unsupported_report_type);
classify_comparison(_) ->
    error(invalid_baseline_comparison).

render_format(<<"json">>) -> {ok, json};
render_format(<<"markdown">>) -> {ok, markdown};
render_format(_) -> error(invalid_format).

render_options(Options) ->
    case bounded_json(Options) of
        ok when is_map(Options) ->
            case only_allowed_keys(Options, [<<"max_output_bytes">>]) of
                true -> max_output_bytes(Options);
                false -> error(invalid_options)
            end;
        _ -> error(invalid_options)
    end.

comparison_options(Options) ->
    case bounded_json(Options) of
        ok when is_map(Options) ->
            Allowed = [<<"max_pass_rate_drop">>,
                       <<"metric_tolerances">>,
                       <<"max_output_bytes">>],
            case only_allowed_keys(Options, Allowed) of
                false -> error(invalid_comparison_options);
                true -> normalize_comparison_options(Options)
            end;
        _ -> error(invalid_comparison_options)
    end.

normalize_comparison_options(Options) ->
    MaxDrop = maps:get(<<"max_pass_rate_drop">>, Options, 0.0),
    Tolerances = maps:get(<<"metric_tolerances">>, Options, #{}),
    case {valid_fraction(MaxDrop), valid_tolerances(Tolerances),
          max_output_bytes(Options)} of
        {true, true, {ok, MaxBytes}} ->
            {ok, #{max_pass_rate_drop => MaxDrop,
                   metric_tolerances => Tolerances}, MaxBytes};
        _ -> error(invalid_comparison_options)
    end.

max_output_bytes(Options) ->
    Value = maps:get(<<"max_output_bytes">>, Options,
                     ?DEFAULT_MAX_OUTPUT_BYTES),
    case is_integer(Value) andalso Value > 0
         andalso Value =< ?MAX_OUTPUT_BYTES of
        true -> {ok, Value};
        false -> error(invalid_output_limit)
    end.

valid_tolerances(Value) when is_map(Value),
                             map_size(Value) =< ?MAX_TOLERANCES ->
    lists:all(
      fun({Id, Tolerance}) ->
          is_binary(Id) andalso byte_size(Id) > 0
              andalso valid_utf8(Id)
              andalso valid_fraction(Tolerance)
      end, maps:to_list(Value));
valid_tolerances(_) -> false.

strict_comparison(Value) when is_map(Value) ->
    case adk_eval_report:validate_comparison(Value) of
        ok -> ok;
        {error, _} -> error
    end.

only_allowed_keys(Map, Allowed) ->
    lists:all(fun(Key) -> lists:member(Key, Allowed) end,
              maps:keys(Map)).

bounded_json(Value) ->
    case adk_eval_limits:check(Value) of
        ok ->
            case json_value(Value) of
                true -> ok;
                false -> {error, shape}
            end;
        {error, _} -> {error, limit}
    end.

json_value(Value) when is_binary(Value) -> valid_utf8(Value);
json_value(Value) when is_integer(Value) -> true;
json_value(Value) when is_float(Value) -> Value =:= Value;
json_value(true) -> true;
json_value(false) -> true;
json_value(null) -> true;
json_value(Value) when is_list(Value) ->
    lists:all(fun json_value/1, Value);
json_value(Value) when is_map(Value) ->
    lists:all(
      fun({Key, Nested}) ->
          is_binary(Key) andalso valid_utf8(Key) andalso json_value(Nested)
      end, maps:to_list(Value));
json_value(_) -> false.

valid_utf8(Binary) ->
    try unicode:characters_to_binary(Binary) of
        Binary -> true;
        _ -> false
    catch
        _:_ -> false
    end.

valid_fraction(Value) when is_integer(Value) ->
    Value >= 0 andalso Value =< 1;
valid_fraction(Value) when is_float(Value) ->
    Value =:= Value andalso Value >= 0.0 andalso Value =< 1.0;
valid_fraction(_) -> false.

error(Code) -> {error, {eval_dev_view, Code}}.
