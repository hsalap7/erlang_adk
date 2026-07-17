-module(adk_llm_anthropic_content_test).
-include_lib("eunit/include/eunit.hrl").

decodes_text_response_with_usage_metadata_test() ->
    Response = response(
                 [#{<<"type">> => <<"text">>,
                    <<"text">> => <<"Hello ">>},
                  #{<<"type">> => <<"text">>,
                    <<"text">> => <<"world">>}]),
    Result = adk_llm_anthropic_content:decode_response(Response, #{}),
    {ok, {ok, <<"Hello world">>}, Action} =
        adk_provider_result:decode(Result),
    ?assertEqual(<<"anthropic">>, maps:get(<<"provider">>, Action)),
    ?assertEqual(<<"generation_metadata">>, maps:get(<<"type">>, Action)),
    Metadata = maps:get(<<"metadata">>, Action),
    ?assertEqual(<<"msg_1">>, maps:get(<<"message_id">>, Metadata)),
    ?assertEqual(#{<<"input_tokens">> => 12,
                   <<"output_tokens">> => 3},
                 maps:get(<<"usage_metadata">>, Metadata)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Metadata)).

decodes_tool_use_and_preserves_id_test() ->
    Response = response(
                 [#{<<"type">> => <<"text">>,
                    <<"text">> => <<"I will check.">>},
                  #{<<"type">> => <<"tool_use">>,
                    <<"id">> => <<"toolu_abc">>,
                    <<"name">> => <<"weather">>,
                    <<"input">> => #{<<"city">> => <<"Pune">>}}]),
    Result = adk_llm_anthropic_content:decode_response(Response, #{}),
    {ok, {tool_calls, Calls}, _Action} = adk_provider_result:decode(Result),
    ?assertEqual(
       [{<<"weather">>, #{<<"city">> => <<"Pune">>},
         undefined, <<"toolu_abc">>}], Calls).

decodes_json_binary_response_test() ->
    Result = adk_llm_anthropic_content:decode_response(
               jsx:encode(response(
                 [#{<<"type">> => <<"text">>, <<"text">> => <<"ok">>}])),
               #{}),
    ?assertMatch({provider_result, _}, Result).

rejects_malformed_or_unsupported_response_blocks_test() ->
    ?assertMatch(
       {error, {invalid_anthropic_response_block, 0,
                unsupported_anthropic_content_block}},
       adk_llm_anthropic_content:decode_response(
         response([#{<<"type">> => <<"thinking">>,
                     <<"thinking">> => <<"private">>}]), #{})),
    %% Large provider-controlled discriminators must not be retained in the
    %% error term returned to callers.
    RemoteType = binary:copy(<<"x">>, 1048576),
    TypeError = adk_llm_anthropic_content:decode_response(
                  response([#{<<"type">> => RemoteType}]), #{}),
    ?assertEqual(
       {error, {invalid_anthropic_response_block, 0,
                unsupported_anthropic_content_block}},
       TypeError),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(TypeError), RemoteType)),
    ?assertMatch(
       {error, {invalid_anthropic_response_block, 0,
                invalid_anthropic_tool_name}},
       adk_llm_anthropic_content:decode_response(
         response([#{<<"type">> => <<"tool_use">>,
                     <<"id">> => <<"toolu_1">>,
                     <<"name">> => <<"bad name">>,
                     <<"input">> => #{}}]), #{})),
    ?assertEqual(
       {error, invalid_anthropic_response},
       adk_llm_anthropic_content:decode_response(
         #{<<"type">> => <<"message">>,
           <<"role">> => <<"user">>, <<"content">> => []}, #{})).

rejects_invalid_usage_and_noncanonical_json_test() ->
    InvalidUsage = (response(
                      [#{<<"type">> => <<"text">>,
                         <<"text">> => <<"ok">>}]))#{
        <<"usage">> => #{<<"input_tokens">> => -1,
                          <<"output_tokens">> => 2}},
    ?assertEqual(
       {error, invalid_anthropic_response_metadata},
       adk_llm_anthropic_content:decode_response(InvalidUsage, #{})),
    Coercing = (response(
                  [#{<<"type">> => <<"text">>,
                     <<"text">> => <<"ok">>}]))#{
        <<"usage">> => #{<<"input_tokens">> => 1,
                          <<"output_tokens">> => 2,
                          atom_key => <<"not canonical">>}},
    ?assertEqual(
       {error, invalid_anthropic_response_metadata},
       adk_llm_anthropic_content:decode_response(Coercing, #{})).

decodes_bounded_error_without_remote_message_test() ->
    Error = #{<<"type">> => <<"error">>,
              <<"error">> =>
                  #{<<"type">> => <<"rate_limit_error">>,
                    <<"message">> => <<"secret request value echoed here">>},
              <<"request_id">> => <<"req_1">>},
    ?assertEqual(
       {error, {anthropic_api_error, 429,
                <<"rate_limit_error">>, <<"req_1">>}},
       adk_llm_anthropic_content:decode_error(429, Error)),
    Unknown = Error#{<<"error">> =>
                        #{<<"type">> => <<"future_error">>,
                          <<"message">> => <<"future">>}},
    ?assertEqual(
       {error, {anthropic_api_error, undefined,
                <<"future_error">>, <<"req_1">>}},
       adk_llm_anthropic_content:decode_error(Unknown)),
    ?assertEqual(
       {error, invalid_anthropic_error_response},
       adk_llm_anthropic_content:decode_error(
         #{<<"type">> => <<"error">>, <<"error">> => #{}})).

response(Blocks) ->
    #{<<"id">> => <<"msg_1">>,
      <<"type">> => <<"message">>,
      <<"role">> => <<"assistant">>,
      <<"model">> => <<"claude-test">>,
      <<"content">> => Blocks,
      <<"stop_reason">> => <<"end_turn">>,
      <<"stop_sequence">> => null,
      <<"usage">> => #{<<"input_tokens">> => 12,
                        <<"output_tokens">> => 3}}.
