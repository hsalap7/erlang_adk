-module(adk_context_compaction_test).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

compaction_test_() ->
    [fun strict_configuration/0,
     fun trigger_precedence_and_exchange_retention/0,
     fun no_trigger_and_insufficient_history/0,
     fun deadline_and_failure_are_contained/0,
     fun explicit_cancellation_kills_executor/0,
     fun owner_death_kills_executor/0].

strict_configuration() ->
    ?assertMatch(
       {error, {invalid_compaction_options, {unknown_keys, [unknown]}}},
       adk_context_compaction:compile(
         (base_options())#{unknown => true})),
    ?assertMatch(
       {error, {invalid_compaction_options, no_trigger_enabled}},
       adk_context_compaction:compile(
         #{compactor => adk_context_lifecycle_test_compactor})),
    ?assertMatch(
       {error, {invalid_compaction_options, retain_recent_exchanges}},
       adk_context_compaction:compile(
         (base_options())#{max_input_events => 2,
                           retain_recent_exchanges => 2})),
    ?assertMatch(
       {error, {invalid_compactor, unavailable}},
       adk_context_compaction:compile(
         (base_options())#{compactor => adk_missing_compactor})),
    ?assertMatch({ok, _}, adk_context_compaction:compile(base_options())),
    {ok, ByteBound} = adk_context_compaction:compile(
                        (base_options())#{max_input_bytes => 1}),
    ?assertEqual({error, compaction_input_too_large},
                 adk_context_compaction:evaluate(
                   two_events(), #{estimated_tokens => 100}, ByteBound)).

trigger_precedence_and_exchange_retention() ->
    Events = exchange_history(),
    {ok, Policy} = adk_context_compaction:compile(
                     (base_options())#{event_threshold => 1,
                                       turn_interval => 1,
                                       retain_recent_exchanges => 2}),
    {ok, Result} = adk_context_compaction:evaluate(
                     Events,
                     #{estimated_tokens => 100,
                       turns_since_compaction => 100}, Policy),
    ?assertEqual(1, maps:get(<<"schema_version">>, Result)),
    ?assertEqual(<<"compacted">>, maps:get(<<"status">>, Result)),
    Metadata = maps:get(<<"metadata">>, Result),
    ?assertEqual(<<"token_pressure">>, maps:get(<<"trigger">>, Metadata)),
    ?assertEqual(2, maps:get(<<"source_event_count">>, Metadata)),
    Output = maps:get(<<"events">>, Result),
    %% One summary plus a complete call/response exchange and current input.
    ?assertEqual(4, length(Output)),
    [_Summary, RetainedCall, RetainedResponse, RetainedCurrent] = Output,
    [_Old1, _Old2, Call, Response, Current] = canonical(Events),
    ?assertEqual(Call, RetainedCall),
    ?assertEqual(Response, RetainedResponse),
    ?assertEqual(Current, RetainedCurrent),
    Checkpoint = maps:get(<<"checkpoint">>, Result),
    ?assertEqual(1, maps:get(<<"schema_version">>, Checkpoint)),
    ?assertEqual(<<"context_compaction_checkpoint">>,
                 maps:get(<<"kind">>, Checkpoint)),
    ?assert(is_binary(jsx:encode(Result))),
    ?assertEqual(false, contains_sensitive_key(Result)).

no_trigger_and_insufficient_history() ->
    Events = two_events(),
    {ok, QuietPolicy} = adk_context_compaction:compile(
                          (base_options())#{token_threshold => 100000}),
    {ok, no_compaction, Quiet} = adk_context_compaction:evaluate(
                                   Events,
                                   #{estimated_tokens => 1,
                                     turns_since_compaction => 0}, QuietPolicy),
    ?assertEqual(<<"not_triggered">>, maps:get(<<"decision">>, Quiet)),
    {ok, ShortPolicy} = adk_context_compaction:compile(
                          (base_options())#{retain_recent_exchanges => 4}),
    {ok, no_compaction, Short} = adk_context_compaction:evaluate(
                                   Events, #{estimated_tokens => 100},
                                   ShortPolicy),
    ?assertEqual(<<"insufficient_history">>,
                 maps:get(<<"decision">>, Short)).

deadline_and_failure_are_contained() ->
    ok = adk_context_lifecycle_test_compactor:reset(),
    {ok, DelayPolicy} = adk_context_compaction:compile(
                          (base_options())#{
                            compactor =>
                                {adk_context_lifecycle_test_compactor,
                                 #{mode => delay, delay_ms => 1000}},
                            timeout_ms => 2000}),
    Deadline = erlang:monotonic_time(millisecond) + 50,
    ?assertEqual(
       {error, compaction_deadline_exceeded},
       adk_context_compaction:evaluate(
         two_events(), #{estimated_tokens => 100, deadline_ms => Deadline},
         DelayPolicy)),
    Executor = wait_compactor_worker(100),
    assert_down(Executor),
    {ok, ErrorPolicy} = adk_context_compaction:compile(
                          (base_options())#{
                            compactor =>
                                {adk_context_lifecycle_test_compactor,
                                 #{mode => error}}}),
    ?assertEqual(
       {error, {compactor_error, fixture_failure}},
       adk_context_compaction:evaluate(
         two_events(), #{estimated_tokens => 100}, ErrorPolicy)),
    {ok, OversizedPolicy} = adk_context_compaction:compile(
                              (base_options())#{
                                compactor =>
                                  {adk_context_lifecycle_test_compactor,
                                   #{mode => oversized}},
                                max_summary_bytes => 128}),
    ?assertEqual(
       {error, compactor_summary_too_large},
       adk_context_compaction:evaluate(
         two_events(), #{estimated_tokens => 100}, OversizedPolicy)).

explicit_cancellation_kills_executor() ->
    ok = adk_context_lifecycle_test_compactor:reset(),
    {ok, Policy} = delay_policy(),
    Parent = self(),
    CancelRef = make_ref(),
    Caller = spawn(fun() ->
        Result = adk_context_compaction:evaluate(
                   two_events(),
                   #{estimated_tokens => 100,
                     deadline_ms => erlang:monotonic_time(millisecond) + 5000,
                     cancel_ref => CancelRef}, Policy),
        Parent ! {cancel_result, Result}
    end),
    Executor = wait_compactor_worker(100),
    Caller ! adk_context_compaction:cancel_message(CancelRef),
    receive
        {cancel_result, Result} ->
            ?assertEqual({error, compaction_cancelled}, Result)
    after 1000 -> error(compaction_did_not_cancel)
    end,
    assert_down(Executor).

owner_death_kills_executor() ->
    ok = adk_context_lifecycle_test_compactor:reset(),
    {ok, Policy} = delay_policy(),
    Caller = spawn(fun() ->
        _ = adk_context_compaction:evaluate(
              two_events(),
              #{estimated_tokens => 100,
                deadline_ms => erlang:monotonic_time(millisecond) + 5000},
              Policy)
    end),
    Executor = wait_compactor_worker(100),
    exit(Caller, kill),
    assert_down(Executor).

base_options() ->
    #{compactor => adk_context_lifecycle_test_compactor,
      token_threshold => 10,
      retain_recent_exchanges => 1}.

delay_policy() ->
    adk_context_compaction:compile(
      (base_options())#{
        compactor => {adk_context_lifecycle_test_compactor,
                      #{mode => delay, delay_ms => 5000}},
        timeout_ms => 10000}).

two_events() ->
    [timestamp(adk_event:new(<<"user">>, <<"old">>), 1),
     timestamp(adk_event:new(<<"user">>, <<"current">>), 2)].

exchange_history() ->
    Invocation = <<"invocation">>,
    CallId = <<"call-1">>,
    [timestamp(adk_event:new(<<"user">>, <<"old one">>), 1),
     timestamp(adk_event:new(<<"agent">>, <<"old two">>), 2),
     timestamp(adk_event:new(
                 <<"agent">>,
                 {tool_calls,
                  [{<<"lookup">>, #{<<"query">> => <<"x">>},
                    undefined, CallId}]},
                 #{invocation_id => Invocation}), 3),
     timestamp(adk_event:new(
                 <<"tool">>,
                 {tool_response, <<"lookup">>, #{<<"result">> => 1},
                  undefined, CallId},
                 #{invocation_id => Invocation}), 4),
     timestamp(adk_event:new(<<"user">>, <<"current">>), 5)].

timestamp(Event, Value) -> Event#adk_event{timestamp = Value}.

canonical(Events) ->
    [begin {ok, Map} = adk_context_guard:sanitize_event(Event), Map end
     || Event <- Events].

assert_down(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(process_outlived_owner_or_deadline)
    end.

wait_compactor_worker(0) -> error(compactor_did_not_start);
wait_compactor_worker(Attempts) ->
    case adk_context_lifecycle_test_compactor:last_worker() of
        undefined ->
            timer:sleep(10),
            wait_compactor_worker(Attempts - 1);
        Pid -> Pid
    end.

contains_sensitive_key(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          adk_context_guard:sensitive_key(Key)
          orelse contains_sensitive_key(Value)
      end, maps:to_list(Map));
contains_sensitive_key(List) when is_list(List) ->
    lists:any(fun contains_sensitive_key/1, List);
contains_sensitive_key(_) -> false.
