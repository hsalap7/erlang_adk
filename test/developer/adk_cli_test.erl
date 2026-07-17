-module(adk_cli_test).

-include_lib("eunit/include/eunit.hrl").

-define(CLI_DEV_TOKEN, "cli-test-dev-token-0123456789abcdef").

cli_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun command_dispatch_contract_case/0,
      fun doctor_redacts_environment_case/0,
      fun doctor_missing_credentials_case/0,
      fun checked_config_validation_case/0,
      fun rich_gemini_config_translation_case/0,
      fun native_provider_config_validation_case/0,
      fun configured_profile_precedes_builtin_cli_alias_case/0,
      fun config_error_contracts_case/0,
      fun checked_repository_examples_case/0,
      fun config_rejects_embedded_secret_case/0,
      fun deterministic_run_case/0,
      fun deterministic_console_case/0,
      fun console_control_contracts_case/0,
      fun deterministic_evaluation_case/0,
      fun versioned_evaluation_case/0,
      fun evaluation_validation_contracts_case/0,
      fun option_and_url_validation_case/0,
      fun remote_command_validation_contracts_case/0,
      fun developer_connection_failure_is_structured_case/0,
      fun oversized_chunked_developer_success_is_bounded_case/0,
      fun oversized_chunked_developer_error_is_bounded_case/0,
      fun successful_developer_commands_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_State) ->
    ok.

command_dispatch_contract_case() ->
    Usage = adk_cli:usage(),
    ?assertEqual({ok, Usage}, adk_cli:command([])),
    ?assertEqual({ok, Usage}, adk_cli:command(["help"])),
    ?assertEqual({ok, Usage}, adk_cli:command(["--help"])),
    ?assertNotEqual(nomatch, binary:match(Usage, <<"adk live send">>)),
    ?assertNotEqual(nomatch, binary:match(Usage, <<"adk eval run">>)),
    ?assertEqual({error, invalid_command},
                 adk_cli:command(["not-a-command"])),
    ?assertEqual({error, {unknown_option, "--bogus"}},
                 adk_cli:command(["run", "--bogus", "value"])),
    ?assertEqual({error, {missing_option_value, "--message"}},
                 adk_cli:command(["run", "--message"])),
    ?assertEqual({error, {missing_required_options, [config, message]}},
                 adk_cli:command(["run"])),
    ?assertEqual({error, {missing_required_options, [config, dataset]}},
                 adk_cli:command(["evaluate"])),
    ?assertEqual({error, {missing_required_options, [config, eval_set]}},
                 adk_cli:command(["eval", "run"])).

doctor_redacts_environment_case() ->
    ApiSecret = "cli-doctor-api-secret-61d9",
    OpenAiSecret = "cli-doctor-openai-secret-77a1",
    AnthropicSecret = "cli-doctor-anthropic-secret-29c4",
    DevSecret = "cli-doctor-dev-secret-43c7",
    OldApi = os:getenv("GEMINI_API_KEY"),
    OldOpenAi = os:getenv("OPENAI_API_KEY"),
    OldAnthropic = os:getenv("ANTHROPIC_API_KEY"),
    OldDev = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    try
        true = os:putenv("GEMINI_API_KEY", ApiSecret),
        true = os:putenv("OPENAI_API_KEY", OpenAiSecret),
        true = os:putenv("ANTHROPIC_API_KEY", AnthropicSecret),
        true = os:putenv("ERLANG_ADK_DEV_TOKEN", DevSecret),
        {ok, Report} = adk_cli:command(["doctor"]),
        ?assertEqual(true, maps:get(gemini_api_key_configured, Report)),
        ?assertEqual(true, maps:get(openai_api_key_configured, Report)),
        ?assertEqual(true, maps:get(anthropic_api_key_configured, Report)),
        Providers = maps:get(providers, Report),
        ?assertEqual(available, maps:get(openai, Providers)),
        ?assertEqual(available, maps:get(anthropic, Providers)),
        ?assertEqual(available, maps:get(compatible, Providers)),
        ?assertEqual(true, maps:get(developer_token_configured, Report)),
        Dependencies = maps:get(dependencies, Report),
        ?assertEqual(available, maps:get(oidcc, Dependencies)),
        ?assertEqual(available, maps:get(jose, Dependencies)),
        ?assertEqual(ok, maps:get(status, Report)),
        Encoded = term_to_binary(Report),
        ?assertEqual(nomatch,
                     binary:match(Encoded, list_to_binary(ApiSecret))),
        ?assertEqual(nomatch,
                     binary:match(Encoded, list_to_binary(OpenAiSecret))),
        ?assertEqual(nomatch,
                     binary:match(Encoded, list_to_binary(AnthropicSecret))),
        ?assertEqual(nomatch,
                     binary:match(Encoded, list_to_binary(DevSecret)))
    after
        restore_env("GEMINI_API_KEY", OldApi),
        restore_env("OPENAI_API_KEY", OldOpenAi),
        restore_env("ANTHROPIC_API_KEY", OldAnthropic),
        restore_env("ERLANG_ADK_DEV_TOKEN", OldDev)
    end.

doctor_missing_credentials_case() ->
    OldApi = os:getenv("GEMINI_API_KEY"),
    OldDev = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    OldEnabled = application:get_env(erlang_adk, dev_enabled),
    try
        true = os:unsetenv("GEMINI_API_KEY"),
        true = os:unsetenv("ERLANG_ADK_DEV_TOKEN"),
        ok = application:set_env(erlang_adk, dev_enabled, true),
        {ok, Report} = adk_cli:command(["doctor"]),
        ?assertEqual(false, maps:get(gemini_api_key_configured, Report)),
        ?assertEqual(false, maps:get(developer_token_configured, Report)),
        Warnings = maps:get(warnings, Report),
        ?assert(lists:member(
                  <<"GEMINI_API_KEY is not configured; live model calls will fail">>,
                  Warnings)),
        ?assert(lists:member(
                  <<"dev_enabled is true but ERLANG_ADK_DEV_TOKEN is missing">>,
                  Warnings))
    after
        restore_env("GEMINI_API_KEY", OldApi),
        restore_env("ERLANG_ADK_DEV_TOKEN", OldDev),
        restore_application_env([{dev_enabled, OldEnabled}])
    end.

checked_config_validation_case() ->
    Path = temp_path("valid-agent"),
    Config = #{<<"name">> => <<"CliValidateAgent">>,
               <<"provider">> => <<"gemini">>,
               <<"model">> => <<"gemini-3.1-flash-lite">>,
               <<"instructions">> => <<"Be concise.">>,
               <<"global_instruction">> => <<"Never expose credentials.">>,
               <<"builtin_tools">> => [<<"google_search">>],
               <<"include_contents">> => <<"none">>,
               <<"temperature">> => 0.2,
               <<"generation_config">> =>
                   #{<<"thinking_config">> =>
                         #{<<"thinking_level">> => <<"low">>,
                           <<"include_thoughts">> => true},
                     <<"safety_settings">> =>
                         [#{<<"category">> =>
                                <<"HARM_CATEGORY_DANGEROUS_CONTENT">>,
                            <<"threshold">> =>
                                <<"BLOCK_MEDIUM_AND_ABOVE">>}]},
               <<"runner_options">> =>
                   #{<<"max_llm_calls">> => 4,
                     <<"tool_execution">> =>
                         #{<<"mode">> => <<"parallel">>,
                           <<"max_concurrency">> => 2,
                           <<"tool_timeout">> => 1000}}},
    try
        ok = file:write_file(Path, jsx:encode(Config)),
        {ok, Result} = adk_cli:command(
                         ["config", "validate", Path]),
        ?assertEqual(valid, maps:get(status, Result)),
        ?assertEqual(<<"CliValidateAgent">>, maps:get(name, Result)),
        ?assertEqual(0, maps:get(tool_count, Result))
    after
        _ = file:delete(Path)
    end.

rich_gemini_config_translation_case() ->
    Path = temp_path("rich-gemini-agent"),
    Config =
        #{<<"name">> => <<"CliRichGemini">>,
          <<"provider">> => <<"gemini">>,
          <<"model">> => <<"gemini-3.1-flash-lite">>,
          <<"instructions">> => <<"Use the complete checked surface.">>,
          <<"global_instruction">> => <<"Keep credentials private.">>,
          <<"input_schema">> => #{<<"type">> => <<"object">>},
          <<"output_schema">> => #{<<"type">> => <<"string">>},
          <<"output_key">> => <<"answer">>,
          <<"include_contents">> => <<"include">>,
          <<"history_policy">> => <<"exclude">>,
          <<"temperature">> => 0.1,
          <<"top_p">> => 0.9,
          <<"top_k">> => 20,
          <<"max_tokens">> => 256,
          <<"candidate_count">> => 1,
          <<"seed">> => 7,
          <<"presence_penalty">> => 0.0,
          <<"frequency_penalty">> => 0.0,
          <<"stop_sequences">> => [<<"STOP">>],
          <<"response_mime_type">> => <<"application/json">>,
          <<"response_schema">> => #{<<"type">> => <<"object">>},
          <<"thinking_config">> =>
              #{<<"thinking_budget">> => 64,
                <<"include_thoughts">> => false},
          <<"safety_settings">> =>
              [#{<<"category">> => <<"HARM_CATEGORY_HATE_SPEECH">>,
                 <<"threshold">> => <<"BLOCK_ONLY_HIGH">>}],
          <<"builtin_tools">> => [<<"google_search">>],
          <<"required_capabilities">> =>
              [<<"streaming">>, <<"function_calling">>,
               <<"structured_output">>, <<"generation_config">>,
               <<"multimodal">>, <<"thinking">>,
               <<"safety_settings">>, <<"content_streaming">>,
               <<"google_search_grounding">>],
          <<"instruction_timeout_ms">> => 1000,
          <<"artifact_timeout_ms">> => 1000,
          <<"max_instruction_bytes">> => 4096,
          <<"request_timeout">> => 2000,
          <<"generation_config">> =>
              #{<<"temperature">> => 0.2,
                <<"top_p">> => 0.8,
                <<"top_k">> => 10,
                <<"max_output_tokens">> => 128,
                <<"candidate_count">> => 1,
                <<"seed">> => 8,
                <<"presence_penalty">> => 0.1,
                <<"frequency_penalty">> => 0.1,
                <<"stop_sequences">> => [<<"END">>],
                <<"response_mime_type">> => <<"text/plain">>,
                <<"thinking_config">> =>
                    #{<<"thinking_level">> => <<"low">>,
                      <<"include_thoughts">> => true},
                <<"safety_settings">> =>
                    [#{<<"category">> =>
                           <<"HARM_CATEGORY_DANGEROUS_CONTENT">>,
                       <<"threshold">> => <<"BLOCK_MEDIUM_AND_ABOVE">>}]},
          <<"runner_options">> =>
              #{<<"run_timeout">> => 2000,
                <<"max_llm_calls">> => 4,
                <<"max_tool_rounds">> => 3,
                <<"service_timeout">> => 1500,
                <<"tool_execution">> => <<"serial">>}},
    try
        ok = file:write_file(Path, jsx:encode(Config)),
        {ok, Result} = adk_cli:command(["config", "validate", Path]),
        ?assertEqual(valid, maps:get(status, Result)),
        ?assertEqual(<<"gemini">>, maps:get(provider, Result)),
        ?assertEqual(<<"gemini-3.1-flash-lite">>, maps:get(model, Result))
    after
        _ = file:delete(Path)
    end.

native_provider_config_validation_case() ->
    Cases = [
        {"openai", #{<<"name">> => <<"CliOpenAI">>,
                     <<"provider">> => <<"openai">>,
                     <<"model">> => <<"gpt-test">>,
                     <<"instructions">> => <<"Be concise.">>,
                     <<"max_output_tokens">> => 128}},
        {"anthropic", #{<<"name">> => <<"CliAnthropic">>,
                        <<"provider">> => <<"anthropic">>,
                        <<"model">> => <<"claude-test">>,
                        <<"instructions">> => <<"Be concise.">>,
                        <<"max_tokens">> => 128}}
    ],
    lists:foreach(
      fun({Suffix, Config}) ->
          Path = temp_path("native-provider-" ++ Suffix),
          try
              ok = file:write_file(Path, jsx:encode(Config)),
              {ok, Result} = adk_cli:command(
                               ["config", "validate", Path]),
              ?assertEqual(valid, maps:get(status, Result)),
              ?assertEqual(maps:get(<<"provider">>, Config),
                           maps:get(provider, Result))
          after
              _ = file:delete(Path)
          end
      end, Cases).

configured_profile_precedes_builtin_cli_alias_case() ->
    Saved = save_application_env([provider_profiles]),
    Path = temp_path("compatible-profile-agent"),
    Profile =
        #{request_adapter => adk_llm_compatible,
          endpoint => #{scheme => https,
                        host => <<"models.vendor.example">>,
                        port => 443,
                        base_path => <<"/v1">>},
          models => #{<<"chat">> => <<"vendor-chat-model">>},
          credential => none,
          request_options => #{auth_scheme => none}},
    Config =
        #{<<"name">> => <<"CliCompatibleProfile">>,
          <<"provider">> => <<"compatible">>,
          <<"model">> => <<"chat">>,
          <<"instructions">> => <<"Use the trusted profile.">>},
    try
        ok = application:set_env(
               erlang_adk, provider_profiles,
               #{<<"compatible">> => Profile}),
        ok = file:write_file(Path, jsx:encode(Config)),
        {ok, Result} = adk_cli:command(["config", "validate", Path]),
        ?assertEqual(valid, maps:get(status, Result)),
        ?assertEqual(<<"compatible">>, maps:get(provider, Result)),
        ?assertEqual(<<"chat">>, maps:get(model, Result))
    after
        _ = file:delete(Path),
        restore_application_env(Saved)
    end.

config_error_contracts_case() ->
    assert_config_result("config-array", [],
                         {error, agent_config_must_be_object}),
    assert_config_bytes("config-invalid-json", <<"{not-json">>,
                        {error, invalid_json}),
    assert_config_result(
      "config-unknown-key", #{<<"unexpected">> => true},
      {error, {unknown_agent_config_keys, [<<"unexpected">>]}}),
    assert_config_result("config-empty-name", #{<<"name">> => <<>>},
                         {error, invalid_agent_name}),
    assert_config_result("config-provider-type", #{<<"provider">> => 42},
                         {error, invalid_provider_name}),
    assert_config_result(
      "config-provider-unknown", #{<<"provider">> => <<"unknown-vendor">>},
      {error, {unknown_provider, <<"unknown-vendor">>}}),
    assert_config_result("config-tools-shape", #{<<"tools">> => #{}},
                         {error, tools_must_be_array}),
    assert_config_result("config-tool-name", #{<<"tools">> => [42]},
                         {error, invalid_tool_name}),
    assert_config_result(
      "config-tool-unknown", #{<<"tools">> => [<<"no_such_cli_tool">>]},
      {error, {unknown_tool_module, <<"no_such_cli_tool">>}}),
    assert_config_result(
      "config-tool-callbacks", #{<<"tools">> => [<<"lists">>]},
      {error, {invalid_tool_module, <<"lists">>}}),
    assert_config_result(
      "config-runner-shape", #{<<"runner_options">> => []},
      {error, runner_options_must_be_object}),
    assert_config_result(
      "config-runner-unknown",
      #{<<"runner_options">> => #{<<"surprise">> => 1}},
      {error, {unknown_runner_options, [<<"surprise">>]}}),
    assert_config_result(
      "config-runner-value",
      #{<<"runner_options">> => #{<<"run_timeout">> => 0}},
      {error, {invalid_runner_option, <<"run_timeout">>}}),
    assert_config_result(
      "config-parallel-policy",
      #{<<"runner_options">> =>
            #{<<"tool_execution">> =>
                  #{<<"mode">> => <<"parallel">>,
                    <<"max_concurrency">> => 0,
                    <<"tool_timeout">> => 1000}}},
      {error, invalid_parallel_tool_policy}).

checked_repository_examples_case() ->
    {ok, ConfigResult} = adk_cli:command(
                           ["config", "validate",
                            "examples/agent.json"]),
    ?assertEqual(valid, maps:get(status, ConfigResult)),
    ?assertEqual(<<"CliAgent">>, maps:get(name, ConfigResult)),
    ?assertEqual(<<"gemini-3.1-flash-lite">>,
                 maps:get(model, ConfigResult)),

    %% Exercise the checked dataset through the real CLI loader/evaluator
    %% with a deterministic provider so repository validation uses no quota.
    ProbePath = temp_path("repository-eval-agent"),
    ProbeConfig = #{<<"name">> => unique_binary(<<"CliRepoEval">>),
                    <<"provider">> => <<"adk_llm_probe">>,
                    <<"response">> => <<"ERLANG">>},
    try
        ok = file:write_file(ProbePath, jsx:encode(ProbeConfig)),
        {ok, EvalResult} = adk_cli:command(
                             ["evaluate", "--config", ProbePath,
                              "--dataset", "examples/eval.json",
                              "--timeout", "2000",
                              "--concurrency", "1"]),
        ?assertEqual(
           1.0,
           maps:get(average_score, maps:get(report, EvalResult)))
    after
        _ = file:delete(ProbePath)
    end.

config_rejects_embedded_secret_case() ->
    Path = temp_path("secret-agent"),
    Secret = <<"must-never-enter-cli-output">>,
    Config = #{<<"provider">> => <<"gemini">>,
               <<"api_key">> => Secret},
    try
        ok = file:write_file(Path, jsx:encode(Config)),
        ?assertEqual(
           {error, secret_in_config_file},
           adk_cli:command(["config", "validate", Path]))
    after
        _ = file:delete(Path)
    end.

deterministic_run_case() ->
    Path = temp_path("run-agent"),
    Name = unique_binary(<<"CliRunAgent">>),
    Config = #{<<"name">> => Name,
               <<"provider">> => <<"adk_llm_probe">>,
               <<"response">> => <<"CLI response">>},
    try
        ok = file:write_file(Path, jsx:encode(Config)),
        {ok, Result} = adk_cli:command(
                         ["run", "--config", Path,
                          "--message", "hello",
                          "--user", "cli-user",
                          "--session", "cli-session",
                          "--timeout", "2000"]),
        ?assertEqual(completed, maps:get(outcome, Result)),
        ?assertEqual(<<"CLI response">>, maps:get(text, Result)),
        ?assertMatch(<<"run-", _/binary>>, maps:get(run_id, Result))
    after
        _ = file:delete(Path),
        _ = erlang_adk_session:delete_session(
              <<"adk-cli">>, <<"cli-user">>, <<"cli-session">>)
    end.

deterministic_console_case() ->
    Path = temp_path("console-agent"),
    Name = unique_binary(<<"CliConsoleAgent">>),
    FirstSession = unique_binary(<<"cli-console-one">>),
    SecondSession = unique_binary(<<"cli-console-two">>),
    InputKey = {console_inputs, make_ref()},
    OutputKey = {console_outputs, make_ref()},
    Config = #{<<"name">> => Name,
               <<"provider">> => <<"adk_llm_probe">>,
               <<"response">> => <<"console response">>},
    put(InputKey,
        [<<"first turn\n">>, <<"/inspect\n">>,
         <<"/session ", SecondSession/binary, "\n">>,
         <<"second turn\n">>, <<"/exit\n">>]),
    put(OutputKey, []),
    Io = #{
        read => fun(_Prompt) ->
                    case get(InputKey) of
                        [Line | Rest] -> put(InputKey, Rest), {ok, Line};
                        [] -> eof
                    end
                end,
        write => fun(Text) ->
                     put(OutputKey, [Text | get(OutputKey)]),
                     ok
                 end},
    try
        ok = file:write_file(Path, jsx:encode(Config)),
        {ok, Result} = adk_cli:command(
                         ["console", "--config", Path,
                          "--app", "adk-cli",
                          "--user", "cli-console-user",
                          "--session", binary_to_list(FirstSession),
                          "--timeout", "2000"], Io),
        ?assertEqual(console, maps:get(command, Result)),
        ?assertEqual(closed, maps:get(outcome, Result)),
        ?assertEqual(2, maps:get(turns, Result)),
        ?assertEqual(SecondSession, maps:get(session_id, Result)),
        Output = iolist_to_binary(lists:reverse(get(OutputKey))),
        ?assertNotEqual(nomatch,
                        binary:match(Output, <<"console response">>)),
        ?assertNotEqual(nomatch, binary:match(Output, FirstSession)),
        ?assertNotEqual(nomatch, binary:match(Output, SecondSession))
    after
        erase(InputKey),
        erase(OutputKey),
        _ = file:delete(Path),
        _ = erlang_adk_session:delete_session(
              <<"adk-cli">>, <<"cli-console-user">>, FirstSession),
        _ = erlang_adk_session:delete_session(
              <<"adk-cli">>, <<"cli-console-user">>, SecondSession)
    end.

console_control_contracts_case() ->
    Path = temp_path("console-controls-agent"),
    InitialSession = unique_binary(<<"cli-console-controls">>),
    InputKey = {console_control_inputs, make_ref()},
    OutputKey = {console_control_outputs, make_ref()},
    Config = #{<<"name">> => unique_binary(<<"CliConsoleControls">>),
               <<"provider">> => <<"adk_llm_probe">>,
               <<"response">> => <<"unused">>},
    put(InputKey,
        [<<"\n">>, <<"/help\n">>, <<"/inspect\n">>, <<"/new\n">>,
         <<"/resume {}\n">>, <<"/unknown\n">>, <<"/quit\n">>]),
    put(OutputKey, []),
    Io = #{read => fun(_Prompt) ->
                         case get(InputKey) of
                             [Line | Rest] ->
                                 put(InputKey, Rest),
                                 {ok, Line};
                             [] -> eof
                         end
                     end,
           write => fun(Text) ->
                          put(OutputKey, [Text | get(OutputKey)]),
                          ok
                      end},
    try
        ok = file:write_file(Path, jsx:encode(Config)),
        {ok, Result} = adk_cli:command(
                         ["console", "--config", Path,
                          "--session", binary_to_list(InitialSession),
                          "--timeout", "2000"], Io),
        ?assertEqual(closed, maps:get(outcome, Result)),
        ?assertEqual(0, maps:get(turns, Result)),
        ?assertMatch(<<"session-", _/binary>>,
                     maps:get(session_id, Result)),
        Output = iolist_to_binary(lists:reverse(get(OutputKey))),
        ?assertNotEqual(nomatch, binary:match(Output, <<"/session SESSION_ID">>)),
        ?assertNotEqual(nomatch, binary:match(Output, <<"not_found">>)),
        ?assertNotEqual(nomatch, binary:match(Output, <<"no_paused_run">>)),
        ?assertNotEqual(nomatch,
                        binary:match(Output, <<"unknown_console_command">>)),
        ?assertEqual(
           {error, invalid_console_io},
           adk_cli:command(["console", "--config", Path], #{})),
        BadInputIo = #{read => fun(_Prompt) -> unexpected end,
                       write => fun(_Text) -> ok end},
        ?assertEqual(
           {error, {console_io_failed, <<"invalid_console_input">>}},
           adk_cli:command(["console", "--config", Path], BadInputIo)),
        EofIo = #{read => fun(_Prompt) -> eof end,
                  write => fun(_Text) -> erlang:error(write_failed) end},
        {ok, EofResult} = adk_cli:command(
                            ["console", "--config", Path], EofIo),
        ?assertEqual(eof, maps:get(outcome, EofResult))
    after
        erase(InputKey),
        erase(OutputKey),
        _ = file:delete(Path),
        _ = erlang_adk_session:delete_session(
              <<"adk-cli">>, <<"local-user">>, InitialSession)
    end.

deterministic_evaluation_case() ->
    AgentPath = temp_path("eval-agent"),
    DatasetPath = temp_path("eval-dataset"),
    Name = unique_binary(<<"CliEvalAgent">>),
    AgentConfig = #{<<"name">> => Name,
                    <<"provider">> => <<"adk_llm_probe">>,
                    <<"response">> => <<"ERLANG">>},
    Dataset = [#{<<"input">> => <<"language">>,
                 <<"expected">> => <<"ERLANG">>,
                 <<"metadata">> => #{<<"case">> => 1}}],
    try
        ok = file:write_file(AgentPath, jsx:encode(AgentConfig)),
        ok = file:write_file(DatasetPath, jsx:encode(Dataset)),
        {ok, Result} = adk_cli:command(
                         ["evaluate", "--config", AgentPath,
                          "--dataset", DatasetPath,
                          "--timeout", "2000",
                          "--concurrency", "1"]),
        Report = maps:get(report, Result),
        ?assertEqual(1.0, maps:get(average_score, Report))
    after
        _ = file:delete(AgentPath),
        _ = file:delete(DatasetPath)
    end.

versioned_evaluation_case() ->
    AgentPath = temp_path("eval-v2-agent"),
    SetPath = temp_path("eval-v2-set"),
    CriteriaPath = temp_path("eval-v2-criteria"),
    BaselinePath = temp_path("eval-v2-baseline"),
    MarkdownPath = temp_path("eval-v2-report"),
    Name = unique_binary(<<"CliEvalV2Agent">>),
    AgentConfig = #{<<"name">> => Name,
                    <<"provider">> => <<"adk_llm_probe">>,
                    <<"response">> => <<"ERLANG">>},
    PassingSet = versioned_eval_set(<<"ERLANG">>),
    FailingSet = versioned_eval_set(<<"NOT ERLANG">>),
    Criteria = [#{<<"id">> => <<"response">>,
                  <<"criterion">> => <<"exact_response">>,
                  <<"threshold">> => 1.0,
                  <<"config">> =>
                      #{<<"normalization">> => <<"exact">>}}],
    BaseArgs = ["eval", "run", "--config", AgentPath,
                "--eval-set", SetPath,
                "--criteria", CriteriaPath,
                "--samples", "2",
                "--concurrency", "2",
                "--sample-concurrency", "2",
                "--timeout", "5000",
                "--case-timeout", "2000"],
    try
        ok = file:write_file(AgentPath, jsx:encode(AgentConfig)),
        ok = file:write_file(SetPath, jsx:encode(PassingSet)),
        ok = file:write_file(CriteriaPath, jsx:encode(Criteria)),

        {ok, Passing} = adk_cli:command(BaseArgs),
        ?assertEqual(eval_run, maps:get(command, Passing)),
        ?assertEqual(stdout, maps:get(delivery, Passing)),
        ?assertEqual(0, maps:get(ci_exit_code, Passing)),
        ?assertEqual(true, maps:get(passed, Passing)),
        PassingReport = maps:get(evaluation, Passing),
        ?assertEqual(2, maps:get(<<"result_schema_version">>,
                                PassingReport)),
        ?assertEqual(2, maps:get(<<"sample_count">>, PassingReport)),
        ?assertMatch(#{<<"result_schema_version">> := 2},
                     jsx:decode(maps:get(report, Passing),
                                [return_maps])),

        ok = file:write_file(
               BaselinePath, jsx:encode(PassingReport)),
        {ok, Markdown} = adk_cli:command(
                           BaseArgs ++
                           ["--format", "markdown",
                            "--output", MarkdownPath]),
        ?assertEqual(file, maps:get(delivery, Markdown)),
        {ok, MarkdownBytes} = file:read_file(MarkdownPath),
        ?assertEqual(maps:get(report, Markdown), MarkdownBytes),
        ?assertNotEqual(
           nomatch, binary:match(MarkdownBytes,
                                 <<"# Evaluation report">>)),

        ok = file:write_file(SetPath, jsx:encode(FailingSet)),
        {ok, Failing} = adk_cli:command(BaseArgs),
        ?assertEqual(2, maps:get(ci_exit_code, Failing)),
        ?assertEqual(false, maps:get(passed, Failing)),

        {ok, Regression} = adk_cli:command(
                             BaseArgs ++
                             ["--baseline", BaselinePath]),
        ?assertEqual(2, maps:get(ci_exit_code, Regression)),
        ?assertEqual(false, maps:get(passed, Regression)),
        DecodedComparison =
            jsx:decode(maps:get(report, Regression), [return_maps]),
        ?assertMatch(
           #{<<"report_type">> := <<"baseline_comparison">>,
             <<"passed">> := false},
           DecodedComparison),
        ?assertEqual(maps:get(comparison, Regression),
                     DecodedComparison),
        ?assertMatch({ok, baseline_comparison, _},
                     adk_eval_dev_view:classify(DecodedComparison)),
        ?assertEqual(false,
                     maps:is_key(<<"evaluation_passed">>,
                                 DecodedComparison)),

        %% A candidate may fail its absolute threshold while showing no
        %% regression against an equally failing baseline. Keep the comparison
        %% canonical while the command-level CI gate remains failed.
        FailingReport = maps:get(evaluation, Failing),
        ok = file:write_file(BaselinePath, jsx:encode(FailingReport)),
        {ok, AbsoluteFailureOnly} =
            adk_cli:command(BaseArgs ++ ["--baseline", BaselinePath]),
        ?assertEqual(false, maps:get(passed, AbsoluteFailureOnly)),
        ?assertEqual(2, maps:get(ci_exit_code, AbsoluteFailureOnly)),
        PassingComparison = maps:get(comparison, AbsoluteFailureOnly),
        ?assertEqual(true, maps:get(<<"passed">>, PassingComparison)),
        ?assertEqual(PassingComparison,
                     jsx:decode(maps:get(report, AbsoluteFailureOnly),
                                [return_maps]))
    after
        _ = file:delete(AgentPath),
        _ = file:delete(SetPath),
        _ = file:delete(CriteriaPath),
        _ = file:delete(BaselinePath),
        _ = file:delete(MarkdownPath)
    end.

evaluation_validation_contracts_case() ->
    AgentPath = temp_path("eval-validation-agent"),
    DatasetPath = temp_path("eval-validation-dataset"),
    SetPath = temp_path("eval-validation-set"),
    CriteriaPath = temp_path("eval-validation-criteria"),
    BaselinePath = temp_path("eval-validation-baseline"),
    TolerancesPath = temp_path("eval-validation-tolerances"),
    AgentConfig = #{<<"name">> => unique_binary(<<"CliEvalValidation">>),
                    <<"provider">> => <<"adk_llm_probe">>,
                    <<"response">> => <<"ERLANG">>},
    BaseArgs = ["eval", "run", "--config", AgentPath,
                "--eval-set", SetPath],
    try
        ok = file:write_file(AgentPath, jsx:encode(AgentConfig)),
        ok = file:write_file(SetPath, jsx:encode(versioned_eval_set(<<"ERLANG">>))),
        ok = file:write_file(DatasetPath, jsx:encode([])),

        ?assertEqual(
           {error, {invalid_positive_integer, timeout}},
           adk_cli:command(["evaluate", "--config", AgentPath,
                            "--dataset", DatasetPath, "--timeout", "0"])),
        ?assertEqual(
           {error, {invalid_positive_integer, concurrency}},
           adk_cli:command(["evaluate", "--config", AgentPath,
                            "--dataset", DatasetPath,
                            "--concurrency", "many"])),
        ?assertEqual({error, invalid_eval_report_format},
                     adk_cli:command(BaseArgs ++ ["--format", "yaml"])),
        ?assertEqual(
           {error, invalid_eval_output_path},
           adk_cli:command(BaseArgs ++ ["--output", "bad" ++ [0] ++ "path"])),
        ?assertEqual(
           {error, {invalid_positive_integer, samples}},
           adk_cli:command(BaseArgs ++ ["--samples", "0"])),
        ?assertEqual(
           {error, {invalid_fraction, pass_rate_threshold}},
           adk_cli:command(BaseArgs ++ ["--pass-rate-threshold", "1.1"])),
        ?assertEqual(
           {error, {invalid_fraction, sample_pass_rate_threshold}},
           adk_cli:command(
             BaseArgs ++ ["--sample-pass-rate-threshold", "not-a-number"])),
        ?assertEqual(
           {error, {invalid_empty_criteria_policy, empty_criteria}},
           adk_cli:command(BaseArgs ++ ["--empty-criteria", "ignore"])),
        ?assertEqual(
           {error, {invalid_boolean, capture_events}},
           adk_cli:command(BaseArgs ++ ["--capture-events", "yes"])),
        ?assertEqual(
           {error, baseline_required_for_comparison_options},
           adk_cli:command(BaseArgs ++ ["--max-pass-rate-drop", "0.1"])),

        ok = file:write_file(DatasetPath, jsx:encode(#{})),
        ?assertEqual(
           {error, dataset_must_be_array},
           adk_cli:command(["evaluate", "--config", AgentPath,
                            "--dataset", DatasetPath])),
        lists:foreach(
          fun({Value, Expected}) ->
              ok = file:write_file(DatasetPath, jsx:encode(Value)),
              ?assertEqual(
                 Expected,
                 adk_cli:command(["evaluate", "--config", AgentPath,
                                  "--dataset", DatasetPath]))
          end,
          [{[42], {error, {invalid_dataset_row, 1}}},
           {[#{<<"input">> => <<"x">>, <<"expected">> => <<"x">>,
                <<"extra">> => true}],
            {error, {invalid_dataset_row, 1}}}]),

        ok = file:write_file(SetPath, jsx:encode([])),
        ?assertEqual({error, eval_set_must_be_object},
                     adk_cli:command(BaseArgs)),
        ok = file:write_file(SetPath, jsx:encode(#{})),
        ?assertMatch({error, {invalid_eval_set, _}},
                     adk_cli:command(BaseArgs)),
        ok = file:write_file(SetPath, jsx:encode(versioned_eval_set(<<"ERLANG">>))),

        ok = file:write_file(CriteriaPath, jsx:encode(#{})),
        ?assertEqual({error, eval_criteria_must_be_array},
                     adk_cli:command(BaseArgs ++ ["--criteria", CriteriaPath])),
        ok = file:write_file(
               CriteriaPath,
               jsx:encode(#{<<"criteria">> => [], <<"extra">> => true})),
        ?assertEqual(
           {error, {unknown_eval_criteria_keys, [<<"extra">>]}},
           adk_cli:command(BaseArgs ++ ["--criteria", CriteriaPath])),
        ok = file:write_file(CriteriaPath, jsx:encode([42])),
        ?assertEqual({error, {invalid_eval_criterion, 0}},
                     adk_cli:command(BaseArgs ++ ["--criteria", CriteriaPath])),
        ok = file:write_file(
               CriteriaPath,
               jsx:encode([#{<<"id">> => <<"bad">>,
                             <<"criterion">> => <<"exact_response">>,
                             <<"unknown">> => true}])),
        ?assertEqual(
           {error, {unknown_eval_criterion_keys, 0, [<<"unknown">>]}},
           adk_cli:command(BaseArgs ++ ["--criteria", CriteriaPath])),
        lists:foreach(
          fun(Name) ->
              Invalid = [#{<<"id">> => <<"criterion">>,
                           <<"criterion">> => Name,
                           <<"threshold">> => 2}],
              ok = file:write_file(CriteriaPath, jsx:encode(Invalid)),
              ?assertEqual(
                 {error, {invalid_eval_criterion, 0}},
                 adk_cli:command(BaseArgs ++ ["--criteria", CriteriaPath]))
          end,
          [<<"trajectory_exact">>, <<"trajectory_in_order">>,
           <<"trajectory_any_order">>, <<"trajectory_subset">>,
           <<"tool_trajectory">>, <<"not-a-criterion">>]),

        ok = file:write_file(BaselinePath, jsx:encode([])),
        ok = file:write_file(TolerancesPath, jsx:encode([])),
        ?assertEqual(
           {error, metric_tolerances_must_be_object},
           adk_cli:command(BaseArgs ++ ["--baseline", BaselinePath,
                                        "--metric-tolerances", TolerancesPath])),
        ok = file:write_file(TolerancesPath,
                             jsx:encode(#{<<"response">> => 2})),
        ?assertEqual(
           {error, invalid_metric_tolerances},
           adk_cli:command(BaseArgs ++ ["--baseline", BaselinePath,
                                        "--metric-tolerances", TolerancesPath])),
        ok = file:write_file(TolerancesPath,
                             jsx:encode(#{<<"response">> => 0.1})),
        ?assertEqual(
           {error, eval_baseline_must_be_object},
           adk_cli:command(BaseArgs ++ ["--baseline", BaselinePath,
                                        "--metric-tolerances", TolerancesPath]))
    after
        lists:foreach(fun(Path) -> _ = file:delete(Path) end,
                      [AgentPath, DatasetPath, SetPath, CriteriaPath,
                       BaselinePath, TolerancesPath])
    end.

versioned_eval_set(Expected) ->
    #{<<"schema_version">> => 2,
      <<"id">> => <<"cli-versioned">>,
      <<"version">> => <<"1">>,
      <<"cases">> =>
          [#{<<"id">> => <<"language">>,
             <<"turns">> =>
                 [#{<<"id">> => <<"turn-1">>,
                    <<"input">> => <<"language">>,
                    <<"expected_response">> => Expected}]}]}.

option_and_url_validation_case() ->
    ?assertEqual(
       {error, developer_server_must_bind_loopback},
       adk_cli:command(["serve", "--ip", "0.0.0.0"])),
    ?assertEqual(
       {error, {duplicate_option, "--url"}},
       adk_cli:command(
         ["inspect", "run", "run-1",
          "--url", "http://127.0.0.1:8080",
          "--url", "http://127.0.0.1:8081"])),
    ?assertEqual(
       {error, insecure_non_loopback_base_url},
       adk_cli:command(
         ["inspect", "run", "run-1",
          "--url", "http://example.invalid"])).

remote_command_validation_contracts_case() ->
    OldToken = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    try
        true = os:unsetenv("ERLANG_ADK_DEV_TOKEN"),
        ?assertEqual(
           {error, {missing_required_options, [text]}},
           adk_cli:command(["live", "send", "live-1"])),
        ?assertEqual(
           {error, invalid_live_text_command},
           adk_cli:command(["live", "send", "", "--text", ""])),
        ?assertEqual(
           {error, {missing_required_options, [model]}},
           adk_cli:command(["inspect", "context-lifecycle",
                            "app", "user", "session"])),
        ?assertEqual(
           {error, invalid_context_cache_model},
           adk_cli:command(["inspect", "context-lifecycle",
                            "app", "user", "session", "--model", ""])),
        ?assertEqual(
           {error, {missing_required_options, [model, confirm_json]}},
           adk_cli:command(["context-cache", "invalidate",
                            "app", "user", "session"])),
        ?assertEqual(
           {error, invalid_resource_limit},
           adk_cli:command(["inspect", "artifacts", "app", "user", "session",
                            "--limit", "1001"])),
        ?assertEqual(
           {error, invalid_resource_cursor},
           adk_cli:command(["inspect", "artifacts", "app", "user", "session",
                            "--cursor", ""])),
        ?assertEqual(
           {error, {missing_required_options, [name]}},
           adk_cli:command(["inspect", "artifact", "app", "user", "session"])),
        ?assertEqual(
           {error, invalid_artifact_name},
           adk_cli:command(["inspect", "artifact", "app", "user", "session",
                            "--name", ""])),
        ?assertEqual(
           {error, invalid_resource_cursor},
           adk_cli:command(["inspect", "artifact", "app", "user", "session",
                            "--name", "report", "--cursor", "0"])),
        ?assertEqual(
           {error, {missing_required_options, [query]}},
           adk_cli:command(["memory", "search", "app", "user"])),
        ?assertEqual(
           {error, invalid_memory_query},
           adk_cli:command(["memory", "search", "app", "user",
                            "--query", ""])),
        ?assertEqual(
           {error, memory_filter_must_be_object},
           adk_cli:command(["memory", "search", "app", "user",
                            "--query", "term", "--filter-json", "[]"])),
        ?assertEqual(
           {error, invalid_artifact_selector},
           adk_cli:command(["artifact", "delete", "app", "user", "session",
                            "report", "0", "--confirm-json", "{}"])),
        ?assertEqual(
           {error, confirmation_does_not_match_target},
           adk_cli:command(["artifact", "delete", "app", "user", "session",
                            "report", "latest", "--confirm-json", "{}"])),
        lists:foreach(
          fun(Args) ->
              ?assertEqual({error, confirmation_does_not_match_target},
                           adk_cli:command(Args))
          end,
          [["memory", "erase", "app", "user", "entry", "entry-1",
            "--confirm-json", "{}"],
           ["memory", "erase", "app", "user", "session", "session-1",
            "--confirm-json", "{}"],
           ["memory", "erase", "app", "user", "user",
            "--confirm-json", "{}"]]),
        ?assertEqual(
           {error, state_delta_must_be_nonempty_object},
           adk_cli:command(["session", "state", "app", "user", "session",
                            "--delta-json", "{}"])),
        ?assertEqual(
           {error, {missing_required_options, [response_json]}},
           adk_cli:command(["resume", "run-1"])),
        ?assertEqual(
           {error, invalid_json},
           adk_cli:command(["resume", "run-1", "--response-json", "{"])),
        ?assertEqual(
           {error, invalid_port},
           adk_cli:command(["serve", "--port", "65536"])),
        ?assertEqual(
           {error, missing_developer_token},
           adk_cli:command(["serve", "--ip", "::1", "--port", "8080"])),
        ?assertEqual(
           {error, invalid_base_url},
           adk_cli:command(["inspect", "agents", "--url", "ftp://localhost"])),
        ?assertEqual(
           {error, invalid_base_url},
           adk_cli:command(["inspect", "agents",
                            "--url", "https://example.com?query=1"])),
        ?assertEqual(
           {error, missing_developer_token},
           adk_cli:command(["inspect", "agents",
                            "--url", "http://localhost:18080/"])),
        true = os:putenv("ERLANG_ADK_DEV_TOKEN", "short"),
        ?assertEqual({error, developer_token_too_short},
                     adk_cli:command(["serve", "--port", "8080"]))
    after
        restore_env("ERLANG_ADK_DEV_TOKEN", OldToken)
    end.

developer_connection_failure_is_structured_case() ->
    Port = free_port(),
    Base = "http://127.0.0.1:" ++ integer_to_list(Port),
    OldToken = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    try
        true = os:putenv("ERLANG_ADK_DEV_TOKEN", ?CLI_DEV_TOKEN),
        ?assertEqual(
           {error, #{code => developer_api_unavailable,
                     reason => connection_refused}},
           adk_cli:command(["inspect", "agents", "--url", Base]))
    after
        restore_env("ERLANG_ADK_DEV_TOKEN", OldToken)
    end.

oversized_chunked_developer_success_is_bounded_case() ->
    assert_oversized_chunked_developer_response(
      200, {error, invalid_developer_api_response}).

oversized_chunked_developer_error_is_bounded_case() ->
    assert_oversized_chunked_developer_response(
      429,
      {error, {developer_api_http_error, 429,
               <<"developer_api_request_failed">>}}).

assert_oversized_chunked_developer_response(Status, Expected) ->
    {Listener, Server, Monitor, Base} =
        start_oversized_chunked_server(Status),
    OldToken = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    try
        true = os:putenv("ERLANG_ADK_DEV_TOKEN", ?CLI_DEV_TOKEN),
        ?assertEqual(
           Expected,
           adk_cli:command(["inspect", "agents", "--url", Base]))
    after
        restore_env("ERLANG_ADK_DEV_TOKEN", OldToken),
        stop_raw_http_server(Listener, Server, Monitor)
    end.

successful_developer_commands_case() ->
    Port = free_port(),
    PortString = integer_to_list(Port),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    BaseString = binary_to_list(Base),
    ConfigPath = temp_path("serve-agent"),
    ServedName = unique_binary(<<"CliServedAgent">>),
    BlockingName = unique_binary(<<"CliBlockingAgent">>),
    ResumeName = unique_binary(<<"CliResumeAgent">>),
    App = unique_binary(<<"cli-dev-app">>),
    User = <<"cli-dev-user">>,
    CompletedSession = unique_binary(<<"completed-session">>),
    CancelSession = unique_binary(<<"cancel-session">>),
    ResumeSession = unique_binary(<<"resume-session">>),
    ManagedSession = unique_binary(<<"managed-session">>),
    BlockingPid = spawn(fun() -> cli_blocking_agent_loop(BlockingName) end),
    OldToken = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    SavedAppEnv = save_application_env(
                    [dev_enabled, dev_auth_token, dev_auth_token_env,
                     a2a_ip, a2a_port]),
    Config = #{<<"name">> => ServedName,
               <<"provider">> => <<"adk_llm_probe">>,
               <<"response">> => <<"CLI served response">>},
    try
        ok = file:write_file(ConfigPath, jsx:encode(Config)),
        true = os:putenv("ERLANG_ADK_DEV_TOKEN", ?CLI_DEV_TOKEN),
        ok = application:unset_env(erlang_adk, dev_auth_token),
        ok = application:unset_env(erlang_adk, dev_auth_token_env),

        %% Exercise the packaged-escript cold-start state. Before this
        %% regression, set_env/3 ran while the application was unloaded and
        %% application:load/1 then silently restored dev_enabled=false.
        ok = application:stop(erlang_adk),
        ok = application:unload(erlang_adk),
        ?assertEqual(undefined,
                     application:get_env(erlang_adk, dev_enabled)),

        {ok, ServeResult} = adk_cli:command(
                              ["serve", "--config", ConfigPath,
                               "--port", PortString,
                               "--ip", "127.0.0.1"]),
        ?assertEqual(serve, maps:get(command, ServeResult)),
        ?assertEqual(listening, maps:get(status, ServeResult)),
        ?assertEqual(<<Base/binary, "/dev">>, maps:get(url, ServeResult)),
        ?assertEqual(ServedName, maps:get(agent_name, ServeResult)),
        ?assertEqual({ok, true},
                     application:get_env(erlang_adk, dev_enabled)),
        ?assert(is_pid(whereis(erlang_adk_http))),

        {ok, AgentList} = adk_cli:command(
                            ["inspect", "agents", "--url", BaseString]),
        AgentNames = [maps:get(<<"name">>, Entry)
                      || Entry <- maps:get(<<"agents">>, AgentList)],
        ?assert(lists:member(ServedName, AgentNames)),

        {ok, CreatedSession} = adk_cli:command(
                                 ["session", "create",
                                  binary_to_list(App),
                                  binary_to_list(User),
                                  binary_to_list(ManagedSession),
                                  "--url", BaseString]),
        ?assertEqual(ManagedSession,
                     maps:get(<<"id">>, CreatedSession)),
        {ok, ListedSessions} = adk_cli:command(
                                 ["inspect", "sessions",
                                  binary_to_list(App),
                                  binary_to_list(User),
                                  "--url", BaseString]),
        ListedIds = [maps:get(<<"id">>, Entry)
                     || Entry <- maps:get(<<"sessions">>, ListedSessions)],
        ?assert(lists:member(ManagedSession, ListedIds)),
        {ok, UpdatedSession} = adk_cli:command(
                                 ["session", "state",
                                  binary_to_list(App),
                                  binary_to_list(User),
                                  binary_to_list(ManagedSession),
                                  "--delta-json", "{\"developer:mode\":\"test\"}",
                                  "--url", BaseString]),
        ?assertEqual(
           <<"test">>,
           maps:get(<<"developer:mode">>,
                    maps:get(<<"state">>, UpdatedSession))),

        ok = register_cli_agent(BlockingName, BlockingPid),
        {ok, _ResumePid} = erlang_adk:spawn_agent(
                             ResumeName,
                             #{provider => adk_llm_probe,
                               mode => tool_call,
                               call_name => <<"request_human_approval">>,
                               call_args =>
                                   #{<<"action_summary">> =>
                                         <<"Publish release">>},
                               response => <<"Release published">>},
                             [adk_long_running_tool]),

        CompletedRunId = start_remote_run(
                           Base, ServedName, App, User, CompletedSession,
                           <<"hello">>),
        Completed = await_cli_state(
                      BaseString, CompletedRunId, <<"completed">>, 200),
        ?assertEqual(
           <<"CLI served response">>,
           maps:get(<<"text">>, maps:get(<<"outcome">>, Completed))),
        {ok, InspectedRun} = adk_cli:command(
                               ["inspect", "run",
                                binary_to_list(CompletedRunId),
                                "--url", BaseString]),
        ?assertEqual(CompletedRunId, maps:get(<<"run_id">>, InspectedRun)),
        {ok, InspectedSession} = adk_cli:command(
                                   ["inspect", "session",
                                    binary_to_list(App),
                                    binary_to_list(User),
                                    binary_to_list(CompletedSession),
                                    "--url", BaseString]),
        ?assertEqual(CompletedSession,
                     maps:get(<<"id">>, InspectedSession)),
        ?assertMatch([_ | _], maps:get(<<"events">>, InspectedSession)),

        CancelRunId = start_remote_run(
                        Base, BlockingName, App, User, CancelSession,
                        <<"wait">>),
        {ok, CancelResult} = adk_cli:command(
                               ["cancel", binary_to_list(CancelRunId),
                                "--url", BaseString]),
        ?assertEqual(CancelRunId, maps:get(<<"run_id">>, CancelResult)),
        Cancelled = await_cli_state(
                      BaseString, CancelRunId, <<"cancelled">>, 200),
        ?assertEqual(
           <<"developer_cancelled">>,
           maps:get(<<"reason">>, maps:get(<<"outcome">>, Cancelled))),

        PausedRunId = start_remote_run(
                        Base, ResumeName, App, User, ResumeSession,
                        <<"publish">>),
        _Paused = await_cli_state(
                    BaseString, PausedRunId, <<"paused">>, 200),
        {ok, ResumeResult} = adk_cli:command(
                               ["resume", binary_to_list(PausedRunId),
                                "--response-json", "{\"approved\":true}",
                                "--url", BaseString]),
        ResumedRunId = maps:get(<<"run_id">>, ResumeResult),
        ?assertNotEqual(PausedRunId, ResumedRunId),
        ?assertEqual(PausedRunId,
                     maps:get(<<"parent_run_id">>, ResumeResult)),
        Resumed = await_cli_state(
                    BaseString, ResumedRunId, <<"completed">>, 200),
        ?assertEqual(PausedRunId,
                     maps:get(<<"parent_run_id">>, Resumed)),
        ?assertEqual(
           <<"Release published">>,
           maps:get(<<"text">>, maps:get(<<"outcome">>, Resumed))),

        {ok, DeletedSession} = adk_cli:command(
                                 ["session", "delete",
                                  binary_to_list(App),
                                  binary_to_list(User),
                                  binary_to_list(ManagedSession),
                                  "--url", BaseString]),
        ?assertEqual(true, maps:get(<<"deleted">>, DeletedSession))
    after
        safe_stop_registered_agent(ServedName),
        safe_stop_registered_agent(ResumeName),
        _ = catch adk_agent_registry:unregister_name(BlockingName),
        BlockingPid ! stop,
        lists:foreach(
          fun(SessionId) ->
              _ = catch erlang_adk_session:delete_session(
                            App, User, SessionId)
          end,
          [CompletedSession, CancelSession, ResumeSession, ManagedSession]),
        _ = catch application:stop(erlang_adk),
        restore_application_env(SavedAppEnv),
        restore_env("ERLANG_ADK_DEV_TOKEN", OldToken),
        _ = file:delete(ConfigPath),
        {ok, _} = application:ensure_all_started(erlang_adk)
    end.

start_remote_run(Base, Agent, App, User, Session, Message) ->
    Body = jsx:encode(
             #{<<"agent_name">> => Agent,
               <<"app_name">> => App,
               <<"user_id">> => User,
               <<"session_id">> => Session,
               <<"message">> => Message}),
    Url = binary_to_list(<<Base/binary, "/dev/v1/runs">>),
    Headers = [{"authorization", "Bearer " ++ ?CLI_DEV_TOKEN}],
    {ok, {{_Version, 202, _Phrase}, _ResponseHeaders, ResponseBody}} =
        httpc:request(
          post, {Url, Headers, "application/json", Body},
          [{timeout, 3000}], [{body_format, binary}]),
    maps:get(<<"run_id">>, jsx:decode(ResponseBody, [return_maps])).

await_cli_state(_Base, RunId, Expected, 0) ->
    erlang:error({cli_state_timeout, RunId, Expected});
await_cli_state(Base, RunId, Expected, Attempts) ->
    Result = adk_cli:command(
               ["inspect", "run", binary_to_list(RunId),
                "--url", Base]),
    case Result of
        {ok, #{<<"state">> := Expected} = Status} ->
            Status;
        _ ->
            receive after 10 ->
                await_cli_state(Base, RunId, Expected, Attempts - 1)
            end
    end.

register_cli_agent(Name, Pid) ->
    case adk_agent_registry:register_name(Name, Pid) of
        yes -> ok;
        no -> erlang:error({agent_registration_failed, Name})
    end.

cli_blocking_agent_loop(Name) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, #{}, [], #{}}),
            cli_blocking_agent_loop(Name);
        {'$gen_call', _From,
         {run_with_events, _History, _InvocationId}} ->
            cli_blocking_agent_loop(Name);
        stop ->
            ok;
        _Other ->
            cli_blocking_agent_loop(Name)
    end.

safe_stop_registered_agent(Name) ->
    try adk_agent_registry:lookup(Name) of
        {ok, Pid} ->
            _ = catch erlang_adk:stop_agent(Pid),
            ok;
        {error, not_found} ->
            ok
    catch
        _:_ -> ok
    end.

save_application_env(Keys) ->
    [{Key, application:get_env(erlang_adk, Key)} || Key <- Keys].

restore_application_env([]) ->
    ok;
restore_application_env([{Key, undefined} | Rest]) ->
    ok = application:unset_env(erlang_adk, Key),
    restore_application_env(Rest);
restore_application_env([{Key, {ok, Value}} | Rest]) ->
    ok = application:set_env(erlang_adk, Key, Value),
    restore_application_env(Rest).

free_port() ->
    {ok, Socket} = gen_tcp:listen(
                     0, [{ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    Port.

start_oversized_chunked_server(Status) ->
    {ok, Listener} = gen_tcp:listen(
                       0, [binary, {packet, raw}, {active, false},
                           {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Listener),
    {Server, Monitor} = spawn_monitor(
                          fun() ->
                              oversized_chunked_server(Listener, Status)
                          end),
    Base = "http://127.0.0.1:" ++ integer_to_list(Port),
    {Listener, Server, Monitor, Base}.

oversized_chunked_server(Listener, Status) ->
    try gen_tcp:accept(Listener, 2000) of
        {ok, Socket} ->
            try
                {ok, _Request} = receive_http_headers(Socket, <<>>),
                send_oversized_chunked_response(Socket, Status)
            catch
                _:_ -> ok
            after
                _ = catch gen_tcp:close(Socket)
            end;
        {error, _} -> ok
    catch
        _:_ -> ok
    end.

receive_http_headers(_Socket, Acc) when byte_size(Acc) > 16384 ->
    {error, request_headers_too_large};
receive_http_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, 2000) of
                {ok, Chunk} ->
                    receive_http_headers(
                      Socket, <<Acc/binary, Chunk/binary>>);
                {error, _} = Error -> Error
            end;
        _ -> {ok, Acc}
    end.

send_oversized_chunked_response(Socket, Status) ->
    Phrase = case Status of
        200 -> <<"OK">>;
        429 -> <<"Too Many Requests">>
    end,
    ok = gen_tcp:send(
           Socket,
           [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>, Phrase,
            <<"\r\ncontent-type: application/json"
              "\r\ntransfer-encoding: chunked"
              "\r\nconnection: close\r\n\r\n">>]),
    Chunk = binary:copy(<<"x">>, 65536),
    ChunkFrame = [integer_to_binary(byte_size(Chunk), 16), <<"\r\n">>,
                  Chunk, <<"\r\n">>],
    send_chunk_frames(Socket, ChunkFrame, 18).

send_chunk_frames(Socket, _ChunkFrame, 0) ->
    _ = gen_tcp:send(Socket, <<"0\r\n\r\n">>),
    ok;
send_chunk_frames(Socket, ChunkFrame, Remaining) ->
    case gen_tcp:send(Socket, ChunkFrame) of
        ok -> send_chunk_frames(Socket, ChunkFrame, Remaining - 1);
        {error, _} -> ok
    end.

stop_raw_http_server(Listener, Server, Monitor) ->
    _ = catch gen_tcp:close(Listener),
    receive
        {'DOWN', Monitor, process, Server, _Reason} -> ok
    after 2000 ->
        exit(Server, kill),
        receive
            {'DOWN', Monitor, process, Server, _Reason} -> ok
        after 1000 -> ok
        end
    end.

temp_path(Prefix) ->
    filename:join(
      os:getenv("TMPDIR", "/tmp"),
      Prefix ++ "-" ++
          integer_to_list(erlang:unique_integer([positive, monotonic])) ++
          ".json").

assert_config_result(Prefix, Value, Expected) ->
    assert_config_bytes(Prefix, jsx:encode(Value), Expected).

assert_config_bytes(Prefix, Bytes, Expected) ->
    Path = temp_path(Prefix),
    try
        ok = file:write_file(Path, Bytes),
        ?assertEqual(Expected,
                     adk_cli:command(["config", "validate", Path]))
    after
        _ = file:delete(Path)
    end.

unique_binary(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "_", Suffix/binary>>.

restore_env(Name, false) ->
    true = os:unsetenv(Name);
restore_env(Name, Value) ->
    true = os:putenv(Name, Value).
