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
    {ok, ApplicationVersion0} = application:get_key(erlang_adk, vsn),
    ApplicationVersion = unicode:characters_to_binary(ApplicationVersion0),
    ?assertEqual(ApplicationVersion, maps:get(<<"version">>, Card)),
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

identifiers_parts_and_payload_bytes_are_bounded_test() ->
    OversizedId = binary:copy(<<"i">>, 513),
    ?assertMatch(
       {error, {invalid_message, <<"messageId">>, _}},
       adk_a2a_v1_codec:validate_message(
         #{<<"messageId">> => OversizedId,
           <<"role">> => <<"ROLE_USER">>,
           <<"parts">> => [#{<<"text">> => <<"x">>}]})),
    TooManyParts = [#{<<"text">> => <<"x">>}
                    || _ <- lists:seq(1, 257)],
    ?assertMatch(
       {error, {invalid_message, <<"parts">>, too_many_parts}},
       adk_a2a_v1_codec:validate_message(
         #{<<"messageId">> => <<"bounded">>,
           <<"role">> => <<"ROLE_USER">>,
           <<"parts">> => TooManyParts})),
    OversizedText = binary:copy(<<"x">>, 524289),
    ?assertMatch(
       {error, {invalid_part, <<"text">>, _}},
       adk_a2a_v1_codec:validate_part(#{<<"text">> => OversizedText})),
    ?assertMatch(
       {error, {invalid_message, payload_too_large}},
       adk_a2a_v1_codec:validate_message(
         #{<<"messageId">> => <<"large">>,
           <<"role">> => <<"ROLE_USER">>,
           <<"parts">> => [#{<<"text">> => OversizedText}]})).

agent_card_security_and_required_extensions_test() ->
    Extension = <<"https://example.test/a2a/extensions/audit/v1">>,
    Config = #{
      url => <<"https://agent.example/a2a/v1">>,
      security_schemes => #{
        <<"bearer">> => #{
          <<"httpAuthSecurityScheme">> =>
              #{<<"scheme">> => <<"Bearer">>,
                <<"bearerFormat">> => <<"JWT">>}}},
      security_requirements => [
        #{<<"schemes">> =>
              #{<<"bearer">> => #{<<"list">> => [<<"a2a.invoke">>]}}}],
      skills => [skill()]},
    {ok, Card0} = adk_a2a_v1_card:new(Config),
    Capabilities = maps:get(<<"capabilities">>, Card0),
    Card = Card0#{
      <<"capabilities">> => Capabilities#{
        <<"extensions">> => [#{<<"uri">> => Extension,
                                <<"required">> => true,
                                <<"params">> => #{<<"mode">> => <<"strict">>}}]}},
    {ok, SafeCard} = adk_a2a_v1_card:validate(Card),
    ?assertEqual([Extension],
                 adk_a2a_v1_card:required_extensions(SafeCard)).

agent_card_security_references_must_resolve_test() ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<"https://agent.example/a2a/v1">>}),
    Invalid = Card#{
      <<"securitySchemes">> => #{
        <<"bearer">> => #{
          <<"httpAuthSecurityScheme">> => #{<<"scheme">> => <<"Bearer">>}}},
      <<"securityRequirements">> => [
        #{<<"schemes">> =>
              #{<<"missing">> => #{<<"list">> => []}}}]},
    ?assertMatch(
       {error, {invalid_agent_card, <<"securityRequirements">>, _}},
       adk_a2a_v1_card:validate(Invalid)).

agent_card_security_scheme_is_a_strict_union_test() ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<"https://agent.example/a2a/v1">>}),
    Invalid = Card#{
      <<"securitySchemes">> => #{
        <<"ambiguous">> => #{
          <<"httpAuthSecurityScheme">> => #{<<"scheme">> => <<"Bearer">>},
          <<"mtlsSecurityScheme">> => #{}}}},
    ?assertMatch(
       {error, {invalid_agent_card, <<"securitySchemes">>, _}},
       adk_a2a_v1_card:validate(Invalid)).

agent_card_extensions_are_bounded_and_unique_test() ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<"https://agent.example/a2a/v1">>}),
    Capabilities = maps:get(<<"capabilities">>, Card),
    Uri = <<"https://example.test/a2a/extensions/duplicate/v1">>,
    Invalid = Card#{
      <<"capabilities">> => Capabilities#{
        <<"extensions">> => [#{<<"uri">> => Uri}, #{<<"uri">> => Uri}]}},
    ?assertMatch(
       {error, {invalid_agent_card, <<"capabilities">>,
                <<"extensions">>, _}},
       adk_a2a_v1_card:validate(Invalid)).

skill() ->
    #{<<"id">> => <<"x">>, <<"name">> => <<"x">>,
      <<"description">> => <<"x">>, <<"tags">> => [<<"x">>]}.
