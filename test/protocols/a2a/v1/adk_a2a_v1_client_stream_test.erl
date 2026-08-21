-module(adk_a2a_v1_client_stream_test).

-include_lib("eunit/include/eunit.hrl").

fragmented_sse_is_decoded_incrementally_test() ->
    Id = 42,
    First = #{<<"message">> => agent_message(<<"started">>)},
    Second = status_update(<<"TASK_STATE_WORKING">>),
    Third = status_update(<<"TASK_STATE_COMPLETED">>),
    Body = iolist_to_binary([frame(10, Id, First),
                             frame(11, Id, Second),
                             frame(12, Id, Third)]),
    Chunks = chunk_binary(Body, [1, 2, 7, 3, 11, 5]),
    put(a2a_stream_payloads, []),
    Callback = fun(Payload) ->
        put(a2a_stream_payloads,
            [Payload | get(a2a_stream_payloads)]),
        continue
    end,
    try
        ?assertEqual(
           {ok, stream_complete},
           adk_a2a_v1_client:test_stream_chunks(
             Chunks, Id, #{max_response_bytes => 65536,
                           max_events => 8}, Callback)),
        ?assertEqual([First, Second, Third],
                     lists:reverse(get(a2a_stream_payloads)))
    after erase(a2a_stream_payloads) end.

replay_gap_is_reported_without_delivering_later_event_test() ->
    Id = <<"request">>,
    First = #{<<"message">> => agent_message(<<"started">>)},
    Gap = status_update(<<"TASK_STATE_WORKING">>),
    Body = <<(frame(4, Id, First))/binary,
             (frame(6, Id, Gap))/binary>>,
    put(a2a_gap_payloads, []),
    Callback = fun(Payload) ->
        put(a2a_gap_payloads, [Payload | get(a2a_gap_payloads)]),
        continue
    end,
    try
        ?assertEqual(
           {error, {a2a_replay_gap, 5, 6}},
           adk_a2a_v1_client:test_stream_chunks(
             [Body], Id, #{max_response_bytes => 65536,
                           max_events => 8}, Callback)),
        ?assertEqual([First], lists:reverse(get(a2a_gap_payloads)))
    after erase(a2a_gap_payloads) end.

callback_stop_cancels_before_following_events_test() ->
    Id = 9,
    First = #{<<"message">> => agent_message(<<"only">>)},
    Second = status_update(<<"TASK_STATE_WORKING">>),
    Body = <<(frame(1, Id, First))/binary,
             (frame(2, Id, Second))/binary>>,
    Parent = self(),
    Callback = fun(Payload) -> Parent ! {stopped_payload, Payload}, stop end,
    ?assertEqual(
       {ok, stream_stopped},
       adk_a2a_v1_client:test_stream_chunks(
         [Body], Id, #{max_response_bytes => 65536,
                       max_events => 8}, Callback)),
    receive {stopped_payload, First} -> ok after 1000 -> ?assert(false) end,
    receive {stopped_payload, _} -> ?assert(false) after 0 -> ok end.

event_and_buffer_limits_fail_closed_test() ->
    Id = 10,
    First = #{<<"message">> => agent_message(<<"first">>)},
    Second = status_update(<<"TASK_STATE_WORKING">>),
    Body = <<(frame(1, Id, First))/binary,
             (frame(2, Id, Second))/binary>>,
    ?assertEqual(
       {error, too_many_a2a_stream_events},
       adk_a2a_v1_client:test_stream_chunks(
         [Body], Id, #{max_response_bytes => 65536, max_events => 1},
         fun(_Payload) -> continue end)),
    ?assertEqual(
       {error, a2a_response_too_large},
       adk_a2a_v1_client:test_stream_chunks(
         [Body], Id, #{max_response_bytes => 8, max_events => 8},
         fun(_Payload) -> continue end)).

frame(Sequence, Id, Payload) ->
    Envelope = jsx:encode(
                 #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                   <<"result">> => Payload}),
    <<"id: ", (integer_to_binary(Sequence))/binary,
      "\r\ndata: ", Envelope/binary, "\r\n\r\n">>.

agent_message(Text) ->
    #{<<"messageId">> => <<"agent-message">>,
      <<"role">> => <<"ROLE_AGENT">>,
      <<"parts">> => [#{<<"text">> => Text}]}.

status_update(State) ->
    #{<<"statusUpdate">> =>
          #{<<"taskId">> => <<"task">>, <<"contextId">> => <<"context">>,
            <<"status">> =>
                #{<<"state">> => State,
                  <<"timestamp">> => <<"2026-08-19T00:00:00.000Z">>}}}.

chunk_binary(Binary, Sizes) -> chunk_binary(Binary, Sizes, []).

chunk_binary(<<>>, _Sizes, Acc) -> lists:reverse(Acc);
chunk_binary(Binary, [], Acc) -> lists:reverse([Binary | Acc]);
chunk_binary(Binary, [Size | _Rest], Acc) when byte_size(Binary) =< Size ->
    lists:reverse([Binary | Acc]);
chunk_binary(Binary, [Size | Rest], Acc) ->
    <<Chunk:Size/binary, Tail/binary>> = Binary,
    chunk_binary(Tail, Rest, [Chunk | Acc]).
