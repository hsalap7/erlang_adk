-module(adk_mcp_modern_runtime_test).
-include_lib("eunit/include/eunit.hrl").

modern_stateless_round_trip_and_catalog_replacement_test_() ->
    {timeout, 20, fun() ->
        Old = tool(<<"old">>),
        New = tool(<<"new">>),
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, tools => [Old]}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true,
                               protocol_version => <<"2026-07-28">>}),
            try
                {ok, Info} = adk_mcp_client:server_info(Client),
                ?assertEqual(<<"2026-07-28">>,
                             maps:get(<<"protocolVersion">>, Info)),
                ?assertNot(maps:is_key(session_id, sys:get_state(Client))),
                {ok, [OldSchema]} = adk_mcp_client:list_tools(Client),
                ?assertEqual(<<"old">>, maps:get(<<"name">>, OldSchema)),
                {ok, Before} = adk_mcp_server:catalog_info(Server),
                ?assertEqual({error, unknown_mcp_catalog_keys},
                             adk_mcp_server:replace_catalog(
                               Server, #{toolz => [New]})),
                ?assertEqual({ok, Before},
                             adk_mcp_server:catalog_info(Server)),
                {ok, Change} = adk_mcp_server:replace_catalog(
                                 Server, #{tools => [New]}),
                ?assertEqual(true,
                             maps:get(tools, maps:get(changed, Change))),
                {ok, After} = adk_mcp_server:catalog_info(Server),
                ?assertEqual(maps:get(generation, Before) + 1,
                             maps:get(generation, After)),
                {ok, [NewSchema]} = adk_mcp_client:list_tools(Client),
                ?assertEqual(<<"new">>, maps:get(<<"name">>, NewSchema)),
                {error, Unknown} = adk_mcp_client:execute_tool(
                                     Client, <<"old">>, #{}),
                ?assertEqual(-32602, maps:get(<<"code">>, Unknown)),
                {ok, Result} = adk_mcp_client:execute_tool(
                                 Client, <<"new">>, #{}),
                ?assertEqual(false, maps:get(<<"isError">>, Result))
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

negotiated_modern_completion_subscription_and_legacy_logging_test_() ->
    {timeout, 20, fun() ->
        Parent = self(),
        Handlers =
            #{<<"completion/complete">> =>
                  fun(Params, Context) ->
                      Parent ! {feature, completion, Context},
                      {ok, #{<<"completion">> =>
                                 #{<<"values">> =>
                                       [maps:get(<<"argument">>, Params)]}}}
                  end,
              <<"subscriptions/listen">> =>
                  fun(Params, Context) ->
                      Parent ! {feature, subscription, Context},
                      {ok, #{<<"subscriptionId">> => <<"sub-1">>,
                             <<"notifications">> =>
                                 maps:get(<<"notifications">>, Params)}}
                  end,
              <<"logging/setLevel">> =>
                  fun(Params, Context) ->
                      Parent ! {feature, logging, Context},
                      {ok, #{<<"level">> => maps:get(<<"level">>, Params)}}
                  end,
              <<"elicitation/create">> =>
                  fun(_Params, Context) ->
                      Parent ! {feature, elicitation, Context},
                      {input_required,
                       #{<<"confirm">> =>
                             #{<<"method">> => <<"elicitation/create">>,
                               <<"params">> =>
                                   #{<<"mode">> => <<"form">>,
                                     <<"message">> => <<"Continue?">>}}},
                       <<"opaque-state">>}
                  end,
              <<"roots/list">> =>
                  fun(_Params, Context) ->
                      Parent ! {feature, roots, Context},
                      {ok, #{<<"roots">> => []}}
                  end,
              <<"sampling/createMessage">> =>
                  fun(_Params, Context) ->
                      Parent ! {feature, sampling, Context},
                      {ok, #{<<"role">> => <<"assistant">>,
                             <<"content">> =>
                                 #{<<"type">> => <<"text">>,
                                   <<"text">> => <<"sample">>}}}
                  end},
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, method_handlers => Handlers}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            {ok, Modern} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true,
                               protocol_version => modern,
                               capabilities => #{<<"elicitation">> => #{}}}),
            try
                {ok, _} = adk_mcp_client:complete(
                            Modern, #{<<"type">> => <<"ref/prompt">>,
                                      <<"name">> => <<"p">>},
                            #{<<"name">> => <<"x">>,
                              <<"value">> => <<"v">>}),
                {ok, #{<<"subscriptionId">> := <<"sub-1">>}} =
                    adk_mcp_client:subscribe(
                      Modern, #{<<"tools">> => true}),
                receive {feature, completion, #{era := modern}} -> ok
                after 1000 -> ?assert(false)
                end,
                receive {feature, subscription, #{era := modern}} -> ok
                after 1000 -> ?assert(false)
                end,
                {ok, #{<<"resultType">> := <<"input_required">>,
                       <<"requestState">> := <<"opaque-state">>}} =
                    adk_mcp_client:elicit(
                      Modern, #{<<"mode">> => <<"form">>,
                                <<"message">> => <<"Continue?">>}),
                receive {feature, elicitation, #{era := modern}} -> ok
                after 1000 -> ?assert(false)
                end,
                ?assertEqual(
                   {error, {capability_not_negotiated, logging}},
                   adk_mcp_client:request(
                     Modern, <<"logging/setLevel">>,
                     #{<<"level">> => <<"info">>}))
            after ok = adk_mcp_client:close(Modern)
            end,
            {ok, Legacy} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true}),
            try
                {ok, #{<<"level">> := <<"debug">>}} =
                    adk_mcp_client:set_log_level(Legacy, <<"debug">>),
                {ok, #{<<"roots">> := []}} =
                    adk_mcp_client:list_roots(Legacy),
                {ok, #{<<"role">> := <<"assistant">>}} =
                    adk_mcp_client:create_message(Legacy, #{}),
                receive {feature, logging, #{era := legacy}} -> ok
                after 1000 -> ?assert(false)
                end,
                receive {feature, roots, #{era := legacy}} -> ok
                after 1000 -> ?assert(false)
                end,
                receive {feature, sampling, #{era := legacy}} -> ok
                after 1000 -> ?assert(false)
                end
            after ok = adk_mcp_client:close(Legacy)
            end
        after ok = adk_mcp_server:stop(Server)
        end
    end}.

legacy_get_sse_adapter_is_opt_in_and_rejects_modern_test_() ->
    {timeout, 10, fun() ->
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, legacy_sse_compat => true}),
        try
            {ok, #{port := Port, path := Path}} =
                adk_mcp_server:endpoint(Server),
            {ok, Conn} = gun:open("127.0.0.1", Port),
            {ok, _} = gun:await_up(Conn, 3000),
            try
                LegacyRef = gun:get(
                              Conn, Path,
                              [{<<"accept">>, <<"text/event-stream">>},
                               {<<"mcp-protocol-version">>,
                                <<"2025-11-25">>}]),
                {response, nofin, 200, LegacyHeaders} =
                    gun:await(Conn, LegacyRef, 3000),
                {ok, LegacyBody} = gun:await_body(Conn, LegacyRef, 3000),
                ?assertEqual(<<"true">>, header(<<"deprecation">>,
                                                LegacyHeaders)),
                ?assertNotEqual(nomatch,
                                binary:match(LegacyBody,
                                             <<"event: endpoint">>)),
                ModernRef = gun:get(
                              Conn, Path,
                              [{<<"accept">>, <<"text/event-stream">>},
                               {<<"mcp-protocol-version">>,
                                <<"2026-07-28">>}]),
                {response, fin, 405, _} = gun:await(Conn, ModernRef, 3000)
            after gun:close(Conn)
            end
        after ok = adk_mcp_server:stop(Server)
        end
    end}.

auto_negotiation_falls_back_only_from_safe_modern_discovery_test_() ->
    {timeout, 10, fun() ->
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, modern_enabled => false,
                           tools => [tool(<<"legacy">>)]}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true,
                               protocol_version => auto}),
            try
                {ok, Info} = adk_mcp_client:server_info(Client),
                ?assertEqual(<<"2025-11-25">>,
                             maps:get(<<"protocolVersion">>, Info)),
                State = sys:get_state(Client),
                ?assertEqual(legacy, maps:get(protocol_era, State)),
                ?assert(is_binary(maps:get(session_id, State))),
                {ok, [_]} = adk_mcp_client:list_tools(Client)
            after ok = adk_mcp_client:close(Client)
            end
        after ok = adk_mcp_server:stop(Server)
        end
    end}.

managed_client_pool_is_unlinked_and_reuses_negotiated_clients_test_() ->
    {timeout, 10, fun() ->
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, tools => [tool(<<"pooled">>)]}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            {ok, Pool} = adk_mcp_client:connect_pool(
                           <<"streamable_http">>, Url,
                           #{allow_http_loopback => true,
                             protocol_version => modern,
                             pool => #{max_size => 2}}),
            try
                {links, Links} = process_info(self(), links),
                ?assertNot(lists:member(Pool, Links)),
                {ok, [Schema]} = adk_mcp_client:with_client(
                                   Pool, read_only,
                                   fun adk_mcp_client:list_tools/1, 2000),
                ?assertEqual(<<"pooled">>, maps:get(<<"name">>, Schema)),
                {ok, #{available := 1, leased := 0}} =
                    adk_mcp_pool:status(Pool)
            after ok = adk_mcp_client:close_pool(Pool)
            end
        after ok = adk_mcp_server:stop(Server)
        end
    end}.

auto_negotiation_never_falls_back_after_auth_failure_test_() ->
    {timeout, 10, fun() ->
        Calls = atomics:new(1, []),
        Auth = fun(_Meta) ->
            _ = atomics:add_get(Calls, 1, 1),
            {error, unauthenticated}
        end,
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, auth_fun => Auth}),
        try
            {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
            ?assertEqual(
               {error, {http_status, 401}},
               adk_mcp_client:connect(
                 <<"streamable_http">>, Url,
                 #{allow_http_loopback => true,
                   protocol_version => auto})),
            ?assertEqual(1, atomics:get(Calls, 1))
        after ok = adk_mcp_server:stop(Server)
        end
    end}.

external_sdk_fixture_exposes_local_contract_without_claiming_results_test_() ->
    {timeout, 10, fun() ->
        {ok, Fixture} = adk_mcp_external_sdk_fixture:start(#{}),
        try
            ?assertEqual(not_run, maps:get(external_sdk_results, Fixture)),
            ?assertEqual([<<"2026-07-28">>, <<"2025-11-25">>,
                          <<"2025-06-18">>],
                         maps:get(protocol_versions, Fixture)),
            Before = maps:get(generation, maps:get(catalog, Fixture)),
            {ok, _Change} = adk_mcp_external_sdk_fixture:replace_generation(
                              Fixture, <<"fixture.echo.v2">>),
            {ok, Updated} = adk_mcp_external_sdk_fixture:descriptor(
                              maps:get(server, Fixture)),
            ?assertEqual(Before + 1,
                         maps:get(generation, maps:get(catalog, Updated)))
        after ok = adk_mcp_external_sdk_fixture:stop(Fixture)
        end
    end}.

modern_resource_reads_include_required_cache_hints_test_() ->
    {timeout, 10, fun() ->
        {ok, Fixture} = adk_mcp_external_sdk_fixture:start(#{}),
        try
            #{endpoint := #{url := Url}} = Fixture,
            {ok, Client} = adk_mcp_client:connect(
                             <<"streamable_http">>, Url,
                             #{allow_http_loopback => true,
                               protocol_version => <<"2026-07-28">>}),
            try
                {ok, Result} = adk_mcp_client:read_resource(
                                 Client, <<"fixture://resource">>),
                ?assertEqual(0, maps:get(<<"ttlMs">>, Result)),
                ?assertEqual(<<"private">>,
                             maps:get(<<"cacheScope">>, Result))
            after
                ok = adk_mcp_client:close(Client)
            end
        after
            ok = adk_mcp_external_sdk_fixture:stop(Fixture)
        end
    end}.

native_modern_subscription_streams_catalog_list_changed_test_() ->
    {timeout, 10, fun() ->
        {ok, Server} = adk_mcp_server:start(
                         <<"streamable_http">>,
                         #{port => 0, modern_subscriptions => true,
                           tools => [tool(<<"old">>)]}),
        try
            {ok, #{port := Port, path := Path}} =
                adk_mcp_server:endpoint(Server),
            {ok, Conn} = gun:open("127.0.0.1", Port),
            {ok, _} = gun:await_up(Conn, 3000),
            try
                Filter = #{<<"toolsListChanged">> => true},
                {ok, #{message := Message, headers := Headers}} =
                    adk_mcp_protocol_modern:subscription_listen(
                      <<"listen-test">>, Filter,
                      #{client_info =>
                            #{<<"name">> => <<"eunit">>,
                              <<"version">> => <<"1">>},
                        client_capabilities => #{}}),
                RequestHeaders =
                    [{<<"accept">>,
                      <<"application/json, text/event-stream">>},
                     {<<"content-type">>, <<"application/json">>} |
                     maps:to_list(Headers)],
                Ref = gun:post(Conn, Path, RequestHeaders,
                               jsx:encode(Message)),
                {response, nofin, 200, ResponseHeaders} =
                    gun:await(Conn, Ref, 3000),
                ?assertNotEqual(
                   nomatch,
                   binary:match(header(<<"content-type">>,
                                       ResponseHeaders),
                                <<"text/event-stream">>)),
                {data, nofin, AckBody} = gun:await(Conn, Ref, 3000),
                ?assertNotEqual(
                   nomatch,
                   binary:match(
                     AckBody,
                     <<"notifications/subscriptions/acknowledged">>)),
                {ok, Change} = adk_mcp_server:replace_catalog(
                                 Server,
                                 #{tools => [tool(<<"new">>)],
                                   resources => [], prompts => []}),
                ?assertEqual(true,
                             maps:get(tools, maps:get(changed, Change))),
                {data, nofin, EventBody} = gun:await(Conn, Ref, 3000),
                ?assertNotEqual(
                   nomatch,
                   binary:match(
                     EventBody, <<"notifications/tools/list_changed">>)),
                gun:cancel(Conn, Ref)
            after
                gun:close(Conn)
            end
        after
            ok = adk_mcp_server:stop(Server)
        end
    end}.

tool(Name) ->
    #{schema => #{<<"name">> => Name,
                  <<"description">> => <<"fixture">>,
                  <<"inputSchema">> => #{<<"type">> => <<"object">>}},
      execute => fun(_Args, _Context) -> {ok, Name} end}.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.
