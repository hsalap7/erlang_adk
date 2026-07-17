-module(adk_llm_compatible_stream_test).

-include_lib("eunit/include/eunit.hrl").

fragmented_sse_and_coalesced_done_preserve_emissions_test() ->
    {ok, S0} = adk_llm_compatible_stream:new(),
    First = sse(chunk(#{<<"role">> => <<"assistant">>,
                        <<"content">> => <<"Hel">>}, null)),
    Split = byte_size(First) div 2,
    <<A:Split/binary, B/binary>> = First,
    {ok, S1, []} = adk_llm_compatible_stream:feed(S0, A),
    {ok, S2, [{text, <<"Hel">>}]} =
        adk_llm_compatible_stream:feed(S1, B),
    Final = <<(sse(chunk(#{<<"content">> => <<"lo">>}, <<"stop">>)))/binary,
              "data: [DONE]\n\n">>,
    {done, Result, Done, [{text, <<"lo">>}]} =
        adk_llm_compatible_stream:feed(S2, Final),
    {ok, streamed, Action} = adk_provider_result:decode(Result),
    ?assertEqual(<<"stop">>,
                 maps:get(<<"finish_reason">>,
                          maps:get(<<"metadata">>, Action))),
    {ok, Content} = adk_llm_compatible_stream:content(Done),
    ?assertEqual([<<"Hello">>],
                 adk_llm_compatible_content:text_parts(Content)),
    ?assertEqual({ok, Result}, adk_llm_compatible_stream:result(Done)).

interleaved_parallel_tool_calls_assemble_test() ->
    {ok, S0} = adk_llm_compatible_stream:new(),
    Start = chunk(
              #{<<"role">> => <<"assistant">>,
                <<"tool_calls">> =>
                    [tool_delta(0, <<"call-a">>, <<"weather">>,
                                <<"{\"city\":\"">>),
                     tool_delta(1, <<"call-b">>, <<"time">>,
                                <<"{\"zone\":\"">>)]}, null),
    {ok, S1, []} = adk_llm_compatible_stream:feed(S0, sse(Start)),
    Continue = chunk(
                 #{<<"tool_calls">> =>
                       [argument_delta(1, <<"UTC\"}">>),
                        argument_delta(0, <<"Paris\"}">>)]},
                 <<"tool_calls">>),
    Terminal = <<(sse(Continue))/binary, "data: [DONE]\n\n">>,
    {done, Result, Done, []} =
        adk_llm_compatible_stream:feed(S1, Terminal),
    {ok, {tool_calls, Calls}, _Action} =
        adk_provider_result:decode(Result),
    ?assertEqual(
       [{<<"weather">>, #{<<"city">> => <<"Paris">>},
         undefined, <<"call-a">>},
        {<<"time">>, #{<<"zone">> => <<"UTC">>},
         undefined, <<"call-b">>}], Calls),
    {ok, Content} = adk_llm_compatible_stream:content(Done),
    ?assertEqual(Calls,
                 adk_llm_compatible_content:tool_calls(Content)).

connection_finish_can_complete_without_done_marker_test() ->
    {ok, S0} = adk_llm_compatible_stream:new(),
    Event = sse(chunk(#{<<"content">> => <<"complete">>}, <<"stop">>)),
    {ok, S1, [{text, <<"complete">>}]} =
        adk_llm_compatible_stream:feed(S0, Event),
    {ok, Result} = adk_llm_compatible_stream:finish(S1),
    {ok, streamed, _Action} = adk_provider_result:decode(Result).

usage_only_chunk_is_accepted_before_done_test() ->
    {ok, S0} = adk_llm_compatible_stream:new(),
    {ok, S1, [{text, <<"ok">>}]} =
        adk_llm_compatible_stream:feed(
          S0, sse(chunk(#{<<"content">> => <<"ok">>}, <<"stop">>))),
    Usage = #{<<"choices">> => [],
              <<"usage">> => #{<<"prompt_tokens">> => 3,
                                 <<"completion_tokens">> => 1,
                                 <<"total_tokens">> => 4}},
    {ok, S2, []} = adk_llm_compatible_stream:feed(S1, sse(Usage)),
    {done, Result, _Done, []} =
        adk_llm_compatible_stream:feed(S2, <<"data: [DONE]\n\n">>),
    {ok, streamed, Action} = adk_provider_result:decode(Result),
    ?assertEqual(#{<<"input_tokens">> => 3,
                   <<"output_tokens">> => 1,
                   <<"total_tokens">> => 4},
                 maps:get(<<"usage">>, maps:get(<<"metadata">>, Action))).

malformed_tool_fragments_fail_without_echoing_data_test() ->
    Secret = <<"stream-tool-secret-must-not-leak">>,
    {ok, S0} = adk_llm_compatible_stream:new(),
    Bad = chunk(#{<<"tool_calls">> =>
                      [tool_delta(0, <<"call-a">>, <<"weather">>, Secret)]},
                <<"tool_calls">>),
    {ok, S1, []} = adk_llm_compatible_stream:feed(S0, sse(Bad)),
    Error = adk_llm_compatible_stream:feed(
              S1, <<"data: [DONE]\n\n">>),
    ?assertEqual({error, invalid_compatible_stream_tool_arguments}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)).

identity_mismatch_and_early_done_fail_test() ->
    {ok, S0} = adk_llm_compatible_stream:new(),
    {ok, S1, [{text, <<"a">>}]} =
        adk_llm_compatible_stream:feed(
          S0, sse(chunk(#{<<"content">> => <<"a">>}, null))),
    Mismatch = (chunk(#{<<"content">> => <<"b">>}, null))#{
                 <<"id">> => <<"other-id">>},
    ?assertEqual(
       {error, compatible_stream_identity_mismatch},
       adk_llm_compatible_stream:feed(S1, sse(Mismatch))),
    ?assertEqual(
       {error, missing_compatible_stream_finish_reason},
       adk_llm_compatible_stream:feed(
         S1, <<"data: [DONE]\n\n">>)).

stream_limits_are_enforced_test() ->
    {ok, S0} = adk_llm_compatible_stream:new(
                 #{content_limits => #{max_text_bytes => 3},
                   max_stream_events => 1}),
    ?assertEqual(
       {error, compatible_stream_text_limit_exceeded},
       adk_llm_compatible_stream:feed(
         S0, sse(chunk(#{<<"content">> => <<"four">>}, null)))),
    {ok, S1} = adk_llm_compatible_stream:new(#{max_stream_events => 1}),
    {ok, S2, [{text, <<"x">>}]} =
        adk_llm_compatible_stream:feed(
          S1, sse(chunk(#{<<"content">> => <<"x">>}, null))),
    ?assertEqual(
       {error, compatible_stream_event_limit_exceeded},
       adk_llm_compatible_stream:feed(
         S2, sse(chunk(#{<<"content">> => <<"y">>}, null)))).

forged_stream_state_fails_as_a_value_test() ->
    {ok, State} = adk_llm_compatible_stream:new(),
    ForgedCalls = State#{calls => #{0 => #{}}},
    ?assertEqual(
       {error, invalid_compatible_stream_state},
       adk_llm_compatible_stream:feed(ForgedCalls, <<>>)),
    ForgedText = State#{text_fragments => [self()], text_bytes => 1},
    ?assertEqual(
       {error, invalid_compatible_stream_state},
       adk_llm_compatible_stream:finish(ForgedText)).

chunk(Delta, FinishReason) ->
    #{<<"id">> => <<"chatcmpl-stream-1">>,
      <<"model">> => <<"vendor-model">>,
      <<"system_fingerprint">> => <<"fp-1">>,
      <<"choices">> =>
          [#{<<"index">> => 0,
             <<"delta">> => Delta,
             <<"finish_reason">> => FinishReason}]}.

tool_delta(Index, Id, Name, Arguments) ->
    #{<<"index">> => Index,
      <<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> => #{<<"name">> => Name,
                            <<"arguments">> => Arguments}}.

argument_delta(Index, Arguments) ->
    #{<<"index">> => Index,
      <<"function">> => #{<<"arguments">> => Arguments}}.

sse(Map) ->
    <<"data: ", (jsx:encode(Map))/binary, "\n\n">>.
