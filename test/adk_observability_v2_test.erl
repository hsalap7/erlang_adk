-module(adk_observability_v2_test).
-include_lib("eunit/include/eunit.hrl").

genai_metadata_only_mapping_test() ->
    {ok, Attributes} = adk_genai_semconv:attributes(
                         generate_content,
                         #{model => <<"gemini-3.1-flash-lite">>,
                           tool => <<"weather">>, call_id => <<"call-1">>},
                         #{provider => <<"google">>,
                           response_model => <<"gemini-3.1-flash-lite">>,
                           response_id => <<"response-1">>,
                           input_tokens => 11, output_tokens => 7,
                           finish_reasons => [<<"STOP">>],
                           prompt => <<"must not be mapped">>,
                           output => <<"must not be mapped">>}),
    ?assertEqual(<<"generate_content">>,
                 maps:get(<<"gen_ai.operation.name">>, Attributes)),
    ?assertEqual(11, maps:get(<<"gen_ai.usage.input_tokens">>, Attributes)),
    ?assertEqual([<<"STOP">>],
                 maps:get(<<"gen_ai.response.finish_reasons">>, Attributes)),
    ?assertNot(maps:is_key(<<"prompt">>, Attributes)),
    ?assertNot(maps:is_key(<<"output">>, Attributes)),
    ?assertMatch({error, _},
                 adk_genai_semconv:attributes(
                   generate_content, #{}, #{provider => <<>>})).

operation_span_uses_execution_time_and_parentage_test() ->
    {ok, Root} = adk_observability:new_context(
                   #{run_id => <<"run-span">>, model => <<"model-a">>}),
    Delivery = #{delivery => sync, exporters => []},
    {ok, Span} = adk_observability:start_span(
                   generate_content, client, Root,
                   #{provider => <<"google">>,
                     request_model => <<"model-a">>}, Delivery),
    timer:sleep(5),
    {ok, End} = adk_observability:finish_span(
                  Span, ok,
                  #{response_model => <<"model-a">>,
                    response_id => <<"response-a">>,
                    input_tokens => 3, output_tokens => 2,
                    finish_reasons => [<<"STOP">>]}),
    ?assertEqual(2, maps:get(<<"schema_version">>, End)),
    ?assertEqual(<<"span">>, maps:get(<<"signal">>, End)),
    ?assertEqual(<<"end">>, maps:get(<<"phase">>, End)),
    ?assert(maps:get(<<"duration_nano">>, End) >= 4000000),
    ?assertEqual(maps:get(span_id, Root),
                 maps:get(<<"parent_span_id">>, End)),
    ?assertEqual({ok, End}, adk_observability:decode(End)).

operation_span_error_is_structural_test() ->
    {ok, Root} = adk_observability:new_context(#{}),
    {ok, Span} = adk_observability:start_span(
                   execute_tool, internal, Root, #{tool => <<"weather">>},
                   #{delivery => sync, exporters => []}),
    {ok, End} = adk_observability:finish_span(
                  Span, {error, timeout}, #{}),
    ?assertEqual(<<"error">>, maps:get(<<"status">>, End)),
    Attributes = maps:get(<<"attributes">>, End),
    ?assertEqual(<<"timeout">>, maps:get(<<"error.type">>, Attributes)).

bounded_metric_cardinality_test() ->
    Name = adk_observability_metrics_v2_test,
    {ok, Pid} = adk_observability_metrics:start_link(
                  #{name => Name, max_instruments => 2,
                    max_series_per_instrument => 2}),
    unlink(Pid),
    try
        {ok, #{overflow := false}} = adk_observability_metrics:record(
                                       Name, <<"gen_ai.client.operation.duration">>,
                                       histogram, 10,
                                       #{<<"gen_ai.provider.name">> => <<"google">>,
                                         <<"status">> => <<"ok">>}),
        {ok, #{overflow := false}} = adk_observability_metrics:record(
                                       Name, <<"gen_ai.client.operation.duration">>,
                                       histogram, 20,
                                       #{<<"gen_ai.provider.name">> => <<"google">>,
                                         <<"status">> => <<"error">>}),
        {ok, #{overflow := true}} = adk_observability_metrics:record(
                                      Name, <<"gen_ai.client.operation.duration">>,
                                      histogram, 30,
                                      #{<<"gen_ai.provider.name">> => <<"other">>,
                                        <<"status">> => <<"ok">>}),
        Snapshot = adk_observability_metrics:snapshot(Name),
        ?assertEqual(1, maps:get(<<"overflow_records">>, Snapshot)),
        Instruments = maps:get(<<"instruments">>, Snapshot),
        Metric = maps:get(<<"gen_ai.client.operation.duration">>, Instruments),
        ?assertEqual(3, length(maps:get(<<"series">>, Metric)))
    after
        gen_server:stop(Pid)
    end.

async_bus_exports_and_drains_test() ->
    Name = adk_observability_bus_v2_test,
    Exporter = #{id => <<"test">>,
                 module => adk_observability_test_exporter,
                 config => #{test_pid => self(), label => async, action => ok},
                 timeout_ms => 1000, max_heap_words => 100000,
                 failure_policy => open},
    {ok, Pid} = adk_observability_bus:start_link(
                  #{name => Name, exporters => [Exporter], batch_size => 2,
                    max_queue_events => 4, max_queue_bytes => 1048576,
                    max_event_bytes => 262144, flush_interval_ms => 10}),
    unlink(Pid),
    try
        Envelope = envelope(),
        {ok, accepted} = adk_observability_bus:enqueue(Name, Envelope),
        ok = adk_observability_bus:drain(Name, 2000),
        receive {exported, async, Envelope} -> ok
        after 1000 -> erlang:error(async_export_timeout)
        end,
        Stats = adk_observability_bus:stats(Name),
        Counters = maps:get(<<"counters">>, Stats),
        ?assertEqual(1, maps:get(<<"accepted">>, Counters)),
        ?assertEqual(1, maps:get(<<"exported">>, Counters)),
        ?assertEqual(0, maps:get(<<"queue_events">>, Stats))
    after
        gen_server:stop(Pid)
    end.

async_bus_count_backpressure_test() ->
    Name = adk_observability_bus_pressure_test,
    Exporter = #{id => <<"slow">>,
                 module => adk_observability_test_exporter,
                 config => #{test_pid => self(), label => slow,
                             action => timeout, delay_ms => 250},
                 timeout_ms => 1000, max_heap_words => 100000,
                 failure_policy => open},
    {ok, Pid} = adk_observability_bus:start_link(
                  #{name => Name, exporters => [Exporter], batch_size => 1,
                    max_inflight_batches => 1, max_queue_events => 1,
                    max_queue_bytes => 1048576, max_event_bytes => 262144,
                    flush_interval_ms => 10, drop_policy => reject}),
    unlink(Pid),
    try
        Envelope = envelope(),
        {ok, accepted} = adk_observability_bus:enqueue(Name, Envelope),
        receive {exported, slow, Envelope} -> ok
        after 1000 -> erlang:error(slow_worker_not_started)
        end,
        {ok, accepted} = adk_observability_bus:enqueue(Name, Envelope),
        ?assertEqual({error, queue_full},
                     adk_observability_bus:enqueue(Name, Envelope)),
        ok = adk_observability_bus:drain(Name, 3000),
        Stats = adk_observability_bus:stats(Name),
        Counters = maps:get(<<"counters">>, Stats),
        ?assertEqual(1, maps:get(<<"dropped_rejected">>, Counters))
    after
        gen_server:stop(Pid)
    end.

async_bus_retries_structural_failures_test() ->
    Name = adk_observability_bus_retry_test,
    Exporter = #{id => <<"error">>,
                 module => adk_observability_test_exporter,
                 config => #{action => error, test_pid => self(),
                             label => delayed_retry}, timeout_ms => 1000,
                 max_heap_words => 100000, failure_policy => open},
    {ok, Pid} = adk_observability_bus:start_link(
                  #{name => Name, exporters => [Exporter], batch_size => 1,
                    max_attempts => 2, flush_interval_ms => 10,
                    retry_base_delay_ms => 100,
                    retry_max_delay_ms => 100}),
    unlink(Pid),
    try
        {ok, accepted} = adk_observability_bus:enqueue(Name, envelope()),
        receive {exported, delayed_retry, _} -> ok
        after 1000 -> erlang:error(first_export_attempt_missing)
        end,
        receive
            {exported, delayed_retry, _} ->
                erlang:error(retry_was_not_delayed)
        after 40 -> ok
        end,
        receive {exported, delayed_retry, _} -> ok
        after 1000 -> erlang:error(delayed_retry_missing)
        end,
        ok = adk_observability_bus:drain(Name, 3000),
        Counters = maps:get(<<"counters">>,
                            adk_observability_bus:stats(Name)),
        ?assertEqual(2, maps:get(<<"failed_attempts">>, Counters)),
        ?assertEqual(1, maps:get(<<"retried">>, Counters)),
        ?assertEqual(1, maps:get(<<"export_failed">>, Counters))
    after
        gen_server:stop(Pid)
    end.

drain_waiters_expire_are_bounded_and_cancel_on_owner_death_test() ->
    Name = adk_observability_bus_drainer_test,
    Exporter = #{id => <<"slow-drain">>,
                 module => adk_observability_test_exporter,
                 config => #{action => timeout, delay_ms => 1000,
                             test_pid => self(), label => drain_slow},
                 timeout_ms => 2000, max_heap_words => 100000,
                 failure_policy => open},
    {ok, Pid} = adk_observability_bus:start_link(
                  #{name => Name, exporters => [Exporter], batch_size => 1,
                    max_inflight_batches => 1, max_drain_waiters => 1,
                    batch_timeout_ms => 2000, flush_interval_ms => 10}),
    unlink(Pid),
    try
        {ok, accepted} = adk_observability_bus:enqueue(Name, envelope()),
        receive {exported, drain_slow, _} -> ok
        after 1000 -> erlang:error(slow_drain_export_not_started)
        end,
        Parent = self(),
        Expiring = spawn(fun() ->
            Parent ! {expiring_drain,
                      adk_observability_bus:drain(Name, 30)}
        end),
        _ = Expiring,
        receive
            {expiring_drain, {error, drain_timeout}} -> ok
        after 1000 -> erlang:error(drain_waiter_did_not_expire)
        end,
        wait_for_drain_waiters(Name, 0, 100),
        Waiting = spawn(fun() ->
            Parent ! {waiting_drain,
                      adk_observability_bus:drain(Name, 1000)}
        end),
        wait_for_drain_waiters(Name, 1, 100),
        ?assertEqual({error, drain_waiter_limit},
                     adk_observability_bus:drain(Name, 100)),
        exit(Waiting, kill),
        wait_for_drain_waiters(Name, 0, 100),
        Stats = adk_observability_bus:stats(Name),
        ?assertEqual(<<"bounded_best_effort">>,
                     maps:get(<<"delivery_guarantee">>, Stats))
    after
        gen_server:stop(Pid)
    end.

batch_timeout_kills_nested_exporter_callback_test() ->
    Name = adk_observability_bus_exporter_owner_test,
    Exporter = #{id => <<"owned-callback">>,
                 module => adk_observability_test_exporter,
                 config => #{action => owner_fence, test_pid => self(),
                             label => owned_callback},
                 timeout_ms => 30000, max_heap_words => 100000,
                 failure_policy => open},
    {ok, Pid} = adk_observability_bus:start_link(
                  #{name => Name, exporters => [Exporter], batch_size => 1,
                    max_inflight_batches => 1, max_attempts => 1,
                    batch_timeout_ms => 30, flush_interval_ms => 10}),
    unlink(Pid),
    try
        {ok, accepted} = adk_observability_bus:enqueue(Name, envelope()),
        Callback = receive
            {exporter_callback_started, CallbackPid} -> CallbackPid
        after 1000 -> erlang:error(nested_exporter_callback_not_started)
        end,
        Monitor = erlang:monitor(process, Callback),
        receive
            {'DOWN', Monitor, process, Callback, _} -> ok
        after 1000 -> erlang:error(nested_exporter_callback_orphaned)
        end,
        ok = adk_observability_bus:drain(Name, 1000),
        Counters = maps:get(
                     <<"counters">>, adk_observability_bus:stats(Name)),
        ?assertEqual(1, maps:get(<<"worker_timeouts">>, Counters)),
        ?assertEqual(1, maps:get(<<"export_failed">>, Counters))
    after
        gen_server:stop(Pid)
    end.

envelope() ->
    {ok, Context} = adk_observability:new_context(#{run_id => <<"run">>}),
    {ok, Envelope} = adk_observability:emit(
                       [erlang_adk, test, async], #{count => 1}, Context),
    Envelope.

wait_for_drain_waiters(_Name, _Expected, 0) ->
    erlang:error(drain_waiter_state_timeout);
wait_for_drain_waiters(Name, Expected, Attempts) ->
    Stats = adk_observability_bus:stats(Name),
    case maps:get(<<"drain_waiters">>, Stats) of
        Expected -> ok;
        _ ->
            timer:sleep(10),
            wait_for_drain_waiters(Name, Expected, Attempts - 1)
    end.
