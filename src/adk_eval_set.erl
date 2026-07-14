%% @doc Versioned multi-turn evaluation sets and bounded execution engine.
%%
%% This complements (and does not replace) the lightweight `adk_eval:run/3,4'
%% API. Cases run concurrently in monitored, heap-limited Erlang processes;
%% turns within a case remain ordered and share adapter state. Every persisted
%% set and result crosses a checked JSON-safe boundary.
-module(adk_eval_set).

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
    decode_result/1
]).

-define(SET_VERSION, 1).
-define(RESULT_VERSION, 1).
-define(DEFAULT_TIMEOUT_MS, 60000).
-define(DEFAULT_CASE_TIMEOUT_MS, 30000).
-define(DEFAULT_MAX_HEAP_WORDS, 1000000).

-type eval_set() :: map().
-type eval_result() :: map().
-export_type([eval_set/0, eval_result/0]).

-spec schema_version() -> pos_integer().
schema_version() -> ?SET_VERSION.

-spec result_schema_version() -> pos_integer().
result_schema_version() -> ?RESULT_VERSION.

%% @doc Build a checked evaluation set from convenient atom- or binary-keyed
%% case maps. Version is the caller's dataset revision (for example `<<"3">>');
%% schema_version independently versions the storage contract.
-spec new(binary(), binary(), [map()]) ->
    {ok, eval_set()} | {error, term()}.
new(Id, Version, Cases) ->
    validate(#{id => Id, version => Version, cases => Cases,
               metadata => #{}}).

-spec validate(map()) -> {ok, eval_set()} | {error, term()}.
validate(Set) when is_map(Set) ->
    SchemaVersion = get(Set, schema_version, ?SET_VERSION),
    case SchemaVersion of
        ?SET_VERSION -> validate_set_fields(Set);
        _ -> {error, {unsupported_eval_set_schema_version, SchemaVersion}}
    end;
validate(_) ->
    {error, invalid_eval_set}.

-spec encode(eval_set()) -> {ok, map()} | {error, term()}.
encode(Set) -> validate(Set).

-spec decode(map()) -> {ok, eval_set()} | {error, term()}.
decode(Set) -> validate(Set).

%% @doc Execute all cases through an adapter and metric descriptors.
%%
%% Adapter is `#{module => Module, target => Target, config => #{}}'. Metrics
%% are ordered descriptors with binary `id', module, optional config, kind
%% (`metric' or `judge'), and a 0..1 threshold. Options include concurrency,
%% timeout_ms, case_timeout_ms, max_heap_words, pass_rate_threshold,
%% capture_events, capture_tool_content, and JSON-safe result_metadata.
-spec run(map(), eval_set(), [map()], map()) ->
    {ok, eval_result()} | {error, term()}.
run(Adapter0, Set0, Metrics0, Opts0)
  when is_map(Adapter0), is_list(Metrics0), is_map(Opts0) ->
    case {validate(Set0), validate_adapter(Adapter0),
          validate_metrics(Metrics0), validate_options(Opts0)} of
        {{ok, Set}, {ok, Adapter}, {ok, Metrics}, {ok, Opts}} ->
            run_validated(Adapter, Set, Metrics, Opts);
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end;
run(_, _, _, _) ->
    {error, invalid_eval_run_arguments}.

%% @doc Check a saved result and return its canonical secret-pruned map.
-spec encode_result(eval_result()) -> {ok, map()} | {error, term()}.
encode_result(#{<<"result_schema_version">> := ?RESULT_VERSION,
                <<"eval_set_id">> := SetId,
                <<"eval_set_version">> := SetVersion,
                <<"cases">> := Cases,
                <<"passed">> := Passed} = Result)
  when is_binary(SetId), is_binary(SetVersion), is_list(Cases),
       is_boolean(Passed) ->
    case adk_context_guard:sanitize_value(Result) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        {ok, _} -> {error, invalid_eval_result};
        {error, Reason} ->
            {error, {invalid_eval_result, reason_tag(Reason)}}
    end;
encode_result(#{<<"result_schema_version">> := Version})
  when Version =/= ?RESULT_VERSION ->
    {error, {unsupported_eval_result_schema_version, Version}};
encode_result(_) ->
    {error, invalid_eval_result}.

-spec decode_result(map()) -> {ok, eval_result()} | {error, term()}.
decode_result(Result) -> encode_result(Result).

validate_set_fields(Set) ->
    Id = get(Set, id, undefined),
    Version = get(Set, version, undefined),
    Cases = get(Set, cases, undefined),
    Metadata = get(Set, metadata, #{}),
    case {valid_nonempty_binary(Id), valid_nonempty_binary(Version),
          is_list(Cases), safe_metadata(Metadata)} of
        {true, true, true, {ok, SafeMetadata}} ->
            case validate_cases(Cases, 0, [], #{}) of
                {ok, SafeCases} ->
                    {ok, #{<<"schema_version">> => ?SET_VERSION,
                           <<"id">> => Id,
                           <<"version">> => Version,
                           <<"cases">> => SafeCases,
                           <<"metadata">> => SafeMetadata}};
                {error, _} = Error -> Error
            end;
        {false, _, _, _} -> {error, invalid_eval_set_id};
        {_, false, _, _} -> {error, invalid_eval_set_version};
        {_, _, false, _} -> {error, invalid_eval_cases};
        {_, _, _, {error, _} = Error} -> Error
    end.

validate_cases([], _Index, Acc, _Ids) -> {ok, lists:reverse(Acc)};
validate_cases([Case | Rest], Index, Acc, Ids) when is_map(Case) ->
    Id = get(Case, id, undefined),
    Metadata = get(Case, metadata, #{}),
    Turns0 = case find(Case, turns) of
        {ok, RawTurns} -> RawTurns;
        error -> single_turn(Case)
    end,
    case {valid_nonempty_binary(Id), maps:is_key(Id, Ids),
          safe_metadata(Metadata), is_list(Turns0)} of
        {true, false, {ok, SafeMetadata}, true} ->
            case validate_turns(Turns0, Id, 0, [], #{}) of
                {ok, []} -> {error, {eval_case_has_no_turns, Id}};
                {ok, ValidatedTurns} ->
                    SafeCase = #{<<"id">> => Id,
                                 <<"turns">> => ValidatedTurns,
                                 <<"metadata">> => SafeMetadata},
                    validate_cases(Rest, Index + 1, [SafeCase | Acc],
                                   Ids#{Id => true});
                {error, _} = Error -> Error
            end;
        {false, _, _, _} -> {error, {invalid_eval_case_id, Index}};
        {_, true, _, _} -> {error, {duplicate_eval_case_id, Id}};
        {_, _, {error, _}, _} ->
            {error, {invalid_eval_case_metadata, Id}};
        {_, _, _, false} -> {error, {invalid_eval_case_turns, Id}}
    end;
validate_cases([_ | _], Index, _Acc, _Ids) ->
    {error, {invalid_eval_case, Index}};
validate_cases(_Improper, Index, _Acc, _Ids) ->
    {error, {invalid_eval_case_list, Index}}.

single_turn(Case) ->
    case find(Case, input) of
        {ok, Input} ->
            [#{id => <<"turn-1">>, input => Input,
               expected => get(Case, expected, null), metadata => #{}}];
        error -> invalid_turns
    end.

validate_turns([], _CaseId, _Index, Acc, _Ids) ->
    {ok, lists:reverse(Acc)};
validate_turns([Turn | Rest], CaseId, Index, Acc, Ids)
  when is_map(Turn) ->
    DefaultId = iolist_to_binary([<<"turn-">>, integer_to_binary(Index + 1)]),
    Id = get(Turn, id, DefaultId),
    Input = get(Turn, input, undefined),
    Expected = get(Turn, expected, null),
    Metadata = get(Turn, metadata, #{}),
    case {valid_nonempty_binary(Id), maps:is_key(Id, Ids),
          Input =/= undefined, safe_json(Input), safe_json(Expected),
          safe_metadata(Metadata)} of
        {true, false, true, {ok, SafeInput}, {ok, SafeExpected},
         {ok, SafeMetadata}} ->
            SafeTurn = #{<<"id">> => Id, <<"input">> => SafeInput,
                         <<"expected">> => SafeExpected,
                         <<"metadata">> => SafeMetadata},
            validate_turns(Rest, CaseId, Index + 1, [SafeTurn | Acc],
                           Ids#{Id => true});
        {false, _, _, _, _, _} ->
            {error, {invalid_eval_turn_id, CaseId, Index}};
        {_, true, _, _, _, _} ->
            {error, {duplicate_eval_turn_id, CaseId, Id}};
        {_, _, false, _, _, _} ->
            {error, {missing_eval_turn_input, CaseId, Id}};
        _ -> {error, {invalid_eval_turn, CaseId, Id}}
    end;
validate_turns([_ | _], CaseId, Index, _Acc, _Ids) ->
    {error, {invalid_eval_turn, CaseId, Index}};
validate_turns(_Improper, CaseId, Index, _Acc, _Ids) ->
    {error, {invalid_eval_turn_list, CaseId, Index}}.

validate_adapter(Adapter) ->
    Module = get(Adapter, module, undefined),
    Target = get(Adapter, target, undefined),
    Config = get(Adapter, config, #{}),
    case {is_atom(Module), Target =/= undefined, is_map(Config)} of
        {true, true, true} ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, run_turn, 5) of
                        true -> {ok, #{module => Module, target => Target,
                                      config => Config}};
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
    Module = get(Metric, module, undefined),
    Config = get(Metric, config, #{}),
    Kind = get(Metric, kind, metric),
    Threshold = get(Metric, threshold, 1.0),
    case {valid_nonempty_binary(Id), maps:is_key(Id, Ids),
          is_atom(Module), is_map(Config), valid_metric_kind(Kind),
          valid_score(Threshold)} of
        {true, false, true, true, true, true} ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, score, 4) of
                        true ->
                            Compiled = #{id => Id, module => Module,
                                         config => Config, kind => Kind,
                                         threshold => Threshold},
                            validate_metrics(Rest, Index + 1,
                                             [Compiled | Acc],
                                             Ids#{Id => true});
                        false ->
                            {error, {eval_metric_missing_callback, Id}}
                    end;
                _ -> {error, {eval_metric_unavailable, Id}}
            end;
        {false, _, _, _, _, _} -> {error, {invalid_eval_metric_id, Index}};
        {_, true, _, _, _, _} -> {error, {duplicate_eval_metric_id, Id}};
        _ -> {error, {invalid_eval_metric, Id}}
    end;
validate_metrics([_ | _], Index, _Acc, _Ids) ->
    {error, {invalid_eval_metric, Index}};
validate_metrics(_Improper, Index, _Acc, _Ids) ->
    {error, {invalid_eval_metric_list, Index}}.

validate_options(Opts) ->
    Concurrency = get(Opts, concurrency, 1),
    Timeout = get(Opts, timeout_ms, ?DEFAULT_TIMEOUT_MS),
    CaseTimeout = get(Opts, case_timeout_ms, ?DEFAULT_CASE_TIMEOUT_MS),
    Heap = get(Opts, max_heap_words, ?DEFAULT_MAX_HEAP_WORDS),
    PassRate = get(Opts, pass_rate_threshold, 1.0),
    CaptureEvents = get(Opts, capture_events, true),
    CaptureTool = get(Opts, capture_tool_content, false),
    ResultMetadata = get(Opts, result_metadata, #{}),
    case {is_integer(Concurrency) andalso Concurrency > 0,
          is_integer(Timeout) andalso Timeout > 0,
          is_integer(CaseTimeout) andalso CaseTimeout > 0,
          is_integer(Heap) andalso Heap >= 1000,
          valid_score(PassRate), is_boolean(CaptureEvents),
          is_boolean(CaptureTool), safe_metadata(ResultMetadata)} of
        {true, true, true, true, true, true, true, {ok, SafeMetadata}} ->
            {ok, #{concurrency => Concurrency, timeout_ms => Timeout,
                   case_timeout_ms => CaseTimeout, max_heap_words => Heap,
                   pass_rate_threshold => PassRate,
                   capture_events => CaptureEvents,
                   capture_tool_content => CaptureTool,
                   result_metadata => SafeMetadata}};
        _ -> {error, invalid_eval_options}
    end.

run_validated(Adapter, Set, Metrics, Opts) ->
    Started = erlang:monotonic_time(millisecond),
    Deadline = Started + maps:get(timeout_ms, Opts),
    Cases = maps:get(<<"cases">>, Set),
    Results = run_case_batches(Cases, Adapter, Metrics, Opts,
                               Deadline, 0, []),
    Duration = elapsed_ms(Started),
    Summary = summarize(Set, Metrics, Results, Duration, Opts),
    encode_result(Summary).

run_case_batches([], _Adapter, _Metrics, _Opts, _Deadline, _Offset, Acc) ->
    lists:append(lists:reverse(Acc));
run_case_batches(Cases, Adapter, Metrics, Opts, Deadline, Offset, Acc) ->
    Concurrency = maps:get(concurrency, Opts),
    Count = erlang:min(Concurrency, length(Cases)),
    {Batch, Rest} = lists:split(Count, Cases),
    case remaining(Deadline) of
        0 ->
            TimedOut = [case_failure(Case, timeout, 0) || Case <- Cases],
            lists:append(lists:reverse([TimedOut | Acc]));
        _ ->
            Jobs = start_case_jobs(Batch, Adapter, Metrics, Opts,
                                   Deadline, Offset, []),
            BatchResults = [collect_case_job(Job) || Job <- Jobs],
            run_case_batches(Rest, Adapter, Metrics, Opts, Deadline,
                             Offset + Count, [BatchResults | Acc])
    end.

start_case_jobs([], _Adapter, _Metrics, _Opts, _Deadline, _Index, Acc) ->
    lists:reverse(Acc);
start_case_jobs([Case | Rest], Adapter, Metrics, Opts, Deadline,
                Index, Acc) ->
    Parent = self(),
    Ref = make_ref(),
    Started = erlang:monotonic_time(millisecond),
    CaseDeadline = erlang:min(Deadline,
                              Started + maps:get(case_timeout_ms, Opts)),
    Worker = fun() ->
        Result = try evaluate_case(Case, Index, Adapter, Metrics, Opts,
                                   CaseDeadline, Started) of
            Value -> Value
        catch
            _:_ -> case_failure(Case, worker_exception,
                                elapsed_ms(Started))
        end,
        Parent ! {adk_eval_case_reply, Ref, self(), Result}
    end,
    {Pid, Monitor} = spawn_opt(
                       Worker,
                       [monitor,
                        {max_heap_size,
                         #{size => maps:get(max_heap_words, Opts),
                           kill => true, error_logger => false}}]),
    Job = #{pid => Pid, monitor => Monitor, ref => Ref,
            eval_case => Case,
            started => Started, deadline => CaseDeadline},
    start_case_jobs(Rest, Adapter, Metrics, Opts, Deadline, Index + 1,
                    [Job | Acc]).

collect_case_job(Job) ->
    Pid = maps:get(pid, Job),
    Monitor = maps:get(monitor, Job),
    Ref = maps:get(ref, Job),
    Case = maps:get(eval_case, Job),
    Started = maps:get(started, Job),
    receive
        {adk_eval_case_reply, Ref, Pid, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, _} ->
            flush_case_reply(Ref, Pid),
            case_failure(Case, worker_down, elapsed_ms(Started))
    after remaining(maps:get(deadline, Job)) ->
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 100 -> erlang:demonitor(Monitor, [flush])
        end,
        flush_case_reply(Ref, Pid),
        case_failure(Case, timeout, elapsed_ms(Started))
    end.

flush_case_reply(Ref, Pid) ->
    receive {adk_eval_case_reply, Ref, Pid, _} -> ok after 0 -> ok end.

evaluate_case(Case, CaseIndex, Adapter, Metrics, Opts,
              Deadline, Started) ->
    Turns = maps:get(<<"turns">>, Case),
    Context0 = #{<<"case_id">> => maps:get(<<"id">>, Case),
                 <<"case_index">> => CaseIndex},
    case evaluate_turns(Turns, 0, null, Context0, Adapter, Metrics,
                        Opts, Deadline, [], []) of
        {ok, TurnResults, Trajectory} ->
            Passed = lists:all(
                       fun(Turn) -> maps:get(<<"passed">>, Turn) end,
                       TurnResults),
            #{<<"case_id">> => maps:get(<<"id">>, Case),
              <<"status">> => status_binary(Passed),
              <<"passed">> => Passed,
              <<"duration_ms">> => elapsed_ms(Started),
              <<"turns">> => TurnResults,
              <<"trajectory">> => Trajectory,
              <<"metadata">> => maps:get(<<"metadata">>, Case)};
        {error, Reason, TurnResults, Trajectory} ->
            #{<<"case_id">> => maps:get(<<"id">>, Case),
              <<"status">> => <<"error">>, <<"passed">> => false,
              <<"duration_ms">> => elapsed_ms(Started),
              <<"turns">> => TurnResults,
              <<"trajectory">> => Trajectory,
              <<"metadata">> => maps:get(<<"metadata">>, Case),
              <<"error">> => atom_to_binary(reason_tag(Reason), utf8)}
    end.

evaluate_turns([], _Index, _State, _CaseContext, _Adapter, _Metrics,
               _Opts, _Deadline, TurnAcc, TrajectoryAcc) ->
    {ok, lists:reverse(TurnAcc), lists:append(lists:reverse(TrajectoryAcc))};
evaluate_turns([Turn | Rest], Index, State0, CaseContext, Adapter,
               Metrics, Opts, Deadline, TurnAcc, TrajectoryAcc) ->
    case remaining(Deadline) of
        0 ->
            {error, timeout, lists:reverse(TurnAcc),
             lists:append(lists:reverse(TrajectoryAcc))};
        _ ->
            Context = CaseContext#{
                <<"turn_id">> => maps:get(<<"id">>, Turn),
                <<"turn_index">> => Index
            },
            case call_adapter(Adapter, Turn, State0, Context) of
                {ok, Actual, Events, State1, AdapterMetadata} ->
                    MetricResults = score_metrics(
                                      Metrics,
                                      maps:get(<<"expected">>, Turn),
                                      Actual, Context, []),
                    Passed = lists:all(
                               fun(MetricResult) ->
                                   maps:get(<<"passed">>, MetricResult)
                               end, MetricResults),
                    TurnTrajectory = event_trajectory(
                                       Events,
                                       maps:get(<<"id">>, Turn), Opts),
                    CapturedEvents = case maps:get(capture_events, Opts) of
                        true -> Events;
                        false -> []
                    end,
                    TurnResult = #{
                        <<"turn_id">> => maps:get(<<"id">>, Turn),
                        <<"input">> => maps:get(<<"input">>, Turn),
                        <<"expected">> => maps:get(<<"expected">>, Turn),
                        <<"actual">> => Actual,
                        <<"passed">> => Passed,
                        <<"metrics">> => MetricResults,
                        <<"events">> => CapturedEvents,
                        <<"trajectory">> => TurnTrajectory,
                        <<"metadata">> => maps:get(<<"metadata">>, Turn),
                        <<"adapter_metadata">> => AdapterMetadata
                    },
                    evaluate_turns(Rest, Index + 1, State1, CaseContext,
                                   Adapter, Metrics, Opts, Deadline,
                                   [TurnResult | TurnAcc],
                                   [TurnTrajectory | TrajectoryAcc]);
                {error, Reason} ->
                    {error, Reason, lists:reverse(TurnAcc),
                     lists:append(lists:reverse(TrajectoryAcc))}
            end
    end.

call_adapter(Adapter, Turn, State, Context) ->
    Module = maps:get(module, Adapter),
    Target = maps:get(target, Adapter),
    Config = maps:get(config, Adapter),
    try Module:run_turn(Target, Turn, State, Context, Config) of
        {ok, Result} when is_map(Result) -> normalize_adapter_result(Result);
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
        {ok, SafeEvent} -> normalize_events(Rest, [SafeEvent | Acc]);
        {error, _} -> {error, invalid_adapter_event}
    end;
normalize_events(_, _) -> {error, invalid_adapter_events}.

score_metrics([], _Expected, _Actual, _Context, Acc) ->
    lists:reverse(Acc);
score_metrics([Metric | Rest], Expected, Actual, Context, Acc) ->
    Module = maps:get(module, Metric),
    Config = maps:get(config, Metric),
    Raw = try Module:score(Expected, Actual, Context, Config) of
        Value -> Value
    catch
        _:_ -> {error, metric_exception}
    end,
    {Score, Status, Metadata} = normalize_metric_score(Raw),
    Threshold = maps:get(threshold, Metric),
    Passed = Status =:= ok andalso Score >= Threshold,
    Result = #{
        <<"metric_id">> => maps:get(id, Metric),
        <<"kind">> => atom_to_binary(maps:get(kind, Metric), utf8),
        <<"score">> => Score,
        <<"threshold">> => Threshold,
        <<"passed">> => Passed,
        <<"status">> => atom_to_binary(Status, utf8),
        <<"metadata">> => Metadata
    },
    score_metrics(Rest, Expected, Actual, Context, [Result | Acc]).

normalize_metric_score(Score) when is_number(Score) ->
    normalize_metric_score({ok, Score, #{}});
normalize_metric_score({ok, Score}) ->
    normalize_metric_score({ok, Score, #{}});
normalize_metric_score({ok, Score, Metadata}) ->
    case {valid_score(Score), safe_metadata(Metadata)} of
        {true, {ok, SafeMetadata}} -> {Score, ok, SafeMetadata};
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
        true -> Base#{<<"result">> => maps:get(<<"result">>, Content, null)};
        false -> Base
    end.

summarize(Set, Metrics, Results, Duration, Opts) ->
    Total = length(Results),
    PassedCount = length([ok || Result <- Results,
                               maps:get(<<"passed">>, Result, false)]),
    PassRate = case Total of 0 -> 0.0; _ -> PassedCount / Total end,
    Threshold = maps:get(pass_rate_threshold, Opts),
    #{<<"result_schema_version">> => ?RESULT_VERSION,
      <<"eval_set_id">> => maps:get(<<"id">>, Set),
      <<"eval_set_version">> => maps:get(<<"version">>, Set),
      <<"passed">> => PassRate >= Threshold,
      <<"pass_rate">> => PassRate,
      <<"pass_rate_threshold">> => Threshold,
      <<"case_count">> => Total,
      <<"passed_case_count">> => PassedCount,
      <<"duration_ms">> => Duration,
      <<"metrics">> => summarize_metrics(Metrics, Results),
      <<"cases">> => Results,
      <<"metadata">> => maps:get(result_metadata, Opts)}.

summarize_metrics(Metrics, Results) ->
    [summarize_metric(Metric, Results) || Metric <- Metrics].

summarize_metric(Metric, Results) ->
    Id = maps:get(id, Metric),
    Scores = [maps:get(<<"score">>, MetricResult)
              || Case <- Results,
                 Turn <- maps:get(<<"turns">>, Case, []),
                 MetricResult <- maps:get(<<"metrics">>, Turn, []),
                 maps:get(<<"metric_id">>, MetricResult) =:= Id],
    Average = case Scores of [] -> 0.0;
                              _ -> lists:sum(Scores) / length(Scores)
              end,
    Threshold = maps:get(threshold, Metric),
    #{<<"metric_id">> => Id,
      <<"kind">> => atom_to_binary(maps:get(kind, Metric), utf8),
      <<"average_score">> => Average,
      <<"threshold">> => Threshold,
      <<"passed">> => Scores =/= [] andalso Average >= Threshold}.

case_failure(Case, Reason, Duration) ->
    #{<<"case_id">> => maps:get(<<"id">>, Case),
      <<"status">> => <<"error">>, <<"passed">> => false,
      <<"duration_ms">> => Duration, <<"turns">> => [],
      <<"trajectory">> => [],
      <<"metadata">> => maps:get(<<"metadata">>, Case, #{}),
      <<"error">> => atom_to_binary(reason_tag(Reason), utf8)}.

status_binary(true) -> <<"passed">>;
status_binary(false) -> <<"failed">>.

safe_json(Value) ->
    case adk_context_guard:sanitize_value(Value) of
        {ok, Safe} -> {ok, Safe};
        {error, Reason} -> {error, reason_tag(Reason)}
    end.

safe_metadata(Value) when is_map(Value) ->
    case adk_context_guard:sanitize_value(Value) of
        {ok, Safe} when is_map(Safe) -> {ok, Safe};
        _ -> {error, invalid_metadata}
    end;
safe_metadata(_) -> {error, invalid_metadata}.

valid_metric_kind(metric) -> true;
valid_metric_kind(judge) -> true;
valid_metric_kind(_) -> false.

valid_score(Value) when is_number(Value), Value >= 0, Value =< 1 -> true;
valid_score(_) -> false.

valid_nonempty_binary(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

elapsed_ms(Started) ->
    erlang:max(0, erlang:monotonic_time(millisecond) - Started).

get(Map, Key, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

find(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, _} = Found -> Found;
        error -> maps:find(atom_to_binary(Key, utf8), Map)
    end.

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _, _}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(_) -> evaluation_failed.
