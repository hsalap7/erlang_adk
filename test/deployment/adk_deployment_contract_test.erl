-module(adk_deployment_contract_test).

-include_lib("eunit/include/eunit.hrl").

docker_non_root_release_contract_test() ->
    Dockerfile = read(<<"Dockerfile">>),
    contains_all(
      Dockerfile,
      [<<"ARG ERLANG_BUILD_IMAGE=erlang:27.3.4.14-alpine">>,
       <<"ARG ERLANG_RUNTIME_IMAGE=alpine:3.24.1">>,
       <<"release -c rel/relx.config">>,
       <<"USER 10001:10001">>,
       <<"STOPSIGNAL SIGTERM">>,
       <<"/var/lib/erlang_adk">>,
       <<"/var/log/erlang_adk">>,
       <<"/tmp/erlang_adk">>,
       <<"ERLANG_ADK_NOFILE_CAP=65536">>,
       <<"ENTRYPOINT [\"/opt/erlang_adk/bin/container-entrypoint\"]">>]),
    ?assertEqual(nomatch, binary:match(Dockerfile, <<"COPY . .">>)).

root_release_is_fail_closed_test() ->
    Relx = read(<<"rel/relx.config">>),
    SysConfig = read(<<"rel/sys.config">>),
    HealthConfig = read(<<"rel/health-http.sys.config.src">>),
    VmArgs = read(<<"rel/vm.args">>),
    contains_all(Relx,
                 [<<"{erlang_adk, \"0.10.0\"}">>,
                  <<"sasl, mnesia, erlang_adk">>,
                  <<"include_erts, true">>,
                  <<"container-entrypoint">>,
                  <<"deployment-health">>,
                  <<"health-http.sys.config.src">>]),
    contains_all(SysConfig,
                 [<<"{a2a_enabled, false}">>,
                  <<"{a2a_v1_enabled, false}">>,
                  <<"{dev_enabled, false}">>,
                  <<"/var/lib/erlang_adk/mnesia">>]),
    contains_all(HealthConfig,
                 [<<"{http_health_enabled, true}">>,
                  <<"{a2a_port, ${PORT:-8080}}">>,
                  <<"{a2a_ip, {0, 0, 0, 0}}">>,
                  <<"{a2a_enabled, false}">>,
                  <<"{a2a_v1_enabled, false}">>,
                  <<"{dev_enabled, false}">>]),
    ?assertEqual(nomatch, binary:match(VmArgs, <<"-setcookie">>)),
    contains_all(VmArgs,
                 [<<"-sname erlang_adk">>,
                  <<"inet_dist_use_interface {127,0,0,1}">>,
                  <<"inet_dist_listen_min 9100">>,
                  <<"inet_dist_listen_max 9100">>]).

health_and_drain_contract_test() ->
    Entry = read(<<"scripts/deployment/container-entrypoint.sh">>),
    Health = read(<<"scripts/deployment/release-health.sh">>),
    contains_all(Entry,
                 [<<"trap begin_drain TERM INT HUP">>,
                  <<"kill -TERM \"$child_pid\"">>,
                  <<"deployment-health\" drain">>,
                  <<"rm -f \"$ready_file\"">>,
                  <<"/dev/urandom">>,
                  <<"chmod 0600 \"$cookie_file\"">>,
                  <<"ERLANG_ADK_NOFILE_CAP">>,
                  <<"ulimit -n \"$nofile_target\"">>,
                  <<"drain_started=false">>,
                  <<"while :; do">>,
                  <<"kill -0 \"$child_pid\" 2>/dev/null || break">>,
                  <<"ERLANG_ADK_STARTUP_GRACE_SECONDS">>]),
    contains_all(Health,
                 [<<"live)">>, <<"ready)">>, <<"drain)">>,
                  <<"adk_deployment_lifecycle liveness_code '[]'">>,
                  <<"adk_deployment_lifecycle readiness_code '[]'">>,
                  <<"adk_deployment_lifecycle drain_code">>,
                  <<"ERLANG_ADK_DIST_PORT">>,
                  <<"ERLANG_ADK_HEALTH_RPC_TIMEOUT_SECONDS">>,
                  <<"drain_rpc_timeout_seconds">>,
                  <<"drain_timeout_ms + 999">>,
                  <<"erts-*/bin/erl_call">>,
                  <<"-address \"127.0.0.1:$dist_port\"">>,
                  <<"ERLANG_ADK_READINESS_HOOK">>,
                  <<"/opt/erlang_adk/hooks/*">>]),
    ?assertEqual(
       nomatch,
       binary:match(Health, <<"\"$release_root/bin/erlang_adk\" rpc">>)).

cloud_run_render_is_immutable_and_single_instance_test() ->
    Template = read(<<"deploy/cloud-run/service.yaml.tpl">>),
    Renderer = read(<<"scripts/deployment/render-cloud-run.sh">>),
    Apply = read(<<"scripts/deployment/deploy-cloud-run.sh">>),
    contains_all(Template,
                 [<<"autoscaling.knative.dev/maxScale: \"@@MAX_INSTANCES@@\"">>,
                  <<"run.googleapis.com/maxScale: \"@@MAX_INSTANCES@@\"">>,
                  <<"containerConcurrency: 1">>,
                  <<"medium: Memory">>,
                  <<"sizeLimit: 512Mi">>,
                  <<"ERLANG_ADK_DRAIN_TIMEOUT_MS">>,
                  <<"/opt/erlang_adk/etc/health-http.sys.config">>,
                  <<"RELX_OUT_FILE_PATH">>,
                  <<"startupProbe:">>, <<"livenessProbe:">>]),
    contains_all(Renderer,
                 [<<"verify-image-ref.sh">>,
                  <<"foundation release is limited to one instance">>]),
    contains_all(Apply,
                 [<<"--apply">>,
                  <<"no changes made; pass --apply">>,
                  <<"gcloud run services replace">>]),
    ?assertEqual(nomatch, binary:match(Template, <<"securityContext:">>)),
    ?assertEqual(nomatch, binary:match(Template, <<"kind: Secret">>)).

helm_defaults_are_hardened_test() ->
    Values = read(<<"deploy/helm/erlang-adk/values.yaml">>),
    Deployment = read(
                   <<"deploy/helm/erlang-adk/templates/deployment.yaml">>),
    NetworkPolicy = read(
                      <<"deploy/helm/erlang-adk/templates/networkpolicy.yaml">>),
    Ingress = read(<<"deploy/helm/erlang-adk/templates/ingress.yaml">>),
    contains_all(Values,
                 [<<"replicaCount: 1">>,
                  <<"singleReplicaOnly: true">>,
                  <<"type: Recreate">>,
                  <<"enabled: false">>,
                  <<"existingSecret">>,
                  <<"readOnlyRootFilesystem: true">>]),
    contains_all(Deployment,
                 [<<"replicaCount must remain 1">>,
                  <<"automountServiceAccountToken: false">>,
                  <<"deployment-health\", \"ready">>,
                  <<"/opt/erlang_adk/etc/runtime/sys.config">>,
                  <<"/opt/erlang_adk/etc/health-http.sys.config">>,
                  <<"key: sys.config">>,
                  <<"ERLANG_ADK_OTLP_ENDPOINT">>,
                  <<"secretKeyRef:">>]),
    ?assertEqual(nomatch, binary:match(Deployment, <<"preStop:">>)),
    contains_all(NetworkPolicy,
                 [<<"policyTypes: [\"Ingress\", \"Egress\"]">>,
                  <<"kubernetes.io/metadata.name: kube-system">>,
                  <<"k8s-app: kube-dns">>]),
    contains_all(Ingress,
                 [<<"TLS must be enabled">>,
                  <<"ingress.tls.secretName is required">>]),
    ?assertEqual(nomatch, binary:match(Values, <<"apiKey:">>)),
    ?assertEqual(nomatch, binary:match(Deployment, <<"kind: Secret">>)).

helm_values_schema_is_valid_json_test() ->
    Schema = read(<<"deploy/helm/erlang-adk/values.schema.json">>),
    Decoded = jsx:decode(Schema, [return_maps]),
    ?assertEqual(<<"object">>, maps:get(<<"type">>, Decoded)),
    Image = maps:get(
              <<"image">>, maps:get(<<"properties">>, Decoded)),
    ?assert(maps:is_key(<<"required">>, Image)).

render_first_apply_explicit_test() ->
    HelmRender = read(<<"scripts/deployment/render-helm.sh">>),
    GkeApply = read(<<"scripts/deployment/deploy-gke.sh">>),
    contains_all(HelmRender,
                 [<<"helm template">>, <<"verify-image-ref.sh">>,
                  <<"image.digest">>]),
    contains_all(GkeApply,
                 [<<"--apply">>, <<"no changes made; pass --apply">>,
                  <<"kubectl config current-context">>,
                  <<"refusing context mismatch">>]).

supply_chain_contract_test() ->
    Build = read(<<"scripts/security/build-image.sh">>),
    Sbom = read(<<"scripts/security/generate-sbom.sh">>),
    Scan = read(<<"scripts/security/scan-sbom.sh">>),
    Sign = read(<<"scripts/security/sign-image.sh">>),
    Attest = read(<<"scripts/security/attest-provenance.sh">>),
    contains_all(Build,
                 [<<"--sbom=true">>, <<"--provenance=mode=max">>,
                  <<"--build-base">>, <<"--runtime-base">>,
                  <<"--apply">>, <<"--push">>]),
    contains_all(Sbom, [<<"cyclonedx-json">>, <<"verify-image-ref.sh">>]),
    contains_all(Scan, [<<"--fail-on">>, <<"sarif">>]),
    contains_all(Sign, [<<"cosign sign --yes">>, <<"--apply">>]),
    contains_all(Attest,
                 [<<"cosign attest --yes">>,
                  <<"--type slsaprovenance">>, <<"--apply">>]).

cli_deploy_is_validated_and_non_mutating_by_default_test() ->
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    CloudPath = filename:join(
                  "/tmp", "erlang-adk-cloud-run-" ++ Suffix ++ ".yaml"),
    GkePath = filename:join(
                "/tmp", "erlang-adk-gke-" ++ Suffix ++ ".yaml"),
    ok = file:write_file(
           CloudPath,
           <<"apiVersion: serving.knative.dev/v1\nkind: Service\n">>),
    ok = file:write_file(
           GkePath,
           <<"apiVersion: apps/v1\nkind: Deployment\n">>),
    try
        {ok, Cloud} = adk_cli:command(
                        ["deploy", "cloud_run", "--manifest", CloudPath,
                         "--project", "example-project",
                         "--region", "us-central1"]),
        ?assertEqual(deploy_cloud_run, maps:get(command, Cloud)),
        ?assertEqual(validate_only, maps:get(mode, Cloud)),
        ?assertEqual(false, maps:get(apply, Cloud)),
        ?assertEqual(64, byte_size(maps:get(manifest_sha256, Cloud))),
        {ok, Gke} = adk_cli:command(
                      ["deploy", "gke", "--manifest", GkePath,
                       "--context", "kind-erlang-adk",
                       "--namespace", "agents"]),
        ?assertEqual(deploy_gke, maps:get(command, Gke)),
        ?assertEqual(validate_only, maps:get(mode, Gke)),
        ?assertEqual(
           {error, {duplicate_option, "--apply"}},
           adk_cli:command(
             ["deploy", "gke", "--apply", "--apply",
              "--manifest", GkePath, "--context", "ctx",
              "--namespace", "agents"])),
        ?assertNotEqual(
           nomatch,
           binary:match(adk_cli:usage(), <<"adk deploy cloud_run">>))
    after
        _ = file:delete(CloudPath),
        _ = file:delete(GkePath)
    end.

read(Path) ->
    {ok, Body} = file:read_file(binary_to_list(Path)),
    Body.

contains_all(Body, Needles) ->
    lists:foreach(
      fun(Needle) ->
          ?assertNotEqual(nomatch, binary:match(Body, Needle))
      end, Needles).
