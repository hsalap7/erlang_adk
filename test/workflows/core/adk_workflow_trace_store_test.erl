-module(adk_workflow_trace_store_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"workflow-trace-owner">>).

workflow_trace_store_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun lifecycle_descriptor_retains_end_to_end_events/0,
      fun active_workflow_outlives_receiver_ttl_and_retains_terminal/0,
      fun unavailable_store_does_not_delay_workflow/0,
      fun suspended_store_does_not_delay_workflow/0,
      fun pid_receiver_behavior_is_preserved/0,
      fun forged_capability_cannot_inject_for_principal/0,
      fun malformed_lifecycle_descriptor_is_rejected/0]}.

lifecycle_descriptor_retains_end_to_end_events() ->
    {ok, Store} = start_store(),
    try
        {ok, Receiver} = adk_trace_store:lifecycle_receiver(
                           Store, ?PRINCIPAL),
        ?assertEqual(nomatch,
                     binary:match(term_to_binary(Receiver), ?PRINCIPAL)),
        Compiled = workflow(<<"trace-retained-workflow">>),
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{},
                      #{lifecycle_receiver => Receiver,
                        retention_ms => 2000}),
        {completed, _State, Checkpoint} = adk_workflow:await(Ref, 1000),
        InvocationId = maps:get(<<"execution_id">>, Checkpoint),
        Selector = #{workflow_id => <<"trace-retained-workflow">>,
                     invocation_id => InvocationId},
        Page = await_terminal_page(Store, ?PRINCIPAL, Selector, 100),
        Events = maps:get(<<"events">>, Page),
        Lifecycle = [maps:get(<<"event">>, Event) || Event <- Events],
        Types = [maps:get(<<"type">>, Event) || Event <- Lifecycle],
        ?assertEqual(<<"workflow_started">>, hd(Types)),
        ?assertEqual(<<"workflow_terminal">>, lists:last(Types)),
        ?assert(lists:member(<<"node_started">>, Types)),
        ?assert(lists:member(<<"node_completed">>, Types)),
        ?assertEqual(lists:seq(1, length(Lifecycle)),
                     [maps:get(<<"sequence">>, Event)
                      || Event <- Lifecycle]),
        ?assertEqual(lists:seq(1, length(Events)),
                     [maps:get(<<"cursor">>, Event) || Event <- Events]),
        ?assertEqual(
           nomatch,
           binary:match(term_to_binary(sys:get_status(Ref)), ?PRINCIPAL))
    after
        gen_server:stop(Store)
    end.

active_workflow_outlives_receiver_ttl_and_retains_terminal() ->
    {ok, Store} = start_store(
                    #{lifecycle_receiver_ttl_ms => 20,
                      prune_interval_ms => 10,
                      retention_ms => 20}),
    try
        {ok, Receiver} = adk_trace_store:lifecycle_receiver(
                           Store, ?PRINCIPAL),
        Compiled = delayed_workflow(<<"trace-owner-bound-ttl">>, 100),
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{},
                      #{lifecycle_receiver => Receiver,
                        retention_ms => 1000}),
        ok = await_active_owner(Store, 100),
        timer:sleep(35),
        {ok, _} = adk_trace_store:prune(Store),
        {completed, _State, Checkpoint} = adk_workflow:await(Ref, 1000),
        Selector = #{workflow_id => <<"trace-owner-bound-ttl">>,
                     invocation_id => maps:get(<<"execution_id">>,
                                               Checkpoint)},
        Page = await_terminal_page(Store, ?PRINCIPAL, Selector, 100),
        ?assertMatch([_ | _], maps:get(<<"events">>, Page))
    after
        gen_server:stop(Store)
    end.

unavailable_store_does_not_delay_workflow() ->
    {ok, Store} = start_store(),
    {ok, Receiver} = adk_trace_store:lifecycle_receiver(Store, ?PRINCIPAL),
    ok = gen_server:stop(Store),
    Compiled = workflow(<<"trace-store-unavailable">>),
    Started = erlang:monotonic_time(millisecond),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{},
                  #{lifecycle_receiver => Receiver, retention_ms => 1000}),
    ?assertMatch({completed, _, _}, adk_workflow:await(Ref, 1000)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 900),
    {ok, Status} = adk_workflow:status(Ref),
    ?assertEqual(completed, maps:get(state, Status)).

suspended_store_does_not_delay_workflow() ->
    {ok, Store} = start_store(),
    try
        {ok, Receiver} = adk_trace_store:lifecycle_receiver(
                           Store, ?PRINCIPAL),
        ok = sys:suspend(Store),
        Compiled = workflow(<<"trace-store-suspended">>),
        Started = erlang:monotonic_time(millisecond),
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{},
                      #{lifecycle_receiver => Receiver,
                        retention_ms => 1000}),
        ?assertMatch({completed, _, _}, adk_workflow:await(Ref, 1000)),
        ?assert(erlang:monotonic_time(millisecond) - Started < 900)
    after
        ok = sys:resume(Store),
        gen_server:stop(Store)
    end.

pid_receiver_behavior_is_preserved() ->
    Compiled = workflow(<<"trace-pid-receiver">>),
    {ok, Ref} = adk_workflow:start(
                  Compiled, #{},
                  #{lifecycle_receiver => self(), retention_ms => 1000}),
    ?assertMatch({completed, _, _}, adk_workflow:await(Ref, 1000)),
    Events = receive_until_terminal(Ref, []),
    ?assertEqual(<<"workflow_started">>,
                 maps:get(<<"type">>, hd(Events))),
    ?assertEqual(<<"workflow_terminal">>,
                 maps:get(<<"type">>, lists:last(Events))).

forged_capability_cannot_inject_for_principal() ->
    {ok, Store} = start_store(),
    try
        Admission = atomics:new(2, [{signed, true}]),
        Forged = {'$adk_trace_store_lifecycle_receiver', 2,
                  Store, make_ref(), Admission, 8},
        Compiled = workflow(<<"trace-forged-capability">>),
        {ok, Ref} = adk_workflow:start(
                      Compiled, #{},
                      #{lifecycle_receiver => Forged,
                        retention_ms => 1000}),
        ?assertMatch({completed, _, _}, adk_workflow:await(Ref, 1000)),
        await_capability_rejection(Store, 100),
        {ok, Page} = adk_trace_store:query(
                       Store, ?PRINCIPAL,
                       #{workflow_id => <<"trace-forged-capability">>}, #{}),
        ?assertEqual([], maps:get(<<"events">>, Page))
    after
        gen_server:stop(Store)
    end.

malformed_lifecycle_descriptor_is_rejected() ->
    Compiled = workflow(<<"trace-forged-receiver">>),
    ?assertEqual(
       {error, {workflow_start_failed, invalid_workflow_options}},
       adk_workflow:start(
         Compiled, #{},
         #{lifecycle_receiver =>
               {'$adk_trace_store_lifecycle_receiver', 2,
                adk_trace_store, make_ref(), make_ref(), 8}})),
    %% A plain reference is not an atomics admission handle and must be
    %% rejected before workflow delivery can touch it.
    Forged = {'$adk_trace_store_lifecycle_receiver', 2,
              adk_trace_store, make_ref(), make_ref(), 8},
    ?assertEqual(false, adk_trace_store:is_lifecycle_receiver(Forged)),
    ?assertEqual(ok, adk_trace_store:deliver_lifecycle(Forged, #{})).

workflow(Id) ->
    {ok, Compiled} = adk_workflow:compile(
                       #{version => 1,
                         id => Id,
                         kind => sequential,
                         definition_revision => 1,
                         steps =>
                             [#{id => <<"work">>,
                                run => fun(State) ->
                                    {output, <<"done">>,
                                     State#{<<"completed">> => true}}
                                end}],
                         max_steps => 2}),
    Compiled.

delayed_workflow(Id, DelayMs) ->
    {ok, Compiled} = adk_workflow:compile(
                       #{version => 1,
                         id => Id,
                         kind => sequential,
                         definition_revision => 1,
                         steps =>
                             [#{id => <<"slow-work">>,
                                run => fun(State) ->
                                    timer:sleep(DelayMs),
                                    {output, <<"done">>, State}
                                end}],
                         max_steps => 2}),
    Compiled.

start_store() ->
    start_store(#{}).

start_store(Overrides) ->
    adk_trace_store:start_link(
      maps:merge(
        #{name => undefined,
        max_events => 32,
        max_bytes => 262144,
        max_event_bytes => 8192,
        max_principals => 4,
        max_events_per_principal => 32,
        max_bytes_per_principal => 262144,
        retention_ms => 5000,
        prune_interval_ms => 1000,
        max_query_events => 32,
        max_query_bytes => 262144}, Overrides)).

receive_until_terminal(Ref, Acc) ->
    receive
        {adk_workflow_lifecycle, Ref, Event} ->
            Next = [Event | Acc],
            case maps:get(<<"type">>, Event) of
                <<"workflow_terminal">> -> lists:reverse(Next);
                _ -> receive_until_terminal(Ref, Next)
            end
    after 1000 ->
        error({missing_terminal_lifecycle, lists:reverse(Acc)})
    end.

await_terminal_page(_Store, _Principal, _Selector, 0) ->
    error(missing_retained_terminal_lifecycle);
await_terminal_page(Store, Principal, Selector, Attempts) ->
    {ok, Page} = adk_trace_store:query(
                   Store, Principal, Selector, #{}),
    Events = maps:get(<<"events">>, Page),
    case lists:any(
           fun(Event) ->
               Envelope = maps:get(<<"event">>, Event),
               maps:get(<<"type">>, Envelope, undefined) =:=
                   <<"workflow_terminal">>
           end, Events) of
        true -> Page;
        false ->
            timer:sleep(5),
            await_terminal_page(Store, Principal, Selector, Attempts - 1)
    end.

await_capability_rejection(_Store, 0) ->
    error(missing_capability_rejection);
await_capability_rejection(Store, Attempts) ->
    {ok, Status} = adk_trace_store:status(Store),
    Counters = maps:get(<<"counters">>, Status),
    case maps:get(<<"lifecycle_capability_rejected">>, Counters) > 0 of
        true -> ok;
        false ->
            timer:sleep(5),
            await_capability_rejection(Store, Attempts - 1)
    end.

await_active_owner(_Store, 0) -> error(missing_lifecycle_owner_binding);
await_active_owner(Store, Attempts) ->
    {ok, Status} = adk_trace_store:status(Store),
    case maps:get(<<"lifecycle_active_owners">>, Status) > 0 of
        true -> ok;
        false ->
            timer:sleep(5),
            await_active_owner(Store, Attempts - 1)
    end.
