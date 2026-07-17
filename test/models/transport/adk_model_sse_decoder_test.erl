-module(adk_model_sse_decoder_test).

-include_lib("eunit/include/eunit.hrl").

fragmented_lf_event_test() ->
    S0 = adk_model_sse_decoder:new(),
    {ok, [], S1} = adk_model_sse_decoder:feed(S0, <<"event: response.out">>),
    {ok, [], S2} = adk_model_sse_decoder:feed(
                     S1, <<"put_text.delta\ndata: {\"delta\":\"hel">>),
    {ok, [Event], _S3} = adk_model_sse_decoder:feed(
                           S2, <<"lo\"}\n\n">>),
    ?assertEqual(<<"response.output_text.delta">>, maps:get(event, Event)),
    ?assertEqual(<<"{\"delta\":\"hello\"}">>, maps:get(data, Event)).

crlf_and_multiple_data_lines_test() ->
    S0 = adk_model_sse_decoder:new(),
    Chunk = <<"id: evt-1\r\nretry: 1500\r\n",
              "data: first\r\ndata: second\r\n\r\n">>,
    {ok, [Event], _S1} = adk_model_sse_decoder:feed(S0, Chunk),
    ?assertEqual(<<"evt-1">>, maps:get(id, Event)),
    ?assertEqual(1500, maps:get(retry, Event)),
    ?assertEqual(<<"first\nsecond">>, maps:get(data, Event)).

multiple_events_one_chunk_test() ->
    S0 = adk_model_sse_decoder:new(),
    {ok, Events, _S1} = adk_model_sse_decoder:feed(
                          S0, <<"data: one\n\ndata: two\n\n">>),
    ?assertEqual([#{data => <<"one">>}, #{data => <<"two">>}], Events).

comments_unknown_fields_and_invalid_retry_test() ->
    S0 = adk_model_sse_decoder:new(),
    Chunk = <<": keepalive\nunknown: ignored\nretry: nope\ndata: ok\n\n">>,
    {ok, [Event], _S1} = adk_model_sse_decoder:feed(S0, Chunk),
    ?assertEqual(#{data => <<"ok">>}, Event).

id_event_and_retry_only_blocks_are_not_dispatched_test() ->
    S0 = adk_model_sse_decoder:new(#{max_events_per_feed => 1}),
    Chunk = <<"id: cursor-only\nevent: ping\nretry: 1000\n\n",
              "data: delivered\n\n">>,
    {ok, [Event], _S1} = adk_model_sse_decoder:feed(S0, Chunk),
    ?assertEqual(#{data => <<"delivered">>}, Event).

an_explicit_empty_data_line_is_dispatched_test() ->
    S0 = adk_model_sse_decoder:new(),
    ?assertMatch(
       {ok, [#{data := <<>>}], _},
       adk_model_sse_decoder:feed(S0, <<"data:\n\n">>)).

event_limit_stops_incremental_scan_of_many_events_test() ->
    S0 = adk_model_sse_decoder:new(#{max_events_per_feed => 1}),
    Chunk = iolist_to_binary(lists:duplicate(10000, <<"data: x\n\n">>)),
    ?assertEqual(
       {error, sse_event_count_limit_exceeded},
       adk_model_sse_decoder:feed(S0, Chunk)).

finish_dispatches_unterminated_event_test() ->
    S0 = adk_model_sse_decoder:new(),
    {ok, [], S1} = adk_model_sse_decoder:feed(S0, <<"data: final">>),
    ?assertEqual({ok, [#{data => <<"final">>}]},
                 adk_model_sse_decoder:finish(S1)).

utf8_split_across_chunks_test() ->
    Utf8 = <<16#E2, 16#82, 16#AC>>,
    S0 = adk_model_sse_decoder:new(),
    <<First:2/binary, Last/binary>> = Utf8,
    {ok, [], S1} = adk_model_sse_decoder:feed(
                     S0, <<"data: ", First/binary>>),
    {ok, [Event], _S2} = adk_model_sse_decoder:feed(
                           S1, <<Last/binary, "\n\n">>),
    ?assertEqual(Utf8, maps:get(data, Event)).

buffer_limit_test() ->
    S0 = adk_model_sse_decoder:new(#{max_buffer_bytes => 4}),
    ?assertEqual({error, sse_buffer_limit_exceeded},
                 adk_model_sse_decoder:feed(S0, <<"12345">>)).

event_limit_test() ->
    S0 = adk_model_sse_decoder:new(#{max_event_bytes => 8}),
    ?assertEqual({error, sse_event_limit_exceeded},
                 adk_model_sse_decoder:feed(S0, <<"data: 123\n">>)).

events_per_feed_limit_test() ->
    S0 = adk_model_sse_decoder:new(#{max_events_per_feed => 1}),
    ?assertEqual({error, sse_event_count_limit_exceeded},
                 adk_model_sse_decoder:feed(
                   S0, <<"data: one\n\ndata: two\n\n">>)).

invalid_options_test() ->
    ?assertError(invalid_sse_decoder_options,
                 adk_model_sse_decoder:new(#{surprise => true})),
    ?assertError(invalid_sse_decoder_limits,
                 adk_model_sse_decoder:new(#{max_event_bytes => 0})).

null_id_is_ignored_test() ->
    S0 = adk_model_sse_decoder:new(),
    {ok, [Event], _S1} = adk_model_sse_decoder:feed(
                           S0, <<"id: bad", 0, "id\ndata: ok\n\n">>),
    ?assertEqual(false, maps:is_key(id, Event)).
