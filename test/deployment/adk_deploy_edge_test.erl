-module(adk_deploy_edge_test).

-include_lib("eunit/include/eunit.hrl").

validation_boundary_matrix_test() ->
    with_manifests(
      fun(Cloud, Gke, Empty, Invalid, Nul) ->
          ?assertEqual({error, invalid_deploy_options},
                       adk_deploy:cloud_run(not_a_map)),
          ?assertEqual({error, invalid_deploy_options},
                       adk_deploy:gke(not_a_map)),
          ?assertEqual({error, deployment_manifest_required},
                       adk_deploy:cloud_run(
                         #{project => <<"project">>,
                           region => <<"us-central1">>})),
          ?assertEqual({error, deployment_manifest_required},
                       adk_deploy:gke(
                         #{context => <<"context">>,
                           namespace => <<"agents">>})),
          ?assertEqual({error, {unknown_deploy_options, [extra]}},
                       adk_deploy:cloud_run(
                         #{manifest => Cloud, project => <<"project">>,
                           region => <<"us-central1">>, extra => true})),
          ?assertEqual({error, {unknown_deploy_options, [extra]}},
                       adk_deploy:gke(
                         #{manifest => Gke, context => <<"context">>,
                           namespace => <<"agents">>, extra => true})),
          ?assertEqual({error, invalid_deployment_manifest_path},
                       adk_deploy:cloud_run(
                         cloud_options(make_ref()))),
          ?assertEqual({error, invalid_deployment_manifest_path},
                       adk_deploy:gke(gke_options(<<0>>))),
          ?assertMatch({error, {deployment_manifest, _}},
                       adk_deploy:cloud_run(
                         cloud_options(<<"/definitely/missing/adk.yaml">>))),
          ?assertEqual({error, invalid_deployment_manifest},
                       adk_deploy:cloud_run(cloud_options(Empty))),
          ?assertEqual({error, invalid_deployment_manifest},
                       adk_deploy:cloud_run(cloud_options(Invalid))),
          ?assertEqual({error, invalid_deployment_manifest},
                       adk_deploy:gke(gke_options(Nul))),
          ?assertEqual({error, invalid_deployment_apply_flag},
                       adk_deploy:cloud_run(
                         (cloud_options(Cloud))#{apply => <<"true">>})),
          ?assertEqual({error, {invalid_deployment_target, project}},
                       adk_deploy:cloud_run(
                         (cloud_options(Cloud))#{project => <<"bad/project">>})),
          ?assertEqual({error, {invalid_deployment_target, region}},
                       adk_deploy:cloud_run(
                         (cloud_options(Cloud))#{region => <<"US-CENTRAL1">>})),
          ?assertEqual({error, {invalid_deployment_target, context}},
                       adk_deploy:gke(
                         (gke_options(Gke))#{context => <<"bad context">>})),
          ?assertEqual({error, {invalid_deployment_target, namespace}},
                       adk_deploy:gke(
                         (gke_options(Gke))#{namespace => <<"bad_name">>})),
          {ok, CloudPlan} = adk_deploy:cloud_run(cloud_options(Cloud)),
          ?assertEqual(validate_only, maps:get(mode, CloudPlan)),
          ?assertEqual(false, maps:get(apply, CloudPlan)),
          ?assertEqual(64, byte_size(maps:get(manifest_sha256, CloudPlan))),
          {ok, GkePlan} = adk_deploy:gke(gke_options(binary_to_list(Gke))),
          ?assertEqual(validate_only, maps:get(mode, GkePlan))
      end).

apply_boundary_uses_exact_executable_and_context_test() ->
    with_fake_path(
      fun(Cloud, Gke) ->
          put_env("ADK_DEPLOY_TEST_CONTEXT", "edge-context"),
          put_env("ADK_DEPLOY_TEST_EXIT", "0"),
          {ok, CloudApplied} = adk_deploy:cloud_run(
                                 (cloud_options(Cloud))#{apply => true}),
          ?assertEqual(applied, maps:get(mode, CloudApplied)),
          ?assertEqual(true, maps:get(apply, CloudApplied)),
          {ok, GkeApplied} = adk_deploy:gke(
                               (gke_options(Gke))#{apply => true}),
          ?assertEqual(applied, maps:get(mode, GkeApplied)),

          put_env("ADK_DEPLOY_TEST_CONTEXT", "other-context"),
          ?assertEqual(deployment_context_mismatch,
                       error_reason(
                         adk_deploy:gke(
                           (gke_options(Gke))#{apply => true})))
      end).

apply_command_failures_are_content_free_test() ->
    with_fake_path(
      fun(Cloud, Gke) ->
          put_env("ADK_DEPLOY_TEST_CONTEXT", "edge-context"),
          put_env("ADK_DEPLOY_TEST_EXIT", "7"),
          ?assertEqual({deployment_command_failed, 7},
                       error_reason(
                         adk_deploy:cloud_run(
                           (cloud_options(Cloud))#{apply => true}))),
          ?assertEqual({deployment_command_failed, 7},
                       error_reason(
                         adk_deploy:gke(
                           (gke_options(Gke))#{apply => true})))
      end).

missing_apply_executables_fail_without_mutation_test() ->
    with_manifests(
      fun(Cloud, Gke, _Empty, _Invalid, _Nul) ->
          PreviousPath = os:getenv("PATH"),
          try
              true = os:putenv("PATH", "/definitely/missing"),
              ?assertEqual(
                 {error, {deployment_executable_unavailable, <<"gcloud">>}},
                 adk_deploy:cloud_run(
                   (cloud_options(Cloud))#{apply => true})),
              ?assertEqual(
                 {error, {deployment_executable_unavailable, <<"kubectl">>}},
                 adk_deploy:gke((gke_options(Gke))#{apply => true}))
          after
              restore_os_env("PATH", PreviousPath)
          end
      end).

cloud_options(Manifest) ->
    #{manifest => Manifest, project => <<"example.project:edge-1">>,
      region => <<"us-central1">>}.

gke_options(Manifest) ->
    #{manifest => Manifest, context => <<"edge-context">>,
      namespace => <<"agent-runtime">>}.

with_fake_path(Fun) ->
    PreviousPath = os:getenv("PATH"),
    PreviousContext = os:getenv("ADK_DEPLOY_TEST_CONTEXT"),
    PreviousExit = os:getenv("ADK_DEPLOY_TEST_EXIT"),
    with_manifests(
      fun(Cloud, Gke, _Empty, _Invalid, _Nul) ->
          Dir = temp_dir("adk-deploy-bin"),
          Script =
              <<"#!/bin/sh\n"
                "if [ \"$1\" = \"config\" ]; then\n"
                "  printf '%s\\n' \"${ADK_DEPLOY_TEST_CONTEXT:-edge-context}\"\n"
                "  exit 0\n"
                "fi\n"
                "exit \"${ADK_DEPLOY_TEST_EXIT:-0}\"\n">>,
          Gcloud = filename:join(Dir, "gcloud"),
          Kubectl = filename:join(Dir, "kubectl"),
          ok = file:write_file(Gcloud, Script),
          ok = file:write_file(Kubectl, Script),
          ok = file:change_mode(Gcloud, 8#700),
          ok = file:change_mode(Kubectl, 8#700),
          try
              Path = case PreviousPath of
                  false -> Dir;
                  Value -> Dir ++ ":" ++ Value
              end,
              true = os:putenv("PATH", Path),
              Fun(Cloud, Gke)
          after
              restore_os_env("PATH", PreviousPath),
              restore_os_env("ADK_DEPLOY_TEST_CONTEXT", PreviousContext),
              restore_os_env("ADK_DEPLOY_TEST_EXIT", PreviousExit),
              _ = file:delete(Gcloud),
              _ = file:delete(Kubectl),
              _ = file:del_dir(Dir)
          end
      end).

with_manifests(Fun) ->
    Dir = temp_dir("adk-deploy-manifests"),
    Cloud = filename:join(Dir, "cloud.yaml"),
    Gke = filename:join(Dir, "gke.yaml"),
    Empty = filename:join(Dir, "empty.yaml"),
    Invalid = filename:join(Dir, "invalid.yaml"),
    Nul = filename:join(Dir, "nul.yaml"),
    ok = file:write_file(
           Cloud,
           <<"apiVersion: serving.knative.dev/v1\nkind: Service\n">>),
    ok = file:write_file(
           Gke,
           <<"apiVersion: apps/v1\nkind: Deployment\n">>),
    ok = file:write_file(Empty, <<>>),
    ok = file:write_file(Invalid, <<"kind: Service\n">>),
    ok = file:write_file(
           Nul, <<"apiVersion: apps/v1\nkind: Deployment\n", 0>>),
    try Fun(list_to_binary(Cloud), list_to_binary(Gke),
            list_to_binary(Empty), list_to_binary(Invalid),
            list_to_binary(Nul))
    after
        lists:foreach(fun file:delete/1,
                      [Cloud, Gke, Empty, Invalid, Nul]),
        _ = file:del_dir(Dir)
    end.

temp_dir(Prefix) ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Dir = filename:join(
            Base, Prefix ++ "-" ++
                  integer_to_list(
                    erlang:unique_integer([positive, monotonic]))),
    ok = file:make_dir(Dir),
    Dir.

put_env(Name, Value) ->
    true = os:putenv(Name, Value),
    ok.

restore_os_env(Name, false) -> os:unsetenv(Name);
restore_os_env(Name, Value) -> os:putenv(Name, Value).

error_reason({error, Reason}) -> Reason.
