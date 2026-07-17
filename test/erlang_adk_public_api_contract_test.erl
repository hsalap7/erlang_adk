-module(erlang_adk_public_api_contract_test).

-include_lib("eunit/include/eunit.hrl").

documented_facade_exports_remain_available_test() ->
    assert_exports(
      erlang_adk,
      [{spawn_agent, 3}, {stop_agent, 1}, {prompt, 2}, {invoke, 3},
       {delegate, 2}, {delegate, 3}, {delegate, 4},
       {sequential, 2}, {parallel, 2}, {parallel, 3}, {loop, 4},
       {compile_workflow, 1},
       {start_workflow, 2}, {start_workflow, 3},
       {run_workflow, 2}, {run_workflow, 3},
       {await_workflow, 1}, {await_workflow, 2},
       {cancel_workflow, 1}, {cancel_workflow, 2},
       {workflow_status, 1}, {workflow_checkpoint, 1},
       {resume_workflow, 2}, {resume_workflow, 3},
       {start_workflow_invocation, 3},
       {resume_workflow_invocation, 3},
       {workflow_invocation_status, 2},
       {delete_workflow_invocation, 2},
       {run_planning, 4}, {run_planning, 5},
       {start_planning, 4}, {start_planning, 5},
       {await_planning, 1}, {await_planning, 2},
       {cancel_planning, 1}, {cancel_planning, 2},
       {start_live_session, 3},
       {live_send_text, 3}, {live_send_audio, 3},
       {live_send_video_frame, 3},
       {live_activity_start, 2}, {live_activity_end, 2},
       {live_audio_stream_end, 2}, {live_send_tool_response, 5},
       {live_subscribe, 3}, {live_subscribe, 4},
       {live_ack, 3}, {live_ack, 4},
       {live_unsubscribe, 2}, {live_unsubscribe, 3},
       {live_status, 2}, {live_status, 3},
       {close_live_session, 3},
       {start_live_voice_bridge, 4}, {live_voice_frame, 2},
       {stop_live_voice_bridge, 1}]).

provider_neutral_dispatch_exports_remain_available_test() ->
    assert_exports(
      adk_llm,
      [{generate, 3}, {stream, 4}, {stream_content, 4},
       {capabilities, 1}, {validate_config, 1}]).

supported_model_provider_contracts_remain_available_test() ->
    Common = [{generate, 3}, {stream, 4}, {stream_content, 4},
              {capabilities, 0}, {validate_config, 1},
              {public_config, 1}],
    [assert_exports(Module, Common)
     || Module <- [adk_llm_gemini, adk_llm_openai,
                   adk_llm_anthropic, adk_llm_compatible]],
    assert_exports(adk_llm_compatible, [{capabilities, 1}]).

supported_bidirectional_provider_contracts_remain_available_test() ->
    Common = [{model, 0}, {capabilities, 0}, {validate_config, 1},
              {transport, 0}, {setup_frame, 1},
              {encode_client, 2}, {decode_server, 2}],
    assert_exports(adk_live_gemini, [{resume_setup_frame, 2} | Common]),
    assert_exports(adk_live_openai, Common).

assert_exports(Module, Expected) ->
    ?assertEqual({module, Module}, code:ensure_loaded(Module)),
    Actual = Module:module_info(exports),
    ?assertEqual([], Expected -- Actual).
