%% @doc Bounded automatic context compaction with explicit checkpoints.
%%
%% The module decides when compaction is needed, keeps recent context-selection
%% units (including complete tool call/response exchanges), and executes the
%% configured compactor in an owner-bound, heap-bounded process.  Results and
%% checkpoints are versioned JSON values suitable for persistence.  This
%% module does not persist anything itself.
-module(adk_context_compaction).

-include("../include/adk_event.hrl").

-export([version/0, capabilities/0, compile/1, evaluate/3,
         cancel_message/1]).

-define(VERSION, 1).
-define(DEFAULT_BYTES_PER_TOKEN, 4).
-define(DEFAULT_RETAIN_UNITS, 4).
-define(DEFAULT_MAX_INPUT_EVENTS, 10000).
-define(DEFAULT_MAX_INPUT_BYTES, 16777216).
-define(DEFAULT_MAX_SUMMARY_BYTES, 1048576).
-define(DEFAULT_MAX_CHECKPOINT_BYTES, 2097152).
-define(DEFAULT_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_HEAP_WORDS, 2000000).

-type policy() :: map().
-export_type([policy/0]).

-spec version() -> pos_integer().
version() -> ?VERSION.

-spec capabilities() -> map().
capabilities() ->
    #{version => ?VERSION,
      triggers => [token_pressure, event_pressure, turn_interval],
      trigger_precedence => [token_pressure, event_pressure, turn_interval],
      retention_unit => complete_context_exchange,
      checkpoint => versioned_json,
      execution => #{owner_bound => true,
                     absolute_deadline => true,
                     explicit_cancellation => true,
                     heap_bounded => true}}.

%% @doc Validate and compile immutable compaction configuration.
%%
%% At least one of `token_threshold', `event_threshold', or `turn_interval'
%% must be enabled.  A trigger is disabled with the atom `disabled'.
-spec compile(map()) -> {ok, policy()} | {error, term()}.
compile(Opts) when is_map(Opts) ->
    case unknown_keys(Opts, option_keys()) of
        [] -> compile_known(Opts);
        Unknown ->
            {error, {invalid_compaction_options,
                     {unknown_keys, lists:sort(Unknown)}}}
    end;
compile(_) ->
    {error, {invalid_compaction_options, expected_map}}.

%% @doc Evaluate triggers and, when selected, return a compacted history.
%%
%% `Stats' accepts `estimated_tokens' (otherwise a deterministic byte estimate
%% is used) and `turns_since_compaction'.  `Runtime' accepts an absolute
%% monotonic `deadline_ms' and a `cancel_ref'.  Send the value returned by
%% `cancel_message/1' to the evaluating process to cancel explicit work.
-spec evaluate([adk_event:event() | map()], map(), policy()) ->
    {ok, no_compaction, map()} | {ok, map()} | {error, term()}.
evaluate(Events, Stats, Policy) when is_list(Events), is_map(Stats),
                                     is_map(Policy) ->
    case validate_compiled_policy(Policy) of
        ok ->
            case normalize_stats(Stats, Policy) of
                {ok, RuntimeStats} ->
                    case sanitize_events_bounded(
                           Events, maps:get(max_input_events, Policy)) of
                        {ok, SafeEvents} ->
                            case {validate_history(SafeEvents),
                                  input_size_allowed(SafeEvents, Policy)} of
                                {ok, true} ->
                                    evaluate_safe(
                                      SafeEvents, RuntimeStats, Policy);
                                {{error, _} = Error, _} -> Error;
                                {ok, false} ->
                                    {error, compaction_input_too_large}
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
evaluate(_, _, _) ->
    {error, invalid_compaction_arguments}.

-spec cancel_message(reference()) -> tuple().
cancel_message(CancelRef) when is_reference(CancelRef) ->
    {adk_context_compaction_cancel, CancelRef}.

compile_known(Opts) ->
    Values = [
        threshold(token_threshold, Opts, disabled),
        threshold(event_threshold, Opts, disabled),
        threshold(turn_interval, Opts, disabled),
        positive(retain_recent_exchanges, Opts, ?DEFAULT_RETAIN_UNITS,
                 1, 10000),
        positive(bytes_per_token, Opts, ?DEFAULT_BYTES_PER_TOKEN, 1, 1024),
        positive(max_input_events, Opts, ?DEFAULT_MAX_INPUT_EVENTS,
                 2, 1000000),
        positive(max_input_bytes, Opts, ?DEFAULT_MAX_INPUT_BYTES,
                 1, 268435456),
        positive(max_summary_bytes, Opts, ?DEFAULT_MAX_SUMMARY_BYTES,
                 1, 16777216),
        positive(max_checkpoint_bytes, Opts, ?DEFAULT_MAX_CHECKPOINT_BYTES,
                 1, 33554432),
        positive(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS, 1, 300000),
        positive(max_heap_words, Opts, ?DEFAULT_MAX_HEAP_WORDS,
                 1024, 16000000),
        utf8_binary(author, Opts, <<"context_compactor">>, 1, 256),
        compactor(maps:get(compactor, Opts, undefined))
    ],
    case first_error(Values) of
        {error, _} = Error -> Error;
        none ->
            [Token, Event, Turns, Retain, BytesPerToken, MaxEvents,
             MaxInputBytes, MaxSummary, MaxCheckpoint, Timeout, MaxHeap, Author,
             {Module, CompactorOpts}] = [Value || {ok, Value} <- Values],
            case at_least_one_trigger(Token, Event, Turns) of
                false ->
                    {error, {invalid_compaction_options,
                             no_trigger_enabled}};
                true when Retain >= MaxEvents ->
                    {error, {invalid_compaction_options,
                             retain_recent_exchanges}};
                true ->
                    {ok, #{'$adk_compaction_policy' => ?VERSION,
                           token_threshold => Token,
                           event_threshold => Event,
                           turn_interval => Turns,
                           retain_recent_exchanges => Retain,
                           bytes_per_token => BytesPerToken,
                           max_input_events => MaxEvents,
                           max_input_bytes => MaxInputBytes,
                           max_summary_bytes => MaxSummary,
                           max_checkpoint_bytes => MaxCheckpoint,
                           timeout_ms => Timeout,
                           max_heap_words => MaxHeap,
                           author => Author,
                           compactor => Module,
                           compactor_options => CompactorOpts}}
            end
    end.

option_keys() ->
    [compactor, token_threshold, event_threshold, turn_interval,
     retain_recent_exchanges, bytes_per_token, max_input_events,
     max_input_bytes,
     max_summary_bytes, max_checkpoint_bytes, timeout_ms, max_heap_words,
     author].

unknown_keys(Map, Allowed) ->
    maps:keys(maps:without(Allowed, Map)).

threshold(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        disabled -> {ok, disabled};
        Value when is_integer(Value), Value > 0, Value =< 1000000000 ->
            {ok, Value};
        _ -> {error, {invalid_compaction_options, Key}}
    end.

positive(Key, Opts, Default, Minimum, Maximum) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value >= Minimum, Value =< Maximum ->
            {ok, Value};
        _ -> {error, {invalid_compaction_options, Key}}
    end.

utf8_binary(Key, Opts, Default, Minimum, Maximum) ->
    Value = maps:get(Key, Opts, Default),
    case is_binary(Value) andalso byte_size(Value) >= Minimum
         andalso byte_size(Value) =< Maximum andalso valid_utf8(Value) of
        true -> {ok, Value};
        false -> {error, {invalid_compaction_options, Key}}
    end.

compactor(undefined) ->
    {error, {invalid_compaction_options, compactor_required}};
compactor(Module) when is_atom(Module) ->
    compactor({Module, #{}});
compactor({Module, Opts}) when is_atom(Module), is_map(Opts) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, compact, 2) of
                true ->
                    case adk_context_guard:sanitize_value(Opts) of
                        {ok, SafeOpts} when is_map(SafeOpts) ->
                            case byte_size(jsx:encode(SafeOpts)) =< 65536 of
                                true -> {ok, {Module, SafeOpts}};
                                false ->
                                    {error, {invalid_compaction_options,
                                             compactor_options_too_large}}
                            end;
                        _ ->
                            {error, {invalid_compaction_options,
                                     compactor_options}}
                    end;
                false -> {error, {invalid_compactor, missing_callback}}
            end;
        _ -> {error, {invalid_compactor, unavailable}}
    end;
compactor(_) ->
    {error, {invalid_compaction_options, compactor}}.

first_error([]) -> none;
first_error([{error, _} = Error | _]) -> Error;
first_error([_ | Rest]) -> first_error(Rest).

at_least_one_trigger(disabled, disabled, disabled) -> false;
at_least_one_trigger(_, _, _) -> true.

validate_compiled_policy(#{'$adk_compaction_policy' := ?VERSION} = Policy) ->
    Required = ['$adk_compaction_policy', token_threshold, event_threshold,
                turn_interval, retain_recent_exchanges, bytes_per_token,
                max_input_events, max_input_bytes, max_summary_bytes,
                max_checkpoint_bytes,
                timeout_ms, max_heap_words, author, compactor,
                compactor_options],
    case lists:sort(maps:keys(Policy)) =:= lists:sort(Required) of
        true -> ok;
        false -> {error, invalid_compaction_policy}
    end;
validate_compiled_policy(_) -> {error, invalid_compaction_policy}.

normalize_stats(Stats, Policy) ->
    case unknown_keys(Stats,
                      [estimated_tokens, turns_since_compaction,
                       deadline_ms, cancel_ref]) of
        [] -> normalize_stats_known(Stats, Policy);
        Unknown ->
            {error, {invalid_compaction_stats,
                     {unknown_keys, lists:sort(Unknown)}}}
    end.

normalize_stats_known(Stats, Policy) ->
    Tokens = maps:get(estimated_tokens, Stats, automatic),
    Turns = maps:get(turns_since_compaction, Stats, 0),
    Deadline = maps:get(deadline_ms, Stats,
                        monotonic_ms() + maps:get(timeout_ms, Policy)),
    CancelRef = maps:get(cancel_ref, Stats, undefined),
    case valid_stats(Tokens, Turns, Deadline, CancelRef) of
        true ->
            {ok, #{estimated_tokens => Tokens,
                   turns_since_compaction => Turns,
                   deadline_ms => Deadline,
                   cancel_ref => CancelRef}};
        false -> {error, invalid_compaction_stats}
    end.

valid_stats(Tokens, Turns, Deadline, CancelRef) ->
    (Tokens =:= automatic orelse
     (is_integer(Tokens) andalso Tokens >= 0
      andalso Tokens =< 1000000000000)) andalso
    is_integer(Turns) andalso Turns >= 0
    andalso Turns =< 1000000000000 andalso
    is_integer(Deadline) andalso
    (CancelRef =:= undefined orelse is_reference(CancelRef)).

sanitize_events_bounded(Events, Max) ->
    sanitize_events_bounded(Events, Max, 0, []).

sanitize_events_bounded([], _Max, _Count, Acc) ->
    {ok, lists:reverse(Acc)};
sanitize_events_bounded(_Rest, Max, Count, _Acc) when Count >= Max ->
    {error, compaction_input_too_many_events};
sanitize_events_bounded([Event | Rest], Max, Count, Acc) ->
    case adk_context_guard:sanitize_event(Event) of
        {ok, Safe} ->
            sanitize_events_bounded(Rest, Max, Count + 1, [Safe | Acc]);
        {error, Reason} ->
            {error, {invalid_compaction_event, reason_tag(Reason)}}
    end;
sanitize_events_bounded(_Improper, _Max, _Count, _Acc) ->
    {error, invalid_compaction_event_list}.

validate_history(Events) ->
    validate_history(Events, undefined, #{}).

validate_history([], _PreviousTimestamp, _Ids) -> ok;
validate_history([Event | Rest], PreviousTimestamp, Ids) ->
    Id = maps:get(<<"id">>, Event),
    Timestamp = maps:get(<<"timestamp">>, Event),
    case {maps:is_key(Id, Ids),
          PreviousTimestamp =:= undefined
          orelse Timestamp >= PreviousTimestamp} of
        {true, _} -> {error, duplicate_compaction_event_id};
        {_, false} -> {error, non_chronological_compaction_history};
        {false, true} ->
            validate_history(Rest, Timestamp, Ids#{Id => true})
    end.

input_size_allowed(Events, Policy) ->
    lists:sum([byte_size(jsx:encode(Event)) || Event <- Events]) =<
    maps:get(max_input_bytes, Policy).

evaluate_safe(Events, Stats0, Policy) ->
    Tokens = case maps:get(estimated_tokens, Stats0) of
        automatic -> estimate_tokens(Events, Policy);
        Provided -> Provided
    end,
    Stats = Stats0#{estimated_tokens => Tokens},
    Trigger = select_trigger(Tokens, length(Events),
                             maps:get(turns_since_compaction, Stats), Policy),
    case Trigger of
        none ->
            {ok, no_compaction,
             decision_metadata(<<"not_triggered">>, Tokens,
                               length(Events), Policy)};
        _ -> prepare_compaction(Events, Trigger, Stats, Policy)
    end.

%% Token pressure deliberately wins even when every trigger is simultaneously
%% eligible. Event pressure wins over the periodic turn trigger.
select_trigger(Tokens, Events, Turns, Policy) ->
    case reached(Tokens, maps:get(token_threshold, Policy)) of
        true -> token_pressure;
        false ->
            case reached(Events, maps:get(event_threshold, Policy)) of
                true -> event_pressure;
                false ->
                    case reached(Turns, maps:get(turn_interval, Policy)) of
                        true -> turn_interval;
                        false -> none
                    end
            end
    end.

reached(_Value, disabled) -> false;
reached(Value, Threshold) -> Value >= Threshold.

prepare_compaction(Events, Trigger, Stats, Policy) ->
    Units = adk_event_filter:exchange_units(Events),
    RetainCount = maps:get(retain_recent_exchanges, Policy),
    case split_old_and_recent(Units, RetainCount) of
        {[], _Recent} ->
            {ok, no_compaction,
             decision_metadata(<<"insufficient_history">>,
                               maps:get(estimated_tokens, Stats),
                               length(Events), Policy)};
        {OldUnits, RecentUnits} ->
            Source = lists:append(OldUnits),
            Retained = lists:append(RecentUnits),
            run_compactor(Source, Retained, Trigger, Stats, Policy)
    end.

split_old_and_recent(Units, RetainCount) ->
    Count = length(Units),
    OldCount = erlang:max(0, Count - RetainCount),
    lists:split(OldCount, Units).

run_compactor(Source, Retained, Trigger, Stats, Policy) ->
    Deadline = effective_deadline(Stats, Policy),
    case Deadline =< monotonic_ms() of
        true -> {error, compaction_deadline_exceeded};
        false ->
            Owner = self(),
            ReplyRef = make_ref(),
            GuardianFun = fun() ->
                compactor_guardian(Owner, ReplyRef, Source, Trigger,
                                    Deadline, Policy)
            end,
            {Guardian, Monitor} = spawn_monitor(GuardianFun),
            await_compactor(Guardian, Monitor, ReplyRef, Source, Retained,
                            Trigger, Stats, Deadline, Policy)
    end.

effective_deadline(Stats, Policy) ->
    erlang:min(maps:get(deadline_ms, Stats),
               monotonic_ms() + maps:get(timeout_ms, Policy)).

compactor_guardian(Owner, ReplyRef, Source, Trigger, Deadline, Policy) ->
    process_flag(trap_exit, true),
    OwnerMonitor = erlang:monitor(process, Owner),
    Guardian = self(),
    ExecutorReply = make_ref(),
    Module = maps:get(compactor, Policy),
    Request = #{<<"schema_version">> => ?VERSION,
                <<"trigger">> => trigger_binary(Trigger),
                <<"source_event_count">> => length(Source),
                <<"options">> => maps:get(compactor_options, Policy)},
    ExecutorFun = fun() ->
        Result = try Module:compact(Source, Request) of
            Outcome -> prevalidate_executor_outcome(Outcome, Policy)
        catch
            Class:_Reason -> {adk_compactor_crashed, Class}
        end,
        Guardian ! {ExecutorReply, Result}
    end,
    SpawnOpts = [monitor, link,
                 {max_heap_size,
                  #{size => maps:get(max_heap_words, Policy),
                    kill => true, error_logger => false}}],
    {Executor, ExecutorMonitor} = spawn_opt(ExecutorFun, SpawnOpts),
    guardian_wait(Owner, OwnerMonitor, ReplyRef, Executor, ExecutorMonitor,
                  ExecutorReply, Deadline).

%% Reduce failures and reject oversized output in the executor. This prevents
%% an unbounded provider return from ever entering the invocation mailbox.
prevalidate_executor_outcome({ok, Summary} = Outcome, Policy) ->
    case summary_bytes(Summary) of
        {ok, Bytes} ->
            case Bytes =< maps:get(max_summary_bytes, Policy) of
                true -> Outcome;
                false -> {adk_compactor_invalid, summary_too_large}
            end;
        {error, _} -> {adk_compactor_invalid, invalid_summary}
    end;
prevalidate_executor_outcome({error, Reason}, _Policy) ->
    {error, reason_tag(Reason)};
prevalidate_executor_outcome(_Other, _Policy) ->
    {adk_compactor_invalid, invalid_return}.

guardian_wait(Owner, OwnerMonitor, ReplyRef, Executor, ExecutorMonitor,
              ExecutorReply, Deadline) ->
    Timeout = erlang:max(0, Deadline - monotonic_ms()),
    receive
        {ExecutorReply, Result} ->
            erlang:demonitor(ExecutorMonitor, [flush]),
            erlang:demonitor(OwnerMonitor, [flush]),
            Owner ! {ReplyRef, Result};
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            stop_process(Executor, ExecutorMonitor);
        {'DOWN', ExecutorMonitor, process, Executor, _Reason} ->
            erlang:demonitor(OwnerMonitor, [flush]),
            Owner ! {ReplyRef, {adk_compactor_crashed, exit}}
    after Timeout ->
        stop_process(Executor, ExecutorMonitor),
        erlang:demonitor(OwnerMonitor, [flush]),
        Owner ! {ReplyRef, adk_compactor_deadline}
    end.

await_compactor(Guardian, Monitor, ReplyRef, Source, Retained, Trigger,
                Stats, Deadline, Policy) ->
    CancelRef = maps:get(cancel_ref, Stats),
    Timeout = erlang:max(0, Deadline - monotonic_ms()),
    receive
        {ReplyRef, adk_compactor_deadline} ->
            erlang:demonitor(Monitor, [flush]),
            {error, compaction_deadline_exceeded};
        {ReplyRef, {adk_compactor_crashed, Class}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, {compactor_crashed, Class}};
        {ReplyRef, {adk_compactor_invalid, summary_too_large}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, compactor_summary_too_large};
        {ReplyRef, {adk_compactor_invalid, invalid_summary}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, invalid_compactor_summary};
        {ReplyRef, {adk_compactor_invalid, invalid_return}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, invalid_compactor_return};
        {ReplyRef, Result} ->
            erlang:demonitor(Monitor, [flush]),
            validate_and_build(Result, Source, Retained, Trigger,
                               Stats, Policy);
        {'DOWN', Monitor, process, Guardian, _Reason} ->
            {error, {compactor_crashed, exit}};
        {adk_context_compaction_cancel, CancelRef}
          when is_reference(CancelRef) ->
            stop_process(Guardian, Monitor),
            flush_reply(ReplyRef),
            {error, compaction_cancelled}
    after Timeout ->
        stop_process(Guardian, Monitor),
        flush_reply(ReplyRef),
        {error, compaction_deadline_exceeded}
    end.

validate_and_build({ok, Summary}, Source, Retained, Trigger, Stats, Policy) ->
    case summary_bytes(Summary) of
        {ok, Bytes} ->
            case Bytes =< maps:get(max_summary_bytes, Policy) of
                true ->
                    build_result(Summary, Source, Retained, Trigger, Stats,
                                 Bytes, Policy);
                false -> {error, compactor_summary_too_large}
            end;
        {error, _} -> {error, invalid_compactor_summary}
    end;
validate_and_build({error, Reason}, _Source, _Retained, _Trigger,
                   _Stats, _Policy) ->
    {error, {compactor_error, reason_tag(Reason)}};
validate_and_build(_, _Source, _Retained, _Trigger, _Stats, _Policy) ->
    {error, invalid_compactor_return}.

summary_bytes(Summary) when is_binary(Summary) ->
    case valid_utf8(Summary) andalso byte_size(Summary) > 0 of
        true -> {ok, byte_size(Summary)};
        false -> {error, invalid_summary}
    end;
summary_bytes(Summary) when is_map(Summary) ->
    case adk_content:validate(Summary, adk_content:safety_limits()) of
        {ok, Canonical} -> {ok, byte_size(jsx:encode(Canonical))};
        {error, _} = Error -> Error
    end;
summary_bytes(_) -> {error, invalid_summary}.

build_result(Summary0, Source, Retained, Trigger, Stats, SummaryBytes, Policy) ->
    {ok, Summary} = normalize_summary(Summary0),
    SourceMeta = source_metadata(Source),
    Action = #{<<"schema_version">> => ?VERSION,
               <<"kind">> => <<"context_compaction">>,
               <<"trigger">> => trigger_binary(Trigger),
               <<"source">> => SourceMeta,
               <<"retained_event_count">> => length(Retained)},
    LastSource = lists:last(Source),
    Event0 = adk_event:new(
               maps:get(author, Policy), Summary,
               #{invocation_id => maps:get(<<"invocation_id">>, LastSource),
                 actions => #{<<"context_compaction">> => Action}}),
    Event = Event0#adk_event{
              timestamp = maps:get(<<"timestamp">>, LastSource)},
    case adk_context_guard:sanitize_event(Event) of
        {ok, SummaryEvent} ->
            Checkpoint = checkpoint(SummaryEvent, SourceMeta, Retained,
                                    Trigger, SummaryBytes),
            Result = #{<<"schema_version">> => ?VERSION,
                       <<"status">> => <<"compacted">>,
                       <<"events">> => [SummaryEvent | Retained],
                       <<"checkpoint">> => Checkpoint,
                       <<"metadata">> =>
                           result_metadata(Trigger, Source, Retained,
                                           Stats, SummaryBytes)},
            validate_result_size(Result, Policy);
        {error, _} -> {error, invalid_compactor_summary_event}
    end.

normalize_summary(Summary) when is_binary(Summary) -> {ok, Summary};
normalize_summary(Summary) -> adk_content:validate(
                                Summary, adk_content:safety_limits()).

source_metadata(Source) ->
    First = hd(Source),
    Last = lists:last(Source),
    #{<<"event_count">> => length(Source),
      <<"first_event_id">> => maps:get(<<"id">>, First),
      <<"last_event_id">> => maps:get(<<"id">>, Last),
      <<"first_timestamp">> => maps:get(<<"timestamp">>, First),
      <<"last_timestamp">> => maps:get(<<"timestamp">>, Last),
      <<"fingerprint">> => fingerprint(Source)}.

checkpoint(SummaryEvent, SourceMeta, Retained, Trigger, SummaryBytes) ->
    #{<<"schema_version">> => ?VERSION,
      <<"kind">> => <<"context_compaction_checkpoint">>,
      <<"checkpoint_id">> => maps:get(<<"id">>, SummaryEvent),
      <<"summary_event_id">> => maps:get(<<"id">>, SummaryEvent),
      <<"trigger">> => trigger_binary(Trigger),
      <<"source">> => SourceMeta,
      <<"retained_event_count">> => length(Retained),
      <<"summary_bytes">> => SummaryBytes}.

result_metadata(Trigger, Source, Retained, Stats, SummaryBytes) ->
    #{<<"trigger">> => trigger_binary(Trigger),
      <<"source_event_count">> => length(Source),
      <<"retained_event_count">> => length(Retained),
      <<"output_event_count">> => length(Retained) + 1,
      <<"estimated_context_units_before">> =>
          maps:get(estimated_tokens, Stats),
      <<"summary_bytes">> => SummaryBytes,
      <<"telemetry">> =>
          #{<<"event">> => <<"erlang_adk.context.compaction">>,
            <<"measurements">> =>
                #{<<"source_events">> => length(Source),
                  <<"retained_events">> => length(Retained),
                  <<"summary_bytes">> => SummaryBytes},
            <<"metadata">> =>
                #{<<"schema_version">> => ?VERSION,
                  <<"trigger">> => trigger_binary(Trigger)}}}.

decision_metadata(Reason, Tokens, EventCount, Policy) ->
    #{<<"schema_version">> => ?VERSION,
      <<"decision">> => Reason,
      <<"estimated_context_units">> => Tokens,
      <<"event_count">> => EventCount,
      <<"thresholds">> =>
          #{<<"context_units">> => json_threshold(
                                      maps:get(token_threshold, Policy)),
            <<"event">> => json_threshold(
                               maps:get(event_threshold, Policy)),
            <<"turn_interval">> => json_threshold(
                                       maps:get(turn_interval, Policy))}}.

validate_result_size(Result, Policy) ->
    case adk_json:normalize(Result) of
        {ok, Safe} ->
            CheckpointBytes = byte_size(
                                jsx:encode(maps:get(<<"checkpoint">>, Safe))),
            case CheckpointBytes =< maps:get(max_checkpoint_bytes, Policy) of
                true -> {ok, Safe};
                false -> {error, compaction_checkpoint_too_large}
            end;
        {error, _} -> {error, invalid_compaction_result}
    end.

estimate_tokens(Events, Policy) ->
    Bytes = lists:sum([byte_size(jsx:encode(Event)) || Event <- Events]),
    case Bytes of
        0 -> 0;
        _ ->
            Divisor = maps:get(bytes_per_token, Policy),
            (Bytes + Divisor - 1) div Divisor
    end.

fingerprint(Value) ->
    hex(crypto:hash(sha256, term_to_binary(Value, [deterministic]))).

trigger_binary(token_pressure) -> <<"token_pressure">>;
trigger_binary(event_pressure) -> <<"event_pressure">>;
trigger_binary(turn_interval) -> <<"turn_interval">>.

json_threshold(disabled) -> null;
json_threshold(Value) -> Value.

stop_process(Pid, Monitor) ->
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush])
    end.

flush_reply(ReplyRef) ->
    receive {ReplyRef, _} -> ok after 0 -> ok end.

monotonic_ms() -> erlang:monotonic_time(millisecond).

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end.

reason_tag(Reason) when is_atom(Reason) -> Reason;
reason_tag(Reason) when is_tuple(Reason), tuple_size(Reason) > 0,
                        is_atom(element(1, Reason)) ->
    element(1, Reason);
reason_tag(_) -> unspecified.

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>
       || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
