-module(adk_release_surface_contract_test).

-include_lib("eunit/include/eunit.hrl").

release_application_keeps_feature_modules_test() ->
    ok = ensure_application_loaded(),
    {ok, Modules} = application:get_key(erlang_adk, modules),
    FeatureAnchors =
        [erlang_adk,
         adk_agent, adk_agent_spec, adk_runner, adk_run,
         adk_workflow, adk_graph, adk_planning_runtime, adk_ambient,
         adk_graph_validate, adk_graph_ir, adk_graph_inspect,
         adk_tool, adk_openapi_toolset, adk_mcp_client,
         adk_artifact_service, adk_memory_service, adk_context,
         adk_auth_provider, adk_oidc_provider_sup,
         adk_a2a_v1_client, adk_dev_router,
         adk_plugin, adk_eval, adk_observability,
         adk_content, adk_live_session, adk_live_voice_bridge,
         adk_llm_gemini, adk_live_gemini,
         adk_llm_openai, adk_live_openai,
         adk_llm_anthropic, adk_llm_compatible,
         adk_llm_vertex, adk_vertex_model_resource,
         adk_provider_profile, adk_provider_registry,
         adk_provider_credential, adk_google_adc,
         adk_local_model_endpoint, adk_model_http_client],
    Expanded010Anchors =
        [%% Declarative agents and sealed operator registries.
         adk_agent_composition, adk_agent_config, adk_agent_yaml,
         adk_config_registry,
         %% Artifact streaming, object storage, and effect reconciliation.
         adk_artifact_gcs, adk_artifact_gcs_credential,
         adk_artifact_gcs_http_transport, adk_artifact_gcs_transport,
         adk_artifact_effect_journal, adk_artifact_orphan_reconciler,
         adk_artifact_reconcile_handler, adk_artifact_stream,
         adk_artifact_stream_sup, adk_artifact_stream_worker,
         %% Bounded developer, evaluation, and trace surfaces.
         adk_bounded_file, adk_dev_graph_catalog, adk_dev_payload_plugin,
         adk_dev_payload_store, adk_dev_trace_view,
         adk_eval_builtin_metric, adk_eval_dev_api, adk_eval_ensemble,
         adk_eval_environment_simulator, adk_eval_export, adk_eval_review,
         adk_eval_service, adk_eval_simulation, adk_eval_statistics,
         adk_eval_store, adk_eval_store_ets, adk_eval_store_mnesia,
         adk_eval_user_simulator, adk_eval_worker, adk_eval_worker_rpc,
         %% Long-term memory contracts, policy, vectors, and erasure fencing.
         adk_memory_embedding_provider, adk_memory_erasure_epoch,
         adk_memory_hybrid_adapter, adk_memory_policy,
         adk_memory_policy_static, adk_memory_vector_adapter,
         adk_memory_vector_ets,
         %% A2A and modern MCP protocol/runtime foundations.
         adk_a2a_v1_push, adk_a2a_v1_task_store,
         adk_a2a_v1_task_store_ets, adk_a2a_v1_task_store_mnesia,
         adk_mcp_catalog, adk_mcp_catalog_store, adk_mcp_oauth,
         adk_mcp_pool, adk_mcp_protocol, adk_mcp_protocol_legacy,
         adk_mcp_protocol_limits, adk_mcp_protocol_modern,
         adk_mcp_sse_stream,
         %% Runtime profiles, deployment health, tracing, and connector core.
         adk_health_handler, adk_deploy, adk_deployment_env,
         adk_deployment_lifecycle,
         adk_runtime_service_bundle, adk_runtime_service_profile,
         adk_trace_event, adk_trace_runtime, adk_trace_store,
         adk_trace_store_exporter, adk_connector_descriptor,
         adk_connector_manifest, adk_connector_toolset],
    ?assertEqual([], (FeatureAnchors ++ Expanded010Anchors) -- Modules),
    %% Recursive test discovery must never leak fixtures into the release
    %% application descriptor or Hex package.
    TestOnly = [adk_llm_dummy, adk_profile_llm_probe,
                adk_live_fake_transport, readme_examples_test],
    ?assertEqual([], [Module || Module <- TestOnly,
                               lists:member(Module, Modules)]).

release_application_version_is_current_test() ->
    ok = ensure_application_loaded(),
    ?assertEqual({ok, "0.10.0"},
                 application:get_key(erlang_adk, vsn)).

release_application_keeps_runtime_dependencies_test() ->
    ok = ensure_application_loaded(),
    {ok, Applications} = application:get_key(erlang_adk, applications),
    Expected = [kernel, stdlib, crypto, inets, ssl, public_key,
                cowboy, telemetry, jsx, gun, oidcc],
    ?assertEqual([], Expected -- Applications).

release_application_keeps_distribution_assets_test() ->
    RepoRoot = filename:dirname(filename:dirname(filename:dirname(?FILE))),
    AppSource = filename:join([RepoRoot, "src", "erlang_adk.app.src"]),
    {ok, [{application, erlang_adk, Properties}]} = file:consult(AppSource),
    Files = proplists:get_value(files, Properties, []),
    Expected = ["Dockerfile", "deploy", "rel", "scripts/deployment",
                "scripts/security", "docs"],
    ?assertEqual([], Expected -- Files),
    %% Connector integrations are independent packages and must not leak into
    %% the root erlang_adk Hex artifact.
    ?assertNot(lists:member("packages", Files)).

provider_profile_public_surface_test() ->
    assert_exports(
      adk_provider_profile,
      [{validate, 2}, {normalize, 2}, {resolve_model, 2},
       {request_config, 2}, {live_config, 2}]),
    assert_exports(
      adk_provider_registry,
      [{profiles, 0}, {lookup, 1}, {resolve, 1}, {resolve, 2},
       {resolve_config, 1}, {resolve_live, 2},
       {resolve_live_config, 2}]),
    assert_exports(
      adk_provider_credential,
      [{resolve, 1}, {resolve, 2}, {resolve_snapshot, 2},
       {describe, 1}]),
    assert_exports(
      adk_model_http_client,
      [{validate_options, 1}, {validate_https_base_url, 1},
       {request, 4}, {stream, 5}, {resolve_api_key, 2},
       {resolve_bound_api_key, 3}, {resolve_explicit_api_key, 1},
       {base_url_matches, 2}]),
    assert_exports(
      adk_model_sse_decoder,
      [{new, 0}, {new, 1}, {feed, 2}, {finish, 1}]),
    assert_exports(
      adk_google_adc,
      [{access_token, 1}, {validate_config, 1}]),
    assert_exports(
      adk_local_model_endpoint,
      [{normalize, 1}, {is_endpoint, 1}, {validate_profile, 5},
       {materialize, 1}, {validate_runtime, 1}]),
    assert_exports(
      adk_vertex_model_resource,
      [{parse, 1}, {generate_path, 1}, {stream_path, 1}]),
    assert_exports(
      adk_graph_inspect,
      [{describe, 1}, {to_dot, 1}, {to_mermaid, 1}]),
    assert_exports(adk_graph_ir, [{from_compiled, 1}, {from_data, 2}]),
    assert_exports(adk_graph_validate, [{validate, 1}, {analyze, 1}]).

graph_public_surface_test() ->
    assert_exports(
      adk_graph,
      [{new, 0}, {add_node, 3}, {add_edge, 3},
       {add_conditional_edge, 3}, {set_entry_point, 2},
       {compile, 1}, {run, 2}, {run, 3}, {to_workflow, 1},
       {describe, 1}, {to_dot, 1}, {to_mermaid, 1}]).

extension_behaviour_callbacks_remain_available_test() ->
    assert_callbacks(
      adk_llm,
      [{generate, 3}, {stream, 4}, {stream_content, 4},
       {capabilities, 0}, {capabilities, 1}, {validate_config, 1}]),
    assert_callbacks(
      adk_live_provider,
      [{capabilities, 0}, {validate_config, 1}, {setup_frame, 1},
       {resume_setup_frame, 2}, {encode_client, 2}, {decode_server, 2}]),
    assert_callbacks(
      adk_live_transport,
      [{open, 2}, {send, 2}, {close, 2}, {consumed, 2}]),
    assert_callbacks(
      adk_model_http_transport,
      [{request, 2}, {stream, 3}]),
    assert_callbacks(adk_openapi_http_transport, [{request, 2}]),
    assert_callbacks(
      adk_plugin,
      [{on_user_message, 3}, {before_run, 3}, {after_run, 3},
       {before_agent, 3}, {after_agent, 3},
       {before_model, 3}, {after_model, 3}, {on_model_error, 3},
       {before_tool, 3}, {after_tool, 3}, {on_tool_error, 3},
       {on_event, 3}, {on_agent_error, 3}, {on_run_error, 3},
       {on_error, 3}]),
    assert_callbacks(
      adk_eval_adapter,
      [{run_turn, 5}, {init_case, 4}, {terminate_case, 3}]).

ensure_application_loaded() ->
    case application:load(erlang_adk) of
        ok -> ok;
        {error, {already_loaded, erlang_adk}} -> ok
    end.

assert_exports(Module, Expected) ->
    ?assertEqual({module, Module}, code:ensure_loaded(Module)),
    Actual = Module:module_info(exports),
    ?assertEqual([], Expected -- Actual).

assert_callbacks(Module, Expected) ->
    ?assertEqual({module, Module}, code:ensure_loaded(Module)),
    Actual = Module:behaviour_info(callbacks),
    ?assertEqual([], Expected -- Actual).
