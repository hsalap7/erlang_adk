-module(adk_mcp_protocol_foundation_test).

-include_lib("eunit/include/eunit.hrl").

protocol_eras_are_explicit_and_deprecated_capabilities_stay_legacy_test() ->
    ?assertEqual(<<"2025-11-25">>, adk_mcp_protocol:legacy_version()),
    ?assertEqual(<<"2026-07-28">>, adk_mcp_protocol:modern_version()),
    ?assertEqual({ok, legacy}, adk_mcp_protocol:era(<<"2025-11-25">>)),
    ?assertEqual({ok, modern}, adk_mcp_protocol:era(<<"2026-07-28">>)),
    ?assertEqual(
       {error, unsupported_mcp_protocol_version},
       adk_mcp_protocol:era(<<"2025-06-18">>)),
    LegacyClient = #{<<"roots">> => #{}, <<"sampling">> => #{}},
    ?assertEqual(
       {ok, LegacyClient},
       adk_mcp_protocol:client_capabilities(legacy, LegacyClient)),
    ?assertEqual(
       {ok, #{<<"logging">> => #{}}},
       adk_mcp_protocol:server_capabilities(
         legacy, #{<<"logging">> => #{}})),
    ?assertEqual(
       {error, {deprecated_mcp_capability, <<"roots">>}},
       adk_mcp_protocol:client_capabilities(modern, LegacyClient)),
    ?assertEqual(
       {error, {deprecated_mcp_capability, <<"logging">>}},
       adk_mcp_protocol:server_capabilities(
         modern, #{<<"logging">> => #{}})).

legacy_initialize_and_results_remain_handshake_shaped_test() ->
    {ok, Request} = adk_mcp_protocol:initialize_request(
                      1, implementation(<<"client">>),
                      #{<<"roots">> => #{}}),
    ?assertEqual(<<"initialize">>, maps:get(<<"method">>, Request)),
    Params = maps:get(<<"params">>, Request),
    ?assertEqual(<<"2025-11-25">>,
                 maps:get(<<"protocolVersion">>, Params)),
    ?assertNot(maps:is_key(<<"_meta">>, Params)),
    {ok, Response} = adk_mcp_protocol:initialize_result(
                       1, implementation(<<"server">>),
                       #{<<"logging">> => #{}}, #{}),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(<<"2025-11-25">>,
                 maps:get(<<"protocolVersion">>, Result)),
    ?assertNot(maps:is_key(<<"resultType">>, Result)),
    ?assertNot(maps:is_key(<<"_meta">>, Result)).

modern_request_is_self_describing_and_headers_match_test() ->
    Context = client_context(),
    {ok, Envelope} = adk_mcp_protocol:request(
                       modern, 7, <<"tools/call">>,
                       #{<<"name">> => <<"weather">>,
                         <<"arguments">> => #{<<"city">> => <<"Pune">>}},
                       Context),
    Headers = maps:get(headers, Envelope),
    Message = maps:get(message, Envelope),
    ?assertEqual(<<"2026-07-28">>,
                 maps:get(<<"mcp-protocol-version">>, Headers)),
    ?assertEqual(<<"tools/call">>, maps:get(<<"mcp-method">>, Headers)),
    ?assertEqual(<<"weather">>, maps:get(<<"mcp-name">>, Headers)),
    Params = maps:get(<<"params">>, Message),
    Meta = maps:get(<<"_meta">>, Params),
    ?assertEqual(
       <<"2026-07-28">>,
       maps:get(<<"io.modelcontextprotocol/protocolVersion">>, Meta)),
    ?assertEqual(
       #{<<"elicitation">> => #{}},
       maps:get(<<"io.modelcontextprotocol/clientCapabilities">>, Meta)),
    ?assertMatch(
       {ok, #{method := <<"tools/call">>}},
       adk_mcp_protocol:validate_http_request(modern, Headers, Message)).

modern_header_validation_is_case_insensitive_but_values_are_exact_test() ->
    {ok, Envelope} = adk_mcp_protocol_modern:request(
                       <<"id">>, <<"resources/read">>,
                       #{<<"uri">> => <<"file:///tmp/report">>},
                       client_context()),
    Message = maps:get(message, Envelope),
    Headers0 = maps:get(headers, Envelope),
    Headers = [{<<"MCP-Protocol-Version">>,
                maps:get(<<"mcp-protocol-version">>, Headers0)},
               {<<"Mcp-Method">>, maps:get(<<"mcp-method">>, Headers0)},
               {<<"MCP-NAME">>, maps:get(<<"mcp-name">>, Headers0)}],
    ?assertMatch({ok, _},
                 adk_mcp_protocol_modern:validate_http_request(
                   Headers, Message)),
    BadMethod = maps:put(<<"mcp-method">>, <<"resources/list">>, Headers0),
    ?assertEqual(
       {error, {mcp_header_mismatch, <<"mcp-method">>}},
       adk_mcp_protocol_modern:validate_http_request(BadMethod, Message)),
    MissingName = maps:remove(<<"mcp-name">>, Headers0),
    ?assertEqual(
       {error, {missing_mcp_header, <<"mcp-name">>}},
       adk_mcp_protocol_modern:validate_http_request(MissingName, Message)),
    ?assertEqual(
       {error, invalid_mcp_method},
       adk_mcp_protocol_modern:request(
         1, <<"tools/call\r\ninjected">>, #{}, client_context())).

modern_name_header_uses_canonical_base64_sentinel_test() ->
    Unicode = unicode:characters_to_binary([16#4E16, 16#754C]),
    {ok, Encoded} = adk_mcp_protocol_modern:encode_header_value(Unicode),
    ?assertMatch(<<"=?base64?", _/binary>>, Encoded),
    ?assertEqual({ok, Unicode},
                 adk_mcp_protocol_modern:decode_header_value(Encoded)),
    Literal = <<"=?base64?literal?=">>,
    {ok, EscapedLiteral} =
        adk_mcp_protocol_modern:encode_header_value(Literal),
    ?assertNotEqual(Literal, EscapedLiteral),
    ?assertEqual({ok, Literal},
                 adk_mcp_protocol_modern:decode_header_value(EscapedLiteral)),
    {ok, Padded} =
        adk_mcp_protocol_modern:encode_header_value(<<" padded ">>),
    ?assertMatch(<<"=?base64?", _/binary>>, Padded),
    ?assertEqual(
       {error, invalid_mcp_header_value},
       adk_mcp_protocol_modern:decode_header_value(
         <<"=?base64?not-canonical?=">>)).

modern_discovery_response_and_cacheable_lists_are_deterministic_test() ->
    ServerInfo = implementation(<<"server">>),
    Capabilities = #{<<"tools">> => #{<<"listChanged">> => true}},
    {ok, Discover} = adk_mcp_protocol:discover_result(
                       ServerInfo, Capabilities,
                       #{ttl_ms => 60000, cache_scope => public,
                         instructions => <<"Use only listed tools.">>}),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Discover)),
    ?assertEqual([<<"2026-07-28">>],
                 maps:get(<<"supportedVersions">>, Discover)),
    ?assertEqual(60000, maps:get(<<"ttlMs">>, Discover)),
    ?assertEqual(<<"public">>, maps:get(<<"cacheScope">>, Discover)),
    ServerMeta = maps:get(<<"_meta">>, Discover),
    ?assertEqual(ServerInfo,
                 maps:get(<<"io.modelcontextprotocol/serverInfo">>,
                          ServerMeta)),
    Items = [#{<<"name">> => <<"zeta">>, <<"inputSchema">> => #{}},
             #{<<"name">> => <<"alpha">>, <<"inputSchema">> => #{}}],
    {ok, ListResult} = adk_mcp_protocol_modern:list_result(
                         tools, Items,
                         #{ttl_ms => 10, cache_scope => private,
                           next_cursor => <<"cursor-2">>}),
    [First, Second] = maps:get(<<"tools">>, ListResult),
    ?assertEqual(<<"alpha">>, maps:get(<<"name">>, First)),
    ?assertEqual(<<"zeta">>, maps:get(<<"name">>, Second)),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, ListResult)),
    ?assertEqual(<<"cursor-2">>, maps:get(<<"nextCursor">>, ListResult)).

modern_response_always_stamps_server_identity_test() ->
    ServerInfo = implementation(<<"server">>),
    {ok, Response} = adk_mcp_protocol_modern:result_response(
                       9, #{<<"content">> => []}, ServerInfo),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(
       ServerInfo,
       maps:get(<<"io.modelcontextprotocol/serverInfo">>,
                maps:get(<<"_meta">>, Result))),
    ?assertEqual(
       {error, reserved_mcp_response_metadata},
       adk_mcp_protocol_modern:result_response(
         9,
         #{<<"_meta">> =>
               #{<<"io.modelcontextprotocol/serverInfo">> =>
                     implementation(<<"attacker">>)}},
         ServerInfo)).

bounded_mrtr_requires_capability_and_exact_response_keys_test() ->
    Requests =
        #{<<"confirm">> =>
              #{<<"method">> => <<"elicitation/create">>,
                <<"params">> =>
                    #{<<"mode">> => <<"form">>,
                      <<"message">> => <<"Continue?">>}}},
    State = <<"opaque-signed-request-state">>,
    Caps = #{<<"elicitation">> => #{}},
    {ok, Required} = adk_mcp_protocol_modern:input_required(
                       Requests, State, Caps),
    ?assertEqual(<<"input_required">>,
                 maps:get(<<"resultType">>, Required)),
    ?assertEqual(State, maps:get(<<"requestState">>, Required)),
    ?assertEqual(
       {error, missing_mcp_elicitation_capability},
       adk_mcp_protocol_modern:input_required(Requests, State, #{})),
    Sampling =
        #{<<"sample">> =>
              #{<<"method">> => <<"sampling/createMessage">>,
                <<"params">> => #{}}},
    ?assertEqual(
       {error, {deprecated_mcp_capability, <<"sampling">>}},
       adk_mcp_protocol_modern:input_required(Sampling, State, Caps)),
    Responses =
        #{<<"confirm">> =>
              #{<<"resultType">> => <<"complete">>,
                <<"action">> => <<"accept">>}},
    {ok, Retry} = adk_mcp_protocol_modern:input_response_params(
                    #{<<"name">> => <<"dangerous">>},
                    Requests, Responses, State),
    ?assertEqual(Responses, maps:get(<<"inputResponses">>, Retry)),
    ?assertEqual(
       {error, mcp_input_response_mismatch},
       adk_mcp_protocol_modern:input_response_params(
         #{<<"name">> => <<"dangerous">>}, Requests,
         #{<<"wrong">> =>
               #{<<"resultType">> => <<"complete">>}}, State)).

subscription_shapes_are_opt_in_bounded_and_correlated_test() ->
    Requested = #{<<"toolsListChanged">> => true,
                  <<"resourceSubscriptions">> =>
                      [<<"file:///b">>, <<"file:///a">>]},
    {ok, Envelope} = adk_mcp_protocol_modern:subscription_listen(
                       <<"listen-1">>, Requested, client_context()),
    Params = maps:get(<<"params">>, maps:get(message, Envelope)),
    Filter = maps:get(<<"notifications">>, Params),
    ?assertEqual([<<"file:///a">>, <<"file:///b">>],
                 maps:get(<<"resourceSubscriptions">>, Filter)),
    {ok, Ack} = adk_mcp_protocol_modern:subscription_acknowledged(
                  <<"listen-1">>, Requested,
                  #{<<"toolsListChanged">> => true}),
    AckParams = maps:get(<<"params">>, Ack),
    ?assertEqual(
       <<"listen-1">>,
       maps:get(<<"io.modelcontextprotocol/subscriptionId">>,
                maps:get(<<"_meta">>, AckParams))),
    {ok, EmptyAck} = adk_mcp_protocol_modern:subscription_acknowledged(
                       <<"listen-1">>, Requested, #{}),
    ?assertEqual(#{}, maps:get(<<"notifications">>,
                                maps:get(<<"params">>, EmptyAck))),
    ?assertEqual(
       {error, mcp_subscription_grant_not_requested},
       adk_mcp_protocol_modern:subscription_acknowledged(
         <<"listen-1">>, Requested,
         #{<<"promptsListChanged">> => true})),
    {ok, Event} = adk_mcp_protocol_modern:subscription_event(
                    <<"listen-1">>,
                    <<"notifications/resources/updated">>,
                    #{<<"uri">> => <<"file:///a">>}),
    ?assertEqual(<<"notifications/resources/updated">>,
                 maps:get(<<"method">>, Event)),
    ?assertEqual(
       {error, empty_mcp_subscription_filter},
       adk_mcp_protocol_modern:subscription_listen(
         1, #{}, client_context())).

strict_json_and_opaque_state_limits_fail_without_echoing_input_test() ->
    ?assertEqual(
       {error, invalid_mcp_json_type},
       adk_mcp_protocol_limits:validate_json(
         #{<<"unsafe">> => self()})),
    Deep = lists:foldl(
             fun(_, Acc) -> #{<<"nested">> => Acc} end,
             null, lists:seq(1, 40)),
    ?assertEqual(
       {error, mcp_json_depth_exceeded},
       adk_mcp_protocol_limits:validate_json(Deep)),
    Secret = <<"request-state-secret-must-not-appear">>,
    Oversized = binary:copy(Secret, 300),
    Error = adk_mcp_protocol_modern:input_required(
              #{}, Oversized, #{<<"elicitation">> => #{}}),
    ?assertEqual({error, invalid_mcp_request_state}, Error),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Error), Secret)).

strict_json_limits_cover_each_resource_boundary_test() ->
    Value = #{<<"text">> => <<"safe">>,
              <<"items">> => [1, 1.5, true, false, null]},
    ?assertEqual({ok, Value},
                 adk_mcp_protocol_limits:validate_json(Value)),
    {ok, EncodedBytes} = adk_mcp_protocol_limits:encoded_bytes(Value),
    ?assert(EncodedBytes > 0),
    ?assertEqual(
       {error, invalid_mcp_json_limits},
       adk_mcp_protocol_limits:validate_json(Value, not_a_map)),
    ?assertEqual(
       {error, invalid_mcp_json_limits},
       adk_mcp_protocol_limits:encoded_bytes(Value, not_a_map)),
    lists:foreach(
      fun(Overrides) ->
          ?assertEqual(
             {error, invalid_mcp_json_limits},
             adk_mcp_protocol_limits:validate_json(Value, Overrides))
      end,
      [#{unknown => 1}, #{max_depth => 0}, #{max_nodes => invalid}]),
    BoundaryCases =
        [{<<255>>, #{}, invalid_mcp_json_utf8},
         {<<"ab">>, #{max_binary_bytes => 1},
          mcp_json_binary_size_exceeded},
         {[<<"aa">>, <<"bb">>], #{max_total_binary_bytes => 3},
          mcp_json_binary_budget_exceeded},
         {[1, 2], #{max_nodes => 2}, mcp_json_node_count_exceeded},
         {[1, 2], #{max_list_length => 1},
          mcp_json_list_length_exceeded},
         {[1 | 2], #{}, invalid_mcp_json_list},
         {#{<<"a">> => 1, <<"b">> => 2}, #{max_map_size => 1},
          mcp_json_map_size_exceeded},
         {#{atom_key => 1}, #{}, invalid_mcp_json_key},
         {[[null]], #{max_depth => 1}, mcp_json_depth_exceeded},
         {<<"abcd">>, #{max_bytes => 3},
          mcp_json_encoded_size_exceeded},
         {<<"a">>, #{max_external_bytes => 1},
          mcp_json_external_size_exceeded},
         {{tuple, is_not_json}, #{}, invalid_mcp_json_type}],
    lists:foreach(
      fun({Candidate, Overrides, Reason}) ->
          ?assertEqual(
             {error, Reason},
             adk_mcp_protocol_limits:validate_json(Candidate, Overrides)),
          ?assertEqual(
             {error, Reason},
             adk_mcp_protocol_limits:encoded_bytes(Candidate, Overrides))
      end, BoundaryCases).

explicit_era_dispatch_rejects_context_confusion_test() ->
    ?assertEqual([<<"2026-07-28">>, <<"2025-11-25">>],
                 adk_mcp_protocol:supported_versions()),
    ?assertEqual({ok, legacy}, adk_mcp_protocol:era(legacy)),
    ?assertEqual({ok, modern}, adk_mcp_protocol:era(modern)),
    {ok, LegacyEnvelope} = adk_mcp_protocol:request(
                             legacy, 1, <<"tools/list">>, #{}, #{}),
    ?assertEqual(#{}, maps:get(headers, LegacyEnvelope)),
    LegacyMessage = maps:get(message, LegacyEnvelope),
    ?assertMatch(
       {ok, #{<<"method">> := <<"tools/list">>}},
       adk_mcp_protocol:validate_http_request(
         legacy, #{<<"ignored">> => <<"legacy">>}, LegacyMessage)),
    ?assertEqual(
       {error, invalid_mcp_legacy_request_context},
       adk_mcp_protocol:request(
         legacy, 1, <<"tools/list">>, #{}, #{session_id => <<"wrong-era">>})),
    ?assertEqual(
       {error, invalid_mcp_request_context},
       adk_mcp_protocol:request(
         legacy, 1, <<"tools/list">>, #{}, not_a_map)),
    ?assertEqual(
       {error, unsupported_mcp_protocol_version},
       adk_mcp_protocol:request(
         <<"unknown">>, 1, <<"tools/list">>, #{}, #{})),
    {ok, LegacyResponse} = adk_mcp_protocol:result_response(
                             legacy, 1, #{<<"tools">> => []}, #{}),
    ?assertEqual(#{<<"tools">> => []},
                 maps:get(<<"result">>, LegacyResponse)),
    ?assertEqual(
       {error, invalid_mcp_legacy_result_context},
       adk_mcp_protocol:result_response(
         legacy, 1, #{}, implementation(<<"server">>))),
    ?assertEqual(
       {error, invalid_mcp_result_context},
       adk_mcp_protocol:result_response(legacy, 1, #{}, not_a_map)),
    ?assertEqual(
       {error, unsupported_mcp_protocol_version},
       adk_mcp_protocol:client_capabilities(<<"unknown">>, #{})),
    ?assertEqual(
       {error, unsupported_mcp_protocol_version},
       adk_mcp_protocol:server_capabilities(<<"unknown">>, #{})).

legacy_handshake_and_message_validation_fail_closed_test() ->
    Client = implementation(<<"client">>),
    Server = implementation(<<"server">>),
    ?assertEqual(
       {error, invalid_mcp_request_id},
       adk_mcp_protocol_legacy:initialize_request(<<>>, Client, #{})),
    ?assertEqual(
       {error, invalid_mcp_implementation},
       adk_mcp_protocol_legacy:initialize_request(
         1, #{<<"name">> => <<"client">>}, #{})),
    ?assertEqual(
       {error, invalid_mcp_legacy_capabilities},
       adk_mcp_protocol_legacy:initialize_request(
         1, Client, #{<<"logging">> => #{}})),
    {ok, Initialized} = adk_mcp_protocol_legacy:initialize_result(
                          1, Server, #{<<"tools">> => #{}},
                          #{instructions => <<"bounded">>}),
    ?assertEqual(<<"bounded">>,
                 maps:get(<<"instructions">>,
                          maps:get(<<"result">>, Initialized))),
    ?assertEqual(
       {error, invalid_mcp_initialize_options},
       adk_mcp_protocol_legacy:initialize_result(
         1, Server, #{}, #{unknown => true})),
    ?assertEqual(
       {error, invalid_mcp_initialize_options},
       adk_mcp_protocol_legacy:initialize_result(1, Server, #{}, [])),
    ?assertEqual(
       {error, invalid_mcp_text},
       adk_mcp_protocol_legacy:initialize_result(
         1, Server, #{}, #{instructions => <<>>})),
    InvalidRequests =
        [adk_mcp_protocol_legacy:request(<<>>, <<"tools/list">>, #{}),
         adk_mcp_protocol_legacy:request(1, <<>>, #{}),
         adk_mcp_protocol_legacy:request(
           1, binary:copy(<<"m">>, 257), #{}),
         adk_mcp_protocol_legacy:validate_request(
           #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
             <<"method">> => <<"tools/list">>, <<"params">> => #{},
             <<"extra">> => true})],
    ?assert(lists:all(
              fun(Result) ->
                  Result =:= {error, invalid_mcp_legacy_request}
              end, InvalidRequests)),
    ?assertEqual(
       {error, invalid_mcp_json_type},
       adk_mcp_protocol_legacy:request(
         1, <<"tools/list">>, not_a_map)),
    ?assertEqual(
       {error, invalid_mcp_result},
       adk_mcp_protocol_legacy:result_response(1, not_a_map)),
    ?assertEqual(
       {error, invalid_mcp_request_id},
       adk_mcp_protocol_legacy:result_response(<<>>, #{})),
    ?assertEqual(
       {error, invalid_mcp_legacy_capabilities},
       adk_mcp_protocol_legacy:client_capabilities(not_a_map)),
    ?assertEqual(
       {error, invalid_mcp_legacy_capabilities},
       adk_mcp_protocol_legacy:server_capabilities(
         #{<<"unknown">> => #{}})).

modern_envelope_metadata_and_header_boundaries_test() ->
    Context = client_context(),
    ?assertEqual(<<"2026-07-28">>, adk_mcp_protocol_modern:version()),
    ?assertEqual(
       {error, reserved_mcp_request_metadata},
       adk_mcp_protocol_modern:request(
         1, <<"tools/list">>, #{<<"_meta">> => #{}}, Context)),
    ?assertEqual(
       {error, invalid_mcp_modern_request},
       adk_mcp_protocol_modern:request(1, <<"tools/list">>, [], Context)),
    ?assertEqual(
       {error, invalid_mcp_client_context},
       adk_mcp_protocol_modern:request(
         1, <<"tools/list">>, #{}, Context#{unknown => true})),
    ?assertEqual(
       {error, {deprecated_mcp_capability, <<"roots">>}},
       adk_mcp_protocol_modern:request(
         1, <<"tools/list">>, #{},
         #{client_capabilities => #{<<"roots">> => #{}}})),
    ?assertEqual(
       {error, invalid_mcp_implementation},
       adk_mcp_protocol_modern:request(
         1, <<"tools/list">>, #{}, #{client_info => #{}})),
    ?assertEqual(
       {error, invalid_mcp_request_metadata},
       adk_mcp_protocol_modern:request(
         1, <<"tools/list">>, #{}, #{meta => []})),
    ?assertEqual(
       {error, reserved_mcp_metadata_key},
       adk_mcp_protocol_modern:request(
         1, <<"tools/list">>, #{},
         #{meta => #{<<"io.modelcontextprotocol/private">> => true}})),
    ?assertEqual(
       {error, invalid_mcp_method},
       adk_mcp_protocol_modern:request(1, <<>>, #{}, Context)),
    ?assertEqual(
       {error, invalid_mcp_name},
       adk_mcp_protocol_modern:request(
         1, <<"tools/call">>, #{<<"name">> => <<>>}, Context)),
    ?assertEqual(
       {error, invalid_mcp_name},
       adk_mcp_protocol_modern:request(
         1, <<"resources/read">>, #{<<"uri">> => <<255>>}, Context)),

    {ok, Envelope} = adk_mcp_protocol_modern:request(
                       1, <<"tools/list">>, #{}, Context),
    Headers = maps:get(headers, Envelope),
    Message = maps:get(message, Envelope),
    Params = maps:get(<<"params">>, Message),
    Meta = maps:get(<<"_meta">>, Params),
    ?assertEqual(
       {error, invalid_mcp_modern_request},
       adk_mcp_protocol_modern:validate_http_request(
         Headers, Message#{<<"extra">> => true})),
    ?assertEqual(
       {error, invalid_mcp_modern_request},
       adk_mcp_protocol_modern:validate_http_request(Headers, #{})),
    ?assertEqual(
       {error, invalid_mcp_json_type},
       adk_mcp_protocol_modern:validate_http_request(
         Headers, Message#{<<"params">> => #{<<"unsafe">> => self()}})),
    ?assertEqual(
       {error, missing_mcp_request_metadata},
       adk_mcp_protocol_modern:validate_http_request(
         Headers, Message#{<<"params">> => #{}})),
    assert_meta_error(
      Headers, Message, Params, maps:remove(
                                   <<"io.modelcontextprotocol/protocolVersion">>,
                                   Meta),
      {error, missing_mcp_protocol_metadata}),
    assert_meta_error(
      Headers, Message, Params,
      maps:remove(<<"io.modelcontextprotocol/clientCapabilities">>, Meta),
      {error, invalid_mcp_modern_capabilities}),
    assert_meta_error(
      Headers, Message, Params,
      Meta#{<<"io.modelcontextprotocol/logLevel">> => <<"debug">>},
      {error, {deprecated_mcp_capability, <<"logging">>}}),
    assert_meta_error(
      Headers, Message, Params,
      Meta#{<<"io.modelcontextprotocol/private">> => true},
      {error, reserved_mcp_metadata_key}),
    assert_meta_error(
      Headers, Message, Params,
      Meta#{<<"io.modelcontextprotocol/protocolVersion">> => <<"old">>},
      {error, unsupported_mcp_protocol_version}),
    assert_meta_error(
      Headers, Message, Params,
      Meta#{<<"io.modelcontextprotocol/clientCapabilities">> => []},
      {error, invalid_mcp_modern_capabilities}),
    assert_meta_error(
      Headers, Message, Params,
      Meta#{<<"io.modelcontextprotocol/clientInfo">> => #{}},
      {error, invalid_mcp_implementation}),

    HeaderErrors =
        [{maps:remove(<<"mcp-protocol-version">>, Headers),
          {error, {missing_mcp_header, <<"mcp-protocol-version">>}}},
         {maps:remove(<<"mcp-method">>, Headers),
          {error, {missing_mcp_header, <<"mcp-method">>}}},
         {Headers#{<<"mcp-protocol-version">> => <<"2025-11-25">>},
          {error, {mcp_header_mismatch, <<"mcp-protocol-version">>}}},
         {Headers#{<<"mcp-method">> => <<"prompts/list">>},
          {error, {mcp_header_mismatch, <<"mcp-method">>}}},
         {Headers#{<<"mcp-name">> => <<"unexpected">>},
          {error, {mcp_header_mismatch, <<"mcp-name">>}}}],
    lists:foreach(
      fun({Candidate, Expected}) ->
          ?assertEqual(
             Expected,
             adk_mcp_protocol_modern:validate_http_request(
               Candidate, Message))
      end, HeaderErrors),
    ?assertEqual(
       {error, duplicate_mcp_header},
       adk_mcp_protocol_modern:validate_http_request(
         [{<<"MCP-Method">>, <<"tools/list">>},
          {<<"mcp-method">>, <<"tools/list">>}], Message)),
    ?assertEqual(
       {error, invalid_mcp_headers},
       adk_mcp_protocol_modern:validate_http_request(
         lists:duplicate(129, {<<"x">>, <<"y">>}), Message)),
    ?assertEqual(
       {error, invalid_mcp_headers},
       adk_mcp_protocol_modern:validate_http_request(
         [{<<"x">>, <<"y">>} | improper], Message)),
    ?assertEqual(
       {error, invalid_mcp_header_name},
       adk_mcp_protocol_modern:validate_http_request(
         [{<<"bad header">>, <<"value">>}], Message)),
    TokenName = <<"A0!#$%&'*+-.^_`|~">>,
    ?assertEqual(
       {error, {missing_mcp_header, <<"mcp-protocol-version">>}},
       adk_mcp_protocol_modern:validate_http_request(
         [{TokenName, <<"value">>}], Message)).

modern_results_discovery_and_lists_fail_closed_test() ->
    Server = implementation(<<"server">>),
    ?assertEqual(
       {error, invalid_mcp_request_id},
       adk_mcp_protocol_modern:result_response(<<>>, #{}, Server)),
    ?assertEqual(
       {error, invalid_mcp_implementation},
       adk_mcp_protocol_modern:result_response(1, #{}, #{})),
    ?assertEqual(
       {error, invalid_mcp_result_type},
       adk_mcp_protocol_modern:result_response(
         1, #{<<"resultType">> => 42}, Server)),
    ?assertEqual(
       {error, invalid_mcp_result_type},
       adk_mcp_protocol_modern:result_response(
         1, #{<<"resultType">> => <<255>>}, Server)),
    ?assertEqual(
       {error, invalid_mcp_result},
       adk_mcp_protocol_modern:result_response(1, [], Server)),
    DiscoveryErrors =
        [{Server, #{}, #{supported_versions => [<<"2025-11-25">>]},
          invalid_mcp_discovery_versions},
         {Server, #{<<"unknown">> => #{}}, #{},
          invalid_mcp_modern_capabilities},
         {#{}, #{}, #{}, invalid_mcp_implementation},
         {Server, #{}, #{ttl_ms => -1}, invalid_mcp_cache_options},
         {Server, #{}, #{cache_scope => shared}, invalid_mcp_cache_options},
         {Server, #{}, #{instructions => <<>>}, invalid_mcp_text},
         {Server, #{}, #{unknown => true}, invalid_mcp_discovery_options}],
    lists:foreach(
      fun({Info, Caps, Options, Reason}) ->
          ?assertEqual(
             {error, Reason},
             adk_mcp_protocol_modern:discover_result(
               Info, Caps, Options))
      end, DiscoveryErrors),
    ?assertEqual(
       {error, invalid_mcp_discovery_options},
       adk_mcp_protocol_modern:discover_result(Server, #{}, [])),
    ?assertEqual(
       {error, reserved_mcp_cache_fields},
       adk_mcp_protocol_modern:cacheable_result(
         #{<<"ttlMs">> => 1}, #{})),
    ?assertEqual(
       {error, invalid_mcp_cache_options},
       adk_mcp_protocol_modern:cacheable_result(#{}, #{unknown => true})),
    ?assertEqual(
       {error, invalid_mcp_result_type},
       adk_mcp_protocol_modern:cacheable_result(
         #{<<"resultType">> => <<>>}, #{})),
    ?assertEqual(
       {error, invalid_mcp_cacheable_result},
       adk_mcp_protocol_modern:cacheable_result([], #{})),

    ResourceItems = [#{<<"uri">> => <<"file:///b">>},
                     #{<<"uri">> => <<"file:///a">>}],
    {ok, ResourceList} = adk_mcp_protocol_modern:list_result(
                           resources, ResourceItems,
                           #{cache_scope => <<"public">>}),
    ?assertEqual([#{<<"uri">> => <<"file:///a">>},
                  #{<<"uri">> => <<"file:///b">>}],
                 maps:get(<<"resources">>, ResourceList)),
    {ok, PromptList} = adk_mcp_protocol_modern:list_result(
                         prompts, [#{<<"name">> => <<"prompt-a">>}], #{}),
    ?assertEqual(1, length(maps:get(<<"prompts">>, PromptList))),
    ListErrors =
        [{tools, [], #{unknown => true}, invalid_mcp_list_options},
         {tools, [], #{next_cursor => <<>>}, invalid_mcp_text},
         {unknown, [], #{}, invalid_mcp_list_kind},
         {tools, [#{}], #{}, invalid_mcp_list_item},
         {tools, [#{<<"name">> => <<"same">>},
                  #{<<"name">> => <<"same">>}], #{},
          duplicate_or_invalid_mcp_list_item},
         {tools, [#{<<"name">> => <<255>>}], #{},
          invalid_mcp_json_utf8},
         {tools, [#{<<"name">> => <<"tool">>, <<"unsafe">> => self()}],
          #{}, invalid_mcp_json_type},
         {tools, lists:duplicate(1025, #{}), #{},
          mcp_list_capacity_exceeded}],
    lists:foreach(
      fun({Kind, Items, Options, Reason}) ->
          ?assertEqual(
             {error, Reason},
             adk_mcp_protocol_modern:list_result(Kind, Items, Options))
      end, ListErrors),
    ?assertEqual(
       {error, invalid_mcp_list_result},
       adk_mcp_protocol_modern:list_result(tools, not_a_list, #{})).

modern_mrtr_validation_rejects_ambiguous_retries_test() ->
    Request = #{<<"method">> => <<"elicitation/create">>,
                <<"params">> => #{}},
    Requests = #{<<"confirm">> => Request},
    Response = #{<<"resultType">> => <<"complete">>},
    Responses = #{<<"confirm">> => Response},
    Caps = #{<<"elicitation">> => #{}},
    ?assertEqual(
       {error, empty_mcp_input_required},
       adk_mcp_protocol_modern:input_required(#{}, undefined, #{})),
    {ok, StateOnly} = adk_mcp_protocol_modern:input_required(
                        #{}, <<"signed-state">>, #{}),
    ?assertEqual(<<"signed-state">>,
                 maps:get(<<"requestState">>, StateOnly)),
    ?assertEqual(
       {error, invalid_mcp_modern_capabilities},
       adk_mcp_protocol_modern:input_required(Requests, undefined, [])),
    ?assertEqual(
       {error, mcp_input_request_capacity_exceeded},
       adk_mcp_protocol_modern:input_required(
         maps:from_list([{integer_to_binary(I), Request}
                         || I <- lists:seq(1, 33)]), undefined, Caps)),
    InvalidRequests =
        [#{<<>> => Request},
         #{<<"confirm">> => not_a_map},
         #{<<"confirm">> => Request#{<<"extra">> => true}},
         #{<<"confirm">> => Request#{<<"method">> =>
                                          <<"sampling/createMessage">>}},
         #{<<"confirm">> => Request#{<<"method">> => <<"roots/list">>}},
         #{<<"confirm">> => Request#{<<"method">> => <<"unknown">>}},
         #{<<"confirm">> => Request#{<<"params">> => []}}],
    lists:foreach(
      fun(Candidate) ->
          ?assertMatch(
             {error, _},
             adk_mcp_protocol_modern:input_required(
               Candidate, undefined, Caps))
      end, InvalidRequests),
    ?assertEqual(
       {error, invalid_mcp_request_state},
       adk_mcp_protocol_modern:input_required(Requests, <<>>, Caps)),
    ?assertEqual(
       {error, invalid_mcp_input_required},
       adk_mcp_protocol_modern:input_required([], undefined, Caps)),
    ?assertEqual(
       {error, reserved_mcp_retry_fields},
       adk_mcp_protocol_modern:input_response_params(
         #{<<"requestState">> => <<"attacker">>}, Requests,
         Responses, undefined)),
    ?assertEqual(
       {error, invalid_mcp_json_type},
       adk_mcp_protocol_modern:input_response_params(
         #{<<"unsafe">> => self()}, Requests, Responses, undefined)),
    ?assertEqual(
       {error, invalid_mcp_input_response},
       adk_mcp_protocol_modern:input_response_params(
         #{}, Requests, #{<<"confirm">> => #{}}, undefined)),
    ?assertEqual(
       {error, mcp_input_response_capacity_exceeded},
       adk_mcp_protocol_modern:input_response_params(
         #{}, Requests,
         maps:from_list([{integer_to_binary(I), Response}
                         || I <- lists:seq(1, 33)]), undefined)),
    ?assertEqual(
       {error, invalid_mcp_request_state},
       adk_mcp_protocol_modern:input_response_params(
         #{}, Requests, Responses, <<>>)),
    ?assertEqual(
       {error, invalid_mcp_input_responses},
       adk_mcp_protocol_modern:input_response_params(
         [], Requests, Responses, undefined)),
    {ok, RetryByState} = adk_mcp_protocol_modern:input_response_params(
                           #{<<"name">> => <<"tool">>}, #{}, #{},
                           <<"signed-state">>),
    ?assertEqual(<<"signed-state">>,
                 maps:get(<<"requestState">>, RetryByState)).

modern_subscription_and_header_security_boundaries_test() ->
    Context = client_context(),
    Requested = #{<<"toolsListChanged">> => true,
                  <<"promptsListChanged">> => true,
                  <<"resourcesListChanged">> => true,
                  <<"resourceSubscriptions">> =>
                      [<<"file:///a">>, <<"file:///b">>]},
    {ok, Ack} = adk_mcp_protocol_modern:subscription_acknowledged(
                  <<"sub-1">>, Requested,
                  #{<<"resourceSubscriptions">> => [<<"file:///a">>]}),
    ?assertMatch(#{<<"params">> := _}, Ack),
    ?assertEqual(
       {error, invalid_mcp_request_id},
       adk_mcp_protocol_modern:subscription_acknowledged(
         <<>>, Requested, #{})),
    ?assertEqual(
       {error, invalid_mcp_subscription_filter},
       adk_mcp_protocol_modern:subscription_acknowledged(
         1, not_a_map, #{})),
    ?assertEqual(
       {error, invalid_mcp_subscription_filter},
       adk_mcp_protocol_modern:subscription_acknowledged(
         1, Requested, not_a_map)),
    ?assertEqual(
       {error, mcp_subscription_grant_not_requested},
       adk_mcp_protocol_modern:subscription_acknowledged(
         1, Requested,
         #{<<"resourceSubscriptions">> => [<<"file:///other">>]})),
    InvalidFilters =
        [not_a_map,
         #{<<"unknown">> => true},
         #{<<"toolsListChanged">> => 1},
         #{<<"resourceSubscriptions">> => not_a_list},
         #{<<"resourceSubscriptions">> => [<<"file:///a">>,
                                              <<"file:///a">>]},
         #{<<"resourceSubscriptions">> => [<<>>]},
         #{<<"resourceSubscriptions">> =>
               [integer_to_binary(I) || I <- lists:seq(1, 257)]}],
    lists:foreach(
      fun(Filter) ->
          ?assertMatch(
             {error, _},
             adk_mcp_protocol_modern:subscription_listen(
               1, Filter, Context))
      end, InvalidFilters),
    lists:foreach(
      fun(Method) ->
          ?assertMatch(
             {ok, #{<<"method">> := Method}},
             adk_mcp_protocol_modern:subscription_event(
               <<"sub-1">>, Method, #{}))
      end,
      [<<"notifications/tools/list_changed">>,
       <<"notifications/prompts/list_changed">>,
       <<"notifications/resources/list_changed">>]),
    EventErrors =
        [{<<"sub-1">>, <<"notifications/tools/list_changed">>,
          #{<<"_meta">> => #{}}, reserved_mcp_subscription_metadata},
         {<<"sub-1">>, <<"notifications/resources/updated">>, #{},
          invalid_mcp_resource_uri},
         {<<"sub-1">>, <<"notifications/resources/updated">>,
          #{<<"uri">> => <<>>}, invalid_mcp_resource_uri},
         {<<"sub-1">>, <<"notifications/unknown">>, #{},
          invalid_mcp_subscription_event},
         {<<>>, <<"notifications/tools/list_changed">>, #{},
          invalid_mcp_subscription_notification}],
    lists:foreach(
      fun({Id, Method, Params, Reason}) ->
          ?assertEqual(
             {error, Reason},
             adk_mcp_protocol_modern:subscription_event(
               Id, Method, Params))
      end, EventErrors),
    ?assertEqual(
       {error, invalid_mcp_subscription_event},
       adk_mcp_protocol_modern:subscription_event(
         <<"sub-1">>, <<"notifications/tools/list_changed">>, [])),
    ?assertMatch(
       {ok, #{<<"result">> := _}},
       adk_mcp_protocol_modern:subscription_complete(
         <<"sub-1">>, implementation(<<"server">>))),

    ?assertEqual({ok, <<>>},
                 adk_mcp_protocol_modern:encode_header_value(<<>>)),
    ?assertEqual(
       {error, invalid_mcp_header_value},
       adk_mcp_protocol_modern:encode_header_value(<<255>>)),
    ?assertEqual(
       {error, invalid_mcp_header_value},
       adk_mcp_protocol_modern:encode_header_value(
         binary:copy(<<"x">>, 2049))),
    ?assertMatch(
       {ok, <<"=?base64?", _/binary>>},
       adk_mcp_protocol_modern:encode_header_value(<<"\tvalue">>)),
    ?assertEqual(
       {error, invalid_mcp_header_value},
       adk_mcp_protocol_modern:decode_header_value(<<" value">>)),
    ?assertEqual(
       {error, invalid_mcp_header_value},
       adk_mcp_protocol_modern:decode_header_value(<<"bad\nvalue">>)),
    ?assertEqual(
       {error, invalid_mcp_header_value},
       adk_mcp_protocol_modern:decode_header_value(
         binary:copy(<<"x">>, 8193))),
    ?assertEqual(
       {error, invalid_mcp_header_value},
       adk_mcp_protocol_modern:decode_header_value(<<"=?base64?%%%?=">>)),
    OversizedDecoded = binary:copy(<<"x">>, 2049),
    OversizedSentinel =
        <<"=?base64?", (base64:encode(OversizedDecoded))/binary, "?=">>,
    ?assertEqual(
       {error, mcp_header_value_too_large},
       adk_mcp_protocol_modern:decode_header_value(OversizedSentinel)).

assert_meta_error(Headers, Message, Params, Meta, Expected) ->
    Candidate = Message#{<<"params">> => Params#{<<"_meta">> => Meta}},
    ?assertEqual(
       Expected,
       adk_mcp_protocol_modern:validate_http_request(Headers, Candidate)).

implementation(Name) ->
    #{<<"name">> => Name, <<"version">> => <<"1.0.0">>}.

client_context() ->
    #{client_info => implementation(<<"test-client">>),
      client_capabilities => #{<<"elicitation">> => #{}},
      meta => #{<<"traceparent">> =>
                    <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>}}.
