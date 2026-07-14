-module(adk_agent_spec_test).

-include_lib("eunit/include/eunit.hrl").

validated_immutable_spec_test() ->
    InputSchema = object_schema(<<"question">>),
    OutputSchema = object_schema(<<"answer">>),
    {ok, Spec} = adk_agent_spec:compile(
                   #{instructions => <<"Answer {user:name}.">>,
                     input_schema => InputSchema,
                     output_schema => OutputSchema,
                     generation_config => #{temperature => 0.2,
                                             max_output_tokens => 128,
                                             stop_sequences => [<<"STOP">>],
                                             thinking_config =>
                                                 #{thinking_level => high}},
                     history_policy => exclude,
                     output_key => <<"user:last_answer">>,
                     required_capabilities => [function_calling]}),
    ?assertEqual([function_calling, generation_config, structured_output,
                  thinking],
                 adk_agent_spec:required_capabilities(Spec)),
    ?assertEqual(
       ok,
       adk_agent_spec:check_capabilities(
         Spec, #{function_calling => true,
                 generation_config => true,
                 structured_output => true,
                 thinking => true})),
    ?assertEqual(
       {error, {missing_capabilities, [structured_output, thinking]}},
       adk_agent_spec:check_capabilities(
         Spec, #{function_calling => true, generation_config => true})),
    {ok, Prepared} = adk_agent_spec:prepare(
                       Spec, #{question => <<"Why OTP?">>},
                       [old_event],
                       #{state => #{<<"user:name">> => <<"Ada">>}}),
    ?assertEqual([], maps:get(history, Prepared)),
    ?assertEqual(<<"Answer Ada.">>, maps:get(instructions, Prepared)),
    ?assertEqual(128,
                 maps:get(max_tokens,
                          maps:get(generation_config, Prepared))).

from_config_never_retains_provider_credentials_test() ->
    Secret = <<"provider-key-that-must-not-be-retained">>,
    Config = #{provider => adk_llm_gemini,
               model => <<"gemini-3.1-flash-lite">>,
               api_key => Secret,
               base_url => <<"https://example.invalid">>,
               instructions => <<"Be concise.">>,
               temperature => 0.1,
               thinking_config => #{thinking_level => low},
               response_schema => object_schema(<<"answer">>)},
    {ok, Spec} = adk_agent_spec:from_config(Config),
    ?assertEqual(nomatch, binary:match(term_to_binary(Spec), Secret)),
    ?assertEqual([generation_config, structured_output, thinking],
                 adk_agent_spec:required_capabilities(Spec)).

configuration_validation_is_typed_test() ->
    ?assertEqual({error, unsupported_agent_spec_options},
                 adk_agent_spec:compile(#{unknown_feature => true})),
    ?assertEqual({error, {invalid_generation_option, temperature}},
                 adk_agent_spec:compile(
                   #{generation_config => #{temperature => 5}})),
    ?assertEqual({error, {invalid_generation_option, thinking_config}},
                 adk_agent_spec:compile(
                   #{generation_config =>
                         #{thinking_config =>
                               #{thinking_level => low,
                                 thinking_budget => 100}}})),
    ?assertEqual({error, invalid_history_policy},
                 adk_agent_spec:compile(
                   #{history_policy => include, include_history => false})),
    ?assertEqual({error, invalid_output_key},
                 adk_agent_spec:compile(#{output_key => <<"api_key">>})),
    ?assertMatch(
       {error, {output_schema_failed,
                {invalid_json_schema, [<<"unsupported">>],
                 unsupported_keyword}}},
       adk_agent_spec:compile(
         #{output_schema => #{unsupported => true}})).

safety_settings_require_provider_capability_test() ->
    Safety = [#{category => dangerous_content,
                threshold => block_medium_and_above}],
    {ok, Spec} = adk_agent_spec:compile(
                   #{generation_config => #{safety_settings => Safety}}),
    ?assertEqual([generation_config, safety_settings],
                 adk_agent_spec:required_capabilities(Spec)),
    ?assertEqual(
       {error, {missing_capabilities, [safety_settings]}},
       adk_agent_spec:check_capabilities(
         Spec, #{generation_config => true})),
    ?assertEqual(
       {error, {invalid_generation_option, safety_settings}},
       adk_agent_spec:compile(
         #{generation_config =>
               #{safety_settings =>
                     [#{category => dangerous_content,
                        threshold => unsupported}]}})).

input_schema_success_and_failure_test() ->
    {ok, Spec} = adk_agent_spec:compile(
                   #{input_schema => object_schema(<<"question">>)}),
    {ok, Canonical} = adk_agent_spec:validate_input(
                        Spec, #{question => <<"What is OTP?">>}),
    ?assertEqual(<<"What is OTP?">>, maps:get(<<"question">>, Canonical)),
    {ok, Decoded} = adk_agent_spec:validate_input(
                      Spec, <<"{\"question\":\"Why Erlang?\"}">>),
    ?assertEqual(<<"Why Erlang?">>, maps:get(<<"question">>, Decoded)),
    ?assertMatch(
       {error, {input_schema_failed,
                {schema_validation_failed, [],
                 {required_property, <<"question">>}}}},
       adk_agent_spec:validate_input(Spec, #{})),
    ?assertMatch(
       {error, {input_schema_failed,
                {schema_validation_failed, [<<"question">>],
                 {expected_type, <<"string">>}}}},
       adk_agent_spec:validate_input(Spec, #{question => 42})).

output_schema_and_atomic_output_key_test() ->
    {ok, Spec} = adk_agent_spec:compile(
                   #{output_schema => object_schema(<<"answer">>),
                     output_key => <<"user:last_answer">>}),
    {ok, Output, Delta} = adk_agent_spec:finalize(
                            Spec, <<"{\"answer\":\"Processes\"}">>),
    ?assertEqual(#{<<"answer">> => <<"Processes">>}, Output),
    ?assertEqual(#{<<"user:last_answer">> => Output}, Delta),
    %% A rejected result returns no partially-applicable state delta.
    ?assertMatch(
       {error, {output_schema_failed,
                {schema_validation_failed, [<<"answer">>],
                 {expected_type, <<"string">>}}}},
       adk_agent_spec:finalize(Spec, #{answer => 17})).

static_template_reads_only_scoped_state_and_artifacts_test() ->
    Secret = <<"state-secret-must-not-escape">>,
    Scope = {session, <<"app">>, <<"user">>, <<"session">>},
    OtherScope = {session, <<"app">>, <<"other-user">>, <<"session">>},
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    try
        {ok, _} = adk_artifact_ets:put(
                    ArtifactPid, Scope, <<"guide.txt">>,
                    <<"SAFE GUIDE">>, #{mime_type => <<"text/plain">>}),
        {ok, _} = adk_artifact_ets:put(
                    ArtifactPid, OtherScope, <<"guide.txt">>,
                    Secret, #{mime_type => <<"text/plain">>}),
        {ok, Spec} = adk_agent_spec:compile(
                       #{instructions =>
                           <<"Hello {{user:name}}; {artifact.guide.txt}; "
                             "{temp:optional?}">>}),
        {ok, Prepared} = adk_agent_spec:prepare(
                           Spec, <<"hello">>, [],
                           #{state => #{<<"user:name">> => <<"Grace">>,
                                        <<"api_key">> => Secret,
                                        <<"nested">> =>
                                            #{<<"client_secret">> => Secret}},
                             artifact_service =>
                                 {adk_artifact_ets, ArtifactPid},
                             artifact_scope => Scope,
                             credential_ref => Secret}),
        Instructions = maps:get(instructions, Prepared),
        ?assertEqual(<<"Hello Grace; SAFE GUIDE; ">>, Instructions),
        ?assertEqual(nomatch, binary:match(Instructions, Secret))
    after
        ok = adk_artifact_ets:stop(ArtifactPid)
    end.

dynamic_instruction_receives_sanitized_context_test() ->
    Secret = <<"dynamic-state-secret">>,
    Scope = {session, <<"app">>, <<"user">>, <<"session">>},
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    try
        {ok, _} = adk_artifact_ets:put(
                    ArtifactPid, Scope, <<"guide.txt">>, <<"GUIDE">>, #{}),
        {ok, Spec} = adk_agent_spec:compile(
                       #{instructions =>
                           {dynamic, adk_agent_spec_instruction_provider,
                            scoped}}),
        {ok, Prepared} = adk_agent_spec:prepare(
                           Spec, <<"hello">>, [],
                           #{state => #{<<"user:name">> => <<"Lin">>,
                                        <<"api_key">> => Secret},
                             app_name => <<"app">>,
                             user_id => <<"user">>,
                             session_id => <<"session">>,
                             artifact_service =>
                                 {adk_artifact_ets, ArtifactPid},
                             artifact_scope => Scope,
                             credential_ref => Secret}),
        Instructions = maps:get(instructions, Prepared),
        ?assertEqual(<<"Dynamic hello Lin; GUIDE">>, Instructions),
        ?assertEqual(nomatch, binary:match(Instructions, Secret))
    after
        ok = adk_artifact_ets:stop(ArtifactPid)
    end.

dynamic_callback_timeout_is_bounded_and_cancelled_test() ->
    Probe = ets:new(adk_agent_spec_callback_probe,
                    [named_table, public, set]),
    try
        {ok, Spec} = adk_agent_spec:compile(
                       #{instructions =>
                           {dynamic, adk_agent_spec_instruction_provider,
                            times_out},
                         instruction_timeout_ms => 20}),
        StartedAt = erlang:monotonic_time(millisecond),
        ?assertEqual(
           {error, instruction_callback_timeout},
           adk_agent_spec:prepare(Spec, <<"hello">>, [], #{state => #{}})),
        Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
        ?assert(Elapsed < 200),
        ?assertMatch([{started, _}], ets:lookup(Probe, started)),
        timer:sleep(280),
        ?assertEqual([], ets:lookup(Probe, finished))
    after
        true = ets:delete(Probe)
    end.

dynamic_callback_failures_are_safe_values_test() ->
    {ok, CrashSpec} = adk_agent_spec:compile(
                        #{instructions =>
                            {dynamic, adk_agent_spec_instruction_provider,
                             crashes}}),
    CrashResult = adk_agent_spec:prepare(
                    CrashSpec, <<"hello">>, [], #{state => #{}}),
    ?assertEqual({error, instruction_callback_failed}, CrashResult),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(CrashResult),
                              <<"must-never-escape">>)),
    {ok, ErrorSpec} = adk_agent_spec:compile(
                        #{instructions =>
                            {dynamic, adk_agent_spec_instruction_provider,
                             returns_error}}),
    ?assertEqual({error, instruction_callback_error},
                 adk_agent_spec:prepare(
                   ErrorSpec, <<"hello">>, [], #{state => #{}})),
    {ok, InvalidSpec} = adk_agent_spec:compile(
                          #{instructions =>
                              {dynamic, adk_agent_spec_instruction_provider,
                               invalid_result}}),
    ?assertEqual({error, invalid_instruction_callback_result},
                 adk_agent_spec:prepare(
                   InvalidSpec, <<"hello">>, [], #{state => #{}})).

secret_template_keys_are_rejected_test() ->
    ?assertEqual(
       {error, {secret_template_key, <<"api_key">>}},
       adk_agent_spec:compile(
         #{instructions => <<"Never interpolate {api_key}">>})),
    ?assertEqual(
       {error, {secret_template_key, <<"user:auth_token">>}},
       adk_agent_spec:compile(
         #{instructions => <<"Never interpolate {user:auth_token}">>})),
    ?assertEqual(
       {error, {secret_template_key, <<"client_secret">>}},
       adk_agent_spec:compile(
         #{instructions => <<"Never load {artifact.client_secret}">>})).

object_schema(RequiredName) ->
    #{type => object,
      properties => #{RequiredName => #{type => string, minLength => 1}},
      required => [RequiredName],
      additionalProperties => false}.
