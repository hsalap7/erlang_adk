-module(erlang_adk_startup_test).

-include_lib("eunit/include/eunit.hrl").

-define(DEV_TOKEN, <<"0123456789abcdef-startup-dev-token">>).

-define(HTTP_ENV_KEYS,
        [a2a_enabled, a2a_v1_enabled, a2a_v1_card,
         a2a_v1_server_options, a2a_v1_auth,
         a2a_v1_jwt_policy,
         a2a_v1_max_body_bytes, a2a_v1_sse_heartbeat_ms,
         a2a_v1_max_extensions, a2a_v1_max_extension_header_bytes,
         a2a_v1_auth_timeout_ms, a2a_v1_auth_max_heap_words,
         a2a_v1_agent_name,
         dev_enabled, dev_auth_token, dev_auth_token_env,
         dev_session_service, dev_runner_options, dev_run_options,
         dev_max_body_bytes, dev_max_field_bytes, dev_sse_heartbeat_ms,
         dev_sse_max_events, dev_sse_max_bytes, dev_sse_max_duration_ms,
         dev_max_session_results, dev_live_principal, dev_live_credit,
         dev_resource_provider, dev_max_resource_results,
         dev_diagnostic_timeout_ms, dev_diagnostic_context_policy,
         a2a_port, a2a_ip, a2a_max_body_bytes,
         a2a_allow_non_loopback, a2a_trusted_tls_proxy, a2a_tls_options,
         a2a_num_acceptors, a2a_max_connections, a2a_request_timeout,
         a2a_idle_timeout, a2a_max_keepalive]).

secure_startup_test_() ->
    {timeout, 30, fun secure_startup/0}.

secure_startup() ->
    AdkWasRunning = application_running(erlang_adk),
    MnesiaWasRunning = application_running(mnesia),
    SavedAdkEnv = save_env(erlang_adk,
                           [session_backend, admission_control,
                            oidc_providers,
                            oidc_max_clock_skew_seconds | ?HTTP_ENV_KEYS]),
    SavedMnesiaDir = application:get_env(mnesia, dir),
    TempMnesiaDir = filename:join(
                       os:getenv("TMPDIR", "/tmp"),
                       "erlang_adk_mnesia_" ++
                           integer_to_list(erlang:unique_integer([positive]))),
    stop_application(erlang_adk),
    stop_application(mnesia),
    try
        default_startup_is_lean(),
        invalid_oidc_clock_skew_fails_startup(),
        configured_mnesia_startup(TempMnesiaDir),
        developer_listener_is_always_loopback(),
        a2a_v1_public_listener_fails_closed(),
        supervised_http_is_bounded(),
        supervised_dev_listener_is_authenticated(),
        supervised_a2a_v1_is_discoverable()
    after
        stop_application(erlang_adk),
        stop_application(mnesia),
        restore_env(erlang_adk, SavedAdkEnv),
        restore_env(mnesia, [{dir, SavedMnesiaDir}]),
        _ = file:del_dir_r(TempMnesiaDir),
        maybe_restart(mnesia, MnesiaWasRunning),
        maybe_restart(erlang_adk, AdkWasRunning)
    end.

default_startup_is_lean() ->
    application:unset_env(erlang_adk, session_backend),
    application:set_env(erlang_adk, a2a_enabled, false),
    application:set_env(erlang_adk, a2a_v1_enabled, false),
    application:set_env(erlang_adk, dev_enabled, false),
    application:set_env(erlang_adk, oidc_providers, []),
    application:set_env(erlang_adk, oidc_max_clock_skew_seconds, 300),
    {ok, _} = application:ensure_all_started(erlang_adk),
    ?assertNot(application_running(mnesia)),
    ?assertEqual(false, supervised_child_present(erlang_adk_http)),
    ?assertEqual(false, supervised_child_present(adk_a2a_v1_server)),
    ?assert(supervised_child_present(adk_auth_sup)),
    ?assert(supervised_child_present(adk_admission_control)),
    ?assert(supervised_child_present(adk_oidc_provider_sup)),
    ?assertEqual({ok, 300},
                 application:get_env(oidcc, max_clock_skew)),
    stop_application(erlang_adk).

invalid_oidc_clock_skew_fails_startup() ->
    application:set_env(erlang_adk, oidc_max_clock_skew_seconds, 301),
    ?assertMatch({error, _},
                 application:ensure_all_started(erlang_adk)),
    ?assertNot(application_running(erlang_adk)),
    application:set_env(erlang_adk, oidc_max_clock_skew_seconds, 300).

configured_mnesia_startup(TempMnesiaDir) ->
    ok = file:make_dir(TempMnesiaDir),
    application:set_env(mnesia, dir, TempMnesiaDir),
    application:set_env(erlang_adk, session_backend,
                        erlang_adk_session_mnesia),
    application:set_env(erlang_adk, a2a_enabled, false),
    application:set_env(erlang_adk, a2a_v1_enabled, false),
    application:set_env(erlang_adk, dev_enabled, false),
    {ok, _} = application:ensure_all_started(erlang_adk),
    ?assert(application_running(mnesia)),
    ?assertEqual(ok, mnesia:wait_for_tables(
                       [adk_sessions_mnesia, adk_session_v2,
                        adk_session_scope], 5000)),
    stop_application(erlang_adk),
    stop_application(mnesia),
    application:unset_env(erlang_adk, session_backend).

developer_listener_is_always_loopback() ->
    Port = free_port(),
    application:set_env(erlang_adk, a2a_enabled, false),
    application:set_env(erlang_adk, a2a_v1_enabled, false),
    application:set_env(erlang_adk, dev_enabled, true),
    application:set_env(erlang_adk, dev_auth_token, ?DEV_TOKEN),
    application:set_env(erlang_adk, a2a_port, Port),
    application:set_env(erlang_adk, a2a_ip, {0, 0, 0, 0}),

    %% The direct listener API is not a bypass around the CLI's loopback
    %% parser.
    ?assertEqual({error, developer_server_must_bind_loopback},
                 isolated_http_start()),

    %% The OTP application path fails on the same invariant before Cowboy can
    %% open a socket.
    ApplicationResult = application:ensure_all_started(erlang_adk),
    ?assertMatch({error, _}, ApplicationResult),
    ?assert(reason_in_term(developer_server_must_bind_loopback,
                           ApplicationResult)),
    ?assertNot(application_running(erlang_adk)),

    %% The legacy A2A route cannot turn a shared /dev listener into a public
    %% endpoint either.
    application:set_env(erlang_adk, a2a_enabled, true),
    ?assertEqual({error, developer_server_must_bind_loopback},
                 isolated_http_start()),

    application:set_env(erlang_adk, a2a_enabled, false),
    application:set_env(erlang_adk, dev_enabled, false),
    application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
    application:unset_env(erlang_adk, dev_auth_token).

a2a_v1_public_listener_fails_closed() ->
    Port = free_port(),
    SecuritySchemes = #{
      <<"bearer">> => #{
        <<"httpAuthSecurityScheme">> => #{<<"scheme">> => <<"Bearer">>}}},
    SecurityRequirements = [
      #{<<"schemes">> =>
            #{<<"bearer">> => #{<<"list">> => [<<"a2a.invoke">>]}}}],
    {ok, PublicCard} = adk_a2a_v1_card:new(
                         #{url => <<"https://agent.example/a2a/v1">>,
                           security_schemes => SecuritySchemes,
                           security_requirements => SecurityRequirements}),
    {ok, AnonymousCard} = adk_a2a_v1_card:new(
                            #{url => <<"http://127.0.0.1/a2a/v1">>}),
    application:set_env(erlang_adk, a2a_enabled, false),
    application:set_env(erlang_adk, a2a_v1_enabled, true),
    application:set_env(erlang_adk, dev_enabled, false),
    application:set_env(erlang_adk, a2a_port, Port),
    application:set_env(erlang_adk, a2a_ip, {0, 0, 0, 0}),
    application:set_env(erlang_adk, a2a_v1_card, PublicCard),
    application:set_env(erlang_adk, a2a_v1_auth, adk_a2a_v1_test_auth),
    application:set_env(erlang_adk, a2a_allow_non_loopback, false),
    application:set_env(erlang_adk, a2a_trusted_tls_proxy, true),
    ?assertMatch(
       {error, non_loopback_a2a_v1_requires_explicit_opt_in},
       isolated_http_start()),

    application:set_env(erlang_adk, a2a_v1_card, AnonymousCard),
    ?assertMatch({error, a2a_v1_auth_card_mismatch},
                 isolated_http_start()),
    application:set_env(erlang_adk, a2a_v1_card, PublicCard),

    application:set_env(erlang_adk, a2a_allow_non_loopback, true),
    application:set_env(erlang_adk, a2a_trusted_tls_proxy, false),
    ?assertMatch({error, non_loopback_a2a_v1_requires_tls},
                 isolated_http_start()),

    application:set_env(erlang_adk, dev_enabled, true),
    application:set_env(erlang_adk, a2a_trusted_tls_proxy, true),
    ?assertMatch({error, public_a2a_v1_requires_dedicated_listener},
                 isolated_http_start()),

    application:set_env(erlang_adk, dev_enabled, false),
    application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
    application:set_env(erlang_adk, a2a_v1_card,
                        AnonymousCard#{
                          <<"securitySchemes">> => SecuritySchemes,
                          <<"securityRequirements">> =>
                              SecurityRequirements}),
    application:set_env(erlang_adk, a2a_v1_auth, none),
    ?assertMatch({error, a2a_v1_auth_card_mismatch},
                 isolated_http_start()),

    application:set_env(erlang_adk, a2a_v1_enabled, false),
    application:set_env(erlang_adk, a2a_allow_non_loopback, false),
    application:set_env(erlang_adk, a2a_trusted_tls_proxy, false),
    application:unset_env(erlang_adk, a2a_v1_card),
    application:unset_env(erlang_adk, a2a_v1_auth).

isolated_http_start() ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(
                       fun() ->
                           process_flag(trap_exit, true),
                           Parent ! {Ref, erlang_adk_http:start_link()}
                       end),
    Result = receive
        {Ref, Value} -> Value
    after 5000 -> timeout
    end,
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 5000 -> ok
    end,
    Result.

supervised_http_is_bounded() ->
    Port = free_port(),
    application:set_env(erlang_adk, a2a_enabled, true),
    application:set_env(erlang_adk, a2a_v1_enabled, false),
    application:set_env(erlang_adk, a2a_port, Port),
    application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
    application:set_env(erlang_adk, a2a_max_body_bytes, 64),
    {ok, _} = application:ensure_all_started(erlang_adk),
    ?assert(supervised_child_present(erlang_adk_http)),
    OversizedBody = binary:copy(<<"x">>, 65),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++
          "/a2a/prompt",
    {ok, {{_HttpVersion, 413, _ReasonPhrase}, _Headers, _Body}} =
        httpc:request(post,
                      {Url, [], "application/json", OversizedBody},
                      [], []),
    stop_application(erlang_adk),
    ?assertEqual(undefined, whereis(erlang_adk_http)),
    application:set_env(erlang_adk, a2a_enabled, false).

supervised_dev_listener_is_authenticated() ->
    Keys = [a2a_enabled, a2a_v1_enabled, dev_enabled,
            dev_auth_token, dev_resource_provider,
            dev_max_resource_results, dev_diagnostic_timeout_ms,
            dev_diagnostic_context_policy, dev_live_principal,
            dev_live_credit, a2a_port, a2a_ip],
    SavedEnv = save_env(erlang_adk, Keys),
    Port = free_port(),
    App = <<"startup-dev-app">>,
    User = <<"startup-dev-user">>,
    Session = <<"startup-dev-session">>,
    Path = "/dev/v1/sessions/" ++ binary_to_list(App) ++ "/" ++
           binary_to_list(User) ++ "/" ++ binary_to_list(Session),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    ArtifactScope = {session, App, User, Session},
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    {ok, _} = adk_artifact_ets:put(
                ArtifactPid, ArtifactScope, <<"startup.txt">>, <<"ready">>,
                #{}),
    ProviderConfig = #{app => App, user => User, session => Session,
                       artifact => {adk_artifact_ets, ArtifactPid}},
    try
        application:set_env(erlang_adk, a2a_enabled, false),
        application:set_env(erlang_adk, a2a_v1_enabled, false),
        application:set_env(erlang_adk, dev_enabled, true),
        application:set_env(erlang_adk, dev_auth_token, ?DEV_TOKEN),
        application:set_env(
          erlang_adk, dev_resource_provider,
          {adk_dev_v05_resource_provider, ProviderConfig}),
        application:set_env(erlang_adk, dev_max_resource_results, 1),
        application:set_env(erlang_adk, dev_live_principal,
                            <<"startup-live-principal">>),
        application:set_env(erlang_adk, dev_live_credit,
                            #{messages => 3, bytes => 1048576}),
        application:set_env(erlang_adk, dev_diagnostic_timeout_ms, 2000),
        application:set_env(
          erlang_adk, dev_diagnostic_context_policy,
          #{max_bytes => 65536, max_tokens => 16384,
            overflow => truncate}),
        application:set_env(erlang_adk, a2a_port, Port),
        application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
        {ok, _} = application:ensure_all_started(erlang_adk),
        ?assert(supervised_child_present(erlang_adk_http)),
        {ok, _} = erlang_adk_session:create_session(
                    App, User, #{session_id => Session}),

        {ok, {{_HttpVersion1, 401, _Reason1}, UnauthorizedHeaders, _Body1}} =
            httpc:request(get, {Url, []}, [], [{body_format, binary}]),
        ?assertNotEqual(
           undefined,
           proplists:get_value("www-authenticate", UnauthorizedHeaders)),

        Authorization = "Bearer " ++ binary_to_list(?DEV_TOKEN),
        {ok, {{_HttpVersion2, 200, _Reason2}, _Headers2, Body2}} =
            httpc:request(
              get, {Url, [{"authorization", Authorization}]}, [],
              [{body_format, binary}]),
        Decoded = jsx:decode(Body2, [return_maps]),
        ?assertEqual(Session, maps:get(<<"id">>, Decoded)),
        ?assertEqual(App, maps:get(<<"app_name">>, Decoded)),
        ?assertEqual(User, maps:get(<<"user_id">>, Decoded)),

        ArtifactUrl = "http://127.0.0.1:" ++ integer_to_list(Port) ++
                      "/dev/v1/artifacts/" ++ binary_to_list(App) ++ "/" ++
                      binary_to_list(User) ++ "/" ++
                      binary_to_list(Session),
        {ok, {{_HttpVersion3, 200, _Reason3}, _Headers3, Body3}} =
            httpc:request(
              get, {ArtifactUrl ++ "?limit=1",
                    [{"authorization", Authorization}]}, [],
              [{body_format, binary}]),
        ArtifactResult = jsx:decode(Body3, [return_maps]),
        ?assertEqual([<<"startup.txt">>],
                     maps:get(<<"names">>, ArtifactResult)),
        {ok, {{_HttpVersion4, 400, _Reason4}, _Headers4, _Body4}} =
            httpc:request(
              get, {ArtifactUrl ++ "?limit=2",
                    [{"authorization", Authorization}]}, [],
              [{body_format, binary}]),

        LiveUrl = "http://127.0.0.1:" ++ integer_to_list(Port) ++
                  "/dev/v1/live/sessions",
        {ok, {{_HttpVersion5, 200, _Reason5}, _Headers5, LiveBody}} =
            httpc:request(
              get, {LiveUrl, [{"authorization", Authorization}]}, [],
              [{body_format, binary}]),
        LivePayload = jsx:decode(LiveBody, [return_maps]),
        ?assert(is_list(maps:get(<<"sessions">>, LivePayload)))
    after
        _ = catch erlang_adk_session:delete_session(App, User, Session),
        _ = adk_artifact_ets:stop(ArtifactPid),
        stop_application(erlang_adk),
        ?assertEqual(undefined, whereis(erlang_adk_http)),
        restore_env(erlang_adk, SavedEnv)
    end.

supervised_a2a_v1_is_discoverable() ->
    Port = free_port(),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<Base/binary, "/a2a/v1">>,
                     name => <<"Startup A2A fixture">>,
                     description => <<"Supervised A2A fixture">>}),
    Executor = fun(_Request, _Emit) -> {ok, <<"fixture response">>} end,
    application:set_env(erlang_adk, a2a_enabled, false),
    application:set_env(erlang_adk, a2a_v1_enabled, true),
    application:set_env(erlang_adk, a2a_v1_card, Card),
    application:set_env(erlang_adk, a2a_v1_server_options,
                        #{executor => Executor}),
    application:set_env(erlang_adk, a2a_v1_auth, none),
    application:set_env(erlang_adk, a2a_v1_max_body_bytes, 65536),
    application:set_env(erlang_adk, a2a_port, Port),
    application:set_env(erlang_adk, a2a_ip, {127, 0, 0, 1}),
    {ok, _} = application:ensure_all_started(erlang_adk),
    ?assert(supervised_child_present(adk_a2a_v1_server)),
    ?assert(supervised_child_present(erlang_adk_http)),
    LocalClient = #{timeout => 3000, allow_http_loopback => true},
    {ok, Discovered} = adk_a2a_v1_client:discover(Base, LocalClient),
    ?assertEqual(Card, Discovered),
    {ok, #{<<"task">> := Task}} = adk_a2a_v1_client:send(
                                      Discovered,
                                      #{<<"messageId">> => <<"startup-msg">>,
                                        <<"role">> => <<"ROLE_USER">>,
                                        <<"parts">> =>
                                            [#{<<"text">> => <<"hello">>}]},
                                      LocalClient),
    ?assertEqual(
       <<"TASK_STATE_COMPLETED">>,
       maps:get(<<"state">>, maps:get(<<"status">>, Task))),
    stop_application(erlang_adk),
    ?assertEqual(undefined, whereis(adk_a2a_v1_server)),
    application:set_env(erlang_adk, a2a_v1_enabled, false),
    application:unset_env(erlang_adk, a2a_v1_card),
    application:unset_env(erlang_adk, a2a_v1_server_options).

supervised_child_present(Id) ->
    lists:keymember(Id, 1, supervisor:which_children(erlang_adk_sup)).

free_port() ->
    {ok, Socket} = gen_tcp:listen(
                     0, [{ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, {_Ip, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    Port.

application_running(Application) ->
    lists:keymember(Application, 1, application:which_applications()).

reason_in_term(Expected, Expected) ->
    true;
reason_in_term(Expected, Tuple) when is_tuple(Tuple) ->
    lists:any(fun(Value) -> reason_in_term(Expected, Value) end,
              tuple_to_list(Tuple));
reason_in_term(Expected, List) when is_list(List) ->
    lists:any(fun(Value) -> reason_in_term(Expected, Value) end, List);
reason_in_term(Expected, Map) when is_map(Map) ->
    lists:any(fun({Key, Value}) ->
                  reason_in_term(Expected, Key) orelse
                  reason_in_term(Expected, Value)
              end, maps:to_list(Map));
reason_in_term(_Expected, _Term) ->
    false.

stop_application(Application) ->
    case application:stop(Application) of
        ok -> ok;
        {error, {not_started, Application}} -> ok
    end.

maybe_restart(_Application, false) ->
    ok;
maybe_restart(Application, true) ->
    {ok, _} = application:ensure_all_started(Application),
    ok.

save_env(Application, Keys) ->
    [{Key, application:get_env(Application, Key)} || Key <- Keys].

restore_env(_Application, []) ->
    ok;
restore_env(Application, [{Key, undefined} | Rest]) ->
    application:unset_env(Application, Key),
    restore_env(Application, Rest);
restore_env(Application, [{Key, {ok, Value}} | Rest]) ->
    application:set_env(Application, Key, Value),
    restore_env(Application, Rest).
