-module(adk_agent_runtime_spec_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"agent_spec_runtime_app">>).
-define(USER, <<"agent_spec_runtime_user">>).

agent_runtime_spec_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun runner_applies_instruction_history_generation_and_output_contract/0,
      fun direct_agent_uses_scoped_state_and_commits_output_key/0,
      fun invocation_output_key_uses_caller_session_scope/0,
      fun invalid_input_never_reaches_the_provider/0,
      fun after_agent_replacement_rebuilds_output_delta/0,
      fun before_agent_short_circuit_cannot_bypass_output_schema/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_) ->
    lists:foreach(
      fun(SessionId) ->
          _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
      end,
      [<<"contract">>, <<"direct-contract">>, <<"bad-input">>,
       <<"configured-scope">>, <<"invocation-scope">>,
       <<"callback-delta">>,
       <<"callback-invalid">>]),
    flush_probe_messages(),
    ok.

runner_applies_instruction_history_generation_and_output_contract() ->
    SessionId = <<"contract">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => SessionId,
                  state => #{<<"user:name">> => <<"Ada">>}}),
    Old = adk_event:new(<<"user">>, <<"old turn">>,
                        #{invocation_id => <<"old-invocation">>}),
    ok = erlang_adk_session:add_event(?APP, ?USER, SessionId, Old),
    Config = #{provider => adk_llm_agent_spec_probe,
               test_pid => self(),
               instructions => <<"Answer {user:name}.">>,
               input_schema => #{type => string, minLength => 1},
               output_schema => object_schema(<<"answer">>),
               output_key => <<"user:last_answer">>,
               history_policy => exclude,
               generation_config => #{temperature => 0.25,
                                        max_output_tokens => 64,
                                        thinking_config =>
                                            #{thinking_level => low}},
               response => <<"{\"answer\":\"OTP\"}">>},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "AgentSpecRuntimeContract", Config, []),
    try
        Runner = adk_runner:new(Agent, ?APP, erlang_adk_session),
        {ok, Response} = adk_runner:run(
                           Runner, ?USER, SessionId, <<"Why Erlang?">>),
        ?assertEqual(#{<<"answer">> => <<"OTP">>},
                     jsx:decode(Response, [return_maps])),
        receive
            {agent_spec_probe, EffectiveConfig, History, []} ->
                ?assertEqual(0.25, maps:get(temperature, EffectiveConfig)),
                ?assertEqual(64, maps:get(max_tokens, EffectiveConfig)),
                ?assertEqual(#{thinking_level => low},
                             maps:get(thinking_config, EffectiveConfig)),
                ?assertEqual(<<"application/json">>,
                             maps:get(response_mime_type, EffectiveConfig)),
                ?assertEqual(
                   [system, user],
                   [maps:get(role, Message) || Message <- History]),
                [System, Current] = History,
                ?assertEqual(<<"Answer Ada.">>, maps:get(content, System)),
                ?assertEqual(<<"Why Erlang?">>, maps:get(content, Current)),
                ?assertNot(lists:any(
                             fun(#{content := <<"old turn">>}) -> true;
                                (_) -> false
                             end, History))
        after 1000 ->
            ?assert(false)
        end,
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Expected = #{<<"answer">> => <<"OTP">>},
        ?assertEqual(Expected,
                     maps:get(<<"user:last_answer">>,
                              maps:get(state, Session))),
        Final = lists:last(maps:get(events, Session)),
        ?assertEqual(
           #{<<"user:last_answer">> => Expected},
           maps:get(<<"state_delta">>, Final#adk_event.actions))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

direct_agent_uses_scoped_state_and_commits_output_key() ->
    SessionId = <<"direct-contract">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => SessionId,
                  state => #{<<"user:name">> => <<"Lin">>}}),
    Config = #{provider => adk_llm_agent_spec_probe,
               test_pid => self(),
               app_name => ?APP,
               user_id => ?USER,
               session_id => SessionId,
               instructions => <<"Write for {user:name}.">>,
               output_schema => #{type => string, minLength => 1},
               output_key => <<"direct_answer">>,
               response => <<"supervised processes">>},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "AgentSpecDirectContract", Config, []),
    try
        ?assertEqual({ok, <<"supervised processes">>},
                     erlang_adk:prompt(Agent, <<"Why OTP?">>)),
        receive
            {agent_spec_probe, _EffectiveConfig, History, []} ->
                ?assert(lists:any(
                          fun(#{role := system,
                                content := <<"Write for Lin.">>}) -> true;
                             (_) -> false
                          end, History))
        after 1000 ->
            ?assert(false)
        end,
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        ?assertEqual(<<"supervised processes">>,
                     maps:get(<<"direct_answer">>, maps:get(state, Session)))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = erlang_adk_session:delete(SessionId)
    end.

invocation_output_key_uses_caller_session_scope() ->
    ConfiguredSession = <<"configured-scope">>,
    InvocationSession = <<"invocation-scope">>,
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => ConfiguredSession,
                  state => #{<<"owner">> => <<"configured">>}}),
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER,
                #{session_id => InvocationSession,
                  state => #{<<"owner">> => <<"invocation">>}}),
    Config = #{provider => adk_llm_agent_spec_probe,
               test_pid => self(),
               app_name => ?APP,
               user_id => ?USER,
               session_id => ConfiguredSession,
               output_key => <<"delegated_answer">>,
               response => <<"caller scoped">>},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "AgentSpecInvocationScope", Config, []),
    Context = #{app_name => ?APP,
                user_id => ?USER,
                session_id => InvocationSession,
                state_ref => erlang_adk_session,
                state => #{<<"owner">> => <<"invocation">>}},
    try
        ?assertEqual({ok, <<"caller scoped">>},
                     erlang_adk:invoke(
                       Agent, <<"write in this session">>, Context)),
        receive
            {agent_spec_probe, _EffectiveConfig, _History, []} -> ok
        after 1000 ->
            ?assert(false)
        end,
        {ok, Configured} = erlang_adk_session:get_session(
                             ?APP, ?USER, ConfiguredSession),
        {ok, Invoked} = erlang_adk_session:get_session(
                          ?APP, ?USER, InvocationSession),
        ?assertEqual(false,
                     maps:is_key(<<"delegated_answer">>,
                                 maps:get(state, Configured))),
        ?assertEqual(<<"caller scoped">>,
                     maps:get(<<"delegated_answer">>,
                              maps:get(state, Invoked)))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

invalid_input_never_reaches_the_provider() ->
    SessionId = <<"bad-input">>,
    Config = #{provider => adk_llm_agent_spec_probe,
               test_pid => self(),
               input_schema => object_schema(<<"question">>),
               response => <<"should not run">>},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "AgentSpecRuntimeBadInput", Config, []),
    try
        Runner = adk_runner:new(Agent, ?APP, erlang_adk_session),
        Result = adk_runner:run(
                   Runner, ?USER, SessionId, <<"not an object">>),
        ?assertMatch(
           {error, {input_schema_failed,
                    {schema_validation_failed, [],
                     {expected_type, <<"object">>}}}},
           Result),
        receive {agent_spec_probe, _, _, _} -> ?assert(false)
        after 30 -> ok
        end
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

after_agent_replacement_rebuilds_output_delta() ->
    SessionId = <<"callback-delta">>,
    Config = #{provider => adk_llm_agent_spec_probe,
               response => <<"original response">>,
               output_schema => #{type => string, minLength => 1},
               output_key => <<"last_callback_value">>,
               callbacks => [adk_agent_history_callback]},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "AgentSpecRuntimeCallbackDelta", Config, []),
    try
        Runner = adk_runner:new(Agent, ?APP, erlang_adk_session),
        ?assertEqual(
           {ok, <<"replacement response">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"replace it">>)),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        ?assertEqual(<<"replacement response">>,
                     maps:get(<<"last_callback_value">>,
                              maps:get(state, Session))),
        Final = lists:last(maps:get(events, Session)),
        ?assertEqual(
           #{<<"last_callback_value">> => <<"replacement response">>},
           maps:get(<<"state_delta">>, Final#adk_event.actions))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

before_agent_short_circuit_cannot_bypass_output_schema() ->
    SessionId = <<"callback-invalid">>,
    Config = #{provider => adk_llm_agent_spec_probe,
               test_pid => self(),
               response => <<"provider must not run">>,
               output_schema => #{type => string},
               output_key => <<"callback_value">>,
               callbacks => [adk_agent_history_callback]},
    {ok, Agent} = erlang_adk:spawn_agent(
                    "AgentSpecRuntimeCallbackInvalid", Config, []),
    try
        Runner = adk_runner:new(Agent, ?APP, erlang_adk_session),
        ?assertMatch(
           {error, {output_schema_failed,
                    {schema_validation_failed, [],
                     {expected_type, <<"string">>}}}},
           adk_runner:run(Runner, ?USER, SessionId, <<"map response">>)),
        receive {agent_spec_probe, _, _, _} -> ?assert(false)
        after 30 -> ok
        end,
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        ?assertEqual(error,
                     maps:find(<<"callback_value">>, maps:get(state, Session)))
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

object_schema(RequiredName) ->
    #{type => object,
      properties => #{RequiredName => #{type => string, minLength => 1}},
      required => [RequiredName],
      additionalProperties => false}.

flush_probe_messages() ->
    receive
        {agent_spec_probe, _, _, _} -> flush_probe_messages();
        {agent_spec_stream_probe, _, _, _} -> flush_probe_messages()
    after 0 ->
        ok
    end.
