-module(adk_mcp_oauth_test).
-include_lib("eunit/include/eunit.hrl").

discovery_rfc9728_rfc8414_and_pkce_resource_test() ->
    Resource = <<"https://api.example/mcp">>,
    ResourceMetadata =
        #{<<"resource">> => Resource,
          <<"authorization_servers">> => [<<"https://id.example/tenant">>],
          <<"scopes_supported">> => [<<"mcp:tools">>]},
    AuthorizationMetadata =
        #{<<"issuer">> => <<"https://id.example/tenant">>,
          <<"authorization_endpoint">> =>
              <<"https://id.example/tenant/authorize">>,
          <<"token_endpoint">> => <<"https://id.example/tenant/token">>,
          <<"code_challenge_methods_supported">> => [<<"S256">>]},
    Parent = self(),
    Fetch = fun(Url, Request) ->
        Parent ! {fetch, Url, Request},
        Body = case binary:match(Url, <<"oauth-protected-resource">>) of
            nomatch -> jsx:encode(AuthorizationMetadata);
            _ -> jsx:encode(ResourceMetadata)
        end,
        {ok, 200, [{<<"content-type">>, <<"application/json">>}], Body}
    end,
    {ok, Discovery} = adk_mcp_oauth:discover(
                        Resource,
                        #{fetch_fun => Fetch,
                          allowed_authorization_servers =>
                              [<<"https://id.example">>]}),
    receive {fetch, <<"https://api.example/.well-known/",
                      "oauth-protected-resource/mcp">>, Request1} ->
        ?assertEqual(none, maps:get(credentials, Request1)),
        ?assertEqual(reject, maps:get(redirect, Request1))
    after 1000 -> ?assert(false)
    end,
    receive {fetch, <<"https://id.example/.well-known/",
                      "oauth-authorization-server/tenant">>, Request2} ->
        ?assertEqual(none, maps:get(credentials, Request2))
    after 1000 -> ?assert(false)
    end,
    Pkce = adk_mcp_oauth:pkce(),
    {ok, Authorization} = adk_mcp_oauth:authorization_request(
                            Discovery,
                            #{client_id => <<"client">>,
                              redirect_uri => <<"https://app.example/cb">>,
                              state => <<"opaque-state">>,
                              scopes => [<<"mcp:tools">>], pkce => Pkce}),
    Url = maps:get(url, Authorization),
    ?assertNotEqual(nomatch, binary:match(Url, <<"code_challenge_method=S256">>)),
    ?assertNotEqual(nomatch, binary:match(Url,
                                         <<"resource=https%3A%2F%2Fapi.example%2Fmcp">>)),
    {ok, TokenParams} = adk_mcp_oauth:token_parameters(
                          Discovery, <<"code">>,
                          <<"https://app.example/cb">>,
                          maps:get(verifier, Pkce)),
    ?assertEqual(Resource, maps:get(<<"resource">>, TokenParams)).

oidc_fallback_is_404_only_test() ->
    Resource = <<"https://same.example/mcp">>,
    ResourceDocument =
        #{<<"resource">> => Resource,
          <<"authorization_servers">> => [<<"https://same.example">>]},
    AuthorizationDocument =
        #{<<"issuer">> => <<"https://same.example">>,
          <<"authorization_endpoint">> => <<"https://same.example/auth">>,
          <<"token_endpoint">> => <<"https://same.example/token">>,
          <<"code_challenge_methods_supported">> => [<<"S256">>]},
    Fetch = fun(Url, _Request) ->
        case {binary:match(Url, <<"oauth-protected-resource">>),
              binary:match(Url, <<"oauth-authorization-server">>)} of
            {{_, _}, _} -> json(ResourceDocument);
            {nomatch, {_, _}} -> {ok, 404, [], <<>>};
            _ -> json(AuthorizationDocument)
        end
    end,
    {ok, Discovery} = adk_mcp_oauth:discover(Resource,
                                              #{fetch_fun => Fetch}),
    ?assertEqual(<<"https://same.example/.well-known/openid-configuration">>,
                 maps:get(authorization_metadata_url, Discovery)).

redirect_ssrf_and_cross_origin_metadata_are_rejected_test() ->
    Redirect = fun(_Url, _Request) ->
        {ok, 302, [{<<"location">>, <<"https://evil.example">>}], <<>>}
    end,
    ?assertEqual({error, {redirect_rejected, 302}},
                 adk_mcp_oauth:discover(<<"https://api.example/mcp">>,
                                        #{fetch_fun => Redirect})),
    ?assertEqual({error, invalid_mcp_oauth_options},
                 adk_mcp_oauth:discover(<<"https://127.0.0.1/mcp">>,
                                        #{fetch_fun => Redirect})),
    ?assertEqual({error, invalid_mcp_oauth_options},
                 adk_mcp_oauth:discover(<<"https://localhost/mcp">>,
                                        #{fetch_fun => Redirect})),
    Cross = fun(Url, _Request) ->
        case binary:match(Url, <<"oauth-protected-resource">>) of
            nomatch -> json(#{});
            _ -> json(#{<<"resource">> => <<"https://api.example/mcp">>,
                        <<"authorization_servers">> =>
                            [<<"https://metadata-attacker.example">>]})
        end
    end,
    ?assertEqual({error, mcp_authorization_server_not_allowed},
                 adk_mcp_oauth:discover(<<"https://api.example/mcp">>,
                                        #{fetch_fun => Cross})).

fetch_callback_deadline_and_size_are_enforced_test() ->
    Slow = fun(_Url, _Request) ->
        receive never -> ok after 1000 -> {error, late} end
    end,
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual({error, mcp_oauth_discovery_timeout},
                 adk_mcp_oauth:discover(
                   <<"https://api.example/mcp">>,
                   #{fetch_fun => Slow, timeout => 20})),
    ?assert(erlang:monotonic_time(millisecond) - Started < 500),
    Oversized = fun(_Url, _Request) ->
        {ok, 200, [{<<"content-type">>, <<"application/json">>}],
         binary:copy(<<"x">>, 1024)}
    end,
    ?assertEqual({error, mcp_oauth_document_too_large},
                 adk_mcp_oauth:discover(
                   <<"https://api.example/mcp">>,
                   #{fetch_fun => Oversized,
                     max_document_bytes => 64})).

fetch_callback_dies_with_discovery_owner_test() ->
    Parent = self(),
    Fetch = fun(_Url, _Request) ->
        Parent ! {oauth_fetch_worker, self()},
        receive never -> {error, impossible} end
    end,
    Caller = spawn(fun() ->
        _ = adk_mcp_oauth:discover(
              <<"https://api.example/mcp">>,
              #{fetch_fun => Fetch, timeout => 5000})
    end),
    Worker = receive {oauth_fetch_worker, Pid} -> Pid
    after 1000 -> error(fetch_worker_not_started)
    end,
    Monitor = erlang:monitor(process, Worker),
    exit(Caller, kill),
    receive {'DOWN', Monitor, process, Worker, killed} -> ok
    after 1000 -> ?assert(false)
    end.

json(Document) ->
    {ok, 200, [{<<"content-type">>, <<"application/json">>}],
     jsx:encode(Document)}.
