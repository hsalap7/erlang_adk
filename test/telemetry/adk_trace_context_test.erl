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

validation_and_format_error_contract_test() ->
    ?assertEqual(ok, adk_trace_context:validate_trace_id(?TRACE_ID)),
    ?assertEqual(ok, adk_trace_context:validate_span_id(?SPAN_ID)),
    [?assertEqual({error, invalid_trace_id},
                  adk_trace_context:validate_trace_id(Value))
     || Value <- [invalid, <<>>, binary:copy(<<"0">>, 32),
                  <<"4BF92F3577B34DA6A3CE929D0E0E4736">>]],
    [?assertEqual({error, invalid_span_id},
                  adk_trace_context:validate_span_id(Value))
     || Value <- [invalid, <<>>, binary:copy(<<"0">>, 16),
                  <<"00F067AA0BA902B7">>]],

    BinaryKeyContext = #{<<"trace_id">> => ?TRACE_ID,
                         <<"span_id">> => ?SPAN_ID,
                         <<"trace_flags">> => <<"af">>},
    ?assertEqual(
       {ok, <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-af">>},
       adk_trace_context:format(BinaryKeyContext)),
    ?assertEqual(
       {ok, <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-ff">>},
       adk_trace_context:format(
         #{trace_id => ?TRACE_ID, span_id => ?SPAN_ID,
           trace_flags => 255})),
    ?assertEqual(
       {error, {invalid_traceparent, invalid_context}},
       adk_trace_context:format(invalid)),
    ?assertEqual(
       {error, {invalid_traceparent, invalid_trace_id}},
       adk_trace_context:format(#{span_id => ?SPAN_ID})),
    ?assertEqual(
       {error, {invalid_traceparent, invalid_span_id}},
       adk_trace_context:format(#{trace_id => ?TRACE_ID})),
    [?assertEqual(
        {error, {invalid_traceparent, invalid_trace_flags}},
        adk_trace_context:format(
          #{trace_id => ?TRACE_ID, span_id => ?SPAN_ID,
            trace_flags => Flags}))
     || Flags <- [-1, 256, <<"GG">>, <<"0">>, invalid]].

version_and_header_error_contract_test() ->
    [?assertEqual(Expected, adk_trace_context:parse(Header))
     || {Header, Expected} <-
            [{<<"zz-invalid">>,
              {error, {invalid_traceparent, invalid_version}}},
             {<<"01-anything">>,
              {error, {invalid_traceparent, unsupported_version}}},
             {<<"ff-anything">>,
              {error, {invalid_traceparent, forbidden_version}}},
             {<<"not-a-traceparent">>,
              {error, {invalid_traceparent,
                       invalid_length_or_delimiters}}}]],
    ?assertEqual(not_found, adk_trace_context:extract(#{})),
    ?assertEqual(not_found, adk_trace_context:extract([{123, ignored}])),
    ?assertEqual(
       {error, {invalid_traceparent, invalid_headers}},
       adk_trace_context:extract(invalid)),

    Header = <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-01">>,
    {ok, FromLists} = adk_trace_context:extract(
                        [{traceparent, binary_to_list(Header)}]),
    ?assertEqual(?TRACE_ID, maps:get(trace_id, FromLists)),
    ?assertEqual(
       {error, {invalid_trace_header, traceparent}},
       adk_trace_context:extract(#{traceparent => 42})),
    ?assertEqual(
       {error, {invalid_trace_header, traceparent}},
       adk_trace_context:extract(
         #{traceparent => binary:copy(<<"x">>, 1025)})),
    ?assertEqual(
       {error, {invalid_tracestate, duplicate_header}},
       adk_trace_context:extract(
         [{traceparent, Header},
          {tracestate, <<"a=1">>}, {<<"TraceState">>, <<"b=2">>}])),
    ?assertEqual(
       {error, {invalid_trace_header, tracestate}},
       adk_trace_context:extract(
         #{traceparent => Header, tracestate => invalid})).

injection_map_and_list_contract_test() ->
    Header = <<"00-", ?TRACE_ID/binary, "-", ?SPAN_ID/binary, "-01">>,
    Context = #{trace_id => ?TRACE_ID, span_id => ?SPAN_ID,
                trace_flags => 1, tracestate => null},
    {ok, MapHeaders} = adk_trace_context:inject(
                         Context,
                         #{"TraceParent" => <<"old">>,
                           tracestate => <<"old=state">>,
                           <<"x-request-id">> => <<"request">>}),
    ?assertEqual(Header, maps:get(<<"traceparent">>, MapHeaders)),
    ?assertEqual(<<"request">>, maps:get(<<"x-request-id">>, MapHeaders)),
    ?assertNot(maps:is_key("TraceParent", MapHeaders)),
    ?assertNot(maps:is_key(tracestate, MapHeaders)),

    {ok, ListHeaders} = adk_trace_context:inject(
                          Context#{tracestate => <<" vendor=value ">>},
                          [{"TraceParent", <<"old">>},
                           {tracestate, <<"old=state">>},
                           {<<"x-extra">>, <<"kept">>}]),
    ?assertEqual(Header, proplists:get_value(<<"traceparent">>, ListHeaders)),
    ?assertEqual(<<"vendor=value">>,
                 proplists:get_value(<<"tracestate">>, ListHeaders)),
    ?assertEqual(<<"kept">>,
                 proplists:get_value(<<"x-extra">>, ListHeaders)),
    ?assertEqual(false, lists:keymember("TraceParent", 1, ListHeaders)),
    ?assertEqual(false, lists:keymember(tracestate, 1, ListHeaders)),
    ?assertEqual(
       {error, {invalid_traceparent, invalid_injection_arguments}},
       adk_trace_context:inject(invalid, #{})),
    ?assertEqual(
       {error, {invalid_traceparent, invalid_injection_arguments}},
       adk_trace_context:inject(Context, invalid)),
    ?assertEqual(
       {error, {invalid_tracestate, invalid_key}},
       adk_trace_context:inject(Context#{tracestate => <<"Bad=value">>},
                                #{})).

tracestate_limits_and_canonicalization_test() ->
    ?assertEqual({ok, null}, adk_trace_context:validate_tracestate(null)),
    ?assertEqual({ok, null},
                 adk_trace_context:validate_tracestate(undefined)),
    ?assertEqual({error, {invalid_tracestate, empty}},
                 adk_trace_context:validate_tracestate(<<>>)),
    ?assertEqual({error, {invalid_tracestate, invalid_type}},
                 adk_trace_context:validate_tracestate(invalid)),
    ?assertEqual({error, {invalid_tracestate, too_large}},
                 adk_trace_context:validate_tracestate(
                   binary:copy(<<"a">>, 513))),
    Members = [<<"a", (integer_to_binary(N))/binary, "=v">>
               || N <- lists:seq(1, 33)],
    ?assertEqual({error, {invalid_tracestate, too_many_members}},
                 adk_trace_context:validate_tracestate(
                   iolist_to_binary(lists:join(<<",">>, Members)))),
    ?assertEqual(
       {ok, <<"1tenant.part@sys_key=value!,simple-*/_key=opaque">>},
       adk_trace_context:validate_tracestate(
         <<" 1tenant.part@sys_key=value! , simple-*/_key=opaque\t">>)).

tracestate_invalid_member_vectors_test() ->
    Vectors =
        [{<<"missing-separator">>, invalid_member},
         {<<"=value">>, invalid_key},
         {<<"Upper=value">>, invalid_key},
         {<<"simple.dot=value">>, invalid_key},
         {<<"tenant@system@extra=value">>, invalid_key},
         {<<"a=">>, invalid_value},
         {<<"a=has=equals">>, invalid_value},
         {<<"a=", 16#1f>>, invalid_value},
         {<<"a=1,a=2">>, duplicate_key}],
    [?assertEqual(
        {error, {invalid_tracestate, Reason}},
        adk_trace_context:validate_tracestate(Value))
     || {Value, Reason} <- Vectors],
    ?assertEqual(
       {error, {invalid_tracestate, invalid_key}},
       adk_trace_context:validate_tracestate(
         <<(binary:copy(<<"a">>, 257))/binary, "=value">>)),
    ?assertEqual(
       {error, {invalid_tracestate, invalid_value}},
       adk_trace_context:validate_tracestate(
         <<"a=", (binary:copy(<<"v">>, 257))/binary>>)).
