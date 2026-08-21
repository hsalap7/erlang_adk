-module(adk_mcp_sse_stream_test).
-include_lib("eunit/include/eunit.hrl").

incremental_credit_and_multiline_data_test() ->
    {ok, State0} = adk_mcp_sse_stream:new(#{max_bytes => 1024,
                                            max_event_bytes => 256,
                                            max_events => 4}),
    {ok, State1} = adk_mcp_sse_stream:grant(State0, 1),
    {ok, [], State2, ready} =
        adk_mcp_sse_stream:decode(State1, <<"event: message\ndata: {\"a\":" >>,
                                  false),
    {ok, [Event], State3, paused} =
        adk_mcp_sse_stream:decode(State2,
                                  <<"1}\ndata: tail\n\ndata: second\n\n">>,
                                  false),
    ?assertEqual(<<"message">>, maps:get(event, Event)),
    ?assertEqual(<<"{\"a\":1}\ntail">>, maps:get(data, Event)),
    {ok, State4} = adk_mcp_sse_stream:grant(State3, 1),
    {ok, [#{data := <<"second">>}], _State5, done} =
        adk_mcp_sse_stream:decode(State4, <<>>, true).

bounded_decoder_rejects_overflow_and_truncation_test() ->
    {ok, State0} = adk_mcp_sse_stream:new(#{max_bytes => 12,
                                            max_event_bytes => 12,
                                            max_events => 1}),
    {ok, State1} = adk_mcp_sse_stream:grant(State0, 1),
    ?assertEqual({error, mcp_sse_limit_exceeded},
                 adk_mcp_sse_stream:decode(
                   State1, <<"data: 123456\n\n">>, false)),
    {ok, Other0} = adk_mcp_sse_stream:new(#{}),
    {ok, Other1} = adk_mcp_sse_stream:grant(Other0, 1),
    ?assertEqual({error, truncated_mcp_sse_event},
                 adk_mcp_sse_stream:decode(Other1, <<"data: partial">>, true)).

crlf_boundaries_and_final_backpressure_are_preserved_test() ->
    {ok, State0} = adk_mcp_sse_stream:new(#{max_bytes => 256,
                                            max_event_bytes => 64,
                                            max_events => 2}),
    {ok, State1} = adk_mcp_sse_stream:grant(State0, 1),
    {ok, [], State2, ready} =
        adk_mcp_sse_stream:decode(State1, <<"data: one\r">>, false),
    {ok, [#{data := <<"one">>}], State3, paused} =
        adk_mcp_sse_stream:decode(
          State2, <<"\n\r\ndata: two\r\n\r\n">>, true),
    {ok, State4} = adk_mcp_sse_stream:grant(State3, 1),
    {ok, [#{data := <<"two">>}], _State5, done} =
        adk_mcp_sse_stream:decode(State4, <<>>, false).

worker_backpressure_and_owner_death_test() ->
    Parent = self(),
    Owner = spawn(fun() -> owner_loop(Parent) end),
    {ok, Stream} = adk_mcp_sse_stream:start(Owner, #{max_events => 2}),
    Owner ! {stream, Stream},
    ?assertEqual({ok, 0, paused},
                 adk_mcp_sse_stream:feed(Stream, <<"data: one\n\n">>, false)),
    ok = adk_mcp_sse_stream:credit(Stream, 1),
    receive {owned_event, #{data := <<"one">>}} -> ok
    after 1000 -> ?assert(false)
    end,
    Monitor = erlang:monitor(process, Stream),
    exit(Owner, kill),
    receive {'DOWN', Monitor, process, Stream, normal} -> ok
    after 1000 -> ?assert(false)
    end.

explicit_cancel_is_terminal_test() ->
    {ok, Stream} = adk_mcp_sse_stream:start(self(), #{}),
    Monitor = erlang:monitor(process, Stream),
    ok = adk_mcp_sse_stream:cancel(Stream),
    receive {'DOWN', Monitor, process, Stream, normal} -> ok
    after 1000 -> ?assert(false)
    end,
    ?assertEqual({error, mcp_sse_stream_closed},
                 adk_mcp_sse_stream:credit(Stream, 1)).

owner_loop(Parent) ->
    receive
        {stream, Stream} -> owner_loop(Parent, Stream)
    end.

owner_loop(Parent, Stream) ->
    receive
        {mcp_sse_event, Stream, Event} ->
            Parent ! {owned_event, Event},
            owner_loop(Parent, Stream)
    end.
