-module(adk_trace_store_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"trace-owner">>).
-define(TRACE_ID, <<"0123456789abcdef0123456789abcdef">>).
-define(RUN_ID, <<"run-1">>).
-define(INVOCATION_ID, <<"invocation-1">>).

configuration_is_strict_test() ->
    ?assertEqual(
       {error, invalid_trace_store_options},
       invalid_start(#{name => undefined, max_events => 0})),
    ?assertMatch(
       {error, {invalid_trace_store_options, {unknown_keys, [_]}}},
       invalid_start(#{name => undefined, unknown => true})),
    ?assertEqual(
       {error, invalid_trace_store_options},
       invalid_start(
         #{name => undefined, max_events => 2, max_bytes => 4096,
           max_event_bytes => 2048, max_bytes_per_principal => 1024})).

observability_events_are_ordered_and_identity_indexed_test() ->
    {ok, Store} = start_store(#{}),
    try
        {ok, 1} = adk_trace_store:append_observability(
                    Store, ?PRINCIPAL,
                    observability(?RUN_ID, ?TRACE_ID, <<"started">>)),
        {ok, 2} = adk_trace_store:append_observability(
                    Store, ?PRINCIPAL,
                    observability(?RUN_ID, ?TRACE_ID, <<"finished">>)),
        {ok, Page} = adk_trace_store:query(
                       Store, ?PRINCIPAL,
                       #{run_id => ?RUN_ID, trace_id => ?TRACE_ID}, #{}),
        Events = maps:get(<<"events">>, Page),
        ?assertEqual([1, 2],
                     [maps:get(<<"cursor">>, Event) || Event <- Events]),
        ?assertEqual(2, maps:get(<<"next_cursor">>, Page)),
        ?assertEqual(false, maps:get(<<"truncated">>, Page)),
        lists:foreach(
          fun(Event) ->
              ?assertEqual(<<"observability">>,
                           maps:get(<<"kind">>, Event)),
              Identity = maps:get(<<"identity">>, Event),
              ?assertEqual(?RUN_ID, maps:get(<<"run_id">>, Identity)),
              ?assertEqual(?TRACE_ID, maps:get(<<"trace_id">>, Identity))
          end, Events),
        {ok, PrincipalStatus} = adk_trace_store:principal_status(
                                  Store, ?PRINCIPAL),
        ?assertEqual(2, maps:get(<<"events">>, PrincipalStatus))
    after
        gen_server:stop(Store)
    end.

workflow_lifecycle_uses_existing_schema_and_combined_selector_test() ->
    {ok, Store} = start_store(#{}),
    try
        Event = lifecycle(<<"node_started">>, 1),
        {ok, 1} = adk_trace_store:append_lifecycle(
                    Store, ?PRINCIPAL, Event),
        {ok, Page} = adk_trace_store:query(
                       Store, ?PRINCIPAL,
                       #{workflow_id => <<"checkout">>,
                         invocation_id => ?INVOCATION_ID}, #{}),
        [Stored] = maps:get(<<"events">>, Page),
        ?assertEqual(<<"workflow_lifecycle">>,
                     maps:get(<<"kind">>, Stored)),
        ?assertEqual(Event, maps:get(<<"event">>, Stored)),
        ?assertEqual(
           {error, invalid_trace_lifecycle_event},
           adk_trace_store:append_lifecycle(
             Store, ?PRINCIPAL, maps:remove(<<"workflow_id">>, Event)))
    after
        gen_server:stop(Store)
    end.

metadata_only_rejects_content_by_default_test() ->
    {ok, Store} = start_store(#{}),
    try
        Content = (observability(?RUN_ID, ?TRACE_ID, <<"private">>))#{
                    <<"content_captured">> => true,
                    <<"content">> => #{<<"prompt">> => <<"secret prompt">>}},
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL, Content)),
        Nested = observability(?RUN_ID, ?TRACE_ID, <<"nested">>),
        Metadata = maps:get(<<"metadata">>, Nested),
        Attributes = maps:get(<<"attributes">>, Metadata),
        NestedContent = Nested#{
                          <<"metadata">> =>
                              Metadata#{<<"attributes">> =>
                                            Attributes#{
                                              <<"arguments">> =>
                                                  #{<<"token">> =>
                                                        <<"secret">>}}}},
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL, NestedContent)),
        {ok, Status} = adk_trace_store:status(Store),
        Counters = maps:get(<<"counters">>, Status),
        ?assertEqual(2, maps:get(<<"content_rejected">>, Counters)),
        ?assertEqual(0, maps:get(<<"events">>, Status))
    after
        gen_server:stop(Store)
    end.

trusted_prune_policy_removes_content_and_marks_record_test() ->
    {ok, Store} = start_store(#{content_policy => prune}),
    try
        Content = (observability(?RUN_ID, ?TRACE_ID, <<"private">>))#{
                    <<"content_captured">> => true,
                    <<"content">> =>
                        #{<<"prompt">> => <<"must-not-be-retained">>},
                    <<"payload">> => <<"payload-must-not-be-retained">>,
                    <<"responseBody">> =>
                        <<"camel-must-not-be-retained">>},
        {ok, 1} = adk_trace_store:append_observability(
                    Store, ?PRINCIPAL, Content),
        {ok, Page} = adk_trace_store:query(
                       Store, ?PRINCIPAL, #{run_id => ?RUN_ID}, #{}),
        [Stored] = maps:get(<<"events">>, Page),
        ?assertEqual(true, maps:get(<<"content_pruned">>, Stored)),
        Envelope = maps:get(<<"event">>, Stored),
        ?assertEqual(false, maps:get(<<"content_captured">>, Envelope)),
        ?assertNot(maps:is_key(<<"content">>, Envelope)),
        ?assertNot(maps:is_key(<<"payload">>, Envelope)),
        ?assertNot(maps:is_key(<<"responseBody">>, Envelope)),
        ?assertEqual(
           nomatch,
           binary:match(term_to_binary(Stored), <<"must-not-be-retained">>)),
        ?assertEqual(
           nomatch,
           binary:match(term_to_binary(Stored),
                        <<"payload-must-not-be-retained">>)),
        ?assertEqual(
           nomatch,
           binary:match(term_to_binary(Stored),
                        <<"camel-must-not-be-retained">>))
    after
        gen_server:stop(Store)
    end.

strict_projection_rejects_alias_and_casing_bypasses_test() ->
    {ok, Store} = start_store(#{}),
    try
        Secret = <<"alias-secret-never-retained">>,
        Aliases = [<<"payload">>, <<"input">>, <<"completion">>,
                   <<"request-body">>, <<"responseBody">>,
                   <<"PromptText">>],
        lists:foreach(
          fun(Key) ->
              Event = (observability(?RUN_ID, ?TRACE_ID, <<"alias">>))#{
                        Key => Secret},
              ?assertEqual(
                 {error, trace_content_rejected},
                 adk_trace_store:append_observability(
                   Store, ?PRINCIPAL, Event))
          end, Aliases),
        Nested0 = observability(?RUN_ID, ?TRACE_ID, <<"nested-alias">>),
        Metadata = maps:get(<<"metadata">>, Nested0),
        Attributes = maps:get(<<"attributes">>, Metadata),
        Nested = Nested0#{
                   <<"metadata">> => Metadata#{
                     <<"attributes">> => Attributes#{
                       <<"payLoad">> => Secret}}},
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL, Nested)),
        NestedMetadata = Nested0#{
                           <<"metadata">> => Metadata#{
                             <<"session">> =>
                                 #{<<"payload">> => Secret}}},
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL, NestedMetadata)),
        MalformedAttributes = Nested0#{
                                <<"metadata">> => Metadata#{
                                  <<"attributes">> => [Secret]}},
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL, MalformedAttributes)),
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_lifecycle(
             Store, ?PRINCIPAL,
             (lifecycle(<<"node_started">>, 1))#{
               <<"completion">> => Secret})),
        Span0 = observability_span(),
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL,
             Span0#{<<"payload">> => Secret})),
        SpanAttributes = maps:get(<<"attributes">>, Span0),
        ?assertEqual(
           {error, trace_content_rejected},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL,
             Span0#{<<"attributes">> =>
                        SpanAttributes#{<<"completionText">> => Secret}})),
        {ok, Status} = adk_trace_store:status(Store),
        ?assertEqual(0, maps:get(<<"events">>, Status)),
        ?assertEqual(length(Aliases) + 6,
                     maps:get(<<"content_rejected">>,
                              maps:get(<<"counters">>, Status)))
    after
        gen_server:stop(Store)
    end.

capacity_eviction_reports_exact_replay_gap_test() ->
    {ok, Store} = start_store(#{max_events => 2,
                                max_events_per_principal => 2,
                                max_query_events => 2}),
    try
        append_three(Store, ?PRINCIPAL, ?RUN_ID),
        {error, {replay_gap, Gap}} = adk_trace_store:query(
                                        Store, ?PRINCIPAL,
                                        #{run_id => ?RUN_ID},
                                        #{after_cursor => 0}),
        ?assertEqual(1, maps:get(<<"evicted_through">>, Gap)),
        ?assertEqual(2, maps:get(<<"oldest_available_cursor">>, Gap)),
        ?assertEqual(3, maps:get(<<"latest_cursor">>, Gap)),
        {ok, Page} = adk_trace_store:query(
                       Store, ?PRINCIPAL, #{run_id => ?RUN_ID},
                       #{after_cursor => 1}),
        ?assertEqual([2, 3], cursors(Page)),
        {ok, CurrentWindow} = adk_trace_store:query(
                                Store, ?PRINCIPAL,
                                #{run_id => ?RUN_ID}, #{}),
        ?assertEqual([2, 3], cursors(CurrentWindow))
    after
        gen_server:stop(Store)
    end.

query_paging_is_bounded_and_cursor_continues_test() ->
    {ok, Store} = start_store(#{max_query_events => 2}),
    try
        append_three(Store, ?PRINCIPAL, ?RUN_ID),
        {ok, First} = adk_trace_store:query(
                        Store, ?PRINCIPAL, #{run_id => ?RUN_ID},
                        #{limit => 2}),
        ?assertEqual([1, 2], cursors(First)),
        ?assertEqual(true, maps:get(<<"truncated">>, First)),
        {ok, Second} = adk_trace_store:query(
                         Store, ?PRINCIPAL, #{run_id => ?RUN_ID},
                         #{after_cursor =>
                               maps:get(<<"next_cursor">>, First),
                           limit => 2}),
        ?assertEqual([3], cursors(Second)),
        ?assertEqual(false, maps:get(<<"truncated">>, Second)),
        ?assertMatch(
           {error, {cursor_ahead, _}},
           adk_trace_store:query(
             Store, ?PRINCIPAL, #{run_id => ?RUN_ID},
             #{after_cursor => 99}))
    after
        gen_server:stop(Store)
    end.

principal_capacity_and_scope_isolation_are_fail_closed_test() ->
    {ok, Store} = start_store(#{max_principals => 1}),
    try
        {ok, 1} = adk_trace_store:append_observability(
                    Store, <<"alice">>,
                    observability(?RUN_ID, ?TRACE_ID, <<"one">>)),
        ?assertEqual(
           {error, trace_principal_capacity_reached},
           adk_trace_store:append_observability(
             Store, <<"bob">>,
             observability(?RUN_ID, ?TRACE_ID, <<"two">>))),
        {ok, Alice} = adk_trace_store:query(
                        Store, <<"alice">>, #{run_id => ?RUN_ID}, #{}),
        ?assertEqual([1], cursors(Alice)),
        {ok, Bob} = adk_trace_store:query(
                      Store, <<"bob">>, #{run_id => ?RUN_ID}, #{}),
        ?assertEqual([], maps:get(<<"events">>, Bob)),
        {ok, Status} = adk_trace_store:status(Store),
        ?assertEqual(1, maps:get(<<"principals">>, Status))
    after
        gen_server:stop(Store)
    end.

event_and_query_byte_limits_are_strict_test() ->
    {ok, Store} = start_store(
                    #{max_event_bytes => 1024,
                      max_query_bytes => 2048}),
    try
        Event = observability(?RUN_ID, ?TRACE_ID, <<"large">>),
        Large = Event#{<<"event">> => binary:copy(<<"x">>, 1500)},
        ?assertEqual(
           {error, trace_event_too_large},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL, Large)),
        ?assertEqual(
           {error, invalid_trace_query_options},
           adk_trace_store:query(
             Store, ?PRINCIPAL, all, #{max_bytes => 1023}))
    after
        gen_server:stop(Store)
    end.

deep_trace_input_is_rejected_before_normalization_test() ->
    {ok, Store} = start_store(#{}),
    try
        Deep = (observability(?RUN_ID, ?TRACE_ID, <<"deep">>))#{
                 <<"nested">> => deep_map(40)},
        ?assertEqual(
           {error, trace_event_input_too_large},
           adk_trace_store:append_observability(
             Store, ?PRINCIPAL, Deep)),
        ?assert(is_process_alive(Store))
    after
        gen_server:stop(Store)
    end.

retention_pruning_preserves_gap_tombstone_test() ->
    {ok, Store} = start_store(#{retention_ms => 20,
                                prune_interval_ms => 20}),
    try
        {ok, 1} = adk_trace_store:append_observability(
                    Store, ?PRINCIPAL,
                    observability(?RUN_ID, ?TRACE_ID, <<"expires">>)),
        timer:sleep(35),
        {ok, _} = adk_trace_store:prune(Store),
        {ok, Status} = adk_trace_store:status(Store),
        ?assertEqual(0, maps:get(<<"events">>, Status)),
        ?assertMatch(
           {error, {replay_gap, _}},
           adk_trace_store:query(
             Store, ?PRINCIPAL, #{run_id => ?RUN_ID},
             #{after_cursor => 0}))
    after
        gen_server:stop(Store)
    end.

caller_lifetime_and_status_are_owner_safe_test() ->
    {ok, Store} = start_store(#{}),
    PrivatePrincipal = <<"principal-never-retained-raw">>,
    Parent = self(),
    Caller = spawn(fun() ->
        Result = adk_trace_store:append_observability(
                   Store, PrivatePrincipal,
                   observability(?RUN_ID, ?TRACE_ID, <<"owner">>)),
        Parent ! {append_result, self(), Result}
    end),
    Monitor = erlang:monitor(process, Caller),
    receive {append_result, Caller, {ok, 1}} -> ok
    after 1000 -> error(append_timeout)
    end,
    receive {'DOWN', Monitor, process, Caller, normal} -> ok
    after 1000 -> error(caller_not_stopped)
    end,
    ?assert(is_process_alive(Store)),
    {ok, Page} = adk_trace_store:query(
                   Store, PrivatePrincipal, #{run_id => ?RUN_ID}, #{}),
    ?assertEqual([1], cursors(Page)),
    Formatted = sys:get_status(Store),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Formatted), PrivatePrincipal)),
    ok = gen_server:stop(Store),
    ?assertEqual({error, trace_store_unavailable},
                 adk_trace_store:status(Store)).

format_status_redacts_in_flight_message_log_and_reason_test() ->
    Secret = <<"raw-principal-and-event-must-not-escape">>,
    Formatted = adk_trace_store:format_status(
                  #{message => {append, Secret, #{payload => Secret}},
                    log => [{in, Secret}],
                    reason => {bad_event, Secret},
                    unrelated => ok}),
    ?assertEqual([], maps:get(log, Formatted)),
    ?assertEqual(ok, maps:get(unrelated, Formatted)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Formatted), Secret)).

forged_admission_cast_does_not_crash_store_test() ->
    {ok, Store} = start_store(#{}),
    try
        gen_server:cast(
          Store,
          {append_lifecycle_capability, make_ref(), make_ref(),
           lifecycle(<<"workflow_terminal">>, 1)}),
        {ok, Status} = adk_trace_store:status(Store),
        ?assert(is_process_alive(Store)),
        ?assertEqual(
           1,
           maps:get(<<"lifecycle_capability_rejected">>,
                    maps:get(<<"counters">>, Status)))
    after
        gen_server:stop(Store)
    end.

rejected_capability_balances_shared_admission_test() ->
    {ok, Store} = start_store(#{max_lifecycle_pending => 2}),
    try
        {ok, {'$adk_trace_store_lifecycle_receiver', 2,
              Store, _Capability, Admission, MaxPending} = Receiver} =
            adk_trace_store:lifecycle_receiver(Store, ?PRINCIPAL),
        Forged = {'$adk_trace_store_lifecycle_receiver', 2,
                  Store, make_ref(), Admission, MaxPending},
        ok = adk_trace_store:deliver_lifecycle(
               Forged, lifecycle(<<"node_started">>, 1)),
        {ok, RejectedStatus} = adk_trace_store:status(Store),
        ?assertEqual(0,
                     maps:get(<<"lifecycle_pending">>, RejectedStatus)),
        ok = adk_trace_store:deliver_lifecycle(
               Receiver, lifecycle(<<"workflow_terminal">>, 2)),
        Page = await_lifecycle_page(Store, 100),
        ?assertEqual(1, length(maps:get(<<"events">>, Page)))
    after
        gen_server:stop(Store)
    end.

expired_capability_does_not_saturate_new_receiver_test() ->
    {ok, Store} = start_store(
                    #{retention_ms => 20, prune_interval_ms => 20,
                      lifecycle_receiver_ttl_ms => 20,
                      max_lifecycle_pending => 2}),
    try
        {ok, OldReceiver} = adk_trace_store:lifecycle_receiver(
                              Store, ?PRINCIPAL),
        timer:sleep(35),
        {ok, _} = adk_trace_store:prune(Store),
        ok = adk_trace_store:deliver_lifecycle(
               OldReceiver, lifecycle(<<"node_started">>, 1)),
        {ok, Status} = adk_trace_store:status(Store),
        ?assertEqual(0, maps:get(<<"lifecycle_pending">>, Status)),
        {ok, NewReceiver} = adk_trace_store:lifecycle_receiver(
                              Store, ?PRINCIPAL),
        ?assertNotEqual(OldReceiver, NewReceiver),
        ok = adk_trace_store:deliver_lifecycle(
               NewReceiver, lifecycle(<<"workflow_terminal">>, 2)),
        Page = await_lifecycle_page(Store, 100),
        ?assertEqual(1, length(maps:get(<<"events">>, Page)))
    after
        gen_server:stop(Store)
    end.

lifecycle_mailbox_admission_is_bounded_test() ->
    {ok, Store} = start_store(#{max_lifecycle_pending => 2}),
    try
        {ok, Receiver} = adk_trace_store:lifecycle_receiver(
                           Store, ?PRINCIPAL),
        ok = sys:suspend(Store),
        lists:foreach(
          fun(Sequence) ->
              ok = adk_trace_store:deliver_lifecycle(
                     Receiver, lifecycle(<<"node_started">>, Sequence))
          end, lists:seq(1, 10)),
        ok = sys:resume(Store),
        Status = await_lifecycle_drain(Store, 100),
        ?assertEqual(0, maps:get(<<"lifecycle_pending">>, Status)),
        Counters = maps:get(<<"counters">>, Status),
        ?assertEqual(8,
                     maps:get(<<"lifecycle_delivery_dropped">>, Counters)),
        ?assertEqual(2, maps:get(<<"accepted">>, Counters))
    after
        _ = catch sys:resume(Store),
        gen_server:stop(Store)
    end.

lifecycle_receiver_ttl_is_independent_of_event_retention_test() ->
    {ok, Store} = start_store(
                    #{retention_ms => 20, prune_interval_ms => 20,
                      lifecycle_receiver_ttl_ms => 200}),
    try
        {ok, Receiver} = adk_trace_store:lifecycle_receiver(
                           Store, ?PRINCIPAL),
        timer:sleep(35),
        {ok, _} = adk_trace_store:prune(Store),
        ok = adk_trace_store:deliver_lifecycle(
               Receiver, lifecycle(<<"workflow_terminal">>, 1)),
        Page = await_lifecycle_page(Store, 100),
        [Stored] = maps:get(<<"events">>, Page),
        ?assertEqual(
           <<"workflow_terminal">>,
           maps:get(<<"type">>, maps:get(<<"event">>, Stored)))
    after
        gen_server:stop(Store)
    end.

small_page_query_work_is_independent_of_stream_size_test() ->
    Count = 2000,
    {ok, Store} = start_store(
                    #{max_events => Count,
                      max_bytes => 8388608,
                      max_events_per_principal => Count,
                      max_bytes_per_principal => 8388608,
                      retention_ms => 60000,
                      prune_interval_ms => 60000}),
    try
        lists:foreach(
          fun(Index) ->
              {ok, Index} = adk_trace_store:append_observability(
                              Store, ?PRINCIPAL,
                              observability(
                                ?RUN_ID, ?TRACE_ID,
                                integer_to_binary(Index)))
          end, lists:seq(1, Count)),
        {reductions, Before} = process_info(Store, reductions),
        {ok, Page} = adk_trace_store:query(
                       Store, ?PRINCIPAL, #{run_id => ?RUN_ID},
                       #{after_cursor => Count - 2, limit => 1}),
        {reductions, After} = process_info(Store, reductions),
        ?assertEqual([Count - 1], cursors(Page)),
        ?assert(After - Before < 20000)
    after
        gen_server:stop(Store)
    end.

start_store(Overrides) ->
    Base = #{name => undefined,
             max_events => 8,
             max_bytes => 65536,
             max_event_bytes => 8192,
             max_principals => 4,
             max_events_per_principal => 8,
             max_bytes_per_principal => 65536,
             retention_ms => 5000,
             prune_interval_ms => 1000,
             max_query_events => 8,
             max_query_bytes => 65536},
    adk_trace_store:start_link(maps:merge(Base, Overrides)).

observability(RunId, TraceId, Phase) ->
    #{<<"schema_version">> => 1,
      <<"event">> => <<"erlang_adk.test.trace">>,
      <<"timestamp_ms">> => erlang:system_time(millisecond),
      <<"measurements">> => #{<<"count">> => 1},
      <<"metadata">> =>
          #{<<"run_id">> => RunId,
            <<"trace_id">> => TraceId,
            <<"invocation_id">> => ?INVOCATION_ID,
            <<"attributes">> => #{<<"phase">> => Phase}},
      <<"content_captured">> => false}.

lifecycle(Type, Sequence) ->
    #{<<"schema_version">> => 1,
      <<"type">> => Type,
      <<"sequence">> => Sequence,
      <<"timestamp">> => erlang:system_time(millisecond),
      <<"workflow_id">> => <<"checkout">>,
      <<"workflow_kind">> => <<"graph">>,
      <<"invocation_id">> => ?INVOCATION_ID,
      <<"node_id">> => <<"authorize">>}.

observability_span() ->
    #{<<"schema_version">> => 2,
      <<"signal">> => <<"span">>,
      <<"phase">> => <<"end">>,
      <<"name">> => <<"gen_ai.generate_content">>,
      <<"kind">> => <<"client">>,
      <<"trace_id">> => ?TRACE_ID,
      <<"span_id">> => <<"0123456789abcdef">>,
      <<"parent_span_id">> => null,
      <<"trace_flags">> => 1,
      <<"start_time_unix_nano">> => 1000,
      <<"end_time_unix_nano">> => 2000,
      <<"duration_nano">> => 1000,
      <<"status">> => <<"ok">>,
      <<"attributes">> =>
          #{<<"gen_ai.operation.name">> => <<"generate_content">>,
            <<"gen_ai.provider.name">> => <<"google">>,
            <<"gen_ai.usage.input_tokens">> => 3}}.

append_three(Store, Principal, RunId) ->
    lists:foreach(
      fun(Index) ->
          {ok, Index} = adk_trace_store:append_observability(
                          Store, Principal,
                          observability(
                            RunId, ?TRACE_ID,
                            integer_to_binary(Index)))
      end, [1, 2, 3]).

cursors(Page) ->
    [maps:get(<<"cursor">>, Event)
     || Event <- maps:get(<<"events">>, Page)].

deep_map(0) -> <<"leaf">>;
deep_map(Depth) -> #{<<"nested">> => deep_map(Depth - 1)}.

invalid_start(Options) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        process_flag(trap_exit, true),
        Parent ! {Ref, adk_trace_store:start_link(Options)}
    end),
    Monitor = erlang:monitor(process, Pid),
    Result = receive
        {Ref, Value} -> Value
    after 1000 -> error(invalid_start_timeout)
    end,
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 -> error(invalid_start_owner_not_stopped)
    end,
    Result.

await_lifecycle_drain(_Store, 0) ->
    error(lifecycle_delivery_did_not_drain);
await_lifecycle_drain(Store, Attempts) ->
    {ok, Status} = adk_trace_store:status(Store),
    case maps:get(<<"lifecycle_pending">>, Status) of
        0 -> Status;
        _ ->
            timer:sleep(5),
            await_lifecycle_drain(Store, Attempts - 1)
    end.

await_lifecycle_page(_Store, 0) ->
    error(lifecycle_event_not_retained);
await_lifecycle_page(Store, Attempts) ->
    {ok, Page} = adk_trace_store:query(
                   Store, ?PRINCIPAL,
                   #{workflow_id => <<"checkout">>}, #{}),
    case maps:get(<<"events">>, Page) of
        [] ->
            timer:sleep(5),
            await_lifecycle_page(Store, Attempts - 1);
        _ -> Page
    end.
