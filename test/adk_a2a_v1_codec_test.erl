-module(adk_a2a_v1_codec_test).
-include_lib("eunit/include/eunit.hrl").

agent_card_uses_v1_supported_interfaces_test() ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<"https://agent.example/a2a">>,
                     name => <<"Fixture">>,
                     description => <<"Fixture agent">>,
                     skills => [#{<<"id">> => <<"echo">>,
                                  <<"name">> => <<"Echo">>,
                                  <<"description">> => <<"Echo input">>,
                                  <<"tags">> => [<<"fixture">>]}]}),
    [#{<<"protocolBinding">> := <<"JSONRPC">>,
       <<"protocolVersion">> := <<"1.0">>}] =
        maps:get(<<"supportedInterfaces">>, Card),
    false = maps:is_key(<<"protocolVersion">>, Card),
    {ok, Json} = adk_a2a_v1_card:json(Card),
    ?assertEqual(nomatch, binary:match(Json, <<"preferredTransport">>)).

legacy_agent_card_is_rejected_test() ->
    Legacy = #{<<"name">> => <<"old">>, <<"description">> => <<"old">>,
               <<"version">> => <<"0.3">>,
               <<"url">> => <<"https://old.example">>,
               <<"preferredTransport">> => <<"JSONRPC">>,
               <<"capabilities">> => #{},
               <<"defaultInputModes">> => [<<"text">>],
               <<"defaultOutputModes">> => [<<"text">>],
               <<"skills">> => [skill()]},
    ?assertMatch({error, _}, adk_a2a_v1_card:validate(Legacy)).

member_discriminated_parts_test() ->
    ?assertMatch({ok, _}, adk_a2a_v1_codec:validate_part(
                           #{<<"text">> => <<"hello">>})),
    ?assertMatch({ok, _}, adk_a2a_v1_codec:validate_part(
                           #{<<"data">> => #{<<"n">> => 1}})),
    ?assertMatch({ok, _}, adk_a2a_v1_codec:validate_part(
                           #{<<"raw">> => base64:encode(<<1, 2, 3>>),
                             <<"filename">> => <<"a.bin">>,
                             <<"mediaType">> =>
                                 <<"application/octet-stream">>})),
    ?assertMatch({ok, _}, adk_a2a_v1_codec:validate_part(
                           #{<<"url">> => <<"https://files.example/a">>,
                             <<"filename">> => <<"a">>})).

legacy_kind_and_ambiguous_parts_are_rejected_test() ->
    ?assertMatch(
       {error, {invalid_a2a_1_0_object, part,
                legacy_kind_discriminator}},
       adk_a2a_v1_codec:validate_part(
         #{<<"kind">> => <<"text">>, <<"text">> => <<"old">>})),
    ?assertMatch({error, {invalid_part, multiple_content_members}},
                 adk_a2a_v1_codec:validate_part(
                   #{<<"text">> => <<"x">>, <<"data">> => #{}})).

stream_response_requires_one_member_test() ->
    ?assertMatch({ok, _}, adk_a2a_v1_codec:validate_stream_response(
                           #{<<"message">> =>
                                 #{<<"messageId">> => <<"direct-1">>,
                                   <<"role">> => <<"ROLE_AGENT">>,
                                   <<"parts">> =>
                                       [#{<<"text">> => <<"hello">>}]}})),
    ?assertMatch({error, _}, adk_a2a_v1_codec:validate_stream_response(#{})),
    ?assertMatch({error, _}, adk_a2a_v1_codec:validate_stream_response(
                              #{<<"task">> => #{},
                                <<"message">> => #{}})).

non_json_terms_are_rejected_test() ->
    ?assertMatch({error, _}, adk_a2a_v1_codec:validate_message(
                              #{<<"messageId">> => <<"m">>,
                                <<"role">> => <<"ROLE_USER">>,
                                <<"parts">> => [#{<<"data">> => self()}]})).

skill() ->
    #{<<"id">> => <<"x">>, <<"name">> => <<"x">>,
      <<"description">> => <<"x">>, <<"tags">> => [<<"x">>]}.
