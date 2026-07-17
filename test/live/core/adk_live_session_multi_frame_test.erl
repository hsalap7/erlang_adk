-module(adk_live_session_multi_frame_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"principal-live-multi-frame-test">>).

multi_frame_live_session_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun ordered_batch_returns_last_sequence_case/0,
      fun priority_batch_preserves_internal_order_case/0,
      fun in_flight_priority_batch_remains_contiguous_case/0,
      fun single_priority_frame_does_not_split_in_flight_batch_case/0,
      fun ignored_action_is_sequence_and_capacity_neutral_case/0,
      fun message_backpressure_is_all_or_nothing_case/0,
      fun byte_backpressure_and_invalid_batches_are_atomic_case/0]}.

setup() ->
    case whereis(adk_live_session_sup) of
        undefined ->
            {ok, Pid} = adk_live_session_sup:start_link(),
            unlink(Pid),
            {started, Pid};
        Pid -> {existing, Pid}
    end.

cleanup({started, Pid}) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        erlang:demonitor(Ref, [flush]),
        ok
    end;
cleanup({existing, _Pid}) -> ok.

ordered_batch_returns_last_sequence_case() ->
    {Session, Handle} = start_ready_session(#{}),
    ok = adk_live_fake_transport:set_busy(Handle, true),
    ?assertEqual(
       {ok, 3},
       adk_live_session:send_text(Session, ?PRINCIPAL, <<"multi">>)),
    {ok, Queued} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(3, maps:get(input_queue_messages, Queued)),
    ?assertEqual(24, maps:get(input_queue_bytes, Queued)),
    ok = adk_live_fake_transport:writable(Handle),
    ?assertEqual(<<"normal-1">>, receive_sent(Handle)),
    ?assertEqual(<<"normal-2">>, receive_sent(Handle)),
    ?assertEqual(<<"normal-3">>, receive_sent(Handle)),
    wait_for_empty_ingress(Session, 50),
    %% The legacy single-frame result still consumes exactly one sequence.
    ?assertEqual(
       {ok, 4},
       adk_live_session:send_text(Session, ?PRINCIPAL, <<"single">>)),
    ?assertEqual(<<"single">>, receive_sent(Handle)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

priority_batch_preserves_internal_order_case() ->
    {Session, Handle} = start_ready_session(#{}),
    ok = adk_live_fake_transport:set_busy(Handle, true),
    {ok, 1} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"single">>),
    %% Control retains its existing queue-front priority. The two provider
    %% frames must not be reversed when inserted ahead of normal input.
    {ok, 3} = adk_live_session:activity_start(Session, ?PRINCIPAL),
    {ok, Queued} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(3, maps:get(input_queue_messages, Queued)),
    ok = adk_live_fake_transport:writable(Handle),
    ?assertEqual(<<"control-1">>, receive_sent(Handle)),
    ?assertEqual(<<"control-2">>, receive_sent(Handle)),
    ?assertEqual(<<"single">>, receive_sent(Handle)),
    wait_for_empty_ingress(Session, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

in_flight_priority_batch_remains_contiguous_case() ->
    {Session, Handle} = start_ready_session(#{}),
    ok = adk_live_fake_transport:set_auto_ack(Handle, false),
    {ok, 2} = adk_live_session:activity_start(Session, ?PRINCIPAL),
    ?assertEqual(<<"control-1">>, receive_sent(Handle)),
    %% The first batch now has one in-flight frame and one queued frame. A
    %% later priority action may precede other actions, but must not split the
    %% provider batch whose transmission has already started.
    {ok, 4} = adk_live_session:activity_end(Session, ?PRINCIPAL),
    ok = adk_live_fake_transport:ack_sent(Handle),
    ?assertEqual(<<"control-2">>, receive_sent(Handle)),
    ok = adk_live_fake_transport:ack_sent(Handle),
    ?assertEqual(<<"later-control-1">>, receive_sent(Handle)),
    ok = adk_live_fake_transport:ack_sent(Handle),
    ?assertEqual(<<"later-control-2">>, receive_sent(Handle)),
    ok = adk_live_fake_transport:ack_sent(Handle),
    wait_for_empty_ingress(Session, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

single_priority_frame_does_not_split_in_flight_batch_case() ->
    {Session, Handle} = start_ready_session(
                          #{provider_config => #{single_end => true}}),
    ok = adk_live_fake_transport:set_auto_ack(Handle, false),
    {ok, 2} = adk_live_session:activity_start(Session, ?PRINCIPAL),
    ?assertEqual(<<"control-1">>, receive_sent(Handle)),
    {ok, 3} = adk_live_session:activity_end(Session, ?PRINCIPAL),
    ok = adk_live_fake_transport:ack_sent(Handle),
    ?assertEqual(<<"control-2">>, receive_sent(Handle)),
    ok = adk_live_fake_transport:ack_sent(Handle),
    ?assertEqual(<<"later-control-single">>, receive_sent(Handle)),
    ok = adk_live_fake_transport:ack_sent(Handle),
    wait_for_empty_ingress(Session, 50),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

ignored_action_is_sequence_and_capacity_neutral_case() ->
    {Session, Handle} = start_ready_session(#{}),
    ok = adk_live_fake_transport:set_busy(Handle, true),
    ?assertEqual(
       {ok, no_op},
       adk_live_session:audio_stream_end(Session, ?PRINCIPAL)),
    {ok, Empty} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(0, maps:get(input_queue_messages, Empty)),
    ?assertEqual(0, maps:get(input_queue_bytes, Empty)),
    assert_no_sent_frame(Handle),
    %% The ignored provider action allocates no input sequence. The next real
    %% frame therefore receives sequence one even while the transport is busy.
    ?assertEqual(
       {ok, 1},
       adk_live_session:send_text(Session, ?PRINCIPAL, <<"single">>)),
    {ok, One} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(1, maps:get(input_queue_messages, One)),
    ?assertEqual(6, maps:get(input_queue_bytes, One)),
    ok = adk_live_fake_transport:writable(Handle),
    ?assertEqual(<<"single">>, receive_sent(Handle)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

message_backpressure_is_all_or_nothing_case() ->
    {Session, Handle} = start_ready_session(
                          #{max_ingress_messages => 3}),
    ok = adk_live_fake_transport:set_busy(Handle, true),
    {ok, 1} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"single">>),
    ?assertEqual(
       {error, ingress_backpressure},
       adk_live_session:send_text(Session, ?PRINCIPAL, <<"multi">>)),
    {ok, Queued} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(1, maps:get(input_queue_messages, Queued)),
    ?assertEqual(6, maps:get(input_queue_bytes, Queued)),
    ok = adk_live_fake_transport:writable(Handle),
    ?assertEqual(<<"single">>, receive_sent(Handle)),
    assert_no_sent_frame(Handle),
    wait_for_empty_ingress(Session, 50),
    %% A rejected batch allocates no input sequences.
    {ok, 2} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"single">>),
    ?assertEqual(<<"single">>, receive_sent(Handle)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

byte_backpressure_and_invalid_batches_are_atomic_case() ->
    {Session, Handle} = start_ready_session(
                          #{max_ingress_messages => 8,
                            max_ingress_bytes => 1024}),
    ok = adk_live_fake_transport:set_busy(Handle, true),
    ?assertEqual(
       {error, ingress_backpressure},
       adk_live_session:send_text(Session, ?PRINCIPAL, <<"wide">>)),
    ?assertEqual(
       {error, invalid_provider_result},
       adk_live_session:send_text(
         Session, ?PRINCIPAL, <<"empty-list">>)),
    ?assertEqual(
       {error, invalid_provider_result},
       adk_live_session:send_text(
         Session, ?PRINCIPAL, <<"invalid-member">>)),
    ?assertEqual(
       {error, invalid_provider_result},
       adk_live_session:send_text(
         Session, ?PRINCIPAL, <<"improper">>)),
    {ok, Empty} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(0, maps:get(input_queue_messages, Empty)),
    ?assertEqual(0, maps:get(input_queue_bytes, Empty)),
    %% Neither failed capacity checks nor invalid provider lists consume a
    %% sequence or leave a partial prefix in the queue.
    {ok, 1} = adk_live_session:send_text(
                Session, ?PRINCIPAL, <<"single">>),
    {ok, One} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(1, maps:get(input_queue_messages, One)),
    ok = adk_live_fake_transport:writable(Handle),
    ?assertEqual(<<"single">>, receive_sent(Handle)),
    assert_no_sent_frame(Handle),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

start_ready_session(Overrides) ->
    SessionId = <<"live-multi-", (integer_to_binary(
                                    erlang:unique_integer([positive])))/binary>>,
    Base = #{provider => adk_live_multi_frame_fixture_provider,
             provider_config => #{},
             transport => adk_live_fake_transport,
             transport_opts => #{test_pid => self()}},
    {ok, Session} = adk_live_session_sup:start_session(
                      SessionId, ?PRINCIPAL, maps:merge(Base, Overrides)),
    Handle = receive
        {adk_live_fake_transport, opened, OpenedHandle} -> OpenedHandle
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual(<<"fixture-setup">>, receive_sent(Handle)),
    adk_live_fake_transport:inject(Handle, <<"fixture-ready">>),
    wait_for_state(Session, active, 50),
    {Session, Handle}.

receive_sent(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, Frame} -> Frame
    after 1000 ->
        ?assert(false)
    end.

assert_no_sent_frame(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, _Frame} -> ?assert(false)
    after 50 ->
        ok
    end.

wait_for_empty_ingress(_Session, 0) ->
    ?assert(false);
wait_for_empty_ingress(Session, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{input_queue_messages := 0}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_empty_ingress(Session, Remaining - 1)
    end.

wait_for_state(_Session, _Expected, 0) ->
    ?assert(false);
wait_for_state(Session, Expected, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{state := Expected}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_state(Session, Expected, Remaining - 1)
    end.
