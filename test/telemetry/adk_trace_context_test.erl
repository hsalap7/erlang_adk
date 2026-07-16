-module(adk_trace_context_test).
-include_lib("eunit/include/eunit.hrl").

-define(TRACE_ID, <<"4bf92f3577b34da6a3ce929d0e0e4736">>).
-define(SPAN_ID, <<"00f067aa0ba902b7">>).

w3c_roundtrip_test() ->
    Header = <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-01">>,
    {ok, Context} = adk_trace_context:parse(Header),
    ?assertEqual(?TRACE_ID, maps:get(trace_id, Context)),
    ?assertEqual(?SPAN_ID, maps:get(span_id, Context)),
    ?assertEqual(1, maps:get(trace_flags, Context)),
    ?assertEqual({ok, Header}, adk_trace_context:format(Context)).

invalid_traceparent_vectors_test() ->
    Invalid = [
        <<"00-00000000000000000000000000000000-00f067aa0ba902b7-01">>,
        <<"00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01">>,
        <<"00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01">>,
        <<"ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
        <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-zz">>,
        <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7">>
    ],
    [?assertMatch({error, {invalid_traceparent, _}},
                  adk_trace_context:parse(Value)) || Value <- Invalid].

extract_inject_and_tracestate_test() ->
    Header = <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-00">>,
    Headers = #{<<"TraceParent">> => Header,
                <<"tracestate">> => <<"vendor=value, tenant@sys=opaque">>,
                <<"x-request-id">> => <<"request">>},
    {ok, Context} = adk_trace_context:extract(Headers),
    ?assertEqual(<<"vendor=value,tenant@sys=opaque">>,
                 maps:get(tracestate, Context)),
    {ok, Injected} = adk_trace_context:inject(Context, Headers),
    ?assertEqual(Header, maps:get(<<"traceparent">>, Injected)),
    ?assertEqual(<<"request">>, maps:get(<<"x-request-id">>, Injected)),
    ?assertNot(maps:is_key(<<"TraceParent">>, Injected)).

duplicate_and_invalid_tracestate_test() ->
    Header = <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-01">>,
    ?assertMatch(
       {error, {invalid_traceparent, duplicate_header}},
       adk_trace_context:extract(
         [{<<"traceparent">>, Header}, {<<"TraceParent">>, Header}])),
    ?assertMatch(
       {error, {invalid_tracestate, duplicate_key}},
       adk_trace_context:validate_tracestate(<<"a=1,a=2">>)),
    ?assertMatch(
       {error, {invalid_tracestate, invalid_key}},
       adk_trace_context:validate_tracestate(<<"Upper=value">>)).

observability_remote_parent_test() ->
    Header = <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-01">>,
    {ok, Local} = adk_observability:from_headers(
                    #{<<"traceparent">> => Header},
                    #{run_id => <<"run-1">>}),
    ?assertEqual(?TRACE_ID, maps:get(trace_id, Local)),
    ?assertEqual(?SPAN_ID, maps:get(parent_id, Local)),
    ?assertNotEqual(?SPAN_ID, maps:get(span_id, Local)),
    ?assertEqual(1, maps:get(trace_flags, Local)),
    {ok, Outbound} = adk_observability:inject_headers(Local, #{}),
    {ok, Parsed} = adk_trace_context:parse(
                     maps:get(<<"traceparent">>, Outbound)),
    ?assertEqual(maps:get(span_id, Local), maps:get(span_id, Parsed)).
