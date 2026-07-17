-module(adk_llm_anthropic_stream_test).
-include_lib("eunit/include/eunit.hrl").

assembles_text_stream_and_cumulative_usage_test() ->
    S0 = adk_llm_anthropic_stream:new(),
    {ok, S1, []} = feed(S0, <<"message_start">>, message_start()),
    {ok, S2, []} = feed(
                     S1, <<"content_block_start">>,
                     #{<<"index">> => 0,
                       <<"content_block">> =>
                           #{<<"type">> => <<"text">>, <<"text">> => <<>>}}),
    {ok, S3, [{text, <<"Hello">>}]} = feed(
                                          S2, <<"content_block_delta">>,
                                          text_delta(0, <<"Hello">>)),
    {ok, S4, []} = feed(S3, <<"ping">>, #{}),
    {ok, S5, [{text, <<" world">>}]} = feed(
                                           S4, <<"content_block_delta">>,
                                           text_delta(0, <<" world">>)),
    {ok, S6, []} = feed(
                     S5, <<"content_block_stop">>, #{<<"index">> => 0}),
    {ok, S7, []} = feed(
                     S6, <<"message_delta">>,
                     #{<<"delta">> =>
                           #{<<"stop_reason">> => <<"end_turn">>,
                             <<"stop_sequence">> => null},
                       <<"usage">> => #{<<"output_tokens">> => 4}}),
    %% Later accounting-only deltas must not reset an earlier stop reason.
    {ok, S8, []} = feed(
                     S7, <<"message_delta">>,
                     #{<<"delta">> => #{},
                       <<"usage">> => #{<<"output_tokens">> => 5}}),
    {done, Result, Done} = feed(S8, <<"message_stop">>, #{}),
    {ok, streamed, Action} = adk_provider_result:decode(Result),
    Metadata = maps:get(<<"metadata">>, Action),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Metadata)),
    ?assertEqual(#{<<"input_tokens">> => 7,
                   <<"output_tokens">> => 5},
                 maps:get(<<"usage_metadata">>, Metadata)),
    {ok, Content} = adk_llm_anthropic_stream:content(Done),
    ?assertEqual([<<"Hello world">>],
                 adk_llm_anthropic_content:text_parts(Content)),
    ?assertEqual(Result, adk_llm_anthropic_stream:result(Done)).

assembles_partial_tool_json_test() ->
    S0 = adk_llm_anthropic_stream:new(),
    {ok, S1, []} = feed(S0, <<"message_start">>, message_start()),
    {ok, S2, []} = feed(
                     S1, <<"content_block_start">>,
                     #{<<"index">> => 0,
                       <<"content_block">> =>
                           #{<<"type">> => <<"tool_use">>,
                             <<"id">> => <<"toolu_1">>,
                             <<"name">> => <<"weather">>,
                             <<"input">> => #{}}}),
    {ok, S3, []} = feed(
                     S2, <<"content_block_delta">>,
                     input_delta(0, <<"{\"city\":\"Pu">>)),
    {ok, S4, []} = feed(
                     S3, <<"content_block_delta">>,
                     input_delta(0, <<"ne\"}">>)),
    {ok, S5, []} = feed(
                     S4, <<"content_block_stop">>, #{<<"index">> => 0}),
    {ok, S6, []} = feed(
                     S5, <<"message_delta">>,
                     #{<<"delta">> =>
                           #{<<"stop_reason">> => <<"tool_use">>},
                       <<"usage">> => #{<<"output_tokens">> => 8}}),
    {done, Result, Done} = feed(S6, <<"message_stop">>, #{}),
    {ok, {tool_calls, Calls}, _Action} = adk_provider_result:decode(Result),
    ?assertEqual(
       [{<<"weather">>, #{<<"city">> => <<"Pune">>},
         undefined, <<"toolu_1">>}], Calls),
    {ok, Content} = adk_llm_anthropic_stream:content(Done),
    ?assertEqual(Calls, adk_llm_anthropic_content:tool_calls(Content)).

handles_ping_and_unknown_events_without_atom_creation_test() ->
    S0 = adk_llm_anthropic_stream:new(),
    UnknownType = <<"future_provider_event">>,
    {ok, {unknown_event, UnknownType}} =
        adk_llm_anthropic_stream:decode_event(
          UnknownType, #{<<"type">> => UnknownType,
                         <<"future">> => #{<<"value">> => 1}}),
    {ok, S0, []} = adk_llm_anthropic_stream:push(
                     {unknown_event, UnknownType}, S0),
    {ok, S0, []} = adk_llm_anthropic_stream:push(ping, S0).

rejects_mismatched_envelope_and_midstream_error_test() ->
    ?assertEqual(
       {error, anthropic_event_type_mismatch},
       adk_llm_anthropic_stream:decode_event(
         <<"ping">>, #{<<"type">> => <<"message_stop">>})),
    %% The SSE envelope permits large events; a mismatch must still collapse
    %% to one fixed structural atom.
    RemoteType = binary:copy(<<"x">>, 1048576),
    Mismatch = adk_llm_anthropic_stream:decode_event(
                 <<"ping">>, #{<<"type">> => RemoteType}),
    ?assertEqual({error, anthropic_event_type_mismatch}, Mismatch),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Mismatch), RemoteType)),
    ErrorData = #{<<"error">> =>
                      #{<<"type">> => <<"overloaded_error">>,
                        <<"message">> => <<"Overloaded">>}},
    {ok, {error_event, SafeReason}} = decode(<<"error">>, ErrorData),
    ?assertEqual(
       {anthropic_api_error, undefined,
        <<"overloaded_error">>, undefined}, SafeReason),
    ?assertEqual(
       {error, {anthropic_stream_error, SafeReason}},
       adk_llm_anthropic_stream:push(
         {error_event, SafeReason}, adk_llm_anthropic_stream:new())).

enforces_event_order_and_indices_test() ->
    S0 = adk_llm_anthropic_stream:new(),
    ?assertMatch(
       {error, {invalid_anthropic_stream_order,
                content_block_start, awaiting_start}},
       adk_llm_anthropic_stream:push(
         {content_block_start, 0, {text, <<>>}}, S0)),
    {ok, {message_start, Metadata}} = decode(
                                      <<"message_start">>, message_start()),
    {ok, S1, []} = adk_llm_anthropic_stream:push(
                     {message_start, Metadata}, S0),
    ?assertEqual(
       {error, {invalid_anthropic_content_block_index, 1, 0}},
       adk_llm_anthropic_stream:push(
         {content_block_start, 1, {text, <<>>}}, S1)),
    {ok, S2, []} = adk_llm_anthropic_stream:push(
                     {content_block_start, 0, {text, <<>>}}, S1),
    ?assertEqual(
       {error, {invalid_anthropic_content_block_index, 1, 0}},
       adk_llm_anthropic_stream:push(
         {content_block_delta, 1, {text, <<"bad">>}}, S2)),
    ?assertMatch(
       {error, {invalid_anthropic_delta_for_block, input_json, text}},
       adk_llm_anthropic_stream:push(
         {content_block_delta, 0, {input_json, <<"{}">>}}, S2)).

rejects_invalid_partial_json_and_applies_limits_test() ->
    S0 = started_state(adk_llm_anthropic_stream:new()),
    {ok, ToolState, []} = adk_llm_anthropic_stream:push(
                            {content_block_start, 0,
                             {tool_use, <<"toolu_1">>, <<"weather">>, #{}}},
                            S0),
    {ok, BadJson, []} = adk_llm_anthropic_stream:push(
                          {content_block_delta, 0,
                           {input_json, <<"{not json">>}}, ToolState),
    ?assertEqual(
       {error, invalid_anthropic_tool_input_json},
       adk_llm_anthropic_stream:push(
         {content_block_stop, 0}, BadJson)),
    Small0 = started_state(
               adk_llm_anthropic_stream:new(#{max_text_bytes => 3})),
    {ok, Small1, []} = adk_llm_anthropic_stream:push(
                         {content_block_start, 0, {text, <<>>}}, Small0),
    ?assertEqual(
       {error, {anthropic_text_limit_exceeded, 4, 3}},
       adk_llm_anthropic_stream:push(
         {content_block_delta, 0, {text, <<"four">>}}, Small1)).

ignores_unknown_content_blocks_but_keeps_supported_output_test() ->
    S0 = started_state(adk_llm_anthropic_stream:new()),
    {ok, S1, []} = adk_llm_anthropic_stream:push(
                     {content_block_start, 0,
                      {ignored, <<"future_block">>}}, S0),
    {ok, S2, []} = adk_llm_anthropic_stream:push(
                     {content_block_delta, 0,
                      {ignored, <<"future_delta">>}}, S1),
    {ok, S3, []} = adk_llm_anthropic_stream:push(
                     {content_block_stop, 0}, S2),
    {ok, S4, [{text, <<"visible">>}]} =
        adk_llm_anthropic_stream:push(
          {content_block_start, 1, {text, <<"visible">>}}, S3),
    {ok, S5, []} = adk_llm_anthropic_stream:push(
                     {content_block_stop, 1}, S4),
    {ok, S6, []} = adk_llm_anthropic_stream:push(
                     {message_delta, <<"end_turn">>, unchanged,
                      #{<<"output_tokens">> => 2}}, S5),
    {done, _Result, Done} = adk_llm_anthropic_stream:push(message_stop, S6),
    {ok, Content} = adk_llm_anthropic_stream:content(Done),
    ?assertEqual([<<"visible">>],
                 adk_llm_anthropic_content:text_parts(Content)).

feed(State, Name, Fields) ->
    adk_llm_anthropic_stream:feed(
      State, #{event => Name,
               data => jsx:encode(Fields#{<<"type">> => Name})}).

decode(Name, Fields) ->
    adk_llm_anthropic_stream:decode_event(
      Name, Fields#{<<"type">> => Name}).

message_start() ->
    #{<<"message">> =>
          #{<<"id">> => <<"msg_stream_1">>,
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"model">> => <<"claude-test">>,
            <<"content">> => [],
            <<"stop_reason">> => null,
            <<"stop_sequence">> => null,
            <<"usage">> => #{<<"input_tokens">> => 7,
                              <<"output_tokens">> => 1}}}.

text_delta(Index, Text) ->
    #{<<"index">> => Index,
      <<"delta">> =>
          #{<<"type">> => <<"text_delta">>, <<"text">> => Text}}.

input_delta(Index, Partial) ->
    #{<<"index">> => Index,
      <<"delta">> =>
          #{<<"type">> => <<"input_json_delta">>,
            <<"partial_json">> => Partial}}.

started_state(S0) ->
    {ok, {message_start, Metadata}} = decode(
                                      <<"message_start">>, message_start()),
    {ok, S1, []} = adk_llm_anthropic_stream:push(
                     {message_start, Metadata}, S0),
    S1.
