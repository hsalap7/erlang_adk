-module(adk_release_surface_contract_test).

-include_lib("eunit/include/eunit.hrl").

release_application_keeps_feature_modules_test() ->
    ok = ensure_application_loaded(),
    {ok, Modules} = application:get_key(erlang_adk, modules),
    FeatureAnchors =
        [erlang_adk,
         adk_agent, adk_agent_spec, adk_runner, adk_run,
         adk_workflow, adk_planning_runtime, adk_ambient,
         adk_tool, adk_openapi_toolset, adk_mcp_client,
         adk_artifact_service, adk_memory_service, adk_context,
         adk_auth_provider, adk_oidc_provider_sup,
         adk_a2a_v1_client, adk_dev_router,
         adk_plugin, adk_eval, adk_observability,
         adk_content, adk_live_session, adk_live_voice_bridge,
         adk_llm_gemini, adk_live_gemini,
         adk_llm_openai, adk_live_openai,
         adk_llm_anthropic, adk_llm_compatible,
         adk_provider_profile, adk_provider_registry,
         adk_provider_credential, adk_model_http_client],
    ?assertEqual([], FeatureAnchors -- Modules),
    %% Recursive test discovery must never leak fixtures into the release
    %% application descriptor or Hex package.
    TestOnly = [adk_llm_dummy, adk_profile_llm_probe,
                adk_live_fake_transport, readme_examples_test],
    ?assertEqual([], [Module || Module <- TestOnly,
                               lists:member(Module, Modules)]).

release_application_keeps_runtime_dependencies_test() ->
    ok = ensure_application_loaded(),
    {ok, Applications} = application:get_key(erlang_adk, applications),
    Expected = [kernel, stdlib, crypto, inets, ssl, public_key,
                cowboy, telemetry, jsx, gun, oidcc],
    ?assertEqual([], Expected -- Applications).

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
      [{new, 0}, {new, 1}, {feed, 2}, {finish, 1}]).

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
