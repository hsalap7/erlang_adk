-module(adk_agent_runtime_feasibility_test).

-include_lib("eunit/include/eunit.hrl").

contract_is_feasibility_only_test() ->
    Contract = contract(),
    ?assertEqual(
       <<"erlang-adk.agent-runtime-feasibility/1">>,
       maps:get(<<"contractVersion">>, Contract)),
    ?assertEqual(<<"feasibility-only">>,
                 maps:get(<<"classification">>, Contract)),
    Support = maps:get(<<"managedServiceSupport">>, Contract),
    ?assertEqual(false, maps:get(<<"claimed">>, Support)),
    ?assertEqual(<<"not-supported">>, maps:get(<<"status">>, Support)),
    Mutations = maps:get(<<"mutationPolicy">>, Contract),
    ?assertEqual(false, maps:get(<<"cloudMutations">>, Mutations)),
    ?assertEqual(false, maps:get(<<"agentTaskMutations">>, Mutations)),
    ?assertEqual(<<"ListTasks">>, maps:get(<<"probeRpcMethod">>, Mutations)).

oci_boundary_matches_release_image_test() ->
    Contract = contract(),
    Oci = maps:get(<<"ociBoundary">>, Contract),
    User = maps:get(<<"runtimeUser">>, Oci),
    ?assertEqual(10001, maps:get(<<"uid">>, User)),
    ?assertEqual(10001, maps:get(<<"gid">>, User)),
    ?assertEqual(true, maps:get(<<"mustRunAsNonRoot">>, User)),
    ?assertEqual(<<"SIGTERM">>, maps:get(<<"stopSignal">>, Oci)),
    ?assertEqual(
       <<"/opt/erlang_adk/bin/container-entrypoint">>,
       maps:get(<<"entrypoint">>, Oci)),
    ?assertEqual(
       [<<"/var/lib/erlang_adk">>, <<"/var/log/erlang_adk">>,
        <<"/tmp/erlang_adk">>],
       maps:get(<<"writableMounts">>, Oci)),
    Dockerfile = read("Dockerfile"),
    contains_all(
      Dockerfile,
      [<<"USER 10001:10001">>, <<"STOPSIGNAL SIGTERM">>,
       <<"ENTRYPOINT [\"/opt/erlang_adk/bin/container-entrypoint\"]">>]).

http_boundary_covers_health_and_a2a_v1_test() ->
    Http = maps:get(<<"httpBoundary">>, contract()),
    ?assertEqual(<<"1.0">>, maps:get(<<"a2aProtocolVersion">>, Http)),
    Endpoints = maps:get(<<"endpoints">>, Http),
    ById = maps:from_list(
             [{maps:get(<<"id">>, E), E} || E <- Endpoints]),
    ?assertEqual(5, map_size(ById)),
    assert_endpoint(ById, <<"liveness">>, <<"GET">>, <<"/livez">>),
    assert_endpoint(ById, <<"readiness">>, <<"GET">>, <<"/readyz">>),
    assert_endpoint(ById, <<"public-agent-card">>, <<"GET">>,
                    <<"/.well-known/agent-card.json">>),
    assert_endpoint(ById, <<"extended-agent-card">>, <<"GET">>,
                    <<"/extendedAgentCard">>),
    assert_endpoint(ById, <<"a2a-jsonrpc">>, <<"POST">>, <<"/a2a/v1">>),
    Rpc = maps:get(<<"a2a-jsonrpc">>, ById),
    ?assertEqual(<<"ListTasks">>, maps:get(<<"probeMethod">>, Rpc)),
    ?assertEqual(<<"read-only">>, maps:get(<<"sideEffect">>, Rpc)),
    Extended = maps:get(<<"extended-agent-card">>, ById),
    ?assertEqual(<<"private, no-store">>,
                 maps:get(<<"cachePolicy">>, Extended)),
    ?assertEqual(
       <<"1.0">>,
       maps:get(<<"A2A-Version">>, maps:get(<<"requiredHeaders">>, Extended))).

all_support_blockers_are_explicit_and_unresolved_test() ->
    Blockers = maps:get(<<"unresolvedBlockers">>, contract()),
    ById = maps:from_list(
             [{maps:get(<<"id">>, B), B} || B <- Blockers]),
    ?assertEqual(
       [<<"conformance">>, <<"identity">>, <<"network">>, <<"state">>,
        <<"vendor-lifecycle">>],
       lists:sort(maps:keys(ById))),
    maps:foreach(
      fun(_Id, Blocker) ->
          ?assertEqual(<<"unresolved">>, maps:get(<<"status">>, Blocker)),
          ?assertEqual(true, maps:get(<<"blocksSupportClaim">>, Blocker)),
          ?assert(byte_size(maps:get(<<"exitEvidence">>, Blocker)) > 40)
      end, ById).

probe_is_bounded_read_only_and_credential_safe_test() ->
    Probe = read("scripts/deployment/probe-agent-runtime.sh"),
    contains_all(
      Probe,
      [<<"--max-filesize 1048576">>, <<"--max-redirs 0">>,
       <<"--proto \"$curl_protocol\"">>, <<"--connect-timeout">>,
       <<"--max-time">>, <<"\"method\":\"ListTasks\"">>,
       <<"printenv \"$token_env\"">>, <<"--config -">>,
       <<"http://127.0.0.1">>, <<"--allow-loopback-http">>]),
    contains_none(
      Probe,
      [<<"gcloud ">>, <<"kubectl ">>, <<"terraform ">>, <<"pulumi ">>,
       <<"--apply">>, <<"SendMessage">>, <<"CancelTask">>,
       <<"CreateTaskPushNotificationConfig">>, <<" eval ">>]),
    ?assertEqual(nomatch, binary:match(Probe, <<"--token ">>)),
    ?assertEqual(nomatch, binary:match(Probe, <<"-H \"Authorization:">>)).

shell_contract_validation_test() ->
    ?assertEqual(
       {0, <<"">>},
       run("sh", ["-n", "scripts/deployment/probe-agent-runtime.sh"])),
    ?assertEqual(
       {0, <<"">>},
       run("sh", ["-n", "scripts/deployment/verify-agent-runtime-contract.sh"])),
    {0, VerifyOutput} = run(
                          "scripts/deployment/verify-agent-runtime-contract.sh",
                          []),
    ?assertNotEqual(
       nomatch,
       binary:match(VerifyOutput, <<"no support claim">>)),
    Hash = lists:duplicate(64, $a),
    {64, ProbeOutput} = run_env(
                          "scripts/deployment/probe-agent-runtime.sh",
                          ["--base-url", "http://127.0.0.1:9",
                           "--allow-loopback-http",
                           "--token-env", "ADK_REVIEW_TOKEN",
                           "--expected-card-sha256", Hash,
                           "--expected-extended-card-sha256", Hash,
                           "--connect-timeout", "1", "--max-time", "1"],
                          [{"ADK_REVIEW_TOKEN", "abc123"}]),
    ?assertEqual(nomatch,
                 binary:match(ProbeOutput,
                              <<"bearer token must not contain">>)),
    ?assertNotEqual(nomatch, binary:match(ProbeOutput, <<"GET ">>)).

contract() ->
    jsx:decode(read("deploy/agent-runtime/boundary-contract.json"),
               [return_maps]).

assert_endpoint(ById, Id, Method, Path) ->
    Endpoint = maps:get(Id, ById),
    ?assertEqual(Method, maps:get(<<"method">>, Endpoint)),
    ?assertEqual(Path, maps:get(<<"path">>, Endpoint)),
    ?assertEqual(200, maps:get(<<"expectedStatus">>, Endpoint)).

read(Path) ->
    {ok, Body} = file:read_file(Path),
    Body.

contains_all(Body, Needles) ->
    lists:foreach(
      fun(Needle) ->
          ?assertNotEqual(nomatch, binary:match(Body, Needle))
      end, Needles).

contains_none(Body, Needles) ->
    lists:foreach(
      fun(Needle) ->
          ?assertEqual(nomatch, binary:match(Body, Needle))
      end, Needles).

run(Executable, Arguments) ->
    run_env(Executable, Arguments, []).

run_env(Executable, Arguments, Environment) ->
    Port = open_port(
             {spawn_executable, executable(Executable)},
             [{args, Arguments}, {env, Environment}, binary,
              exit_status, stderr_to_stdout]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after 10000 ->
        erlang:error({command_timeout, Port})
    end.

executable(Path) ->
    case filename:pathtype(Path) of
        absolute -> Path;
        _ when Path =:= "sh" ->
            case os:find_executable(Path) of
                false -> erlang:error({missing_executable, Path});
                Found -> Found
            end;
        _ -> filename:absname(Path)
    end.
