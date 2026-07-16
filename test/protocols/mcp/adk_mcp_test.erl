-module(adk_mcp_test).
-include_lib("eunit/include/eunit.hrl").

mcp_client_test() ->
    {ok, Client} = adk_mcp_client:connect(<<"stdio">>, <<"dummy">>),
    {links, Links} = process_info(self(), links),
    ?assertNot(lists:member(Client, Links)),
    {ok, []} = adk_mcp_client:list_tools(Client),
    ok = adk_mcp_client:close(Client).

mcp_stdio_handshake_test() ->
    Fixture = filename:absname("test/mcp_stdio_fixture.sh"),
    {ok, Client} = adk_mcp_client:connect(
                     <<"stdio">>, unicode:characters_to_binary(Fixture)),
    {ok, [Tool]} = adk_mcp_client:list_tools(Client),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Tool)),
    {ok, Result} = adk_mcp_client:execute_tool(
                     Client, <<"search">>, #{<<"query">> => <<"erlang">>}),
    ?assertEqual(false, maps:get(<<"isError">>, Result)),
    ok = wait_for_port_closed(Client, 50),
    ?assert(is_process_alive(Client)),
    ?assertEqual({error, port_closed}, adk_mcp_client:list_tools(Client)),
    ok = adk_mcp_client:close(Client).

mcp_deprecated_sse_test() ->
    ?assertEqual(
       {error, {unsupported_transport, sse_deprecated_use_streamable_http}},
       adk_mcp_client:connect(<<"sse">>, <<"http://localhost">>)).

mcp_client_rejects_static_secret_and_transport_headers_test() ->
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"streamable_http">>, <<"http://127.0.0.1:1/mcp">>,
         #{headers => [{<<"authorization">>, <<"Bearer secret">>}]})),
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"streamable_http">>, <<"http://127.0.0.1:1/mcp">>,
         #{headers => [{<<"mcp-session-id">>, <<"injected">>}]})).

mcp_client_rejects_cleartext_bearer_without_explicit_loopback_opt_in_test_() ->
    {timeout, 10, fun() ->
        {Listener, Ref, Url} = start_security_fixture(#{}),
        Auth = fun() ->
            [{<<"authorization">>, <<"Bearer must-not-be-sent">>}]
        end,
        try
            ?assertEqual(
               {error, insecure_mcp_destination},
               adk_mcp_client:connect(
                 <<"streamable_http">>, Url, #{auth_fun => Auth})),
            assert_no_security_fixture_request(Ref)
        after
            ok = cowboy:stop_listener(Listener)
        end
    end}.

mcp_client_rejects_private_and_mixed_dns_destinations_test() ->
    MixedResolver = fun(_Host) ->
        [{127, 0, 0, 1}, {93, 184, 216, 34}]
    end,
    ?assertEqual(
       {error, insecure_mcp_destination},
       adk_mcp_client:connect(
         <<"streamable_http">>, <<"http://mixed.example:8080/mcp">>,
         #{allow_http_loopback => true, resolver_fun => MixedResolver})),
    PrivateResolver = fun(_Host) -> [{10, 0, 0, 8}] end,
    ?assertEqual(
       {error, mcp_private_destination_rejected},
       adk_mcp_client:connect(
         <<"streamable_http">>, <<"https://private.example/mcp">>,
         #{resolver_fun => PrivateResolver})).

mcp_client_pins_validated_address_and_preserves_origin_headers_test_() ->
    {timeout, 10, fun() ->
        {Listener, Ref, LoopbackUrl} = start_security_fixture(#{}),
        Parsed = uri_string:parse(LoopbackUrl),
        Port = maps:get(port, Parsed),
        Url = <<"http://mcp.example:", (integer_to_binary(Port))/binary,
                "/mcp">>,
        Resolver = fun(<<"mcp.example">>) -> [{127, 0, 0, 1}] end,
        Auth = fun() ->
            [{<<"Authorization">>, <<"Bearer pinned-origin">>}]
        end,
        try
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true,
                               resolver_fun => Resolver,
                               allowed_hosts => [<<"mcp.example">>],
                               auth_fun => Auth}),
            try
                receive
                    {mcp_security_fixture_request, Ref, <<"initialize">>,
                     Host, Authorization, ProxyAuthorization} ->
                        ?assertEqual(
                           <<"mcp.example:", (integer_to_binary(Port))/binary>>,
                           Host),
                        ?assertEqual(<<"Bearer pinned-origin">>, Authorization),
                        ?assertEqual(undefined, ProxyAuthorization)
                after 1000 ->
                    ?assert(false)
                end
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = cowboy:stop_listener(Listener),
            flush_security_fixture_requests(Ref)
        end
    end}.

mcp_client_rejects_proxy_authorization_test_() ->
    {timeout, 10, fun() ->
        {Listener, Ref, Url} = start_security_fixture(#{}),
        ProxyAuth = fun() ->
            [{<<"proxy-authorization">>, <<"Bearer proxy-secret">>}]
        end,
        try
            ?assertEqual(
               {error, invalid_auth_headers},
               adk_mcp_client:connect(
                 <<"streamable_http">>, Url,
                 #{allow_http_loopback => true, auth_fun => ProxyAuth})),
            assert_no_security_fixture_request(Ref)
        after
            ok = cowboy:stop_listener(Listener)
        end
    end}.

mcp_client_rejects_redirect_without_forwarding_credentials_test_() ->
    {timeout, 10, fun() ->
        {TargetListener, TargetRef, TargetUrl} = start_security_fixture(#{}),
        {RedirectListener, RedirectRef, RedirectUrl} =
            start_security_fixture(#{mode => redirect, location => TargetUrl}),
        Auth = fun() ->
            [{<<"authorization">>, <<"Bearer redirect-secret">>}]
        end,
        try
            ?assertEqual(
               {error, {redirect_rejected, 302}},
               adk_mcp_client:connect(
                 <<"streamable_http">>, RedirectUrl,
                 #{allow_http_loopback => true, auth_fun => Auth})),
            receive
                {mcp_security_fixture_request, RedirectRef, <<"initialize">>,
                 _Host, <<"Bearer redirect-secret">>, undefined} -> ok
            after 1000 -> ?assert(false)
            end,
            assert_no_security_fixture_request(TargetRef)
        after
            ok = cowboy:stop_listener(RedirectListener),
            ok = cowboy:stop_listener(TargetListener),
            flush_security_fixture_requests(RedirectRef),
            flush_security_fixture_requests(TargetRef)
        end
    end}.

mcp_client_uses_one_absolute_response_deadline_test_() ->
    {timeout, 10, fun() ->
        {Listener, Ref, Url} = start_security_fixture(
                                 #{mode => slow_chunks,
                                   chunk_delay_ms => 80}),
        try
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true,
                               request_timeout => 130}),
            try
                Started = erlang:monotonic_time(millisecond),
                ?assertEqual({error, timeout},
                             adk_mcp_client:list_tools(Client)),
                Elapsed = erlang:monotonic_time(millisecond) - Started,
                ?assert(Elapsed >= 100),
                ?assert(Elapsed < 300)
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = cowboy:stop_listener(Listener),
            flush_security_fixture_requests(Ref)
        end
    end}.

mcp_client_rejects_unbounded_callback_options_test() ->
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"stdio">>, <<"dummy">>, #{callback_max_heap_words => 1023})),
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"stdio">>, <<"dummy">>,
         #{callback_max_heap_words => 4194305})),
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"stdio">>, <<"dummy">>, #{max_resolved_addresses => 0})),
    ?assertEqual(
       {error, invalid_mcp_client_options},
       adk_mcp_client:connect(
         <<"stdio">>, <<"dummy">>, #{max_resolved_addresses => 257})).

mcp_client_resolver_callbacks_are_isolated_test_() ->
    [{"resolver callback " ++ atom_to_list(Failure),
      fun() -> assert_client_resolver_failure(Failure) end}
     || Failure <- [timeout, crash, heap_exhaustion, oversized]].

mcp_client_auth_callbacks_are_isolated_test_() ->
    [{"client auth callback " ++ atom_to_list(Failure),
      fun() -> assert_client_auth_failure(Failure) end}
     || Failure <- [timeout, crash, heap_exhaustion, oversized]].

mcp_client_callback_lifecycle_test_() ->
    [{"queued post-deadline auth result is rejected",
      fun client_rejects_queued_post_deadline_auth_result/0},
     {"auth callback dies with MCP client owner",
      fun client_auth_callback_dies_with_owner/0}].

mcp_http_callback_guard_lifecycle_test_() ->
    [{"queued post-deadline HTTP auth result is rejected",
      fun http_guard_rejects_queued_post_deadline_result/0},
     {"HTTP auth callback dies with request owner",
      fun http_guard_callback_dies_with_owner/0}].

mcp_stdio_request_timeout_test_() ->
    {timeout, 5, fun() ->
        Fixture = filename:absname("test/mcp_stdio_timeout_fixture.sh"),
        Command = unicode:characters_to_binary(["sh ", Fixture]),
        %% Stdio initialization must use its distinct startup budget. The
        %% fixture then blocks the list request for one second, so the shorter
        %% operation budget deterministically exercises request timeout.
        {ok, Client} = adk_mcp_client:connect(
                         <<"stdio">>, Command,
                         #{initialize_timeout => 2000,
                           request_timeout => 250}),
        try
            ?assertEqual({error, timeout}, adk_mcp_client:list_tools(Client)),
            ?assert(is_process_alive(Client))
        after
            ok = adk_mcp_client:close(Client)
        end
    end}.

streamable_http_round_trip_test_() ->
    {timeout, 20, fun streamable_http_round_trip/0}.

streamable_http_does_not_replay_tool_after_session_loss_test_() ->
    {timeout, 20, fun streamable_http_does_not_replay_tool_after_session_loss/0}.

streamable_http_does_not_replay_tool_after_session_loss() ->
    TestPid = self(),
    Tool = #{schema =>
                 #{<<"name">> => <<"side_effect">>,
                   <<"description">> => <<"Count executions">>,
                   <<"inputSchema">> => #{<<"type">> => <<"object">>}},
             execute => fun(_Args, _Context) ->
                 TestPid ! side_effect_executed,
                 {ok, <<"done">>}
             end},
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, tools => [Tool]}),
    try
        {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
        {ok, Client} = adk_mcp_client:connect(
                         <<"streamable_http">>, Url,
                         #{allow_http_loopback => true}),
        try
            OldSession = maps:get(session_id, sys:get_state(Client)),
            ok = adk_mcp_server:delete_session(
                   Server, OldSession, <<"2025-11-25">>),
            ?assertEqual(
               {error, {mcp_session_lost, request_not_replayed}},
               adk_mcp_client:execute_tool(
                 Client, <<"side_effect">>, #{})),
            receive side_effect_executed -> ?assert(false)
            after 0 -> ok
            end,
            ?assertNotEqual(
               OldSession, maps:get(session_id, sys:get_state(Client))),
            {ok, _Result} = adk_mcp_client:execute_tool(
                              Client, <<"side_effect">>, #{}),
            receive side_effect_executed -> ok
            after 1000 -> ?assert(false)
            end,
            receive side_effect_executed -> ?assert(false)
            after 0 -> ok
            end
        after
            ok = adk_mcp_client:close(Client)
        end
    after
        ok = adk_mcp_server:stop(Server)
    end.

streamable_http_round_trip() ->
    Token = <<"fixture-token-at-least-16-bytes">>,
    Resource = #{uri => <<"memo://readme">>,
                 name => <<"readme">>,
                 mime_type => <<"text/plain">>,
                 read => fun() -> {ok, <<"OTP-native MCP">>} end},
    Prompt = #{name => <<"review">>,
               description => <<"Review a topic">>,
               arguments => [#{<<"name">> => <<"topic">>,
                               <<"required">> => true}],
               get => fun(#{<<"topic">> := Topic}) ->
                   {ok, #{<<"description">> => <<"Fixture prompt">>,
                          <<"messages">> =>
                              [#{<<"role">> => <<"user">>,
                                 <<"content">> =>
                                     #{<<"type">> => <<"text">>,
                                       <<"text">> => <<"Review ", Topic/binary>>}}]}}
               end},
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, auth_token => Token,
                       tools => [adk_mcp_fixture_tool],
                       resources => [Resource], prompts => [Prompt]}),
    try
        {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
        Auth = fun() ->
            [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
        end,
        {ok, Client} = adk_mcp_client:connect(
                         <<"streamable_http">>, Url,
                         #{auth_fun => Auth, request_timeout => 5000,
                           allow_http_loopback => true}),
        try
            assert_status_redacted(Client, Token),
            assert_status_redacted(Server, Token),
            assert_status_redacted(
              Server, maps:get(session_id, sys:get_state(Client))),
            {ok, Info} = adk_mcp_client:server_info(Client),
            ?assertEqual(<<"2025-11-25">>,
                         maps:get(<<"protocolVersion">>, Info)),
            {ok, [Tool]} = adk_mcp_client:list_tools(Client),
            ?assertEqual(<<"echo">>, maps:get(<<"name">>, Tool)),
            ?assert(maps:is_key(<<"inputSchema">>, Tool)),
            [ProviderSchema] = adk_mcp_client:schemas(Client),
            ?assert(maps:is_key(<<"parameters">>, ProviderSchema)),
            {ok, Resolved} = adk_mcp_client:resolved_call(
                               Client, <<"echo">>,
                               #{<<"text">> => <<"resolved">>},
                               #{secret_ref => should_not_cross_transport}),
            {ok, #{<<"structuredContent">> :=
                       #{<<"echo">> := <<"resolved">>}}} =
                (maps:get(execute, Resolved))(),
            ?assertEqual({error, unknown_tool},
                         adk_mcp_client:resolved_call(
                           Client, <<"missing">>, #{}, #{})),
            {ok, ToolResult} = adk_mcp_client:execute_tool(
                                 Client, <<"echo">>,
                                 #{<<"text">> => <<"hello">>}),
            ?assertEqual(#{<<"echo">> => <<"hello">>},
                         maps:get(<<"structuredContent">>, ToolResult)),
            {ok, [ListedResource]} = adk_mcp_client:list_resources(Client),
            ?assertEqual(<<"memo://readme">>,
                         maps:get(<<"uri">>, ListedResource)),
            {ok, #{<<"contents">> := [Content]}} =
                adk_mcp_client:read_resource(Client, <<"memo://readme">>),
            ?assertEqual(<<"OTP-native MCP">>, maps:get(<<"text">>, Content)),
            {ok, [ListedPrompt]} = adk_mcp_client:list_prompts(Client),
            ?assertEqual(<<"review">>, maps:get(<<"name">>, ListedPrompt)),
            {ok, #{<<"messages">> := [_]}} = adk_mcp_client:get_prompt(
                                                    Client, <<"review">>,
                                                    #{<<"topic">> => <<"OTP">>}),
            OldSession = maps:get(session_id, sys:get_state(Client)),
            ok = adk_mcp_server:delete_session(
                   Server, OldSession, <<"2025-11-25">>),
            %% MCP requires a client receiving 404 for a session to create a
            %% new session. The original operation is retried exactly once.
            {ok, [_]} = adk_mcp_client:list_tools(Client),
            ?assertNotEqual(OldSession,
                            maps:get(session_id, sys:get_state(Client)))
        after
            ok = adk_mcp_client:close(Client)
        end
    after
        ok = adk_mcp_server:stop(Server)
    end.

streamable_http_rejects_bad_auth_test_() ->
    {timeout, 10, fun() ->
        Token = <<"fixture-token-at-least-16-bytes">>,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, auth_token => Token,
                           tools => [adk_mcp_fixture_tool]}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            Auth = fun() ->
                [{<<"authorization">>, <<"Bearer definitely-wrong">>}]
            end,
            ?assertEqual({error, {http_status, 401}},
                         adk_mcp_client:connect(<<"streamable_http">>, Url,
                                                #{auth_fun => Auth,
                                                  allow_http_loopback => true}))
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

streamable_http_auth_hook_test_() ->
    {timeout, 10, fun() ->
        TestPid = self(),
        AuthRef = make_ref(),
        Hook = fun(Meta) ->
            TestPid ! {mcp_auth_meta, AuthRef,
                       maps:without([authorization], Meta)},
            maps:get(authorization, Meta, undefined) =:= <<"Bearer hook-token">>
        end,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, auth_fun => Hook,
                           tools => [adk_mcp_fixture_tool]}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            ClientAuth = fun() ->
                [{<<"authorization">>, <<"Bearer hook-token">>}]
            end,
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{auth_fun => ClientAuth,
                               allow_http_loopback => true}),
            try
                receive
                    {mcp_auth_meta, AuthRef,
                     #{method := <<"POST">>, endpoint := <<"/mcp">>,
                       peer := {_Ip, _Port}}} ->
                        ok
                after 1000 -> ?assert(false)
                end
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = adk_mcp_server:stop(Server),
            flush_mcp_auth_meta(AuthRef)
        end
    end}.

mcp_server_rejects_unbounded_callback_policy_test() ->
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>, #{callback_timeout => 0})),
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>, #{callback_timeout => 30001})),
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>, #{callback_max_heap_words => 1023})),
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>,
         #{callback_max_heap_words => 4194305})),
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>, #{max_response_bytes => 255})).

streamable_http_server_callbacks_are_isolated_test_() ->
    [{atom_to_list(Kind) ++ " callback " ++ atom_to_list(Failure),
      fun() ->
          {ok, _} = application:ensure_all_started(gun),
          assert_server_callback_failure(Kind, Failure)
      end}
     || Kind <- [authentication, authorization],
        Failure <- [timeout, crash, heap_exhaustion]].

streamable_http_registered_callbacks_are_isolated_test_() ->
    [{atom_to_list(Kind) ++ " operation callback " ++ atom_to_list(Failure),
      fun() ->
          {ok, _} = application:ensure_all_started(gun),
          assert_registered_callback_failure(Kind, Failure)
      end}
     || Kind <- [tool, resource, prompt],
        Failure <- [timeout, crash, heap_exhaustion, oversized]].

streamable_http_registered_callback_lifecycle_test_() ->
    [{"queued post-deadline operation result is rejected",
      fun server_rejects_post_deadline_operation_result/0},
     {"operation callback dies with MCP server owner",
      fun server_callback_dies_with_owner/0}].

streamable_http_negotiates_latest_for_unknown_version_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(gun),
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>, #{port => 0}),
        try
            {ok, #{port := Port, path := Path}} =
                adk_mcp_server:endpoint(Server),
            {ok, Conn} = gun:open("127.0.0.1", Port),
            {ok, _} = gun:await_up(Conn, 3000),
            try
                Init = mcp_initialize(1, <<"2099-01-01">>),
                {200, Headers, Body} = mcp_raw_post(Conn, Path, [], Init),
                ?assert(is_binary(mcp_header(<<"mcp-session-id">>, Headers))),
                Response = jsx:decode(Body, [return_maps]),
                Result = maps:get(<<"result">>, Response),
                ?assertEqual(<<"2025-11-25">>,
                             maps:get(<<"protocolVersion">>, Result))
            after
                gun:close(Conn)
            end
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

streamable_http_session_is_principal_bound_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(gun),
        Hook = fun(#{authorization := <<"Bearer alice">>}) ->
                       {ok, <<"alice">>};
                  (#{authorization := <<"Bearer bob">>}) ->
                       {ok, <<"bob">>};
                  (_) -> {error, unauthenticated}
               end,
        Authorize = fun(#{principal_id := <<"alice">>},
                        <<"tools/list">>, #{kind := tools}) ->
                            {error, insufficient_scope};
                       (_Identity, _Operation, _Resource) -> ok
                    end,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, auth_fun => Hook,
                           authorization_fun => Authorize,
                           tools => [adk_mcp_fixture_tool]}),
        try
            {ok, #{port := Port, path := Path}} =
                adk_mcp_server:endpoint(Server),
            {ok, Conn} = gun:open("127.0.0.1", Port),
            {ok, _} = gun:await_up(Conn, 3000),
            try
                Alice = [{<<"authorization">>, <<"Bearer alice">>}],
                Bob = [{<<"authorization">>, <<"Bearer bob">>}],
                {200, InitHeaders, _} =
                    mcp_raw_post(Conn, Path, Alice,
                                 mcp_initialize(1, <<"2025-11-25">>)),
                Session = mcp_header(<<"mcp-session-id">>, InitHeaders),
                SessionHeaders =
                    [{<<"mcp-session-id">>, Session},
                     {<<"mcp-protocol-version">>, <<"2025-11-25">>}],
                Initialized = #{<<"jsonrpc">> => <<"2.0">>,
                                <<"method">> =>
                                    <<"notifications/initialized">>},
                {202, _, <<>>} = mcp_raw_post(
                                   Conn, Path, Alice ++ SessionHeaders,
                                   Initialized),
                List = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                         <<"method">> => <<"tools/list">>,
                         <<"params">> => #{}},
                %% Both a stolen POST and DELETE look like an unknown session.
                {404, _, <<>>} = mcp_raw_post(
                                   Conn, Path, Bob ++ SessionHeaders, List),
                {403, DeniedHeaders, <<>>} = mcp_raw_post(
                                               Conn, Path,
                                               Alice ++ SessionHeaders, List),
                ?assertNotEqual(
                   nomatch,
                   binary:match(
                     mcp_header(<<"www-authenticate">>, DeniedHeaders),
                     <<"insufficient_scope">>)),
                {404, _, <<>>} = mcp_raw_delete(
                                   Conn, Path, Bob ++ SessionHeaders),
                %% The failed theft attempt must not terminate Alice's session.
                {204, _, <<>>} = mcp_raw_delete(
                                   Conn, Path, Alice ++ SessionHeaders)
            after
                gun:close(Conn)
            end
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

streamable_http_oauth_metadata_and_challenges_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(gun),
        MetadataPath = <<"/.well-known/oauth-protected-resource/mcp">>,
        MetadataUrl =
            <<"https://mcp.example.com/.well-known/",
              "oauth-protected-resource/mcp">>,
        Hook = fun(#{authorization := <<"Bearer allowed">>}) ->
                       {ok, <<"allowed-user">>};
                  (#{authorization := <<"Bearer under-scoped">>}) ->
                       {error, insufficient_scope};
                  (#{authorization := <<"Bearer forbidden">>}) ->
                       {error, forbidden};
                  (_) -> {error, unauthenticated}
               end,
        OAuth = #{resource => <<"https://mcp.example.com/mcp">>,
                  authorization_servers => [<<"https://id.example.com">>],
                  scopes_supported => [<<"mcp:tools">>, <<"mcp:resources">>],
                  required_scopes => [<<"mcp:tools">>],
                  metadata_path => MetadataPath,
                  resource_metadata_url => MetadataUrl},
        Authorize = fun(_Identity, _Operation, _Resource) -> ok end,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, auth_fun => Hook,
                           authorization_fun => Authorize,
                           oauth_protected_resource => OAuth}),
        try
            {ok, #{port := Port, path := Path}} =
                adk_mcp_server:endpoint(Server),
            {ok, Conn} = gun:open("127.0.0.1", Port),
            {ok, _} = gun:await_up(Conn, 3000),
            try
                {200, MetadataHeaders, MetadataBody} =
                    mcp_raw_get(Conn, MetadataPath, []),
                ?assertEqual(<<"application/json">>,
                             mcp_header(<<"content-type">>, MetadataHeaders)),
                Metadata = jsx:decode(MetadataBody, [return_maps]),
                ?assertEqual(<<"https://mcp.example.com/mcp">>,
                             maps:get(<<"resource">>, Metadata)),
                ?assertEqual([<<"https://id.example.com">>],
                             maps:get(<<"authorization_servers">>, Metadata)),
                Init = mcp_initialize(1, <<"2025-11-25">>),
                {401, UnauthorizedHeaders, <<>>} =
                    mcp_raw_post(Conn, Path, [], Init),
                Unauthorized = mcp_header(
                                 <<"www-authenticate">>,
                                 UnauthorizedHeaders),
                ?assertNotEqual(nomatch,
                                binary:match(Unauthorized, MetadataUrl)),
                ?assertNotEqual(nomatch,
                                binary:match(Unauthorized,
                                             <<"scope=\"mcp:tools\"">>)),
                {403, ForbiddenHeaders, <<>>} =
                    mcp_raw_post(
                      Conn, Path,
                      [{<<"authorization">>, <<"Bearer under-scoped">>}],
                      Init),
                Forbidden = mcp_header(<<"www-authenticate">>,
                                       ForbiddenHeaders),
                ?assertNotEqual(
                   nomatch,
                   binary:match(Forbidden,
                                <<"error=\"insufficient_scope\"">>)),
                ?assertNotEqual(nomatch,
                                binary:match(Forbidden, MetadataUrl)),
                {403, GenericForbiddenHeaders, <<>>} =
                    mcp_raw_post(
                      Conn, Path,
                      [{<<"authorization">>, <<"Bearer forbidden">>}],
                      Init),
                GenericForbidden = mcp_header(
                                     <<"www-authenticate">>,
                                     GenericForbiddenHeaders),
                ?assertEqual(nomatch,
                             binary:match(GenericForbidden,
                                          <<"insufficient_scope">>)),
                ?assertNotEqual(nomatch,
                                binary:match(GenericForbidden, MetadataUrl))
            after
                gun:close(Conn)
            end
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

flush_mcp_auth_meta(AuthRef) ->
    receive
        {mcp_auth_meta, AuthRef, _Meta} ->
            flush_mcp_auth_meta(AuthRef)
    after 0 ->
        ok
    end.

streamable_http_client_accepts_sse_post_response_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(cowboy),
        Listener = {mcp_sse_fixture, make_ref()},
        Dispatch = cowboy_router:compile(
                     [{'_', [{"/mcp", adk_mcp_sse_fixture_handler, #{}}]}]),
        {ok, _} = cowboy:start_clear(
                    Listener, #{socket_opts => [{ip, {127, 0, 0, 1}},
                                                 {port, 0}]},
                    #{env => #{dispatch => Dispatch}}),
        try
            Port = ranch:get_port(Listener),
            Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary,
                    "/mcp">>,
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true}),
            try
                {ok, [Tool]} = adk_mcp_client:list_tools(Client),
                ?assertEqual(<<"sse_tool">>, maps:get(<<"name">>, Tool))
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = cowboy:stop_listener(Listener)
        end
    end}.

mcp_server_explicit_unsupported_test() ->
    ?assertEqual(
       {error, {unsupported_transport, sse_deprecated_use_streamable_http}},
       adk_mcp_server:start(<<"sse">>, [])).

mcp_server_rejects_unauthenticated_non_loopback_test() ->
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(<<"streamable_http">>,
                            #{ip => {0, 0, 0, 0}, port => 0})).

mcp_server_requires_explicit_non_loopback_opt_in_test() ->
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>,
         #{ip => {0, 0, 0, 0}, port => 0,
           auth_token => <<"valid-token-at-least-16-bytes">>})).

mcp_server_rejects_authenticated_public_cleartext_listener_test() ->
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>,
         #{ip => {0, 0, 0, 0}, port => 0,
           auth_token => <<"valid-token-at-least-16-bytes">>,
           allow_non_loopback => true})).

mcp_server_rejects_invalid_direct_tls_config_test() ->
    ?assertEqual(
       {error, invalid_mcp_server_config},
       adk_mcp_server:start(
         <<"streamable_http">>,
         #{ip => {0, 0, 0, 0}, port => 0,
           auth_token => <<"valid-token-at-least-16-bytes">>,
           allow_non_loopback => true,
           tls_options => []})).

mcp_server_allows_explicit_trusted_tls_proxy_boundary_test_() ->
    {timeout, 10, fun() ->
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{ip => {0, 0, 0, 0}, port => 0,
                           auth_token =>
                               <<"valid-token-at-least-16-bytes">>,
                           allow_non_loopback => true,
                           trusted_tls_proxy => true}),
        try
            {ok, #{scheme := <<"http">>, port := Port}} =
                adk_mcp_server:endpoint(Server),
            ?assert(Port > 0)
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

mcp_server_direct_tls_public_boundary_round_trip_test_() ->
    {timeout, 20, fun() ->
        CertFile = filename:absname("test/fixtures/mcp_test_cert.pem"),
        KeyFile = filename:absname("test/fixtures/mcp_test_key.pem"),
        CaFile = filename:absname("test/fixtures/mcp_test_ca.pem"),
        Token = <<"valid-token-at-least-16-bytes">>,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{ip => {0, 0, 0, 0}, port => 0,
                           auth_token => Token,
                           allow_non_loopback => true,
                           tls_options => [{certfile, CertFile},
                                           {keyfile, KeyFile}]}),
        try
            {ok, #{scheme := <<"https">>, port := Port}} =
                adk_mcp_server:endpoint(Server),
            Url = <<"https://127.0.0.1:",
                    (integer_to_binary(Port))/binary, "/mcp">>,
            Auth = fun() ->
                [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
            end,
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{auth_fun => Auth,
                               allowed_private_hosts => [<<"127.0.0.1">>],
                               tls_opts => [{cacertfile, CaFile}]}),
            try
                ?assertMatch({ok, #{<<"protocolVersion">> := <<"2025-11-25">>}},
                             adk_mcp_client:server_info(Client))
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

start_security_fixture(ExtraState) ->
    {ok, _} = application:ensure_all_started(cowboy),
    Listener = {mcp_security_fixture, make_ref()},
    Ref = make_ref(),
    State = maps:merge(#{parent => self(), ref => Ref}, ExtraState),
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/mcp",
                           adk_mcp_client_security_fixture_handler,
                           State}]}]),
    {ok, _} = cowboy:start_clear(
                Listener,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, 0}]},
                #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(Listener),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary,
            "/mcp">>,
    {Listener, Ref, Url}.

assert_no_security_fixture_request(Ref) ->
    receive
        {mcp_security_fixture_request, Ref, _Method, _Host, _Auth, _Proxy} ->
            ?assert(false)
    after 100 -> ok
    end.

flush_security_fixture_requests(Ref) ->
    receive
        {mcp_security_fixture_request, Ref, _Method, _Host, _Auth, _Proxy} ->
            flush_security_fixture_requests(Ref)
    after 0 -> ok
    end.

wait_for_port_closed(_Client, 0) -> {error, fixture_did_not_exit};
wait_for_port_closed(Client, Attempts) ->
    case maps:get(port_closed, sys:get_state(Client), false) of
        true -> ok;
        false -> timer:sleep(10), wait_for_port_closed(Client, Attempts - 1)
    end.

assert_status_redacted(Pid, Secret) ->
    Rendered = unicode:characters_to_binary(
                 io_lib:format("~p", [sys:get_status(Pid)])),
    ?assertEqual(nomatch, binary:match(Rendered, Secret)).

assert_server_callback_failure(Kind, Failure) ->
    TestPid = self(),
    CallbackRef = make_ref(),
    Secret = <<"Bearer callback-secret-must-not-leak">>,
    Invoke = fun() ->
        adversarial_server_callback(Failure, TestPid, CallbackRef, Secret)
    end,
    KindConfig = case Kind of
        authentication -> #{auth_fun => fun(_Meta) -> Invoke() end};
        authorization ->
            #{authorization_fun =>
                  fun(_AuthContext, _Operation, _Resource) -> Invoke() end}
    end,
    Config = maps:merge(
               #{port => 0, callback_timeout => 40,
                 callback_max_heap_words => 16384}, KindConfig),
    {ok, Server} = adk_mcp_server:start(<<"streamable_http">>, Config),
    try
        {ok, #{port := Port, path := Path}} =
            adk_mcp_server:endpoint(Server),
        {ok, Conn} = gun:open("127.0.0.1", Port),
        {ok, _} = gun:await_up(Conn, 3000),
        try
            Started = erlang:monotonic_time(millisecond),
            {Status, Headers, Body} =
                mcp_raw_post(
                  Conn, Path, [{<<"authorization">>, Secret}],
                  mcp_initialize(1, <<"2025-11-25">>)),
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            Expected = case Kind of
                authentication -> 401;
                authorization -> 403
            end,
            ?assertEqual(Expected, Status),
            ?assertEqual(<<>>, Body),
            ?assert(Elapsed < 1000),
            RenderedResponse = unicode:characters_to_binary(
                                 io_lib:format("~p", [{Headers, Body}])),
            ?assertEqual(nomatch,
                         binary:match(RenderedResponse, Secret)),
            CallbackPid = receive
                {adversarial_mcp_callback, CallbackRef, Pid} -> Pid
            after 1000 ->
                ?assert(false)
            end,
            ?assertEqual(ok, wait_process_dead(CallbackPid, 100)),
            assert_status_redacted(Server, Secret)
        after
            gun:close(Conn)
        end
    after
        ok = adk_mcp_server:stop(Server),
        flush_adversarial_callbacks(CallbackRef)
    end.

assert_client_resolver_failure(Failure) ->
    TestPid = self(),
    CallbackRef = make_ref(),
    Resolver = fun(_Host) ->
        adversarial_client_callback(Failure, resolver, TestPid, CallbackRef)
    end,
    Expected = case Failure of
        timeout -> {error, mcp_connect_timeout};
        _ -> {error, mcp_dns_resolution_failed}
    end,
    Started = erlang:monotonic_time(millisecond),
    Result = adk_mcp_client:connect(
               <<"streamable_http">>, <<"https://resolver.invalid/mcp">>,
               #{resolver_fun => Resolver, connect_timeout => 40,
                 callback_max_heap_words => 16384,
                 max_resolved_addresses => 2}),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertEqual(Expected, Result),
    ?assert(Elapsed < 1000),
    CallbackPid = receive
        {adversarial_mcp_client_callback, CallbackRef, Pid} -> Pid
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual(ok, wait_process_dead(CallbackPid, 100)).

assert_client_auth_failure(Failure) ->
    {Listener, FixtureRef, Url} = start_security_fixture(#{}),
    TestPid = self(),
    CallbackRef = make_ref(),
    Auth = fun() ->
        adversarial_client_callback(Failure, auth, TestPid, CallbackRef)
    end,
    Expected = case Failure of
        timeout -> {error, timeout};
        crash -> {error, auth_provider_failed};
        heap_exhaustion -> {error, auth_provider_failed};
        oversized -> {error, invalid_auth_headers}
    end,
    try
        Started = erlang:monotonic_time(millisecond),
        Result = adk_mcp_client:connect(
                   <<"streamable_http">>, Url,
                   #{allow_http_loopback => true, auth_fun => Auth,
                     initialize_timeout => 40,
                     callback_max_heap_words => 16384}),
        Elapsed = erlang:monotonic_time(millisecond) - Started,
        ?assertEqual(Expected, Result),
        ?assert(Elapsed < 1000),
        CallbackPid = receive
            {adversarial_mcp_client_callback, CallbackRef, Pid} -> Pid
        after 1000 ->
            ?assert(false)
        end,
        ?assertEqual(ok, wait_process_dead(CallbackPid, 100)),
        assert_no_security_fixture_request(FixtureRef)
    after
        ok = cowboy:stop_listener(Listener),
        flush_security_fixture_requests(FixtureRef),
        flush_adversarial_client_callbacks(CallbackRef)
    end.

adversarial_client_callback(Failure, Kind, TestPid, Ref) ->
    TestPid ! {adversarial_mcp_client_callback, Ref, self()},
    case Failure of
        timeout -> receive stop -> invalid end;
        crash -> erlang:error(client_callback_failed);
        heap_exhaustion -> grow_callback_heap(1000000, []);
        oversized when Kind =:= resolver ->
            [{127, 0, 0, 1}, {127, 0, 0, 2}, {127, 0, 0, 3}];
        oversized when Kind =:= auth ->
            [{<<"authorization">>, binary:copy(<<"x">>, 8193)}]
    end.

flush_adversarial_client_callbacks(Ref) ->
    receive
        {adversarial_mcp_client_callback, Ref, _Pid} ->
            flush_adversarial_client_callbacks(Ref)
    after 0 -> ok
    end.

client_rejects_queued_post_deadline_auth_result() ->
    {Listener, FixtureRef, Url} = start_security_fixture(#{}),
    TestPid = self(),
    Ref = make_ref(),
    Counter = atomics:new(1, []),
    Auth = staged_client_auth(Counter, late, TestPid, Ref),
    try
        {ok, Client} = adk_mcp_client:connect(
                         <<"streamable_http">>, Url,
                         #{allow_http_loopback => true, auth_fun => Auth,
                           request_timeout => 40,
                           callback_max_heap_words => 16384}),
        try
            flush_security_fixture_requests(FixtureRef),
            Parent = self(),
            _Caller = spawn(fun() ->
                Parent ! {late_auth_result,
                          adk_mcp_client:list_tools(Client)}
            end),
            Callback = receive
                {staged_mcp_auth, Ref, Pid} -> Pid
            after 1000 -> error(auth_callback_not_started)
            end,
            true = erlang:suspend_process(Client),
            try timer:sleep(100)
            after true = erlang:resume_process(Client)
            end,
            receive
                {late_auth_result, Result} ->
                    ?assertEqual({error, timeout}, Result)
            after 1000 -> error(late_auth_result_missing)
            end,
            ?assertEqual(ok, wait_process_dead(Callback, 100)),
            assert_no_security_fixture_request(FixtureRef)
        after
            ok = adk_mcp_client:close(Client)
        end
    after
        ok = cowboy:stop_listener(Listener),
        flush_security_fixture_requests(FixtureRef)
    end.

client_auth_callback_dies_with_owner() ->
    {Listener, FixtureRef, Url} = start_security_fixture(#{}),
    TestPid = self(),
    Ref = make_ref(),
    Counter = atomics:new(1, []),
    Auth = staged_client_auth(Counter, block, TestPid, Ref),
    try
        {ok, Client} = adk_mcp_client:connect(
                         <<"streamable_http">>, Url,
                         #{allow_http_loopback => true, auth_fun => Auth,
                           request_timeout => 5000,
                           callback_max_heap_words => 16384}),
        flush_security_fixture_requests(FixtureRef),
        Parent = self(),
        _Caller = spawn(fun() ->
            Result = catch adk_mcp_client:list_tools(Client),
            Parent ! {owner_auth_result, Result}
        end),
        Callback = receive
            {staged_mcp_auth, Ref, Pid} -> Pid
        after 1000 -> error(auth_callback_not_started)
        end,
        Monitor = erlang:monitor(process, Client),
        exit(Client, kill),
        receive {'DOWN', Monitor, process, Client, _} -> ok
        after 1000 -> error(mcp_client_did_not_die)
        end,
        ?assertEqual(ok, wait_process_dead(Callback, 100)),
        receive {owner_auth_result, _} -> ok after 1000 -> ok end,
        assert_no_security_fixture_request(FixtureRef)
    after
        ok = cowboy:stop_listener(Listener),
        flush_security_fixture_requests(FixtureRef)
    end.

staged_client_auth(Counter, Mode, TestPid, Ref) ->
    fun() ->
        case atomics:add_get(Counter, 1, 1) of
            Count when Count =< 2 ->
                [{<<"authorization">>, <<"Bearer staged">>}];
            3 ->
                TestPid ! {staged_mcp_auth, Ref, self()},
                case Mode of
                    late ->
                        timer:sleep(70),
                        [{<<"authorization">>, <<"Bearer staged">>}];
                    block -> receive stop -> [] end
                end;
            _ -> [{<<"authorization">>, <<"Bearer staged">>}]
        end
    end.

http_guard_rejects_queued_post_deadline_result() ->
    Parent = self(),
    Ref = make_ref(),
    Callback = fun() ->
        Parent ! {http_guard_started, Ref, self()},
        timer:sleep(70),
        ok
    end,
    Owner = spawn(fun() ->
        Result = adk_auth_callback_guard:run(
                   Callback, fun(Value) -> Value end,
                   40, 16384, 4096),
        Parent ! {http_guard_result, Ref, Result}
    end),
    receive {http_guard_started, Ref, _CallbackPid} -> ok
    after 1000 -> error(http_guard_not_started)
    end,
    true = erlang:suspend_process(Owner),
    try timer:sleep(100)
    after true = erlang:resume_process(Owner)
    end,
    receive
        {http_guard_result, Ref, Result} -> ?assertEqual(timeout, Result)
    after 1000 -> error(http_guard_result_missing)
    end.

http_guard_callback_dies_with_owner() ->
    Parent = self(),
    Ref = make_ref(),
    Callback = fun() ->
        Parent ! {http_guard_owner_started, Ref, self()},
        receive stop -> ok end
    end,
    Owner = spawn(fun() ->
        _ = adk_auth_callback_guard:run(
              Callback, fun(Value) -> Value end,
              5000, 16384, 4096)
    end),
    CallbackPid = receive
        {http_guard_owner_started, Ref, Pid} -> Pid
    after 1000 -> error(http_guard_not_started)
    end,
    exit(Owner, kill),
    ?assertEqual(ok, wait_process_dead(CallbackPid, 100)).

assert_registered_callback_failure(Kind, Failure) ->
    TestPid = self(),
    CallbackRef = make_ref(),
    Secret = <<"registered-callback-secret-must-not-leak">>,
    Callback = fun() ->
        Value = adversarial_registered_callback(
                  Failure, TestPid, CallbackRef, Secret),
        registered_callback_result(Kind, Value)
    end,
    {RegistryKey, RegistryValue, Method, Params} =
        registered_callback_fixture(Kind, Callback),
    Config = #{port => 0, request_timeout => 40,
               callback_max_heap_words => 16384,
               max_response_bytes => 1024,
               RegistryKey => [RegistryValue]},
    {ok, Server} = adk_mcp_server:start(<<"streamable_http">>, Config),
    try
        {ok, #{port := Port, path := Path}} =
            adk_mcp_server:endpoint(Server),
        {ok, Conn} = gun:open("127.0.0.1", Port),
        {ok, _} = gun:await_up(Conn, 3000),
        try
            {Session, SessionHeaders} = initialize_raw_mcp(Conn, Path),
            ?assert(is_binary(Session)),
            Started = erlang:monotonic_time(millisecond),
            {200, _, Body} = mcp_raw_post(
                               Conn, Path, SessionHeaders,
                               #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                                 <<"method">> => Method,
                                 <<"params">> => Params}),
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            ?assert(Elapsed < 1000),
            ?assert(byte_size(Body) =< 1024),
            Response = jsx:decode(Body, [return_maps]),
            ?assert(maps:is_key(<<"result">>, Response) orelse
                    maps:is_key(<<"error">>, Response)),
            case Failure of
                oversized ->
                    Error = maps:get(<<"error">>, Response),
                    ?assertEqual(<<"Response exceeds limit">>,
                                 maps:get(<<"message">>, Error));
                _ -> ok
            end,
            Rendered = unicode:characters_to_binary(
                         io_lib:format("~p", [Response])),
            ?assertEqual(nomatch, binary:match(Rendered, Secret)),
            CallbackPid = receive
                {adversarial_registered_callback, CallbackRef, Pid} -> Pid
            after 1000 ->
                ?assert(false)
            end,
            ?assertEqual(ok, wait_process_dead(CallbackPid, 100)),
            ?assert(is_process_alive(Server)),
            {200, _, ListBody} = mcp_raw_post(
                                   Conn, Path, SessionHeaders,
                                   #{<<"jsonrpc">> => <<"2.0">>,
                                     <<"id">> => 3,
                                     <<"method">> => <<"tools/list">>,
                                     <<"params">> => #{}}),
            ?assert(maps:is_key(
                     <<"result">>, jsx:decode(ListBody, [return_maps])))
        after
            gun:close(Conn)
        end
    after
        ok = adk_mcp_server:stop(Server),
        flush_adversarial_registered_callbacks(CallbackRef)
    end.

registered_callback_fixture(tool, Callback) ->
    Tool = #{schema =>
                 #{<<"name">> => <<"adversarial">>,
                   <<"inputSchema">> => #{<<"type">> => <<"object">>}},
             execute => fun(_Args, _Context) -> Callback() end},
    {tools, Tool, <<"tools/call">>,
     #{<<"name">> => <<"adversarial">>, <<"arguments">> => #{}}};
registered_callback_fixture(resource, Callback) ->
    Resource = #{uri => <<"test://adversarial">>, name => <<"adversarial">>,
                 read => fun() -> Callback() end},
    {resources, Resource, <<"resources/read">>,
     #{<<"uri">> => <<"test://adversarial">>}};
registered_callback_fixture(prompt, Callback) ->
    Prompt = #{name => <<"adversarial">>,
               get => fun(_Args) -> Callback() end},
    {prompts, Prompt, <<"prompts/get">>,
     #{<<"name">> => <<"adversarial">>, <<"arguments">> => #{}}}.

registered_callback_result(tool, Value) -> {ok, Value};
registered_callback_result(resource, Value) -> {ok, Value};
registered_callback_result(prompt, Value) ->
    {ok, [#{<<"role">> => <<"user">>,
            <<"content">> => #{<<"type">> => <<"text">>,
                                <<"text">> => Value}}]}.

adversarial_registered_callback(Failure, TestPid, Ref, Secret) ->
    TestPid ! {adversarial_registered_callback, Ref, self()},
    case Failure of
        timeout -> receive stop -> <<"stopped">> end;
        crash -> erlang:error({registered_callback_credential, Secret});
        heap_exhaustion -> grow_callback_heap(1000000, []);
        oversized -> binary:copy(<<"x">>, 4096)
    end.

initialize_raw_mcp(Conn, Path) ->
    {200, InitHeaders, _} = mcp_raw_post(
                              Conn, Path, [],
                              mcp_initialize(1, <<"2025-11-25">>)),
    Session = mcp_header(<<"mcp-session-id">>, InitHeaders),
    SessionHeaders =
        [{<<"mcp-session-id">>, Session},
         {<<"mcp-protocol-version">>, <<"2025-11-25">>}],
    {202, _, <<>>} = mcp_raw_post(
                       Conn, Path, SessionHeaders,
                       #{<<"jsonrpc">> => <<"2.0">>,
                         <<"method">> => <<"notifications/initialized">>}),
    {Session, SessionHeaders}.

flush_adversarial_registered_callbacks(Ref) ->
    receive
        {adversarial_registered_callback, Ref, _Pid} ->
            flush_adversarial_registered_callbacks(Ref)
    after 0 -> ok
    end.

server_rejects_post_deadline_operation_result() ->
    TestPid = self(),
    Ref = make_ref(),
    Tool = blocking_registered_tool(TestPid, Ref),
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, request_timeout => 5000,
                       callback_max_heap_words => 16384,
                       tools => [Tool]}),
    try
        {Session, Version} = initialize_direct_mcp(Server),
        Parent = self(),
        _Caller = spawn(fun() ->
            Result = adk_mcp_server:handle_http(
                       Server, Session, Version,
                       registered_tool_request(2), legacy, 7000),
            Parent ! {post_deadline_server_result, Ref, Result}
        end),
        Callback = receive
            {blocking_registered_tool, Ref, Pid} -> Pid
        after 1000 -> error(operation_callback_not_started)
        end,
        State = sys:get_state(Server),
        [{PendingRef, Pending}] = maps:to_list(maps:get(pending, State)),
        Deadline = maps:get(deadline, Pending),
        ForgedResponse = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                           <<"result">> => #{<<"accepted">> => true}},
        Server ! {mcp_worker_result, PendingRef, Deadline + 1,
                  ForgedResponse},
        receive
            {post_deadline_server_result, Ref,
             {json, 200, [], #{<<"error">> := Error}}} ->
                ?assertEqual(<<"Request timed out">>,
                             maps:get(<<"message">>, Error))
        after 1000 -> error(post_deadline_server_result_missing)
        end,
        ?assertEqual(ok, wait_process_dead(Callback, 100)),
        ?assert(is_process_alive(Server))
    after
        ok = adk_mcp_server:stop(Server)
    end.

server_callback_dies_with_owner() ->
    TestPid = self(),
    Ref = make_ref(),
    Tool = blocking_registered_tool(TestPid, Ref),
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, request_timeout => 5000,
                       callback_max_heap_words => 16384,
                       tools => [Tool]}),
    State0 = sys:get_state(Server),
    Listener = maps:get(listener, State0),
    {Session, Version} = initialize_direct_mcp(Server),
    Parent = self(),
    _Caller = spawn(fun() ->
        Result = catch adk_mcp_server:handle_http(
                         Server, Session, Version,
                         registered_tool_request(2), legacy, 7000),
        Parent ! {dead_server_call, Ref, Result}
    end),
    Callback = receive
        {blocking_registered_tool, Ref, Pid} -> Pid
    after 1000 -> error(operation_callback_not_started)
    end,
    Monitor = erlang:monitor(process, Server),
    exit(Server, kill),
    receive {'DOWN', Monitor, process, Server, _} -> ok
    after 1000 -> error(mcp_server_did_not_die)
    end,
    ?assertEqual(ok, wait_process_dead(Callback, 100)),
    receive {dead_server_call, Ref, _} -> ok after 1000 -> ok end,
    _ = catch cowboy:stop_listener(Listener),
    ok.

blocking_registered_tool(TestPid, Ref) ->
    #{schema => #{<<"name">> => <<"blocking">>,
                  <<"inputSchema">> => #{<<"type">> => <<"object">>}},
      execute => fun(_Args, _Context) ->
          TestPid ! {blocking_registered_tool, Ref, self()},
          receive stop -> {ok, <<"stopped">>} end
      end}.

registered_tool_request(Id) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"method">> => <<"tools/call">>,
      <<"params">> => #{<<"name">> => <<"blocking">>,
                         <<"arguments">> => #{}}}.

initialize_direct_mcp(Server) ->
    Version = <<"2025-11-25">>,
    {json, 200, Headers, _} = adk_mcp_server:handle_http(
                               Server, undefined, undefined,
                               mcp_initialize(1, Version), legacy, 1000),
    Session = mcp_header(<<"mcp-session-id">>, Headers),
    {accepted, []} = adk_mcp_server:handle_http(
                       Server, Session, Version,
                       #{<<"jsonrpc">> => <<"2.0">>,
                         <<"method">> => <<"notifications/initialized">>},
                       legacy, 1000),
    {Session, Version}.

adversarial_server_callback(timeout, TestPid, Ref, _Secret) ->
    TestPid ! {adversarial_mcp_callback, Ref, self()},
    receive stop -> true end;
adversarial_server_callback(crash, TestPid, Ref, Secret) ->
    TestPid ! {adversarial_mcp_callback, Ref, self()},
    erlang:error({callback_credential, Secret});
adversarial_server_callback(heap_exhaustion, TestPid, Ref, _Secret) ->
    TestPid ! {adversarial_mcp_callback, Ref, self()},
    grow_callback_heap(1000000, []).

grow_callback_heap(0, Acc) -> Acc =/= [];
grow_callback_heap(N, Acc) ->
    grow_callback_heap(N - 1, [{N, N, N, N} | Acc]).

wait_process_dead(_Pid, 0) -> {error, callback_worker_survived};
wait_process_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true -> timer:sleep(5), wait_process_dead(Pid, Attempts - 1)
    end.

flush_adversarial_callbacks(Ref) ->
    receive
        {adversarial_mcp_callback, Ref, _Pid} ->
            flush_adversarial_callbacks(Ref)
    after 0 ->
        ok
    end.

mcp_initialize(Id, Version) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"method">> => <<"initialize">>,
      <<"params">> => #{<<"protocolVersion">> => Version,
                         <<"capabilities">> => #{},
                         <<"clientInfo">> =>
                             #{<<"name">> => <<"eunit">>,
                               <<"version">> => <<"1">>}}}.

mcp_raw_post(Conn, Path, Headers, Message) ->
    Ref = gun:post(Conn, Path, mcp_common_headers() ++ Headers,
                   jsx:encode(Message)),
    mcp_await_response(Conn, Ref).

mcp_raw_delete(Conn, Path, Headers) ->
    Ref = gun:request(Conn, <<"DELETE">>, Path,
                      mcp_common_headers() ++ Headers, <<>>),
    mcp_await_response(Conn, Ref).

mcp_raw_get(Conn, Path, Headers) ->
    Ref = gun:get(Conn, Path, Headers),
    mcp_await_response(Conn, Ref).

mcp_await_response(Conn, Ref) ->
    case gun:await(Conn, Ref, 3000) of
        {response, fin, Status, Headers} -> {Status, Headers, <<>>};
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(Conn, Ref, 3000),
            {Status, Headers, Body}
    end.

mcp_common_headers() ->
    [{<<"accept">>, <<"application/json, text/event-stream">>},
     {<<"content-type">>, <<"application/json">>}].

mcp_header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.
