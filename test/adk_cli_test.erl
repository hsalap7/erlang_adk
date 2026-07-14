-module(adk_cli_test).

-include_lib("eunit/include/eunit.hrl").

-define(CLI_DEV_TOKEN, "cli-test-dev-token-0123456789abcdef").

cli_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun doctor_redacts_environment_case/0,
      fun checked_config_validation_case/0,
      fun checked_repository_examples_case/0,
      fun config_rejects_embedded_secret_case/0,
      fun deterministic_run_case/0,
      fun deterministic_console_case/0,
      fun deterministic_evaluation_case/0,
      fun option_and_url_validation_case/0,
      fun developer_connection_failure_is_structured_case/0,
      fun successful_developer_commands_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_State) ->
    ok.

doctor_redacts_environment_case() ->
    ApiSecret = "cli-doctor-api-secret-61d9",
    DevSecret = "cli-doctor-dev-secret-43c7",
    OldApi = os:getenv("GEMINI_API_KEY"),
    OldDev = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    try
        true = os:putenv("GEMINI_API_KEY", ApiSecret),
        true = os:putenv("ERLANG_ADK_DEV_TOKEN", DevSecret),
        {ok, Report} = adk_cli:command(["doctor"]),
        ?assertEqual(true, maps:get(gemini_api_key_configured, Report)),
        ?assertEqual(true, maps:get(developer_token_configured, Report)),
        Dependencies = maps:get(dependencies, Report),
        ?assertEqual(available, maps:get(oidcc, Dependencies)),
        ?assertEqual(available, maps:get(jose, Dependencies)),
        ?assertEqual(ok, maps:get(status, Report)),
        Encoded = term_to_binary(Report),
        ?assertEqual(nomatch,
                     binary:match(Encoded, list_to_binary(ApiSecret))),
        ?assertEqual(nomatch,
                     binary:match(Encoded, list_to_binary(DevSecret)))
    after
        restore_env("GEMINI_API_KEY", OldApi),
        restore_env("ERLANG_ADK_DEV_TOKEN", OldDev)
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

option_and_url_validation_case() ->
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

temp_path(Prefix) ->
    filename:join(
      os:getenv("TMPDIR", "/tmp"),
      Prefix ++ "-" ++
          integer_to_list(erlang:unique_integer([positive, monotonic])) ++
          ".json").

unique_binary(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "_", Suffix/binary>>.

restore_env(Name, false) ->
    true = os:unsetenv(Name);
restore_env(Name, Value) ->
    true = os:putenv(Name, Value).
