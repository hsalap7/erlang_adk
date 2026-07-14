%% @doc Versioned, bounded multi-turn agent evaluation.
%%
%% Schema/result version 2 adds full-case criteria, repeated samples, strict
%% result accounting, deterministic sample identities, and per-case adapter
%% lifecycle. Version 1 sets, adapters, per-turn metrics, and saved results
%% remain accepted.
-module(adk_eval_set).
-compile({no_auto_import, [statistics/1]}).

-include("../include/adk_event.hrl").

-export([
    schema_version/0,
    result_schema_version/0,
    new/3,
    validate/1,
    encode/1,
    decode/1,
    run/4,
    encode_result/1,
    decode_result/1,
    compare/3,
    report/2
]).

-define(SET_VERSION, 2).
-define(LEGACY_SET_VERSION, 1).
-define(RESULT_VERSION, 2).
-define(LEGACY_RESULT_VERSION, 1).
-define(DEFAULT_TIMEOUT_MS, 60000).
-define(DEFAULT_CASE_TIMEOUT_MS, 30000).
-define(DEFAULT_MAX_HEAP_WORDS, 1000000).
-define(DEFAULT_VALIDATION_TIMEOUT_MS, 2000).
-define(DEFAULT_VALIDATION_HEAP_WORDS, 1000000).
-define(DEFAULT_MAX_REPORT_BYTES, 16777216).
-define(DEFAULT_FINALIZE_MAX_HEAP_WORDS, 4000000).
-define(MAX_CASES, 1000).
-define(MAX_TURNS_PER_CASE, 1000).
-define(MAX_SAMPLES, 100).
-define(MAX_CONCURRENCY, 256).
-define(MAX_TOTAL_SAMPLES, 10000).
-define(MAX_TIMEOUT_MS, 3600000).
-define(MAX_SAMPLE_HEAP_WORDS, 20000000).
-define(MAX_FINALIZE_HEAP_WORDS, 20000000).
-define(REPORT_FIXED_RESERVE_BYTES, 4096).

-type eval_set() :: map().
-type eval_result() :: map().
-export_type([eval_set/0, eval_result/0]).

-spec schema_version() -> pos_integer().
schema_version() -> ?SET_VERSION.

-spec result_schema_version() -> pos_integer().
result_schema_version() -> ?RESULT_VERSION.

-spec new(binary(), binary(), [map()]) ->
    {ok, eval_set()} | {error, term()}.
new(Id, Version, Cases) ->
    validate(#{schema_version => ?SET_VERSION,
               id => Id, version => Version, cases => Cases,
               metadata => #{}}).

%% Validation is performed in a heap/time-limited process. This matters because
%% the convenient Erlang input term has not crossed the JSON-safe boundary yet.
-spec validate(map()) -> {ok, eval_set()} | {error, term()}.
validate(Set) when is_map(Set) ->
    bounded_validation(fun() -> validate_local(Set) end);
validate(_) ->
    {error, invalid_eval_set}.

-spec encode(eval_set()) -> {ok, map()} | {error, term()}.
encode(Set) -> validate(Set).

-spec decode(map()) -> {ok, eval_set()} | {error, term()}.
decode(Set) -> validate(Set).

%% @doc Run a versioned set.
%%
%% Existing module descriptors default to the legacy per-turn score/4
%% callback. A descriptor with scope set to case calls score_case/2 with the
%% entire canonical case. Built-ins use criterion = exact_response,
%% trajectory_exact, trajectory_in_order, trajectory_any_order, or
%% trajectory_subset. Trajectory config accepts args = exact, subset, or
%% ignored.
%%
%% New options are sample_count (alias samples), sample_concurrency,
%% sample_pass_rate_threshold, min_successful_samples, empty_criteria
%% (error by default; pass must be explicit), and max_report_bytes.
-spec run(map(), eval_set(), [map()], map()) ->
    {ok, eval_result()} | {error, term()}.
run(Adapter0, Set0, Metrics0, Opts0)
  when is_map(Adapter0), is_list(Metrics0), is_map(Opts0) ->
    %% Preserve v1 error precedence: malformed adapters are reported before
    %% criteria/options which would never be invoked.
    case validate(Set0) of
        {error, _} = Error -> Error;
        {ok, Set} ->
            case validate_adapter(Adapter0) of
                {error, _} = Error -> Error;
                {ok, Adapter} ->
                    case validate_metrics(Metrics0) of
                        {error, _} = Error -> Error;
                        {ok, Metrics} ->
                            case validate_options(Opts0) of
                                {error, _} = Error -> Error;
                                {ok, Opts} ->
                                    case validate_empty_criteria(Metrics, Opts) of
                                        ok ->
                                            run_validated(Adapter, Set,
                                                          Metrics, Opts);
                                        {error, _} = Error -> Error
                                    end
                            end
                    end
            end
    end;
run(_, _, _, _) ->
    {error, invalid_eval_run_arguments}.

-spec encode_result(eval_result()) -> {ok, map()} | {error, term()}.
encode_result(Result) when is_map(Result) ->
    bounded_validation(fun() -> encode_result_local(Result) end);
encode_result(_) ->
    {error, invalid_eval_result}.

-spec decode_result(map()) -> {ok, eval_result()} | {error, term()}.
decode_result(Result) -> encode_result(Result).

%% @doc Compare a saved baseline with a current result. Options are
%% max_pass_rate_drop and binary-keyed metric_tolerances.
-spec compare(eval_result(), eval_result(), map()) ->
    {ok, map()} | {error, term()}.
compare(Baseline, Current, Opts) ->
    adk_eval_report:compare(Baseline, Current, Opts).

%% @doc Render a checked result or comparison as stable JSON or Markdown.
-spec report(eval_result() | map(), json | markdown) ->
    {ok, binary()} | {error, term()}.
report(Value, Format) ->
    adk_eval_report:render(Value, Format).

%% ------------------------------------------------------------------
%% Set validation
%% ------------------------------------------------------------------

validate_local(Set) ->
    case adk_eval_limits:check(Set) of
        ok ->
            SchemaVersion = get(Set, schema_version, ?SET_VERSION),
            case SchemaVersion of
                ?LEGACY_SET_VERSION ->
                    validate_set_fields(Set, ?LEGACY_SET_VERSION);
                ?SET_VERSION ->
                    validate_set_fields(Set, ?SET_VERSION);
                _ ->
                    {error,
                     {unsupported_eval_set_schema_version, SchemaVersion}}
            end;
        {error, Reason} ->
            {error, {invalid_eval_set, reason_tag(Reason)}}
    end.

validate_set_fields(Set, SchemaVersion) ->
    Id = get(Set, id, undefined),
    Version = get(Set, version, undefined),
    Cases = get(Set, cases, undefined),
    Metadata = get(Set, metadata, #{}),
    case {valid_nonempty_binary(Id), valid_nonempty_binary(Version),
          is_list(Cases), bounded_length(Cases, ?MAX_CASES),
          safe_metadata(Metadata)} of
        {true, true, true, true, {ok, SafeMetadata}} ->
            case validate_cases(Cases, SchemaVersion, 0, [], #{}) of
                {ok, SafeCases} ->
                    Base = #{<<"schema_version">> => SchemaVersion,
                             <<"id">> => Id,
                             <<"version">> => Version,
                             <<"cases">> => SafeCases,
                             <<"metadata">> => SafeMetadata},
                    preserve_set_descriptors(Set, Base);
                {error, _} = Error -> Error
            end;
        {false, _, _, _, _} -> {error, invalid_eval_set_id};
        {_, false, _, _, _} -> {error, invalid_eval_set_version};
        {_, _, false, _, _} -> {error, invalid_eval_cases};
        {_, _, _, false, _} -> {error, eval_set_case_limit_exceeded};
        {_, _, _, _, {error, _} = Error} -> Error
    end.

preserve_set_descriptors(Set, Base) ->
    case maybe_safe_binary(Set, name, Base) of
        {ok, WithName} -> maybe_safe_binary(Set, description, WithName);
        {error, _} = Error -> Error
    end.

maybe_safe_binary(Source, Key, Acc) ->
    case find(Source, Key) of
        error -> {ok, Acc};
        {ok, Value} when is_binary(Value) ->
            case adk_eval_limits:check(Value) of
                ok -> {ok, Acc#{atom_to_binary(Key, utf8) => Value}};
                {error, _} -> {error, {invalid_eval_set_field, Key}}
            end;
        {ok, _} -> {error, {invalid_eval_set_field, Key}}
    end.

validate_cases([], _Schema, _Index, Acc, _Ids) ->
    {ok, lists:reverse(Acc)};
validate_cases([Case | Rest], Schema, Index, Acc, Ids)
  when is_map(Case) ->
    Id = get(Case, id, undefined),
    Metadata = get(Case, metadata, #{}),
    Turns0 = case find(Case, turns) of
        {ok, RawTurns} -> RawTurns;
        error -> single_turn(Case)
    end,
    case {valid_nonempty_binary(Id), maps:is_key(Id, Ids),
          safe_metadata(Metadata), is_list(Turns0),
          is_list(Turns0) andalso
              bounded_length(Turns0, ?MAX_TURNS_PER_CASE)} of
        {true, false, {ok, SafeMetadata}, true, true} ->
            case validate_turns(Turns0, Schema, Id, 0, [], #{}) of
                {ok, []} -> {error, {eval_case_has_no_turns, Id}};
                {ok, ValidatedTurns} ->
                    Base = #{<<"id">> => Id,
                             <<"turns">> => ValidatedTurns,
                             <<"metadata">> => SafeMetadata},
                    case preserve_case_v2_fields(Case, Schema, Base) of
                        {ok, SafeCase} ->
                            validate_cases(Rest, Schema, Index + 1,
                                           [SafeCase | Acc],
                                           Ids#{Id => true});
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {false, _, _, _, _} -> {error, {invalid_eval_case_id, Index}};
        {_, true, _, _, _} -> {error, {duplicate_eval_case_id, Id}};
        {_, _, {error, _}, _, _} ->
            {error, {invalid_eval_case_metadata, Id}};
        {_, _, _, false, _} -> {error, {invalid_eval_case_turns, Id}};
        {_, _, _, _, false} -> {error, {eval_case_turn_limit_exceeded, Id}}
    end;
validate_cases([_ | _], _Schema, Index, _Acc, _Ids) ->
    {error, {invalid_eval_case, Index}};
validate_cases(_Improper, _Schema, Index, _Acc, _Ids) ->
    {error, {invalid_eval_case_list, Index}}.

preserve_case_v2_fields(_Case, ?LEGACY_SET_VERSION, Base) ->
    {ok, Base};
preserve_case_v2_fields(Case, ?SET_VERSION, Base) ->
    preserve_json_fields(
      Case,
      [session_input, expected_trajectory, expected_final_response],
      Base).

preserve_json_fields(_Source, [], Acc) -> {ok, Acc};
preserve_json_fields(Source, [Key | Rest], Acc) ->
    case find(Source, Key) of
        error -> preserve_json_fields(Source, Rest, Acc);
        {ok, Value} ->
            case safe_json(Value) of
                {ok, Safe} ->
                    preserve_json_fields(
                      Source, Rest,
                      Acc#{atom_to_binary(Key, utf8) => Safe});
                {error, _} ->
                    {error, {invalid_eval_field, Key}}
            end
    end.

single_turn(Case) ->
    case find(Case, input) of
        {ok, Input} ->
            [#{id => <<"turn-1">>, input => Input,
               expected => get(Case, expected, null), metadata => #{}}];
        error -> invalid_turns
    end.

validate_turns([], _Schema, _CaseId, _Index, Acc, _Ids) ->
    {ok, lists:reverse(Acc)};
validate_turns([Turn | Rest], Schema, CaseId, Index, Acc, Ids)
  when is_map(Turn) ->
    DefaultId = iolist_to_binary([<<"turn-">>,
                                  integer_to_binary(Index + 1)]),
    Id = get(Turn, id, DefaultId),
    Input = get(Turn, input, undefined),
    Metadata = get(Turn, metadata, #{}),
    {ok, Expected} = canonical_expected(Turn, Schema),
    case {valid_nonempty_binary(Id), maps:is_key(Id, Ids),
          Input =/= undefined, safe_json(Input),
          safe_json(Expected), safe_metadata(Metadata)} of
        {true, false, true, {ok, SafeInput}, {ok, SafeExpected},
         {ok, SafeMetadata}} ->
            SafeTurn = #{<<"id">> => Id, <<"input">> => SafeInput,
                         <<"expected">> => SafeExpected,
                         <<"metadata">> => SafeMetadata},
            validate_turns(Rest, Schema, CaseId, Index + 1,
                           [SafeTurn | Acc], Ids#{Id => true});
        {false, _, _, _, _, _} ->
            {error, {invalid_eval_turn_id, CaseId, Index}};
        {_, true, _, _, _, _} ->
            {error, {duplicate_eval_turn_id, CaseId, Id}};
        {_, _, false, _, _, _} ->
            {error, {missing_eval_turn_input, CaseId, Id}};
        _ ->
            {error, {invalid_eval_turn, CaseId, Id}}
    end;
validate_turns([_ | _], _Schema, CaseId, Index, _Acc, _Ids) ->
    {error, {invalid_eval_turn, CaseId, Index}};
validate_turns(_Improper, _Schema, CaseId, Index, _Acc, _Ids) ->
    {error, {invalid_eval_turn_list, CaseId, Index}}.

canonical_expected(Turn, ?LEGACY_SET_VERSION) ->
    {ok, get(Turn, expected, null)};
canonical_expected(Turn, ?SET_VERSION) ->
    Legacy = get(Turn, expected, null),
    Explicit = [{response, find(Turn, expected_response)},
                {trajectory, find(Turn, expected_trajectory)},
                {intermediate_responses,
                 find(Turn, expected_intermediate_responses)}],
    case lists:any(fun({_Key, Found}) -> Found =/= error end, Explicit) of
        false -> {ok, Legacy};
        true ->
            Base = case Legacy of
                Map when is_map(Map) -> Map;
                null -> #{};
                Value -> #{response => Value}
            end,
            {ok, lists:foldl(
                   fun({_Key, error}, Acc) -> Acc;
                      ({Key, {ok, Value}}, Acc) -> Acc#{Key => Value}
                   end, Base, Explicit)}
    end.

%% ------------------------------------------------------------------
%% Adapter, criteria, and option validation
%% ------------------------------------------------------------------

validate_adapter(Adapter) ->
    Module = get(Adapter, module, undefined),
    Target = get(Adapter, target, undefined),
    Config = get(Adapter, config, #{}),
    case {is_atom(Module), Target =/= undefined, is_map(Config)} of
        {true, true, true} ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, run_turn, 5) of
                        true ->
                            {ok, #{module => Module, target => Target,
                                   config => Config,
                                   init_case =>
                                       erlang:function_exported(
                                         Module, init_case, 4),
                                   terminate_case =>
                                       erlang:function_exported(
                                         Module, terminate_case, 3)}};
                        false -> {error, eval_adapter_missing_callback}
                    end;
                _ -> {error, eval_adapter_unavailable}
            end;
        _ -> {error, invalid_eval_adapter}
    end.

validate_metrics(Metrics) ->
    validate_metrics(Metrics, 0, [], #{}).

validate_metrics([], _Index, Acc, _Ids) -> {ok, lists:reverse(Acc)};
validate_metrics([Metric | Rest], Index, Acc, Ids) when is_map(Metric) ->
    Id = get(Metric, id, undefined),
    Config = get(Metric, config, #{}),
    Kind = get(Metric, kind, metric),
    Threshold = get(Metric, threshold, 1.0),
    case {valid_nonempty_binary(Id), maps:is_key(Id, Ids),
          is_map(Config), valid_metric_kind(Kind),
          valid_score(Threshold)} of
        {true, false, true, true, true} ->
            case compile_metric(Metric, Id, Kind, Threshold, Config) of
                {ok, Compiled} ->
                    validate_metrics(Rest, Index + 1,
                                     [Compiled | Acc], Ids#{Id => true});
                {error, Reason} ->
                    {error, {invalid_eval_metric, Id, Reason}}
            end;
        {false, _, _, _, _} -> {error, {invalid_eval_metric_id, Index}};
        {_, true, _, _, _} -> {error, {duplicate_eval_metric_id, Id}};
        _ -> {error, {invalid_eval_metric, Id}}
    end;
validate_metrics([_ | _], Index, _Acc, _Ids) ->
    {error, {invalid_eval_metric, Index}};
validate_metrics(_Improper, Index, _Acc, _Ids) ->
    {error, {invalid_eval_metric_list, Index}}.

compile_metric(Metric, Id, Kind, Threshold, Config) ->
    case find(Metric, criterion) of
        {ok, Criterion} ->
            CriterionConfig = Config#{criterion => Criterion},
            case adk_eval_criteria:validate_config(CriterionConfig) of
                ok ->
                    {ok, #{id => Id, kind => Kind,
                           threshold => Threshold, scope => 'case',
                           source => builtin, module => adk_eval_criteria,
                           config => CriterionConfig}};
                {error, Reason} -> {error, Reason}
            end;
        error ->
            compile_module_metric(Metric, Id, Kind, Threshold, Config)
    end.

compile_module_metric(Metric, Id, Kind, Threshold, Config) ->
    Module = get(Metric, module, undefined),
    Scope = get(Metric, scope, turn),
    case {is_atom(Module), valid_metric_scope(Scope)} of
        {true, true} ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    Callback = case Scope of
                        turn -> erlang:function_exported(Module, score, 4);
                        'case' -> erlang:function_exported(
                                  Module, score_case, 2)
                    end,
                    case Callback of
                        true ->
                            {ok, #{id => Id, module => Module,
                                   config => Config, kind => Kind,
                                   threshold => Threshold, scope => Scope,
                                   source => module}};
                        false -> {error, missing_callback}
                    end;
                _ -> {error, module_unavailable}
            end;
        _ -> {error, invalid_module_or_scope}
    end.

validate_options(Opts) ->
    Concurrency = get(Opts, concurrency, 1),
    SampleConcurrency = get(Opts, sample_concurrency, Concurrency),
    SampleCount = case find(Opts, sample_count) of
        {ok, Value} -> Value;
        error -> get(Opts, samples, 1)
    end,
    Timeout = get(Opts, timeout_ms, ?DEFAULT_TIMEOUT_MS),
    CaseTimeout = get(Opts, case_timeout_ms, ?DEFAULT_CASE_TIMEOUT_MS),
    Heap = get(Opts, max_heap_words, ?DEFAULT_MAX_HEAP_WORDS),
    PassRate = get(Opts, pass_rate_threshold, 1.0),
    SamplePassRate = get(Opts, sample_pass_rate_threshold, 1.0),
    MinimumSuccessful = get(Opts, min_successful_samples, SampleCount),
    CaptureEvents = get(Opts, capture_events, true),
    CaptureTool = get(Opts, capture_tool_content, false),
    EmptyCriteria = get(Opts, empty_criteria, error),
    MaxReportBytes = get(Opts, max_report_bytes,
                         ?DEFAULT_MAX_REPORT_BYTES),
    FinalizeHeap = get(Opts, finalize_max_heap_words,
                       ?DEFAULT_FINALIZE_MAX_HEAP_WORDS),
    ResultMetadata = get(Opts, result_metadata, #{}),
    case {positive_integer(Concurrency) andalso
              Concurrency =< ?MAX_CONCURRENCY,
          positive_integer(SampleConcurrency) andalso
              SampleConcurrency =< ?MAX_CONCURRENCY,
          positive_integer(SampleCount) andalso SampleCount =< ?MAX_SAMPLES,
          positive_integer(Timeout) andalso Timeout =< ?MAX_TIMEOUT_MS,
          positive_integer(CaseTimeout) andalso
              CaseTimeout =< ?MAX_TIMEOUT_MS,
          is_integer(Heap) andalso Heap >= 1000 andalso
              Heap =< ?MAX_SAMPLE_HEAP_WORDS,
          valid_score(PassRate), valid_score(SamplePassRate),
          is_integer(MinimumSuccessful) andalso MinimumSuccessful > 0
              andalso MinimumSuccessful =< SampleCount,
          is_boolean(CaptureEvents), is_boolean(CaptureTool),
          valid_empty_policy(EmptyCriteria),
          positive_integer(MaxReportBytes) andalso
              MaxReportBytes =< ?DEFAULT_MAX_REPORT_BYTES,
          is_integer(FinalizeHeap) andalso FinalizeHeap >= 1000 andalso
              FinalizeHeap =< ?MAX_FINALIZE_HEAP_WORDS,
          safe_metadata(ResultMetadata)} of
        {true, true, true, true, true, true, true, true, true,
         true, true, true, true, true, {ok, SafeMetadata}} ->
            {ok, #{concurrency => Concurrency,
                   sample_concurrency => SampleConcurrency,
                   sample_count => SampleCount,
                   timeout_ms => Timeout,
                   case_timeout_ms => CaseTimeout,
                   max_heap_words => Heap,
                   pass_rate_threshold => PassRate,
                   sample_pass_rate_threshold => SamplePassRate,
                   min_successful_samples => MinimumSuccessful,
                   capture_events => CaptureEvents,
                   capture_tool_content => CaptureTool,
                   empty_criteria => EmptyCriteria,
                   max_report_bytes => MaxReportBytes,
                   finalize_max_heap_words => FinalizeHeap,
                   result_metadata => SafeMetadata}};
        _ -> {error, invalid_eval_options}
    end.

validate_empty_criteria([], #{empty_criteria := error}) ->
    {error, empty_eval_criteria};
validate_empty_criteria(_, _) -> ok.

%% ------------------------------------------------------------------
%% Repeated-sample execution
%% ------------------------------------------------------------------

run_validated(Adapter, Set, Metrics, Opts) ->
    Started = erlang:monotonic_time(millisecond),
    Deadline = Started + maps:get(timeout_ms, Opts),
    Cases = maps:get(<<"cases">>, Set),
    SampleCount = maps:get(sample_count, Opts),
    TotalSamples = length(Cases) * SampleCount,
    case TotalSamples =< ?MAX_TOTAL_SAMPLES of
        false ->
            {error, {eval_sample_limit_exceeded, TotalSamples,
                     ?MAX_TOTAL_SAMPLES}};
        true ->
            Specs = sample_specs(Set, Cases, SampleCount),
            ReportBudget = initial_report_budget(
                             Cases, Metrics,
                             maps:get(max_report_bytes, Opts)),
            case run_sample_batches(
                   Specs, Adapter, Metrics, Opts, Deadline, [],
                   ReportBudget) of
                {ok, SampleResults, _BudgetLeft} ->
                    bounded_finalize(
                      fun() ->
                          finalize_result(Set, Cases, Metrics, SampleResults,
                                          Started, Opts)
                      end,
                      Deadline,
                      maps:get(finalize_max_heap_words, Opts));
                {error, _} = Error -> Error
            end
    end.

finalize_result(Set, Cases, Metrics, SampleResults, Started, Opts) ->
    Results = aggregate_cases(Cases, SampleResults, Opts, []),
    Duration = elapsed_ms(Started),
    Summary = summarize(Set, Metrics, Results, Duration, Opts),
    case adk_eval_limits:check(
           Summary,
           #{max_external_bytes => maps:get(max_report_bytes, Opts)}) of
        ok -> encode_result(Summary);
        {error, Reason} ->
            {error, {eval_report_too_large, reason_tag(Reason)}}
    end.

initial_report_budget(Cases, Metrics, MaxBytes) ->
    %% Each sample is retained below its case aggregate and the first sample's
    %% public fields are projected once more into that aggregate. Charging two
    %% external encodings per completed sample is intentionally conservative;
    %% the fixed/case/metric reserve covers the summary maps built afterwards.
    Reserve = ?REPORT_FIXED_RESERVE_BYTES +
              (length(Cases) * 1024) + (length(Metrics) * 512),
    erlang:max(0, MaxBytes - Reserve).

sample_specs(Set, Cases, SampleCount) ->
    Indexed = lists:zip(lists:seq(0, length(Cases) - 1), Cases),
    [#{eval_case => Case, case_index => CaseIndex,
       sample_index => SampleIndex,
       sample_id => sample_id(Set, Case, SampleIndex)}
     || SampleIndex <- lists:seq(0, SampleCount - 1),
        {CaseIndex, Case} <- Indexed].

sample_id(Set, Case, SampleIndex) ->
    Identity = [maps:get(<<"id">>, Set), 0,
                maps:get(<<"version">>, Set), 0,
                maps:get(<<"id">>, Case), 0,
                integer_to_binary(SampleIndex)],
    <<Prefix:12/binary, _/binary>> =
        crypto:hash(sha256, iolist_to_binary(Identity)),
    <<"sample-", (hex_binary(Prefix))/binary>>.

run_sample_batches([], _Adapter, _Metrics, _Opts, _Deadline, Acc,
                   BudgetLeft) ->
    {ok, lists:append(lists:reverse(Acc)), BudgetLeft};
run_sample_batches(Specs, Adapter, Metrics, Opts, Deadline, Acc,
                   BudgetLeft) ->
    Limit = erlang:min(maps:get(concurrency, Opts),
                       maps:get(sample_concurrency, Opts)),
    Count = erlang:min(Limit, length(Specs)),
    {Batch, Rest} = lists:split(Count, Specs),
    case remaining(Deadline) of
        0 ->
            TimedOut = [sample_failure(Spec, timeout, 0)
                        || Spec <- Specs],
            case charge_sample_results(TimedOut, BudgetLeft) of
                {ok, RemainingBudget} ->
                    {ok, lists:append(lists:reverse([TimedOut | Acc])),
                     RemainingBudget};
                {error, _} = Error -> Error
            end;
        _ ->
            Jobs = start_sample_jobs(Batch, Adapter, Metrics, Opts,
                                     Deadline, []),
            BatchResults = [collect_sample_job(Job) || Job <- Jobs],
            case charge_sample_results(BatchResults, BudgetLeft) of
                {ok, RemainingBudget} ->
                    run_sample_batches(
                      Rest, Adapter, Metrics, Opts, Deadline,
                      [BatchResults | Acc], RemainingBudget);
                {error, _} = Error -> Error
            end
    end.

charge_sample_results([], BudgetLeft) -> {ok, BudgetLeft};
charge_sample_results([Result | Rest], BudgetLeft) ->
    case safe_external_size(Result) of
        {ok, Bytes} ->
            Charge = (Bytes * 2) + 256,
            case Charge =< BudgetLeft of
                true -> charge_sample_results(Rest, BudgetLeft - Charge);
                false -> {error, eval_report_budget_exceeded}
            end;
        error -> {error, eval_report_budget_exceeded}
    end.

start_sample_jobs([], _Adapter, _Metrics, _Opts, _Deadline, Acc) ->
    lists:reverse(Acc);
start_sample_jobs([Spec | Rest], Adapter, Metrics, Opts, Deadline, Acc) ->
    Owner = self(),
    Alias = erlang:alias([reply]),
    Started = erlang:monotonic_time(millisecond),
    SampleDeadline = erlang:min(
                       Deadline,
                       Started + maps:get(case_timeout_ms, Opts)),
    Worker = fun() ->
        Result = try evaluate_sample(Spec, Adapter, Metrics, Opts,
                                     SampleDeadline, Started) of
            Value -> Value
        catch
            _:_ -> sample_failure(Spec, worker_exception,
                                  elapsed_ms(Started))
        end,
        Completed = erlang:monotonic_time(millisecond),
        Alias ! {adk_eval_sample_reply, Alias, self(), Completed, Result}
    end,
    {Pid, Monitor} = spawn_opt(
                       Worker,
                       [monitor, {message_queue_data, off_heap},
                        {max_heap_size,
                         #{size => maps:get(max_heap_words, Opts),
                           kill => true, error_logger => false}}]),
    Watcher = spawn(fun() -> owner_watcher(Owner, Pid) end),
    Job = #{pid => Pid, monitor => Monitor, alias => Alias,
            watcher => Watcher, sample_spec => Spec,
            started => Started, deadline => SampleDeadline},
    start_sample_jobs(Rest, Adapter, Metrics, Opts, Deadline, [Job | Acc]).

owner_watcher(Owner, Worker) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, Worker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _} ->
            exit(Worker, kill),
            erlang:demonitor(WorkerMonitor, [flush]);
        {'DOWN', WorkerMonitor, process, Worker, _} ->
            erlang:demonitor(OwnerMonitor, [flush]);
        stop ->
            erlang:demonitor(OwnerMonitor, [flush]),
            erlang:demonitor(WorkerMonitor, [flush])
    end.

collect_sample_job(Job) ->
    Pid = maps:get(pid, Job),
    Monitor = maps:get(monitor, Job),
    Alias = maps:get(alias, Job),
    Spec = maps:get(sample_spec, Job),
    Started = maps:get(started, Job),
    Deadline = maps:get(deadline, Job),
    receive
        {adk_eval_sample_reply, Alias, Pid, Completed, Result} ->
            _ = erlang:unalias(Alias),
            stop_watcher(Job),
            erlang:demonitor(Monitor, [flush]),
            case Completed =< Deadline of
                true -> Result;
                false -> sample_failure(Spec, timeout,
                                        elapsed_ms(Started))
            end;
        {'DOWN', Monitor, process, Pid, _} ->
            _ = erlang:unalias(Alias),
            stop_watcher(Job),
            sample_failure(Spec, worker_down, elapsed_ms(Started))
    after remaining(Deadline) ->
        _ = erlang:unalias(Alias),
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 100 -> erlang:demonitor(Monitor, [flush])
        end,
        stop_watcher(Job),
        sample_failure(Spec, timeout, elapsed_ms(Started))
    end.

stop_watcher(Job) ->
    maps:get(watcher, Job) ! stop,
    ok.

evaluate_sample(Spec, Adapter, Metrics, Opts, Deadline, Started) ->
    Case = maps:get(eval_case, Spec),
    CaseIndex = maps:get(case_index, Spec),
    SampleIndex = maps:get(sample_index, Spec),
    SampleId = maps:get(sample_id, Spec),
    Context0 = #{<<"case_id">> => maps:get(<<"id">>, Case),
                 <<"case_index">> => CaseIndex,
                 <<"sample_id">> => SampleId,
                 <<"sample_index">> => SampleIndex},
    case adapter_init(Adapter, Case, Context0) of
        {error, Reason} ->
            sample_failure(Spec, Reason, elapsed_ms(Started));
        {ok, CaseTarget, InitialState} ->
            {RawResult, FinalState} =
                evaluate_sample_body(Case, CaseTarget, InitialState,
                                     Context0, Adapter, Metrics, Opts,
                                     Deadline, Started),
            case adapter_terminate(Adapter, CaseTarget, FinalState) of
                ok ->
                    RawResult#{<<"sample_id">> => SampleId,
                               <<"sample_index">> => SampleIndex};
                {error, Reason} ->
                    RawResult#{<<"sample_id">> => SampleId,
                               <<"sample_index">> => SampleIndex,
                               <<"status">> => <<"error">>,
                               <<"passed">> => false,
                               <<"error">> =>
                                   atom_to_binary(reason_tag(Reason), utf8)}
            end
    end.

adapter_init(#{init_case := false, target := Target}, _Case, _Context) ->
    {ok, Target, null};
adapter_init(#{module := Module, target := Target, config := Config},
             Case, Context) ->
    try Module:init_case(Target, Case, Context, Config) of
        {ok, CaseTarget, InitialState} ->
            {ok, CaseTarget, InitialState};
        {ok, InitialState} ->
            {ok, Target, InitialState};
        {error, Reason} ->
            {error, reason_tag(Reason)};
        _ ->
            {error, invalid_adapter_init_result}
    catch
        _:_ -> {error, adapter_init_exception}
    end.

adapter_terminate(#{terminate_case := false}, _Target, _State) -> ok;
adapter_terminate(#{module := Module, config := Config}, Target, State) ->
    try Module:terminate_case(Target, State, Config) of
        ok -> ok;
        {error, Reason} -> {error, reason_tag(Reason)};
        _ -> {error, invalid_adapter_terminate_result}
    catch
        _:_ -> {error, adapter_terminate_exception}
    end.

evaluate_sample_body(Case, Target, InitialState, Context0, Adapter,
                     Metrics, Opts, Deadline, Started) ->
    TurnMetrics = [M || M <- Metrics, maps:get(scope, M) =:= turn],
    CaseMetrics = [M || M <- Metrics, maps:get(scope, M) =:= 'case'],
    Turns = maps:get(<<"turns">>, Case),
    case evaluate_turns(Turns, 0, InitialState, Context0, Target,
                        Adapter, TurnMetrics, Opts, Deadline,
                        [], [], []) of
        {ok, TurnResults, FullTrajectory, PublicTrajectory, FinalState} ->
            EvalInput = #{<<"eval_case">> => Case,
                          <<"turns">> => TurnResults,
                          <<"trajectory">> => FullTrajectory,
                          <<"context">> => Context0},
            Criteria = score_case_metrics(CaseMetrics, EvalInput, []),
            TurnPassed = lists:all(
                           fun(Turn) -> maps:get(<<"passed">>, Turn) end,
                           TurnResults),
            CriteriaPassed = lists:all(
                               fun(Criterion) ->
                                   maps:get(<<"passed">>, Criterion)
                               end, Criteria),
            Passed = TurnPassed andalso CriteriaPassed,
            {#{<<"case_id">> => maps:get(<<"id">>, Case),
               <<"status">> => status_binary(Passed),
               <<"passed">> => Passed,
               <<"duration_ms">> => elapsed_ms(Started),
               <<"turns">> => TurnResults,
               <<"trajectory">> => PublicTrajectory,
               <<"criteria">> => Criteria,
               <<"metadata">> => maps:get(<<"metadata">>, Case)},
             FinalState};
        {error, Reason, TurnResults, FullTrajectory, PublicTrajectory,
         FinalState} ->
            _ = FullTrajectory,
            {#{<<"case_id">> => maps:get(<<"id">>, Case),
               <<"status">> => <<"error">>, <<"passed">> => false,
               <<"duration_ms">> => elapsed_ms(Started),
               <<"turns">> => TurnResults,
               <<"trajectory">> => PublicTrajectory,
               <<"criteria">> => [],
               <<"metadata">> => maps:get(<<"metadata">>, Case),
               <<"error">> => atom_to_binary(reason_tag(Reason), utf8)},
             FinalState}
    end.

evaluate_turns([], _Index, State, _CaseContext, _Target, _Adapter,
               _Metrics, _Opts, _Deadline, TurnAcc, FullAcc, PublicAcc) ->
    {ok, lists:reverse(TurnAcc),
     lists:append(lists:reverse(FullAcc)),
     lists:append(lists:reverse(PublicAcc)), State};
evaluate_turns([Turn | Rest], Index, State0, CaseContext, Target,
               Adapter, Metrics, Opts, Deadline,
               TurnAcc, FullAcc, PublicAcc) ->
    case remaining(Deadline) of
        0 ->
            {error, timeout, lists:reverse(TurnAcc),
             lists:append(lists:reverse(FullAcc)),
             lists:append(lists:reverse(PublicAcc)), State0};
        _ ->
            Context0 = CaseContext#{
                <<"turn_id">> => maps:get(<<"id">>, Turn),
                <<"turn_index">> => Index
            },
            case call_adapter(Adapter, Target, Turn, State0, Context0) of
                {ok, Actual, Events, State1, AdapterMetadata} ->
                    TurnId = maps:get(<<"id">>, Turn),
                    FullTrajectory = event_trajectory(
                                       Events, TurnId,
                                       Opts#{capture_tool_content => true}),
                    PublicTrajectory = event_trajectory(
                                         Events, TurnId, Opts),
                    Context = Context0#{
                        <<"trajectory">> => FullTrajectory
                    },
                    MetricResults = score_turn_metrics(
                                      Metrics,
                                      maps:get(<<"expected">>, Turn),
                                      Actual, Context, []),
                    Passed = lists:all(
                               fun(MetricResult) ->
                                   maps:get(<<"passed">>, MetricResult)
                               end, MetricResults),
                    CapturedEvents =
                        case maps:get(capture_events, Opts) of
                            true -> Events;
                            false -> []
                        end,
                    TurnResult = #{
                        <<"turn_id">> => TurnId,
                        <<"input">> => maps:get(<<"input">>, Turn),
                        <<"expected">> => maps:get(<<"expected">>, Turn),
                        <<"actual">> => Actual,
                        <<"passed">> => Passed,
                        <<"metrics">> => MetricResults,
                        <<"events">> => CapturedEvents,
                        <<"trajectory">> => PublicTrajectory,
                        <<"metadata">> => maps:get(<<"metadata">>, Turn),
                        <<"adapter_metadata">> => AdapterMetadata
                    },
                    evaluate_turns(Rest, Index + 1, State1, CaseContext,
                                   Target, Adapter, Metrics, Opts, Deadline,
                                   [TurnResult | TurnAcc],
                                   [FullTrajectory | FullAcc],
                                   [PublicTrajectory | PublicAcc]);
                {error, Reason} ->
                    {error, Reason, lists:reverse(TurnAcc),
                     lists:append(lists:reverse(FullAcc)),
                     lists:append(lists:reverse(PublicAcc)), State0}
            end
    end.

call_adapter(Adapter, Target, Turn, State, Context) ->
    Module = maps:get(module, Adapter),
    Config = maps:get(config, Adapter),
    try Module:run_turn(Target, Turn, State, Context, Config) of
        {ok, Result} when is_map(Result) ->
            normalize_adapter_result(Result);
        {error, Reason} -> {error, reason_tag(Reason)};
        _ -> {error, invalid_adapter_result}
    catch
        _:_ -> {error, adapter_exception}
    end.

normalize_adapter_result(Result) ->
    Output = get(Result, output, undefined),
    Events0 = get(Result, events, []),
    State = get(Result, state, null),
    Metadata0 = get(Result, metadata, #{}),
    case {Output =/= undefined, safe_json(Output),
          normalize_events(Events0, []), safe_metadata(Metadata0)} of
        {true, {ok, Actual}, {ok, Events}, {ok, Metadata}} ->
            {ok, Actual, Events, State, Metadata};
        _ -> {error, invalid_adapter_result}
    end.

normalize_events([], Acc) -> {ok, lists:reverse(Acc)};
normalize_events([Event | Rest], Acc) ->
    case adk_context_guard:sanitize_event(Event) of
        {ok, SafeEvent} ->
            case adk_eval_limits:check(SafeEvent) of
                ok -> normalize_events(Rest, [SafeEvent | Acc]);
                {error, _} -> {error, invalid_adapter_event}
            end;
        {error, _} -> {error, invalid_adapter_event}
    end;
normalize_events(_, _) -> {error, invalid_adapter_events}.

score_turn_metrics([], _Expected, _Actual, _Context, Acc) ->
    lists:reverse(Acc);
score_turn_metrics([Metric | Rest], Expected, Actual, Context, Acc) ->
    Module = maps:get(module, Metric),
    Config = maps:get(config, Metric),
    Raw = try Module:score(Expected, Actual, Context, Config) of
        Value -> Value
    catch
        _:_ -> {error, metric_exception}
    end,
    Result = metric_result(Metric, Raw),
    score_turn_metrics(Rest, Expected, Actual, Context,
                       [Result | Acc]).

score_case_metrics([], _Input, Acc) -> lists:reverse(Acc);
score_case_metrics([Metric | Rest], Input, Acc) ->
    Module = maps:get(module, Metric),
    Config = maps:get(config, Metric),
    Raw = try Module:score_case(Input, Config) of
        Value -> Value
    catch
        _:_ -> {error, metric_exception}
    end,
    Result = metric_result(Metric, Raw),
    score_case_metrics(Rest, Input, [Result | Acc]).

metric_result(Metric, Raw) ->
    {Score, Status, Metadata} = normalize_metric_score(Raw),
    Threshold = maps:get(threshold, Metric),
    Passed = Status =:= ok andalso Score >= Threshold,
    #{<<"metric_id">> => maps:get(id, Metric),
      <<"kind">> => atom_to_binary(maps:get(kind, Metric), utf8),
      <<"scope">> => atom_to_binary(maps:get(scope, Metric), utf8),
      <<"score">> => Score,
      <<"threshold">> => Threshold,
      <<"passed">> => Passed,
      <<"status">> => atom_to_binary(Status, utf8),
      <<"metadata">> => Metadata}.

normalize_metric_score(Score) when is_number(Score) ->
    normalize_metric_score({ok, Score, #{}});
normalize_metric_score({ok, Score}) ->
    normalize_metric_score({ok, Score, #{}});
normalize_metric_score({ok, Score, Metadata}) ->
    case {valid_score(Score), safe_metadata(Metadata)} of
        {true, {ok, SafeMetadata}} -> {Score, ok, SafeMetadata};
        _ -> {0.0, error, #{}}
    end;
normalize_metric_score({not_evaluated, Metadata}) ->
    case safe_metadata(Metadata) of
        {ok, SafeMetadata} -> {0.0, not_evaluated, SafeMetadata};
        _ -> {0.0, error, #{}}
    end;
normalize_metric_score({error, _}) -> {0.0, error, #{}};
normalize_metric_score(_) -> {0.0, error, #{}}.

event_trajectory(Events, TurnId, Opts) ->
    lists:append([event_trajectory_item(Event, TurnId, Opts)
                  || Event <- Events]).

event_trajectory_item(Event, TurnId, Opts) ->
    Content = maps:get(<<"content">>, Event, #{}),
    case maps:get(<<"type">>, Content, undefined) of
        <<"tool_calls">> ->
            [tool_call_trajectory(Call, TurnId, Opts)
             || Call <- maps:get(<<"calls">>, Content, [])];
        <<"tool_response">> ->
            [tool_response_trajectory(Content, TurnId, Opts)];
        _ -> []
    end.

tool_call_trajectory(Call, TurnId, Opts) ->
    Base = #{<<"turn_id">> => TurnId,
             <<"kind">> => <<"tool_call">>,
             <<"tool">> => maps:get(<<"name">>, Call),
             <<"call_id">> => maps:get(<<"call_id">>, Call, null)},
    case maps:get(capture_tool_content, Opts) of
        true -> Base#{<<"args">> => maps:get(<<"args">>, Call, #{})};
        false -> Base
    end.

tool_response_trajectory(Content, TurnId, Opts) ->
    Base = #{<<"turn_id">> => TurnId,
             <<"kind">> => <<"tool_response">>,
             <<"tool">> => maps:get(<<"name">>, Content),
             <<"call_id">> => maps:get(<<"call_id">>, Content, null)},
    case maps:get(capture_tool_content, Opts) of
        true ->
            Base#{<<"result">> => maps:get(<<"result">>, Content, null)};
        false -> Base
    end.

sample_failure(Spec, Reason, Duration) ->
    Case = maps:get(eval_case, Spec),
    #{<<"case_id">> => maps:get(<<"id">>, Case),
      <<"sample_id">> => maps:get(sample_id, Spec),
      <<"sample_index">> => maps:get(sample_index, Spec),
      <<"status">> => <<"error">>, <<"passed">> => false,
      <<"duration_ms">> => Duration, <<"turns">> => [],
      <<"trajectory">> => [], <<"criteria">> => [],
      <<"metadata">> => maps:get(<<"metadata">>, Case, #{}),
      <<"error">> => atom_to_binary(reason_tag(Reason), utf8)}.

%% ------------------------------------------------------------------
%% Aggregation and strict result codec
%% ------------------------------------------------------------------

aggregate_cases([], _Samples, _Opts, Acc) -> lists:reverse(Acc);
aggregate_cases([Case | Rest], Samples, Opts, Acc) ->
    CaseId = maps:get(<<"id">>, Case),
    CaseSamples = [Sample || Sample <- Samples,
                             maps:get(<<"case_id">>, Sample) =:= CaseId],
    Aggregate = aggregate_case(Case, CaseSamples, Opts),
    aggregate_cases(Rest, Samples, Opts, [Aggregate | Acc]).

aggregate_case(Case, Samples, Opts) ->
    Successful = [Sample || Sample <- Samples,
                            maps:get(<<"status">>, Sample) =/= <<"error">>],
    PassedSamples = [Sample || Sample <- Successful,
                               maps:get(<<"passed">>, Sample)],
    SuccessfulCount = length(Successful),
    PassedCount = length(PassedSamples),
    ErrorCount = length(Samples) - SuccessfulCount,
    PassRate = ratio(PassedCount, SuccessfulCount),
    Passed = SuccessfulCount >= maps:get(min_successful_samples, Opts)
        andalso PassRate >= maps:get(sample_pass_rate_threshold, Opts),
    Status = aggregate_status(Passed, SuccessfulCount, ErrorCount),
    Base = case Samples of
        [First | _] -> First;
        [] ->
            #{<<"case_id">> => maps:get(<<"id">>, Case),
              <<"turns">> => [], <<"trajectory">> => [],
              <<"criteria">> => [],
              <<"metadata">> => maps:get(<<"metadata">>, Case)}
    end,
    SampleScores = [case maps:get(<<"passed">>, Sample) of
                        true -> 1.0;
                        false -> 0.0
                    end || Sample <- Successful],
    Base#{<<"status">> => Status,
          <<"passed">> => Passed,
          <<"duration_ms">> =>
              lists:sum([maps:get(<<"duration_ms">>, S) || S <- Samples]),
          <<"criteria">> => aggregate_case_criteria(Samples),
          <<"sample_count">> => length(Samples),
          <<"successful_sample_count">> => SuccessfulCount,
          <<"passed_sample_count">> => PassedCount,
          <<"error_sample_count">> => ErrorCount,
          <<"sample_pass_rate">> => PassRate,
          <<"sample_pass_rate_threshold">> =>
              maps:get(sample_pass_rate_threshold, Opts),
          <<"min_successful_samples">> =>
              maps:get(min_successful_samples, Opts),
          <<"sample_statistics">> => statistics(SampleScores),
          <<"samples">> => Samples}.

aggregate_status(_Passed, 0, _Errors) -> <<"error">>;
aggregate_status(_Passed, _Successful, Errors) when Errors > 0 ->
    <<"partial">>;
aggregate_status(true, _Successful, 0) -> <<"passed">>;
aggregate_status(false, _Successful, 0) -> <<"failed">>.

aggregate_case_criteria(Samples) ->
    Ids = ordered_unique(
            [maps:get(<<"metric_id">>, Result)
             || Sample <- Samples,
                Result <- maps:get(<<"criteria">>, Sample, [])]),
    [aggregate_metric_results(
       Id,
       [Result || Sample <- Samples,
                  Result <- maps:get(<<"criteria">>, Sample, []),
                  maps:get(<<"metric_id">>, Result) =:= Id])
     || Id <- Ids].

aggregate_metric_results(Id, Results) ->
    Ok = [maps:get(<<"score">>, R) || R <- Results,
                                       maps:get(<<"status">>, R) =:= <<"ok">>],
    ErrorCount = length([ok || R <- Results,
                              maps:get(<<"status">>, R) =:= <<"error">>]),
    NotEvaluated = length([ok || R <- Results,
                                maps:get(<<"status">>, R) =:=
                                    <<"not_evaluated">>]),
    First = hd(Results),
    Score = mean(Ok),
    Threshold = maps:get(<<"threshold">>, First),
    Status = case {Ok, ErrorCount, NotEvaluated} of
        {[], 0, _} -> <<"not_evaluated">>;
        {[], _, _} -> <<"error">>;
        {_, 0, 0} -> <<"ok">>;
        _ -> <<"partial">>
    end,
    #{<<"metric_id">> => Id,
      <<"kind">> => maps:get(<<"kind">>, First),
      <<"scope">> => maps:get(<<"scope">>, First),
      <<"score">> => Score,
      <<"threshold">> => Threshold,
      <<"passed">> => Status =:= <<"ok">> andalso Score >= Threshold,
      <<"status">> => Status,
      <<"metadata">> => #{<<"sample_count">> => length(Results),
                           <<"error_count">> => ErrorCount,
                           <<"not_evaluated_count">> => NotEvaluated,
                           <<"statistics">> => statistics(Ok)}}.

summarize(Set, Metrics, Results, Duration, Opts) ->
    Total = length(Results),
    PassedCount = length([ok || Result <- Results,
                               maps:get(<<"passed">>, Result, false)]),
    ErrorCount = length([ok || Result <- Results,
                              maps:get(<<"status">>, Result) =:= <<"error">>]),
    PartialCount = length([ok || Result <- Results,
                                maps:get(<<"status">>, Result) =:=
                                    <<"partial">>]),
    PassRate = ratio(PassedCount, Total),
    Threshold = maps:get(pass_rate_threshold, Opts),
    #{<<"result_schema_version">> => ?RESULT_VERSION,
      <<"eval_set_schema_version">> =>
          maps:get(<<"schema_version">>, Set),
      <<"eval_set_id">> => maps:get(<<"id">>, Set),
      <<"eval_set_version">> => maps:get(<<"version">>, Set),
      <<"passed">> => PassRate >= Threshold,
      <<"pass_rate">> => PassRate,
      <<"pass_rate_threshold">> => Threshold,
      <<"case_count">> => Total,
      <<"passed_case_count">> => PassedCount,
      <<"error_case_count">> => ErrorCount,
      <<"partial_case_count">> => PartialCount,
      <<"sample_count">> => maps:get(sample_count, Opts),
      <<"duration_ms">> => Duration,
      <<"metrics">> => summarize_metrics(Metrics, Results),
      <<"cases">> => Results,
      <<"metadata">> => maps:get(result_metadata, Opts)}.

summarize_metrics(Metrics, Results) ->
    [summarize_metric(Metric, Results) || Metric <- Metrics].

summarize_metric(Metric, Results) ->
    Id = maps:get(id, Metric),
    MetricResults = metric_occurrences(Id, Results),
    OkScores = [maps:get(<<"score">>, Result)
                || Result <- MetricResults,
                   maps:get(<<"status">>, Result) =:= <<"ok">>],
    ErrorCount = length([ok || Result <- MetricResults,
                              maps:get(<<"status">>, Result) =:= <<"error">>]),
    NotEvaluated = length(
                     [ok || Result <- MetricResults,
                            maps:get(<<"status">>, Result) =:=
                                <<"not_evaluated">>]),
    Threshold = maps:get(threshold, Metric),
    Average = mean(OkScores),
    #{<<"metric_id">> => Id,
      <<"kind">> => atom_to_binary(maps:get(kind, Metric), utf8),
      <<"scope">> => atom_to_binary(maps:get(scope, Metric), utf8),
      <<"average_score">> => Average,
      <<"threshold">> => Threshold,
      <<"passed">> => OkScores =/= [] andalso ErrorCount =:= 0
          andalso NotEvaluated =:= 0 andalso Average >= Threshold,
      <<"evaluated_count">> => length(OkScores),
      <<"error_count">> => ErrorCount,
      <<"not_evaluated_count">> => NotEvaluated,
      <<"statistics">> => statistics(OkScores)}.

metric_occurrences(Id, Results) ->
    [MetricResult
     || Case <- Results,
        Sample <- maps:get(<<"samples">>, Case, [Case]),
        MetricResult <- sample_metric_results(Sample),
        maps:get(<<"metric_id">>, MetricResult) =:= Id].

sample_metric_results(Sample) ->
    maps:get(<<"criteria">>, Sample, []) ++
        [MetricResult
         || Turn <- maps:get(<<"turns">>, Sample, []),
            MetricResult <- maps:get(<<"metrics">>, Turn, [])].

encode_result_local(Result) ->
    case adk_eval_limits:check(Result) of
        {error, Reason} ->
            {error, {invalid_eval_result, reason_tag(Reason)}};
        ok ->
            case adk_context_guard:sanitize_value(Result) of
                {ok, Safe} when is_map(Safe) ->
                    validate_saved_result(Safe);
                {ok, _} -> {error, invalid_eval_result};
                {error, Reason} ->
                    {error, {invalid_eval_result, reason_tag(Reason)}}
            end
    end.

validate_saved_result(
  #{<<"result_schema_version">> := ?LEGACY_RESULT_VERSION,
    <<"eval_set_id">> := SetId, <<"eval_set_version">> := SetVersion,
    <<"cases">> := Cases, <<"passed">> := Passed} = Result)
  when is_binary(SetId), is_binary(SetVersion), is_list(Cases),
       is_boolean(Passed) ->
    {ok, Result};
validate_saved_result(
  #{<<"result_schema_version">> := ?RESULT_VERSION} = Result) ->
    case validate_v2_result(Result) of
        ok -> {ok, Result};
        {error, _} = Error -> Error
    end;
validate_saved_result(#{<<"result_schema_version">> := Version}) ->
    {error, {unsupported_eval_result_schema_version, Version}};
validate_saved_result(_) ->
    {error, invalid_eval_result}.

validate_v2_result(Result) ->
    Required = [<<"eval_set_schema_version">>, <<"eval_set_id">>,
                <<"eval_set_version">>, <<"passed">>, <<"pass_rate">>,
                <<"pass_rate_threshold">>, <<"case_count">>,
                <<"passed_case_count">>, <<"error_case_count">>,
                <<"partial_case_count">>, <<"sample_count">>,
                <<"duration_ms">>, <<"metrics">>, <<"cases">>,
                <<"metadata">>],
    case lists:all(fun(Key) -> maps:is_key(Key, Result) end, Required) of
        false -> {error, invalid_eval_result};
        true ->
            Cases = maps:get(<<"cases">>, Result),
            Metrics = maps:get(<<"metrics">>, Result),
            Count = maps:get(<<"case_count">>, Result),
            PassedCount = maps:get(<<"passed_case_count">>, Result),
            PassRate = maps:get(<<"pass_rate">>, Result),
            Threshold = maps:get(<<"pass_rate_threshold">>, Result),
            Passed = maps:get(<<"passed">>, Result),
            ErrorCount = maps:get(<<"error_case_count">>, Result),
            PartialCount = maps:get(<<"partial_case_count">>, Result),
            SamplesPerCase = maps:get(<<"sample_count">>, Result),
            Duration = maps:get(<<"duration_ms">>, Result),
            Basic =
                is_binary(maps:get(<<"eval_set_id">>, Result))
                    andalso
                is_binary(maps:get(<<"eval_set_version">>, Result))
                    andalso
                nonnegative_integer(Count)
                    andalso
                is_list(Cases)
                    andalso
                is_list(Metrics)
                    andalso
                Count =:= length(Cases)
                    andalso
                nonnegative_integer(PassedCount)
                    andalso
                PassedCount =< Count
                    andalso
                nonnegative_integer(ErrorCount)
                    andalso
                nonnegative_integer(PartialCount)
                    andalso
                positive_integer(SamplesPerCase)
                    andalso
                nonnegative_integer(Duration)
                    andalso
                valid_score(PassRate)
                    andalso
                valid_score(Threshold)
                    andalso
                is_boolean(Passed)
                    andalso
                is_map(maps:get(<<"metadata">>, Result)),
            case Basic of
                true ->
                    ExpectedRate = ratio(PassedCount, Count),
                    ActualPassed = length(
                                     [ok || Case <- Cases,
                                            maps:get(<<"passed">>, Case,
                                                     false)]),
                    ActualErrors = length(
                                     [ok || Case <- Cases,
                                            maps:get(<<"status">>, Case,
                                                     invalid) =:= <<"error">>]),
                    ActualPartial = length(
                                      [ok || Case <- Cases,
                                             maps:get(<<"status">>, Case,
                                                      invalid) =:=
                                                 <<"partial">>]),
                    case near(PassRate, ExpectedRate)
                         andalso Passed =:= (PassRate >= Threshold)
                         andalso PassedCount =:= ActualPassed
                         andalso ErrorCount =:= ActualErrors
                         andalso PartialCount =:= ActualPartial
                         andalso lists:all(
                                   fun(Case) ->
                                       maps:get(<<"sample_count">>, Case,
                                                invalid) =:= SamplesPerCase
                                   end, Cases)
                         andalso valid_case_results(Cases)
                         andalso valid_summary_metrics(Metrics) of
                        true -> ok;
                        false -> {error, invalid_eval_result}
                    end;
                false -> {error, invalid_eval_result}
            end
    end.

valid_case_results(Cases) ->
    lists:all(fun valid_case_result/1, Cases).

valid_case_result(Case) when is_map(Case) ->
    Samples = maps:get(<<"samples">>, Case, invalid),
    SampleCount = maps:get(<<"sample_count">>, Case, invalid),
    Successful = maps:get(<<"successful_sample_count">>, Case, invalid),
    PassedCount = maps:get(<<"passed_sample_count">>, Case, invalid),
    ErrorCount = maps:get(<<"error_sample_count">>, Case, invalid),
    PassRate = maps:get(<<"sample_pass_rate">>, Case, invalid),
    PassThreshold = maps:get(
                      <<"sample_pass_rate_threshold">>, Case, invalid),
    MinimumSuccessful = maps:get(
                          <<"min_successful_samples">>, Case, invalid),
    Passed = maps:get(<<"passed">>, Case, invalid),
    Status = maps:get(<<"status">>, Case, invalid),
    Basic =
        valid_nonempty_binary(maps:get(<<"case_id">>, Case, undefined))
            andalso
        valid_status(Status)
            andalso
        is_boolean(Passed)
            andalso
        nonnegative_integer(maps:get(<<"duration_ms">>, Case, invalid))
            andalso
        is_list(maps:get(<<"turns">>, Case, invalid))
            andalso
        is_list(maps:get(<<"trajectory">>, Case, invalid))
            andalso
        is_list(maps:get(<<"criteria">>, Case, invalid))
            andalso
        is_map(maps:get(<<"metadata">>, Case, invalid))
            andalso
        is_list(Samples)
            andalso
        nonnegative_integer(SampleCount)
            andalso
        SampleCount =:= length(Samples)
            andalso
        nonnegative_integer(Successful)
            andalso
        nonnegative_integer(PassedCount)
            andalso
        nonnegative_integer(ErrorCount)
            andalso
        Successful + ErrorCount =:= SampleCount
            andalso
        PassedCount =< Successful
            andalso
        valid_score(PassRate)
            andalso
        valid_score(PassThreshold)
            andalso
        positive_integer(MinimumSuccessful)
            andalso
        MinimumSuccessful =< SampleCount,
    Basic
        andalso near(PassRate, ratio(PassedCount, Successful))
        andalso Passed =:=
            (Successful >= MinimumSuccessful andalso
             PassRate >= PassThreshold)
        andalso Status =:= aggregate_status(Passed, Successful, ErrorCount)
        andalso lists:all(fun valid_sample_result/1, Samples);
valid_case_result(_) -> false.

valid_sample_result(Sample) when is_map(Sample) ->
    Status = maps:get(<<"status">>, Sample, invalid),
    Passed = maps:get(<<"passed">>, Sample, invalid),
    lists:all(
      fun(Boolean) -> Boolean end,
      [valid_nonempty_binary(maps:get(<<"sample_id">>, Sample, undefined)),
       nonnegative_integer(maps:get(<<"sample_index">>, Sample, invalid)),
       valid_sample_status(Status),
       is_boolean(Passed),
       nonnegative_integer(maps:get(<<"duration_ms">>, Sample, invalid)),
       is_list(maps:get(<<"turns">>, Sample, invalid)),
       is_list(maps:get(<<"trajectory">>, Sample, invalid)),
       is_list(maps:get(<<"criteria">>, Sample, invalid)),
       is_map(maps:get(<<"metadata">>, Sample, invalid)),
       valid_metric_results(maps:get(<<"criteria">>, Sample, [])),
       valid_turn_results(maps:get(<<"turns">>, Sample, [])),
       sample_status_consistent(Status, Passed)]);
valid_sample_result(_) -> false.

valid_turn_results(Turns) ->
    lists:all(
      fun(Turn) when is_map(Turn) ->
              valid_nonempty_binary(
                maps:get(<<"turn_id">>, Turn, undefined))
                  andalso
              is_boolean(maps:get(<<"passed">>, Turn, invalid))
                  andalso
              is_list(maps:get(<<"metrics">>, Turn, invalid))
                  andalso
              valid_metric_results(maps:get(<<"metrics">>, Turn, []));
         (_) -> false
      end, Turns).

valid_metric_results(Results) ->
    lists:all(
      fun(Result) when is_map(Result) ->
              valid_nonempty_binary(
                maps:get(<<"metric_id">>, Result, undefined))
                  andalso
              valid_metric_status(maps:get(<<"status">>, Result, invalid))
                  andalso
              valid_score(maps:get(<<"score">>, Result, invalid))
                  andalso
              valid_score(maps:get(<<"threshold">>, Result, invalid))
                  andalso
              is_boolean(maps:get(<<"passed">>, Result, invalid))
                  andalso
              is_map(maps:get(<<"metadata">>, Result, invalid));
         (_) -> false
      end, Results).

valid_summary_metrics(Metrics) ->
    lists:all(
      fun(Metric) when is_map(Metric) ->
              valid_nonempty_binary(
                maps:get(<<"metric_id">>, Metric, undefined))
                  andalso
              valid_score(maps:get(<<"average_score">>, Metric, invalid))
                  andalso
              valid_score(maps:get(<<"threshold">>, Metric, invalid))
                  andalso
              is_boolean(maps:get(<<"passed">>, Metric, invalid))
                  andalso
              nonnegative_integer(
                maps:get(<<"evaluated_count">>, Metric, invalid))
                  andalso
              nonnegative_integer(
                maps:get(<<"error_count">>, Metric, invalid))
                  andalso
              nonnegative_integer(
                maps:get(<<"not_evaluated_count">>, Metric, invalid));
         (_) -> false
      end, Metrics).

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

bounded_finalize(Fun, Deadline, MaxHeapWords) ->
    case remaining(Deadline) of
        0 -> {error, evaluation_timeout};
        Wait ->
            Alias = erlang:alias([reply]),
            Parent = self(),
            Worker = fun() ->
                Result = try Fun() of
                    Value -> Value
                catch
                    _:_ -> {error, evaluation_finalize_exception}
                end,
                Alias ! {adk_eval_finalize_reply, Alias, self(),
                         erlang:monotonic_time(millisecond), Result}
            end,
            {Pid, Monitor} = spawn_opt(
                               Worker,
                               [monitor, {message_queue_data, off_heap},
                                {max_heap_size,
                                 #{size => MaxHeapWords, kill => true,
                                   error_logger => false,
                                   include_shared_binaries => true}}]),
            Watcher = spawn(fun() -> owner_watcher(Parent, Pid) end),
            receive
                {adk_eval_finalize_reply, Alias, Pid, Completed, Result} ->
                    _ = erlang:unalias(Alias),
                    Watcher ! stop,
                    erlang:demonitor(Monitor, [flush]),
                    case Completed =< Deadline of
                        true -> Result;
                        false -> {error, evaluation_timeout}
                    end;
                {'DOWN', Monitor, process, Pid, _} ->
                    _ = erlang:unalias(Alias),
                    Watcher ! stop,
                    {error, evaluation_finalize_worker_down}
            after Wait ->
                _ = erlang:unalias(Alias),
                exit(Pid, kill),
                receive {'DOWN', Monitor, process, Pid, _} -> ok
                after 100 -> erlang:demonitor(Monitor, [flush])
                end,
                Watcher ! stop,
                {error, evaluation_timeout}
            end
    end.

bounded_validation(Fun) ->
    Alias = erlang:alias([reply]),
    Parent = self(),
    Worker = fun() ->
        Result = try Fun() of
            Value -> Value
        catch
            _:_ -> {error, evaluation_validation_exception}
        end,
        Alias ! {adk_eval_validation_reply, Alias, self(), Result}
    end,
    {Pid, Monitor} = spawn_opt(
                       Worker,
                       [monitor, {message_queue_data, off_heap},
                        {max_heap_size,
                         #{size => ?DEFAULT_VALIDATION_HEAP_WORDS,
                           kill => true, error_logger => false}}]),
    Watcher = spawn(fun() -> owner_watcher(Parent, Pid) end),
    receive
        {adk_eval_validation_reply, Alias, Pid, Result} ->
            _ = erlang:unalias(Alias),
            Watcher ! stop,
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, _} ->
            _ = erlang:unalias(Alias),
            Watcher ! stop,
            {error, evaluation_validation_worker_down}
    after ?DEFAULT_VALIDATION_TIMEOUT_MS ->
        _ = erlang:unalias(Alias),
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 100 -> erlang:demonitor(Monitor, [flush])
        end,
        Watcher ! stop,
        {error, evaluation_validation_timeout}
    end.

safe_external_size(Value) ->
    try erlang:external_size(Value) of
        Bytes when is_integer(Bytes), Bytes >= 0 -> {ok, Bytes}
    catch
        _:_ -> error
    end.

statistics([]) ->
    #{<<"count">> => 0, <<"mean">> => 0.0,
      <<"minimum">> => 0.0, <<"maximum">> => 0.0,
      <<"standard_deviation">> => 0.0};
statistics(Scores) ->
    Mean = mean(Scores),
    Variance = lists:sum(
                 [math:pow(Score - Mean, 2) || Score <- Scores])
        / length(Scores),
    #{<<"count">> => length(Scores), <<"mean">> => Mean,
      <<"minimum">> => lists:min(Scores),
      <<"maximum">> => lists:max(Scores),
      <<"standard_deviation">> => math:sqrt(Variance)}.

mean([]) -> 0.0;
mean(Scores) -> lists:sum(Scores) / length(Scores).

ratio(_Numerator, 0) -> 0.0;
ratio(Numerator, Denominator) -> Numerator / Denominator.

near(A, B) when is_number(A), is_number(B) -> abs(A - B) =< 1.0e-12;
near(_, _) -> false.

ordered_unique(Values) -> ordered_unique(Values, #{}, []).
ordered_unique([], _Seen, Acc) -> lists:reverse(Acc);
ordered_unique([Value | Rest], Seen, Acc) ->
    case maps:is_key(Value, Seen) of
        true -> ordered_unique(Rest, Seen, Acc);
        false -> ordered_unique(Rest, Seen#{Value => true}, [Value | Acc])
    end.

bounded_length(List, Limit) -> bounded_length(List, Limit, 0).
bounded_length([], _Limit, _Count) -> true;
bounded_length([_ | Rest], Limit, Count) when Count < Limit ->
    bounded_length(Rest, Limit, Count + 1);
bounded_length(_, _Limit, _Count) -> false.

valid_status(<<"passed">>) -> true;
valid_status(<<"failed">>) -> true;
valid_status(<<"partial">>) -> true;
valid_status(<<"error">>) -> true;
valid_status(_) -> false.

valid_sample_status(<<"passed">>) -> true;
valid_sample_status(<<"failed">>) -> true;
valid_sample_status(<<"error">>) -> true;
valid_sample_status(_) -> false.

sample_status_consistent(<<"passed">>, true) -> true;
sample_status_consistent(<<"failed">>, false) -> true;
sample_status_consistent(<<"error">>, false) -> true;
sample_status_consistent(_, _) -> false.

valid_metric_status(<<"ok">>) -> true;
valid_metric_status(<<"error">>) -> true;
valid_metric_status(<<"not_evaluated">>) -> true;
valid_metric_status(_) -> false.

status_binary(true) -> <<"passed">>;
status_binary(false) -> <<"failed">>.

safe_json(Value) ->
    case adk_eval_limits:check(Value) of
        ok ->
            case adk_context_guard:sanitize_value(Value) of
                {ok, Safe} -> {ok, Safe};
                {error, Reason} -> {error, reason_tag(Reason)}
            end;
        {error, Reason} -> {error, reason_tag(Reason)}
    end.

safe_metadata(Value) when is_map(Value) ->
    case safe_json(Value) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        _ -> {error, invalid_metadata}
    end;
safe_metadata(_) -> {error, invalid_metadata}.

valid_metric_kind(metric) -> true;
valid_metric_kind(judge) -> true;
valid_metric_kind(_) -> false.

valid_metric_scope(turn) -> true;
valid_metric_scope('case') -> true;
valid_metric_scope(_) -> false.

valid_empty_policy(error) -> true;
valid_empty_policy(pass) -> true;
valid_empty_policy(_) -> false.

valid_score(Value) when is_integer(Value), Value >= 0, Value =< 1 -> true;
valid_score(Value) when is_float(Value), Value >= 0.0, Value =< 1.0 ->
    Value =:= Value;
valid_score(_) -> false.

valid_nonempty_binary(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0.

nonnegative_integer(Value) -> is_integer(Value) andalso Value >= 0.
positive_integer(Value) -> is_integer(Value) andalso Value > 0.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

elapsed_ms(Started) ->
    erlang:max(0, erlang:monotonic_time(millisecond) - Started).

hex_binary(Binary) ->
    << <<(hex(Nibble))>> || <<Nibble:4>> <= Binary >>.

hex(N) when N < 10 -> $0 + N;
hex(N) -> $a + (N - 10).

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

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _, _}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(_) -> evaluation_failed.
