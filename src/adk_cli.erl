%% @doc Integrated command-line tooling for local Erlang ADK development.
%%
%% The CLI deliberately consumes JSON configuration with a small, checked key
%% set. It never accepts model API keys in files; providers read their normal
%% environment-backed credentials. `inspect' talks to the authenticated local
%% developer API, while `run' and `evaluate' execute in the current VM.
-module(adk_cli).

-export([main/1, command/1, command/2, usage/0]).

-define(DEFAULT_MODEL, <<"gemini-3.1-flash-lite">>).
-define(DEFAULT_BASE_URL, <<"http://127.0.0.1:8080">>).
-define(DEFAULT_TIMEOUT, 120000).
-define(MAX_CONFIG_BYTES, 1048576).

-spec main([string()]) -> no_return() | ok.
main(Args) ->
    case command(Args) of
        {ok, #{command := serve} = Result} ->
            write_result(Result),
            wait_for_shutdown();
        {ok, Result} ->
            write_result(Result),
            ok;
        {error, Reason} ->
            write_error(Reason),
            erlang:halt(1)
    end.

-spec command([string()]) -> {ok, term()} | {error, term()}.
command(Args) ->
    command(Args, default_console_io()).

%% @doc Execute a command with an injectable interactive IO adapter.  The
%% second form makes the console deterministic in tests and embeddable in an
%% Erlang shell without replacing the caller's group leader.
-spec command([string()], map()) -> {ok, term()} | {error, term()}.
command(["console" | Args], Io) ->
    with_options(
      Args,
      #{"--config" => config,
        "--app" => app_name,
        "--user" => user_id,
        "--session" => session_id,
        "--timeout" => timeout},
      fun(Opts) -> console_command(Opts, Io) end);
command(Args, _Io) ->
    command_noninteractive(Args).

command_noninteractive([]) ->
    {ok, usage()};
command_noninteractive(["help"]) ->
    {ok, usage()};
command_noninteractive(["--help"]) ->
    {ok, usage()};
command_noninteractive(["doctor"]) ->
    doctor();
command_noninteractive(["config", "validate", Path]) ->
    validate_config_command(Path);
command_noninteractive(["run" | Args]) ->
    with_options(
      Args,
      #{"--config" => config,
        "--message" => message,
        "--app" => app_name,
        "--user" => user_id,
        "--session" => session_id,
        "--timeout" => timeout},
      fun run_command/1);
command_noninteractive(["evaluate" | Args]) ->
    with_options(
      Args,
      #{"--config" => config,
        "--dataset" => dataset,
        "--concurrency" => concurrency,
        "--timeout" => timeout},
      fun evaluate_command/1);
command_noninteractive(["serve" | Args]) ->
    with_options(
      Args,
      #{"--config" => config,
        "--port" => port,
        "--ip" => ip},
      fun serve_command/1);
command_noninteractive(["inspect", "agents" | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun inspect_agents/1);
command_noninteractive(["inspect", "diagnostics" | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun inspect_diagnostics/1);
command_noninteractive(["inspect", "run", RunId | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> inspect_run(RunId, Opts) end);
command_noninteractive(["inspect", "sessions", App, User | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> inspect_sessions(App, User, Opts) end);
command_noninteractive(["inspect", "session", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> inspect_session(App, User, Session, Opts) end);
command_noninteractive(["inspect", "context", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> inspect_context(App, User, Session, Opts) end);
command_noninteractive(
  ["inspect", "context-lifecycle", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--model" => model},
      fun(Opts) -> inspect_context_lifecycle(
                     App, User, Session, Opts) end);
command_noninteractive(
  ["context-cache", "invalidate", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--model" => model,
              "--confirm-json" => confirm_json},
      fun(Opts) -> invalidate_remote_context_cache(
                     App, User, Session, Opts) end);
command_noninteractive(["inspect", "artifacts", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--limit" => limit,
              "--cursor" => cursor},
      fun(Opts) -> inspect_artifacts(App, User, Session, Opts) end);
command_noninteractive(
  ["inspect", "artifact", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--name" => name,
              "--limit" => limit, "--cursor" => cursor},
      fun(Opts) -> inspect_artifact_versions(
                     App, User, Session, Opts) end);
command_noninteractive(["inspect", "memory", App, User | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> inspect_memory(App, User, Opts) end);
command_noninteractive(["memory", "search", App, User | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--query" => query,
              "--filter-json" => filter_json, "--limit" => limit},
      fun(Opts) -> search_remote_memory(App, User, Opts) end);
command_noninteractive(
  ["artifact", "delete", App, User, Session, Name, Selector | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--confirm-json" => confirm_json},
      fun(Opts) -> delete_remote_artifact(
                     App, User, Session, Name, Selector, Opts) end);
command_noninteractive(
  ["memory", "erase", App, User, "entry", Id | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--confirm-json" => confirm_json},
      fun(Opts) -> erase_remote_memory(
                     App, User, entry, Id, Opts) end);
command_noninteractive(
  ["memory", "erase", App, User, "session", Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--confirm-json" => confirm_json},
      fun(Opts) -> erase_remote_memory(
                     App, User, session, Session, Opts) end);
command_noninteractive(["memory", "erase", App, User, "user" | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--confirm-json" => confirm_json},
      fun(Opts) -> erase_remote_memory(App, User, user, User, Opts) end);
command_noninteractive(["session", "create", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> create_remote_session(App, User, Session, Opts) end);
command_noninteractive(["session", "delete", App, User, Session | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> delete_remote_session(App, User, Session, Opts) end);
command_noninteractive(["session", "state", App, User, Session | Args]) ->
    with_options(
      Args,
      #{"--url" => base_url, "--delta-json" => delta_json},
      fun(Opts) -> update_remote_session_state(
                     App, User, Session, Opts) end);
command_noninteractive(["cancel", RunId | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun(Opts) -> cancel_remote_run(RunId, Opts) end);
command_noninteractive(["resume", RunId | Args]) ->
    with_options(
      Args,
      #{"--url" => base_url, "--response-json" => response_json},
      fun(Opts) -> resume_remote_run(RunId, Opts) end);
command_noninteractive(_Args) ->
    {error, invalid_command}.

-spec usage() -> binary().
usage() ->
    <<"Erlang ADK developer CLI\n\n"
      "  adk doctor\n"
      "  adk config validate AGENT.json\n"
      "  adk run --config AGENT.json --message TEXT [--user ID --session ID]\n"
      "  adk console --config AGENT.json [--user ID --session ID]\n"
      "  adk evaluate --config AGENT.json --dataset DATASET.json\n"
      "  adk serve [--config AGENT.json] [--port 8080 --ip 127.0.0.1]\n"
      "  adk inspect agents [--url URL]\n"
      "  adk inspect diagnostics [--url URL]\n"
      "  adk inspect run RUN_ID [--url http://127.0.0.1:8080]\n"
      "  adk inspect sessions APP USER [--url URL]\n"
      "  adk inspect session APP USER SESSION [--url URL]\n"
      "  adk inspect context APP USER SESSION [--url URL]\n"
      "  adk inspect context-lifecycle APP USER SESSION --model MODEL [--url URL]\n"
      "  adk context-cache invalidate APP USER SESSION --model MODEL --confirm-json JSON\n"
      "  adk inspect artifacts APP USER SESSION [--limit N --cursor NAME]\n"
      "  adk inspect artifact APP USER SESSION --name NAME [--limit N --cursor VERSION]\n"
      "  adk inspect memory APP USER [--url URL]\n"
      "  adk memory search APP USER --query TEXT [--filter-json JSON --limit N]\n"
      "  adk artifact delete APP USER SESSION NAME SELECTOR --confirm-json JSON\n"
      "  adk memory erase APP USER entry ID --confirm-json JSON\n"
      "  adk memory erase APP USER session SESSION --confirm-json JSON\n"
      "  adk memory erase APP USER user --confirm-json JSON\n"
      "  adk session create APP USER SESSION [--url URL]\n"
      "  adk session delete APP USER SESSION [--url URL]\n"
      "  adk session state APP USER SESSION --delta-json JSON [--url URL]\n"
      "  adk cancel RUN_ID [--url URL]\n"
      "  adk resume RUN_ID --response-json JSON [--url URL]\n\n"
      "Model credentials stay in provider environment variables. The local\n"
      "developer API uses ERLANG_ADK_DEV_TOKEN.\n">>.

with_options(Args, Allowed, Fun) ->
    case parse_options(Args, Allowed, #{}) of
        {ok, Opts} -> Fun(Opts);
        {error, _} = Error -> Error
    end.

parse_options([], _Allowed, Acc) ->
    {ok, Acc};
parse_options([Flag, Value | Rest], Allowed, Acc) ->
    case maps:find(Flag, Allowed) of
        {ok, Key} ->
            case maps:is_key(Key, Acc) of
                true -> {error, {duplicate_option, Flag}};
                false -> parse_options(Rest, Allowed, Acc#{Key => Value})
            end;
        error ->
            {error, {unknown_option, Flag}}
    end;
parse_options([Flag], _Allowed, _Acc) ->
    {error, {missing_option_value, Flag}}.

doctor() ->
    _ = application:load(erlang_adk),
    ProviderStatus = module_status(adk_llm_gemini),
    DependencyModules = [cowboy, gun, jsx, telemetry, oidcc, jose],
    Dependencies = maps:from_list(
                     [{Module, module_status(Module)}
                      || Module <- DependencyModules]),
    DependenciesAvailable = lists:all(
                              fun(available) -> true;
                                 (_) -> false
                              end,
                              maps:values(Dependencies)),
    ApiKeyConfigured = valid_environment_secret("GEMINI_API_KEY"),
    DevTokenConfigured = valid_environment_secret(
                           "ERLANG_ADK_DEV_TOKEN"),
    Warnings0 = case ApiKeyConfigured of
        true -> [];
        false -> [<<"GEMINI_API_KEY is not configured; live model calls will fail">>]
    end,
    Warnings = case application:get_env(erlang_adk, dev_enabled, false) of
        true when not DevTokenConfigured ->
            [<<"dev_enabled is true but ERLANG_ADK_DEV_TOKEN is missing">>
             | Warnings0];
        _ -> Warnings0
    end,
    {ok, #{command => doctor,
           status => case {ProviderStatus, DependenciesAvailable} of
                         {available, true} -> ok;
                         _ -> degraded
                     end,
           otp_release => unicode:characters_to_binary(
                            erlang:system_info(otp_release)),
           erlang_adk_version => application_version(),
           default_model => ?DEFAULT_MODEL,
           gemini_provider => ProviderStatus,
           dependencies => Dependencies,
           gemini_api_key_configured => ApiKeyConfigured,
           developer_token_configured => DevTokenConfigured,
           warnings => lists:reverse(Warnings)}}.

validate_config_command(Path) ->
    case load_agent_file(Path) of
        {ok, Agent} ->
            {ok, #{command => config_validate,
                   status => valid,
                   name => maps:get(name, Agent),
                   provider => maps:get(provider_name, Agent),
                   model => maps:get(model, Agent),
                   tool_count => length(maps:get(tools, Agent))}};
        {error, _} = Error -> Error
    end.

run_command(Opts) ->
    with_required(Opts, [config, message],
      fun() ->
          case parse_positive_integer(
                 maps:get(timeout, Opts,
                          integer_to_list(?DEFAULT_TIMEOUT)), timeout) of
              {ok, Timeout} -> run_loaded_agent(Opts, Timeout);
              {error, _} = Error -> Error
          end
      end).

run_loaded_agent(Opts, Timeout) ->
    case load_agent_file(maps:get(config, Opts)) of
        {error, _} = Error -> Error;
        {ok, Agent} ->
            case ensure_application_started() of
                ok -> execute_cli_run(Agent, Opts, Timeout);
                {error, _} = Error -> Error
            end
    end.

execute_cli_run(Agent, Opts, Timeout) ->
    Name = maps:get(name, Agent),
    Config = maps:get(config, Agent),
    Tools = maps:get(tools, Agent),
    case erlang_adk:spawn_agent(Name, Config, Tools) of
        {error, Reason} -> {error, {agent_start_failed, public_reason(Reason)}};
        {ok, AgentPid} ->
            try
                AppName = option_binary(Opts, app_name, <<"adk-cli">>),
                UserId = option_binary(Opts, user_id, <<"local-user">>),
                SessionId = option_binary(
                              Opts, session_id, generate_id(<<"session">>)),
                RunnerOptions0 = maps:get(runner_options, Agent, #{}),
                RunnerOptions = RunnerOptions0#{run_timeout => Timeout},
                Runner = adk_runner:new(
                           AgentPid, AppName, erlang_adk_session,
                           RunnerOptions),
                Message = unicode:characters_to_binary(
                            maps:get(message, Opts)),
                case adk_run:start(
                       Runner, UserId, SessionId, Message,
                       #{retention_ms => erlang:max(60000, Timeout + 1000),
                         max_buffered_events => 256}) of
                    {ok, RunId} ->
                        Outcome = adk_run:await(RunId, Timeout + 1000),
                        cli_run_result(RunId, SessionId, Outcome);
                    {error, Reason} ->
                        {error, {run_start_failed, public_reason(Reason)}}
                end
            after
                _ = catch erlang_adk:stop_agent(AgentPid)
            end
    end.

cli_run_result(RunId, SessionId, {completed, Text}) ->
    {ok, #{command => run, run_id => RunId, session_id => SessionId,
           outcome => completed, text => safe_binary(Text)}};
cli_run_result(RunId, SessionId, {paused, Event}) ->
    EventMap = case adk_event:encode(Event) of
        {ok, Encoded} -> Encoded;
        {error, _} -> #{<<"encoding_error">> => true}
    end,
    {ok, #{command => run, run_id => RunId, session_id => SessionId,
           outcome => paused, event => EventMap,
           note => <<"Use the persistent serve/UI mode for cross-command resume">>}};
cli_run_result(RunId, SessionId, {cancelled, Reason}) ->
    {ok, #{command => run, run_id => RunId, session_id => SessionId,
           outcome => cancelled, reason => public_reason(Reason)}};
cli_run_result(_RunId, _SessionId, {failed, Reason}) ->
    {error, {run_failed, public_reason(Reason)}};
cli_run_result(RunId, _SessionId, {error, timeout}) ->
    _ = adk_run:cancel(RunId, cli_timeout),
    {error, timeout};
cli_run_result(_RunId, _SessionId, Other) ->
    {error, {invalid_run_outcome, public_reason(Other)}}.

console_command(Opts, Io) ->
    with_required(Opts, [config],
      fun() ->
          case {validate_console_io(Io),
                parse_positive_integer(
                  maps:get(timeout, Opts,
                           integer_to_list(?DEFAULT_TIMEOUT)), timeout)} of
              {ok, {ok, Timeout}} ->
                  start_console(Opts, Timeout, Io);
              {{error, _} = Error, _} -> Error;
              {_, {error, _} = Error} -> Error
          end
      end).

start_console(Opts, Timeout, Io) ->
    case load_agent_file(maps:get(config, Opts)) of
        {error, _} = Error -> Error;
        {ok, Agent} ->
            case ensure_application_started() of
                ok -> run_console(Agent, Opts, Timeout, Io);
                {error, _} = Error -> Error
            end
    end.

run_console(Agent, Opts, Timeout, Io) ->
    case erlang_adk:spawn_agent(
           maps:get(name, Agent), maps:get(config, Agent),
           maps:get(tools, Agent)) of
        {error, Reason} ->
            {error, {agent_start_failed, public_reason(Reason)}};
        {ok, AgentPid} ->
            try
                AppName = option_binary(Opts, app_name, <<"adk-cli">>),
                UserId = option_binary(Opts, user_id, <<"local-user">>),
                SessionId = option_binary(
                              Opts, session_id,
                              generate_id(<<"session">>)),
                RunnerOptions = (maps:get(runner_options, Agent, #{}))#{
                    run_timeout => Timeout},
                Runner = adk_runner:new(
                           AgentPid, AppName, erlang_adk_session,
                           RunnerOptions),
                console_write(
                  Io,
                  <<"Erlang ADK console. /help lists commands; /exit closes.\n">>),
                console_loop(
                  #{runner => Runner, app_name => AppName,
                    user_id => UserId, session_id => SessionId,
                    timeout => Timeout, io => Io, turns => 0,
                    paused_run_id => undefined})
            after
                _ = catch erlang_adk:stop_agent(AgentPid)
            end
    end.

console_loop(State = #{io := Io, session_id := SessionId}) ->
    Prompt = <<"adk[", SessionId/binary, "]> ">>,
    case console_read(Io, Prompt) of
        eof -> console_summary(State, eof);
        {error, Reason} -> {error, {console_io_failed,
                                    public_reason(Reason)}};
        {ok, Line0} ->
            Line = trim_binary(Line0),
            case console_action(Line) of
                exit -> console_summary(State, closed);
                help ->
                    console_write(Io, console_help()),
                    console_loop(State);
                inspect ->
                    console_inspect(State),
                    console_loop(State);
                {switch_session, NewSession} ->
                    console_write(
                      Io, <<"session: ", NewSession/binary, "\n">>),
                    console_loop(State#{session_id => NewSession,
                                        paused_run_id => undefined});
                new_session ->
                    NewSession = generate_id(<<"session">>),
                    console_write(
                      Io, <<"session: ", NewSession/binary, "\n">>),
                    console_loop(State#{session_id => NewSession,
                                        paused_run_id => undefined});
                {resume, ResponseJson} ->
                    console_resume(ResponseJson, State);
                empty -> console_loop(State);
                {message, Message} -> console_turn(Message, State);
                {error, Reason} ->
                    console_write_json(
                      Io, #{status => error, reason => Reason}),
                    console_loop(State)
            end
    end.

console_turn(Message, State = #{runner := Runner, user_id := UserId,
                                session_id := SessionId,
                                timeout := Timeout, io := Io,
                                turns := Turns}) ->
    RunOptions = #{retention_ms => erlang:max(60000, Timeout + 1000),
                   max_buffered_events => 256},
    case adk_run:start(Runner, UserId, SessionId, Message, RunOptions) of
        {ok, RunId} ->
            console_outcome(
              RunId, adk_run:await(RunId, Timeout + 1000),
              State#{turns => Turns + 1});
        {error, Reason} ->
            console_write_json(
              Io, #{status => error,
                    reason => {run_start_failed, public_reason(Reason)}}),
            console_loop(State)
    end.

console_resume(_ResponseJson, State = #{paused_run_id := undefined,
                                        io := Io}) ->
    console_write_json(Io, #{status => error, reason => no_paused_run}),
    console_loop(State);
console_resume(ResponseJson, State = #{paused_run_id := RunId,
                                       timeout := Timeout, io := Io}) ->
    case decode_json_binary(ResponseJson) of
        {ok, Response} ->
            case adk_run:resume(RunId, Response) of
                {ok, ResumedRunId} ->
                    console_outcome(
                      ResumedRunId,
                      adk_run:await(ResumedRunId, Timeout + 1000), State);
                {error, Reason} ->
                    console_write_json(
                      Io, #{status => error,
                            reason => {resume_failed,
                                       public_reason(Reason)}}),
                    console_loop(State)
            end;
        {error, _} ->
            console_write_json(Io, #{status => error,
                                     reason => invalid_resume_json}),
            console_loop(State)
    end.

console_outcome(_RunId, {completed, Text}, State = #{io := Io}) ->
    console_write(Io, <<(safe_binary(Text))/binary, "\n">>),
    console_loop(State#{paused_run_id => undefined});
console_outcome(RunId, {paused, Event}, State = #{io := Io}) ->
    Encoded = case adk_event:encode(Event) of
        {ok, Value} -> Value;
        {error, _} -> #{<<"encoding_error">> => true}
    end,
    console_write_json(
      Io, #{status => paused, run_id => RunId, event => Encoded,
            next => <<"/resume JSON">>}),
    console_loop(State#{paused_run_id => RunId});
console_outcome(_RunId, {cancelled, Reason}, State = #{io := Io}) ->
    console_write_json(Io, #{status => cancelled,
                             reason => public_reason(Reason)}),
    console_loop(State#{paused_run_id => undefined});
console_outcome(_RunId, {failed, Reason}, State = #{io := Io}) ->
    console_write_json(Io, #{status => failed,
                             reason => public_reason(Reason)}),
    console_loop(State#{paused_run_id => undefined});
console_outcome(RunId, {error, timeout}, State = #{io := Io}) ->
    _ = adk_run:cancel(RunId, cli_timeout),
    console_write_json(Io, #{status => error, reason => timeout}),
    console_loop(State#{paused_run_id => undefined});
console_outcome(_RunId, Other, State = #{io := Io}) ->
    console_write_json(Io, #{status => error,
                             reason => public_reason(Other)}),
    console_loop(State#{paused_run_id => undefined}).

console_inspect(#{app_name := App, user_id := User,
                  session_id := Session, io := Io}) ->
    case erlang_adk_session:get_session(App, User, Session) of
        {ok, Stored} -> console_write_json(Io, Stored);
        {error, not_found} ->
            console_write_json(Io, #{status => not_found,
                                     session_id => Session});
        {error, Reason} ->
            console_write_json(Io, #{status => error,
                                     reason => public_reason(Reason)})
    end.

console_action(<<>>) -> empty;
console_action(<<"/exit">>) -> exit;
console_action(<<"/quit">>) -> exit;
console_action(<<"/help">>) -> help;
console_action(<<"/inspect">>) -> inspect;
console_action(<<"/new">>) -> new_session;
console_action(<<"/session ", Session0/binary>>) ->
    case trim_binary(Session0) of
        <<>> -> {error, invalid_session_id};
        Session when byte_size(Session) =< 4096 ->
            {switch_session, Session};
        _ -> {error, invalid_session_id}
    end;
console_action(<<"/resume ", Response0/binary>>) ->
    case trim_binary(Response0) of
        <<>> -> {error, missing_resume_json};
        Response -> {resume, Response}
    end;
console_action(<<"/", _/binary>>) -> {error, unknown_console_command};
console_action(Message) when byte_size(Message) =< ?MAX_CONFIG_BYTES ->
    {message, Message};
console_action(_Message) -> {error, message_too_large}.

console_help() ->
    <<"/help                 show commands\n"
      "/inspect              print the current session\n"
      "/new                  switch to a generated session\n"
      "/session SESSION_ID   switch sessions\n"
      "/resume JSON          resume the last paused run\n"
      "/exit                 close the console\n">>.

console_summary(State, Outcome) ->
    {ok, #{command => console, outcome => Outcome,
           app_name => maps:get(app_name, State),
           user_id => maps:get(user_id, State),
           session_id => maps:get(session_id, State),
           turns => maps:get(turns, State)}}.

default_console_io() ->
    #{read => fun(Prompt) ->
                  case io:get_line(binary_to_list(Prompt)) of
                      eof -> eof;
                      {error, _} = Error -> Error;
                      Line -> {ok, unicode:characters_to_binary(Line)}
                  end
              end,
      write => fun(Text) -> io:put_chars(Text), ok end}.

validate_console_io(#{read := Read, write := Write})
  when is_function(Read, 1), is_function(Write, 1) -> ok;
validate_console_io(_Io) -> {error, invalid_console_io}.

console_read(#{read := Read}, Prompt) ->
    try Read(Prompt) of
        eof -> eof;
        {ok, Value} when is_binary(Value); is_list(Value) ->
            {ok, safe_binary(Value)};
        {error, _} = Error -> Error;
        _ -> {error, invalid_console_input}
    catch
        Class:Reason -> {error, {Class, public_reason(Reason)}}
    end.

console_write(#{write := Write}, Text0) ->
    Text = safe_binary(Text0),
    try Write(Text) of
        _ -> ok
    catch
        _:_ -> ok
    end.

console_write_json(Io, Value) ->
    case adk_json:normalize(adk_secret_redactor:redact(Value)) of
        {ok, Json} -> console_write(Io, <<(jsx:encode(Json))/binary, "\n">>);
        {error, _} -> console_write(Io, <<"{\"status\":\"error\"}\n">>)
    end.

trim_binary(Value) ->
    try string:trim(safe_binary(Value)) of
        Trimmed when is_binary(Trimmed) -> Trimmed;
        Trimmed -> safe_binary(Trimmed)
    catch
        _:_ -> <<>>
    end.

evaluate_command(Opts) ->
    with_required(Opts, [config, dataset],
      fun() ->
          case {parse_positive_integer(
                  maps:get(timeout, Opts,
                           integer_to_list(?DEFAULT_TIMEOUT)), timeout),
                parse_positive_integer(
                  maps:get(concurrency, Opts, "1"), concurrency)} of
              {{ok, Timeout}, {ok, Concurrency}} ->
                  evaluate_loaded(Opts, Timeout, Concurrency);
              {{error, _} = Error, _} -> Error;
              {_, {error, _} = Error} -> Error
          end
      end).

evaluate_loaded(Opts, Timeout, Concurrency) ->
    case {load_agent_file(maps:get(config, Opts)),
          load_dataset(maps:get(dataset, Opts))} of
        {{ok, Agent}, {ok, Dataset}} ->
            case ensure_application_started() of
                ok -> execute_evaluation(Agent, Dataset, Timeout, Concurrency);
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

execute_evaluation(Agent, Dataset, Timeout, Concurrency) ->
    case erlang_adk:spawn_agent(
           maps:get(name, Agent), maps:get(config, Agent),
           maps:get(tools, Agent)) of
        {error, Reason} -> {error, {agent_start_failed, public_reason(Reason)}};
        {ok, AgentPid} ->
            try
                Metric = fun(Expected, Actual) ->
                    case safe_binary(Expected) =:= safe_binary(Actual) of
                        true -> 1.0;
                        false -> 0.0
                    end
                end,
                case adk_eval:run(
                       AgentPid, Dataset, Metric,
                       #{timeout => Timeout, concurrency => Concurrency}) of
                    {ok, Report} ->
                        {ok, #{command => evaluate, report => Report}};
                    {error, Reason} ->
                        {error, {evaluation_failed, public_reason(Reason)}}
                end
            after
                _ = catch erlang_adk:stop_agent(AgentPid)
            end
    end.

serve_command(Opts) ->
    case {parse_port(maps:get(port, Opts, "8080")),
          parse_loopback_ip(maps:get(ip, Opts, "127.0.0.1")),
          developer_token()} of
        {{ok, Port}, {ok, Ip}, ok} ->
            case prepare_developer_application(Port, Ip) of
                ok -> maybe_start_served_agent(Opts, Port, Ip);
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

maybe_start_served_agent(Opts, Port, Ip) ->
    case maps:find(config, Opts) of
        error ->
            {ok, serve_result(Port, Ip, undefined)};
        {ok, Path} ->
            case load_agent_file(Path) of
                {error, _} = Error -> Error;
                {ok, Agent} ->
                    case erlang_adk:spawn_agent(
                           maps:get(name, Agent), maps:get(config, Agent),
                           maps:get(tools, Agent)) of
                        {ok, _Pid} ->
                            {ok, serve_result(
                                   Port, Ip, maps:get(name, Agent))};
                        {error, Reason} ->
                            {error, {agent_start_failed,
                                     public_reason(Reason)}}
                    end
            end
    end.

serve_result(Port, Ip, AgentName) ->
    IpText = unicode:characters_to_binary(inet:ntoa(Ip)),
    Base = <<"http://", IpText/binary, ":",
             (integer_to_binary(Port))/binary>>,
    #{command => serve, status => listening, url => <<Base/binary, "/dev">>,
      api_url => <<Base/binary, "/dev/v1">>, agent_name => AgentName,
      note => <<"Runs survive browser disconnects; Ctrl-C stops this VM">>}.

inspect_run(RunId0, Opts) ->
    RunId = safe_binary(RunId0),
    remote_json(get, <<"/dev/v1/runs/", (quote(RunId))/binary>>,
                undefined, Opts).

inspect_agents(Opts) ->
    remote_json(get, <<"/dev/v1/agents">>, undefined, Opts).

inspect_diagnostics(Opts) ->
    remote_json(get, <<"/dev/v1/diagnostics">>, undefined, Opts).

inspect_sessions(App0, User0, Opts) ->
    App = quote(safe_binary(App0)),
    User = quote(safe_binary(User0)),
    remote_json(
      get, <<"/dev/v1/sessions/", App/binary, "/", User/binary>>,
      undefined, Opts).

inspect_session(App0, User0, Session0, Opts) ->
    App = quote(safe_binary(App0)),
    User = quote(safe_binary(User0)),
    Session = quote(safe_binary(Session0)),
    remote_json(
      get,
      <<"/dev/v1/sessions/", App/binary, "/", User/binary, "/",
        Session/binary>>, undefined, Opts).

inspect_context(App0, User0, Session0, Opts) ->
    App = quote(safe_binary(App0)),
    User = quote(safe_binary(User0)),
    Session = quote(safe_binary(Session0)),
    remote_json(
      get,
      <<"/dev/v1/context/", App/binary, "/", User/binary, "/",
        Session/binary>>, undefined, Opts).

inspect_context_lifecycle(App0, User0, Session0, Opts) ->
    with_required(Opts, [model],
      fun() ->
          Model = option_binary(Opts, model, <<>>),
          case valid_nonempty_binary(Model) of
              false -> {error, invalid_context_cache_model};
              true ->
                  App = quote(safe_binary(App0)),
                  User = quote(safe_binary(User0)),
                  Session = quote(safe_binary(Session0)),
                  remote_json(
                    get,
                    <<"/dev/v1/context/", App/binary, "/", User/binary,
                      "/", Session/binary, "/lifecycle?model=",
                      (quote(Model))/binary>>, undefined, Opts)
          end
      end).

invalidate_remote_context_cache(App0, User0, Session0, Opts) ->
    with_required(Opts, [model, confirm_json],
      fun() ->
          AppRaw = safe_binary(App0),
          UserRaw = safe_binary(User0),
          SessionRaw = safe_binary(Session0),
          Model = option_binary(Opts, model, <<>>),
          case valid_nonempty_binary(Model) of
              false -> {error, invalid_context_cache_model};
              true ->
                  case inspect_context_lifecycle(
                         AppRaw, UserRaw, SessionRaw, Opts) of
                      {ok, Lifecycle} ->
                          checked_remote_context_cache_invalidation(
                            AppRaw, UserRaw, SessionRaw, Model,
                            Lifecycle, Opts);
                      {error, _} = Error -> Error
                  end
          end
      end).

checked_remote_context_cache_invalidation(App, User, Session, Model,
                                          Lifecycle, Opts) ->
    Cache = maps:get(<<"cache">>, Lifecycle, #{}),
    Fingerprint = maps:get(<<"scope_fingerprint">>, Cache, undefined),
    Expected = #{<<"app_name">> => App,
                 <<"user_id">> => User,
                 <<"session_id">> => Session,
                 <<"model">> => Model,
                 <<"scope_fingerprint">> => Fingerprint},
    case is_binary(Fingerprint) andalso
         checked_confirmation(Opts, Expected) =:= ok of
        false -> {error, confirmation_does_not_match_target};
        true ->
            AppPath = quote(App),
            UserPath = quote(User),
            SessionPath = quote(Session),
            Payload = #{<<"model">> => Model, <<"confirm">> => Expected},
            remote_json(
              post,
              <<"/dev/v1/context/", AppPath/binary, "/", UserPath/binary,
                "/", SessionPath/binary, "/cache/invalidate">>,
              jsx:encode(Payload), Opts)
    end.

inspect_artifacts(App0, User0, Session0, Opts) ->
    case resource_page_query(Opts, name) of
        {error, _} = Error -> Error;
        {ok, Query} ->
            App = quote(safe_binary(App0)),
            User = quote(safe_binary(User0)),
            Session = quote(safe_binary(Session0)),
            remote_json(
              get,
              <<"/dev/v1/artifacts/", App/binary, "/", User/binary,
                "/", Session/binary, Query/binary>>, undefined, Opts)
    end.

inspect_artifact_versions(App0, User0, Session0, Opts) ->
    with_required(Opts, [name],
      fun() ->
          Name = option_binary(Opts, name, <<>>),
          case {valid_nonempty_binary(Name),
                resource_page_query(Opts, version)} of
              {true, {ok, PageQuery}} ->
                  App = quote(safe_binary(App0)),
                  User = quote(safe_binary(User0)),
                  Session = quote(safe_binary(Session0)),
                  NameQuery = <<"?name=", (quote(Name))/binary>>,
                  Query = append_query(NameQuery, PageQuery),
                  remote_json(
                    get,
                    <<"/dev/v1/artifacts/", App/binary, "/", User/binary,
                      "/", Session/binary, "/versions", Query/binary>>,
                    undefined, Opts);
              {false, _} -> {error, invalid_artifact_name};
              {_, {error, _} = Error} -> Error
          end
      end).

inspect_memory(App0, User0, Opts) ->
    App = quote(safe_binary(App0)),
    User = quote(safe_binary(User0)),
    remote_json(
      get, <<"/dev/v1/memory/", App/binary, "/", User/binary>>,
      undefined, Opts).

search_remote_memory(App0, User0, Opts) ->
    with_required(Opts, [query],
      fun() ->
          Query = option_binary(Opts, query, <<>>),
          case {valid_nonempty_binary(Query), remote_memory_options(Opts)} of
              {true, {ok, SearchOptions}} ->
                  App = quote(safe_binary(App0)),
                  User = quote(safe_binary(User0)),
                  Payload = SearchOptions#{<<"query">> => Query},
                  remote_json(
                    post,
                    <<"/dev/v1/memory/", App/binary, "/", User/binary,
                      "/search">>, jsx:encode(Payload), Opts);
              {false, _} -> {error, invalid_memory_query};
              {_, {error, _} = Error} -> Error
          end
      end).

delete_remote_artifact(App0, User0, Session0, Name0, Selector0, Opts) ->
    with_required(Opts, [confirm_json],
      fun() ->
          AppRaw = safe_binary(App0),
          UserRaw = safe_binary(User0),
          SessionRaw = safe_binary(Session0),
          Name = safe_binary(Name0),
          case cli_artifact_selector(Selector0) of
              {error, _} = Error -> Error;
              {ok, Selector} ->
                  Expected = #{<<"app_name">> => AppRaw,
                               <<"user_id">> => UserRaw,
                               <<"session_id">> => SessionRaw,
                               <<"name">> => Name,
                               <<"selector">> => Selector},
                  case checked_confirmation(Opts, Expected) of
                      ok ->
                          App = quote(AppRaw),
                          User = quote(UserRaw),
                          Session = quote(SessionRaw),
                          Payload = #{<<"name">> => Name,
                                      <<"selector">> => Selector,
                                      <<"confirm">> => Expected},
                          remote_json(
                            post,
                            <<"/dev/v1/artifacts/", App/binary, "/",
                              User/binary, "/", Session/binary, "/delete">>,
                            jsx:encode(Payload), Opts);
                      {error, _} = Error -> Error
                  end
          end
      end).

erase_remote_memory(App0, User0, Target, Identifier0, Opts) ->
    with_required(Opts, [confirm_json],
      fun() ->
          AppRaw = safe_binary(App0),
          UserRaw = safe_binary(User0),
          Identifier = safe_binary(Identifier0),
          TargetBin = atom_to_binary(Target, utf8),
          Expected = #{<<"app_name">> => AppRaw,
                       <<"user_id">> => UserRaw,
                       <<"target">> => TargetBin,
                       <<"identifier">> => Identifier},
          case checked_confirmation(Opts, Expected) of
              ok ->
                  App = quote(AppRaw),
                  User = quote(UserRaw),
                  Payload0 = #{<<"target">> => TargetBin,
                               <<"confirm">> => Expected},
                  Payload = case Target of
                      entry -> Payload0#{<<"id">> => Identifier};
                      session -> Payload0#{<<"session_id">> => Identifier};
                      user -> Payload0
                  end,
                  remote_json(
                    post,
                    <<"/dev/v1/memory/", App/binary, "/", User/binary,
                      "/erase">>, jsx:encode(Payload), Opts);
              {error, _} = Error -> Error
          end
      end).

resource_page_query(Opts, CursorType) ->
    case cli_page_limit(Opts) of
        {error, _} = Error -> Error;
        {ok, LimitPart} ->
            case maps:find(cursor, Opts) of
                error -> {ok, query_parts(LimitPart)};
                {ok, Cursor0} ->
                    Cursor = safe_binary(Cursor0),
                    case valid_cli_cursor(CursorType, Cursor) of
                        true ->
                            {ok, query_parts(
                                   LimitPart ++
                                   [{<<"cursor">>, quote(Cursor)}])};
                        false -> {error, invalid_resource_cursor}
                    end
            end
    end.

cli_page_limit(Opts) ->
    case maps:find(limit, Opts) of
        error -> {ok, []};
        {ok, Value} ->
            case parse_positive_integer(Value, limit) of
                {ok, Integer} when Integer =< 1000 ->
                    {ok, [{<<"limit">>, integer_to_binary(Integer)}]};
                _ -> {error, invalid_resource_limit}
            end
    end.

valid_cli_cursor(name, Cursor) -> valid_nonempty_binary(Cursor);
valid_cli_cursor(version, Cursor) ->
    case positive_binary_integer(Cursor) of
        {ok, _} -> true;
        _ -> false
    end.

query_parts([]) -> <<>>;
query_parts(Parts) ->
    Encoded = [<<Key/binary, "=", Value/binary>> || {Key, Value} <- Parts],
    <<"?", (iolist_to_binary(lists:join(<<"&">>, Encoded)))/binary>>.

append_query(NameQuery, <<>>) -> NameQuery;
append_query(NameQuery, <<"?", Rest/binary>>) ->
    <<NameQuery/binary, "&", Rest/binary>>.

remote_memory_options(Opts) ->
    case {remote_memory_filter(Opts), cli_page_limit(Opts)} of
        {{ok, Filter}, {ok, LimitParts}} ->
            Base = case map_size(Filter) of
                0 -> #{};
                _ -> #{<<"filter">> => Filter}
            end,
            case LimitParts of
                [] -> {ok, Base};
                [{<<"limit">>, LimitBin}] ->
                    {ok, Limit} = positive_binary_integer(LimitBin),
                    {ok, Base#{<<"limit">> => Limit}}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

remote_memory_filter(Opts) ->
    case maps:find(filter_json, Opts) of
        error -> {ok, #{}};
        {ok, Json0} ->
            case decode_json_binary(safe_binary(Json0)) of
                {ok, Filter} when is_map(Filter) -> {ok, Filter};
                _ -> {error, memory_filter_must_be_object}
            end
    end.

cli_artifact_selector("all") -> {ok, <<"all">>};
cli_artifact_selector("latest") -> {ok, <<"latest">>};
cli_artifact_selector(Value) ->
    case parse_positive_integer(Value, selector) of
        {ok, Version} -> {ok, Version};
        _ -> {error, invalid_artifact_selector}
    end.

positive_binary_integer(Value) when is_binary(Value) ->
    try binary_to_integer(Value) of
        Integer when Integer > 0 -> {ok, Integer};
        _ -> {error, invalid_positive_integer}
    catch
        _:_ -> {error, invalid_positive_integer}
    end.

checked_confirmation(Opts, Expected) ->
    Json = option_binary(Opts, confirm_json, <<>>),
    case decode_json_binary(Json) of
        {ok, Expected} -> ok;
        _ -> {error, confirmation_does_not_match_target}
    end.

create_remote_session(App0, User0, Session0, Opts) ->
    App = quote(safe_binary(App0)),
    User = quote(safe_binary(User0)),
    Session = safe_binary(Session0),
    remote_json(
      post, <<"/dev/v1/sessions/", App/binary, "/", User/binary>>,
      jsx:encode(#{<<"session_id">> => Session}), Opts).

delete_remote_session(App0, User0, Session0, Opts) ->
    App = quote(safe_binary(App0)),
    User = quote(safe_binary(User0)),
    Session = quote(safe_binary(Session0)),
    remote_json(
      delete,
      <<"/dev/v1/sessions/", App/binary, "/", User/binary, "/",
        Session/binary>>, undefined, Opts).

update_remote_session_state(App0, User0, Session0, Opts) ->
    with_required(Opts, [delta_json],
      fun() ->
          DeltaJson = unicode:characters_to_binary(
                        maps:get(delta_json, Opts)),
          case decode_json_binary(DeltaJson) of
              {ok, Delta} when is_map(Delta), map_size(Delta) > 0 ->
                  App = quote(safe_binary(App0)),
                  User = quote(safe_binary(User0)),
                  Session = quote(safe_binary(Session0)),
                  remote_json(
                    post,
                    <<"/dev/v1/sessions/", App/binary, "/", User/binary,
                      "/", Session/binary, "/state">>,
                    jsx:encode(#{<<"state_delta">> => Delta}), Opts);
              _ -> {error, state_delta_must_be_nonempty_object}
          end
      end).

cancel_remote_run(RunId0, Opts) ->
    RunId = quote(safe_binary(RunId0)),
    remote_json(delete, <<"/dev/v1/runs/", RunId/binary>>,
                undefined, Opts).

resume_remote_run(RunId0, Opts) ->
    with_required(Opts, [response_json],
      fun() ->
          case decode_json_binary(
                 unicode:characters_to_binary(
                   maps:get(response_json, Opts))) of
              {ok, Response} ->
                  RunId = quote(safe_binary(RunId0)),
                  remote_json(
                    post,
                    <<"/dev/v1/runs/", RunId/binary, "/resume">>,
                    jsx:encode(#{<<"tool_response">> => Response}), Opts);
              {error, _} = Error -> Error
          end
      end).

remote_json(Method, Path, Body, Opts) ->
    Base0 = option_binary(Opts, base_url, ?DEFAULT_BASE_URL),
    case validate_base_url(Base0) of
        {error, _} = Error -> Error;
        {ok, Base} ->
            case developer_token_value() of
                {error, _} = Error -> Error;
                {ok, Token} ->
                    {ok, _} = application:ensure_all_started(inets),
                    Url = binary_to_list(<<Base/binary, Path/binary>>),
                    Auth = {"authorization",
                            "Bearer " ++ binary_to_list(Token)},
                    Request = case Method of
                        get -> {Url, [Auth]};
                        delete -> {Url, [Auth]};
                        post -> {Url, [Auth], "application/json", Body}
                    end,
                    HttpOptions = developer_http_options(Base),
                    case safe_httpc_request(Method, Request, HttpOptions) of
                        {ok, {{_Version, Status, _Phrase}, _Headers,
                              ResponseBody}}
                          when Status >= 200, Status < 300 ->
                            case decode_json_binary(ResponseBody) of
                                {ok, Json} -> {ok, Json};
                                {error, _} ->
                                    {error, invalid_developer_api_response}
                            end;
                        {ok, {{_Version, Status, _Phrase}, _Headers,
                              ResponseBody}} ->
                            {error, {developer_api_http_error, Status,
                                     public_http_error(ResponseBody)}};
                        {error, Reason} ->
                            {error, developer_api_transport_error(Reason)}
                    end
            end
    end.

%% Supplying an explicit SSL option prevents OTP's httpc defaults from loading
%% OS CA certificates for a plain loopback HTTP request. HTTPS deliberately
%% retains httpc's verified defaults.
developer_http_options(<<"http://", _/binary>>) ->
    [{timeout, 5000}, {ssl, [{verify, verify_none}]}];
developer_http_options(_Base) ->
    [{timeout, 5000}].

safe_httpc_request(Method, Request, HttpOptions) ->
    try httpc:request(
          Method, Request, HttpOptions, [{body_format, binary}]) of
        Result -> Result
    catch
        Class:Reason:_Stacktrace ->
            {error, {http_client_exception, Class, Reason}}
    end.

load_agent_file(Path) ->
    case read_json_file(Path) of
        {ok, Value} when is_map(Value) -> build_agent_config(Value);
        {ok, _} -> {error, agent_config_must_be_object};
        {error, _} = Error -> Error
    end.

build_agent_config(Json) ->
    Allowed = [<<"name">>, <<"provider">>, <<"model">>,
               <<"instructions">>, <<"global_instruction">>,
               <<"input_schema">>, <<"output_schema">>, <<"output_key">>,
               <<"include_contents">>, <<"history_policy">>,
               <<"generation_config">>,
               <<"temperature">>, <<"top_p">>,
               <<"top_k">>, <<"max_tokens">>, <<"candidate_count">>,
               <<"max_output_tokens">>,
               <<"seed">>, <<"presence_penalty">>,
               <<"frequency_penalty">>, <<"stop_sequences">>,
               <<"response_mime_type">>, <<"response_schema">>,
               <<"thinking_config">>, <<"safety_settings">>,
               <<"builtin_tools">>,
               <<"required_capabilities">>,
               <<"instruction_timeout_ms">>, <<"artifact_timeout_ms">>,
               <<"max_instruction_bytes">>,
               <<"request_timeout">>, <<"response">>, <<"tools">>,
               <<"runner_options">>],
    Unknown = maps:keys(maps:without(Allowed, Json)),
    case {Unknown, contains_forbidden_secret(Json)} of
        {_, true} -> {error, secret_in_config_file};
        {[_ | _], false} -> {error, {unknown_agent_config_keys, Unknown}};
        {[], false} -> build_checked_agent(Json)
    end.

build_checked_agent(Json) ->
    Name = maps:get(<<"name">>, Json, <<"CliAgent">>),
    ProviderName = maps:get(<<"provider">>, Json, <<"gemini">>),
    Model = maps:get(<<"model">>, Json, ?DEFAULT_MODEL),
    case {valid_nonempty_binary(Name), provider_module(ProviderName),
          tools_from_json(maps:get(<<"tools">>, Json, [])),
          runner_options_from_json(
            maps:get(<<"runner_options">>, Json, #{}))} of
        {true, {ok, Provider}, {ok, Tools}, {ok, RunnerOptions}} ->
            Config0 = maps:fold(
                        fun agent_config_field/3,
                        #{provider => Provider, model => Model}, Json),
            case adk_llm:validate_config(Config0) of
                ok ->
                    {ok, #{name => Name, provider_name => ProviderName,
                           provider => Provider, model => Model,
                           config => Config0, tools => Tools,
                           runner_options => RunnerOptions}};
                {error, Reason} ->
                    {error, {invalid_provider_config,
                             public_reason(Reason)}}
            end;
        {false, _, _, _} -> {error, invalid_agent_name};
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end.

agent_config_field(<<"name">>, _Value, Acc) -> Acc;
agent_config_field(<<"provider">>, _Value, Acc) -> Acc;
agent_config_field(<<"tools">>, _Value, Acc) -> Acc;
agent_config_field(<<"runner_options">>, _Value, Acc) -> Acc;
agent_config_field(<<"include_contents">>, Value, Acc) ->
    Acc#{include_contents => cli_history_value(Value)};
agent_config_field(<<"history_policy">>, Value, Acc) ->
    Acc#{history_policy => cli_history_value(Value)};
agent_config_field(<<"generation_config">>, Value, Acc) ->
    Acc#{generation_config => cli_generation_config(Value)};
agent_config_field(<<"thinking_config">>, Value, Acc) ->
    Acc#{thinking_config => cli_thinking_config(Value)};
agent_config_field(<<"safety_settings">>, Value, Acc) ->
    Acc#{safety_settings => cli_safety_settings(Value)};
agent_config_field(<<"builtin_tools">>, Value, Acc) ->
    Acc#{builtin_tools => cli_builtin_tools(Value)};
agent_config_field(<<"required_capabilities">>, Value, Acc) ->
    Acc#{required_capabilities => cli_capabilities(Value)};
agent_config_field(Key, Value, Acc) ->
    case config_atom(Key) of
        undefined -> Acc;
        AtomKey -> Acc#{AtomKey => Value}
    end.

config_atom(<<"model">>) -> model;
config_atom(<<"instructions">>) -> instructions;
config_atom(<<"global_instruction">>) -> global_instruction;
config_atom(<<"input_schema">>) -> input_schema;
config_atom(<<"output_schema">>) -> output_schema;
config_atom(<<"output_key">>) -> output_key;
config_atom(<<"temperature">>) -> temperature;
config_atom(<<"top_p">>) -> top_p;
config_atom(<<"top_k">>) -> top_k;
config_atom(<<"max_tokens">>) -> max_tokens;
config_atom(<<"max_output_tokens">>) -> max_output_tokens;
config_atom(<<"candidate_count">>) -> candidate_count;
config_atom(<<"seed">>) -> seed;
config_atom(<<"presence_penalty">>) -> presence_penalty;
config_atom(<<"frequency_penalty">>) -> frequency_penalty;
config_atom(<<"stop_sequences">>) -> stop_sequences;
config_atom(<<"response_mime_type">>) -> response_mime_type;
config_atom(<<"response_schema">>) -> response_schema;
config_atom(<<"instruction_timeout_ms">>) -> instruction_timeout_ms;
config_atom(<<"artifact_timeout_ms">>) -> artifact_timeout_ms;
config_atom(<<"max_instruction_bytes">>) -> max_instruction_bytes;
config_atom(<<"request_timeout">>) -> request_timeout;
config_atom(<<"response">>) -> response;
config_atom(_) -> undefined.

cli_history_value(<<"default">>) -> default;
cli_history_value(<<"none">>) -> none;
cli_history_value(<<"include">>) -> include;
cli_history_value(<<"exclude">>) -> exclude;
cli_history_value(Value) -> Value.

cli_generation_config(Value) when is_map(Value) ->
    maps:fold(
      fun(Key, NestedValue, Acc) ->
          case cli_generation_key(Key) of
              undefined -> Acc#{Key => NestedValue};
              thinking_config ->
                  Acc#{thinking_config =>
                           cli_thinking_config(NestedValue)};
              safety_settings ->
                  Acc#{safety_settings =>
                           cli_safety_settings(NestedValue)};
              Atom -> Acc#{Atom => NestedValue}
          end
      end, #{}, Value);
cli_generation_config(Value) -> Value.

cli_generation_key(<<"temperature">>) -> temperature;
cli_generation_key(<<"top_p">>) -> top_p;
cli_generation_key(<<"top_k">>) -> top_k;
cli_generation_key(<<"max_tokens">>) -> max_tokens;
cli_generation_key(<<"max_output_tokens">>) -> max_output_tokens;
cli_generation_key(<<"candidate_count">>) -> candidate_count;
cli_generation_key(<<"seed">>) -> seed;
cli_generation_key(<<"presence_penalty">>) -> presence_penalty;
cli_generation_key(<<"frequency_penalty">>) -> frequency_penalty;
cli_generation_key(<<"stop_sequences">>) -> stop_sequences;
cli_generation_key(<<"response_mime_type">>) -> response_mime_type;
cli_generation_key(<<"thinking_config">>) -> thinking_config;
cli_generation_key(<<"safety_settings">>) -> safety_settings;
cli_generation_key(_) -> undefined.

cli_thinking_config(Value) when is_map(Value) ->
    maps:fold(
      fun(<<"thinking_level">>, Nested, Acc) ->
              Acc#{thinking_level => Nested};
         (<<"thinking_budget">>, Nested, Acc) ->
              Acc#{thinking_budget => Nested};
         (<<"include_thoughts">>, Nested, Acc) ->
              Acc#{include_thoughts => Nested};
         (Key, Nested, Acc) -> Acc#{Key => Nested}
      end, #{}, Value);
cli_thinking_config(Value) -> Value.

cli_safety_settings(Settings) when is_list(Settings) ->
    [cli_safety_setting(Setting) || Setting <- Settings];
cli_safety_settings(Value) -> Value.

cli_safety_setting(Setting) when is_map(Setting) ->
    maps:fold(
      fun(<<"category">>, Value, Acc) -> Acc#{category => Value};
         (<<"threshold">>, Value, Acc) -> Acc#{threshold => Value};
         (Key, Value, Acc) -> Acc#{Key => Value}
      end, #{}, Setting);
cli_safety_setting(Value) -> Value.

cli_builtin_tools(Values) when is_list(Values) ->
    [cli_builtin_tool(Value) || Value <- Values];
cli_builtin_tools(Value) -> Value.

cli_builtin_tool(<<"google_search">>) -> google_search;
cli_builtin_tool(Value) -> Value.

cli_capabilities(Values) when is_list(Values) ->
    [cli_capability(Value) || Value <- Values];
cli_capabilities(Value) -> Value.

cli_capability(<<"streaming">>) -> streaming;
cli_capability(<<"function_calling">>) -> function_calling;
cli_capability(<<"structured_output">>) -> structured_output;
cli_capability(<<"generation_config">>) -> generation_config;
cli_capability(<<"multimodal">>) -> multimodal;
cli_capability(<<"thinking">>) -> thinking;
cli_capability(<<"safety_settings">>) -> safety_settings;
cli_capability(<<"content_streaming">>) -> content_streaming;
cli_capability(<<"google_search_grounding">>) -> google_search_grounding;
cli_capability(Value) -> Value.

provider_module(<<"gemini">>) -> {ok, adk_llm_gemini};
provider_module(<<"adk_llm_probe">>) ->
    checked_provider(adk_llm_probe, <<"adk_llm_probe">>);
provider_module(Name) when is_binary(Name) ->
    case Name of
        <<"adk_llm_", _/binary>> ->
            try binary_to_existing_atom(Name, utf8) of
                Module -> checked_provider(Module, Name)
            catch
                error:badarg -> {error, {unknown_provider, Name}}
            end;
        _ -> {error, {unknown_provider, Name}}
    end;
provider_module(_Name) ->
    {error, invalid_provider_name}.

checked_provider(Module, Name) ->
    case adk_llm:capabilities(Module) of
        {ok, _} -> {ok, Module};
        {error, Reason} ->
            {error, {invalid_provider, Name, public_reason(Reason)}}
    end.

tools_from_json(Tools) when is_list(Tools) ->
    tools_from_json(Tools, []);
tools_from_json(_Tools) ->
    {error, tools_must_be_array}.

tools_from_json([], Acc) -> {ok, lists:reverse(Acc)};
tools_from_json([Name | Rest], Acc) when is_binary(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        Module ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, schema, 0) andalso
                         erlang:function_exported(Module, execute, 2) of
                        true -> tools_from_json(Rest, [Module | Acc]);
                        false -> {error, {invalid_tool_module, Name}}
                    end;
                _ -> {error, {unknown_tool_module, Name}}
            end
    catch
        error:badarg -> {error, {unknown_tool_module, Name}}
    end;
tools_from_json([_ | _], _Acc) ->
    {error, invalid_tool_name}.

runner_options_from_json(Options) when is_map(Options) ->
    Allowed = [<<"run_timeout">>, <<"max_llm_calls">>,
               <<"max_tool_rounds">>, <<"service_timeout">>,
               <<"tool_execution">>],
    case maps:keys(maps:without(Allowed, Options)) of
        [] -> convert_runner_options(maps:to_list(Options), #{});
        Unknown -> {error, {unknown_runner_options, Unknown}}
    end;
runner_options_from_json(_Options) ->
    {error, runner_options_must_be_object}.

convert_runner_options([], Acc) -> {ok, Acc};
convert_runner_options([{<<"run_timeout">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0 ->
    convert_runner_options(Rest, Acc#{run_timeout => Value});
convert_runner_options([{<<"max_llm_calls">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0 ->
    convert_runner_options(Rest, Acc#{max_llm_calls => Value});
convert_runner_options([{<<"max_tool_rounds">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0 ->
    convert_runner_options(Rest, Acc#{max_tool_rounds => Value});
convert_runner_options([{<<"service_timeout">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0 ->
    convert_runner_options(Rest, Acc#{service_timeout => Value});
convert_runner_options([{<<"tool_execution">>, <<"serial">>} | Rest], Acc) ->
    convert_runner_options(Rest, Acc#{tool_execution => serial});
convert_runner_options([{<<"tool_execution">>, Value} | Rest], Acc)
  when is_map(Value) ->
    case parallel_tool_policy(Value) of
        {ok, Policy} ->
            convert_runner_options(Rest, Acc#{tool_execution => Policy});
        {error, _} = Error -> Error
    end;
convert_runner_options([{Key, _Value} | _], _Acc) ->
    {error, {invalid_runner_option, Key}}.

parallel_tool_policy(Value) ->
    Allowed = [<<"mode">>, <<"max_concurrency">>, <<"tool_timeout">>],
    case {maps:keys(maps:without(Allowed, Value)),
          maps:get(<<"mode">>, Value, undefined),
          maps:get(<<"max_concurrency">>, Value, undefined),
          maps:get(<<"tool_timeout">>, Value, undefined)} of
        {[], <<"parallel">>, Max, Timeout}
          when is_integer(Max), Max > 0,
               is_integer(Timeout), Timeout > 0 ->
            {ok, #{mode => parallel, max_concurrency => Max,
                   tool_timeout => Timeout}};
        _ -> {error, invalid_parallel_tool_policy}
    end.

load_dataset(Path) ->
    case read_json_file(Path) of
        {ok, Rows} when is_list(Rows) -> dataset_rows(Rows, 1, []);
        {ok, _} -> {error, dataset_must_be_array};
        {error, _} = Error -> Error
    end.

dataset_rows([], _Index, Acc) -> {ok, lists:reverse(Acc)};
dataset_rows([#{<<"input">> := Input,
                <<"expected">> := Expected} = Row | Rest], Index, Acc) ->
    Allowed = [<<"input">>, <<"expected">>, <<"metadata">>],
    Metadata = maps:get(<<"metadata">>, Row, #{}),
    case maps:keys(maps:without(Allowed, Row)) =:= [] andalso
         is_map(Metadata) of
        true ->
            dataset_rows(
              Rest, Index + 1,
              [#{input => Input, expected => Expected,
                 metadata => Metadata} | Acc]);
        false -> {error, {invalid_dataset_row, Index}}
    end;
dataset_rows([_ | _], Index, _Acc) ->
    {error, {invalid_dataset_row, Index}}.

read_json_file(Path0) ->
    Path = unicode:characters_to_list(Path0),
    case file:read_file(Path) of
        {ok, Binary} when byte_size(Binary) =< ?MAX_CONFIG_BYTES ->
            decode_json_binary(Binary);
        {ok, _Binary} -> {error, file_too_large};
        {error, Reason} -> {error, {file_read_failed, Reason}}
    end.

decode_json_binary(Binary) ->
    try jsx:decode(Binary, [return_maps]) of
        Json -> {ok, Json}
    catch
        _:_ -> {error, invalid_json}
    end.

contains_forbidden_secret(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          forbidden_secret_key(Key) orelse contains_forbidden_secret(Value)
      end, maps:to_list(Map));
contains_forbidden_secret(List) when is_list(List) ->
    lists:any(fun contains_forbidden_secret/1, List);
contains_forbidden_secret(_Value) -> false.

forbidden_secret_key(Key) when is_binary(Key) ->
    Normalized0 = string:lowercase(Key),
    Normalized = binary:replace(
                   Normalized0, <<"-">>, <<"_">>, [global]),
    lists:member(
      Normalized,
      [<<"api_key">>, <<"apikey">>, <<"authorization">>,
       <<"access_token">>, <<"refresh_token">>, <<"id_token">>,
       <<"password">>, <<"client_secret">>, <<"secret">>,
       <<"credential">>, <<"credentials">>, <<"private_key">>]);
forbidden_secret_key(_Key) -> false.

with_required(Opts, Keys, Fun) ->
    case [Key || Key <- Keys, not maps:is_key(Key, Opts)] of
        [] -> Fun();
        Missing -> {error, {missing_required_options, Missing}}
    end.

ensure_application_started() ->
    case application:ensure_all_started(erlang_adk) of
        {ok, _} -> ok;
        {error, Reason} -> {error, {application_start_failed,
                                    public_reason(Reason)}}
    end.

%% A packaged escript may enter main/1 before the main application has been
%% loaded. application:set_env/3 accepts that state, but a later load of the
%% .app file replaces the temporary values with its defaults. Load first so the
%% developer listener settings survive the subsequent application start.
prepare_developer_application(Port, Ip) ->
    stop_application(),
    case application:load(erlang_adk) of
        ok -> configure_and_start_developer_application(Port, Ip);
        {error, {already_loaded, erlang_adk}} ->
            configure_and_start_developer_application(Port, Ip);
        {error, Reason} ->
            {error, #{code => application_load_failed,
                      reason => public_reason(Reason)}}
    end.

configure_and_start_developer_application(Port, Ip) ->
    ok = application:set_env(erlang_adk, dev_enabled, true),
    ok = application:set_env(erlang_adk, a2a_ip, Ip),
    ok = application:set_env(erlang_adk, a2a_port, Port),
    ensure_application_started().

stop_application() ->
    case application:stop(erlang_adk) of
        ok -> ok;
        {error, {not_started, erlang_adk}} -> ok
    end.

wait_for_shutdown() ->
    receive
        stop -> ok
    after infinity -> ok
    end.

module_status(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> available;
        {error, Reason} -> {unavailable, public_reason(Reason)}
    end.

application_version() ->
    case application:get_key(erlang_adk, vsn) of
        {ok, Version} -> safe_binary(Version);
        undefined -> <<"unknown">>
    end.

valid_environment_secret(Name) ->
    case os:getenv(Name) of
        Value when is_list(Value), Value =/= [] -> true;
        _ -> false
    end.

developer_token() ->
    case developer_token_value() of
        {ok, Token} when byte_size(Token) >= 16 -> ok;
        {ok, _} -> {error, developer_token_too_short};
        {error, _} = Error -> Error
    end.

developer_token_value() ->
    case os:getenv("ERLANG_ADK_DEV_TOKEN") of
        Value when is_list(Value), Value =/= [] ->
            {ok, unicode:characters_to_binary(Value)};
        _ -> {error, missing_developer_token}
    end.

parse_positive_integer(Value, Name) ->
    try list_to_integer(Value) of
        Integer when Integer > 0 -> {ok, Integer};
        _ -> {error, {invalid_positive_integer, Name}}
    catch
        _:_ -> {error, {invalid_positive_integer, Name}}
    end.

parse_port(Value) ->
    case parse_positive_integer(Value, port) of
        {ok, Port} when Port =< 65535 -> {ok, Port};
        _ -> {error, invalid_port}
    end.

parse_loopback_ip("127.0.0.1") -> {ok, {127, 0, 0, 1}};
parse_loopback_ip("::1") -> {ok, {0, 0, 0, 0, 0, 0, 0, 1}};
parse_loopback_ip(_) -> {error, developer_server_must_bind_loopback}.

validate_base_url(Base) ->
    try uri_string:parse(Base) of
        #{scheme := Scheme, host := _Host} = Parsed
          when Scheme =:= <<"https">>; Scheme =:= "https" ->
            case maps:is_key(query, Parsed) orelse maps:is_key(fragment,
                                                               Parsed) of
                true -> {error, invalid_base_url};
                false -> {ok, trim_trailing_slash(safe_binary(Base))}
            end;
        #{scheme := Scheme, host := Host} = Parsed
          when Scheme =:= <<"http">>; Scheme =:= "http" ->
            HostBin = safe_binary(Host),
            case is_loopback_host(HostBin) andalso
                 not maps:is_key(query, Parsed) andalso
                 not maps:is_key(fragment, Parsed) of
                true -> {ok, trim_trailing_slash(safe_binary(Base))};
                false -> {error, insecure_non_loopback_base_url}
            end;
        _ -> {error, invalid_base_url}
    catch
        _:_ -> {error, invalid_base_url}
    end.

is_loopback_host(<<"127.0.0.1">>) -> true;
is_loopback_host(<<"localhost">>) -> true;
is_loopback_host(<<"::1">>) -> true;
is_loopback_host(_) -> false.

trim_trailing_slash(Value) when byte_size(Value) > 0 ->
    case binary:last(Value) of
        $/ -> binary:part(Value, 0, byte_size(Value) - 1);
        _ -> Value
    end;
trim_trailing_slash(Value) -> Value.

quote(Value) ->
    safe_binary(uri_string:quote(Value)).

option_binary(Opts, Key, Default) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> unicode:characters_to_binary(Value);
        error -> Default
    end.

valid_nonempty_binary(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0.

generate_id(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.

safe_binary(Value) when is_binary(Value) -> Value;
safe_binary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value)
    catch _:_ -> <<>>
    end;
safe_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
safe_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

public_reason(Reason) ->
    Redacted = adk_secret_redactor:redact(Reason),
    case adk_json:normalize(Redacted) of
        {ok, Json} -> Json;
        {error, _} -> <<"operation_failed">>
    end.

public_http_error(Body) ->
    case decode_json_binary(Body) of
        {ok, Json} -> adk_secret_redactor:redact(Json);
        {error, _} -> <<"developer_api_request_failed">>
    end.

developer_api_transport_error(Reason) ->
    #{code => developer_api_unavailable,
      reason => transport_failure_reason(Reason)}.

transport_failure_reason(Reason) ->
    case {term_contains_atom(Reason, econnrefused),
          term_contains_atom(Reason, timeout),
          term_contains_atom(Reason, nxdomain)} of
        {true, _, _} -> connection_refused;
        {_, true, _} -> timeout;
        {_, _, true} -> name_resolution_failed;
        _ -> connection_failed
    end.

term_contains_atom(Value, Value) when is_atom(Value) -> true;
term_contains_atom(Tuple, Atom) when is_tuple(Tuple) ->
    term_contains_atom(tuple_to_list(Tuple), Atom);
term_contains_atom([Head | Tail], Atom) ->
    term_contains_atom(Head, Atom) orelse term_contains_atom(Tail, Atom);
term_contains_atom([], _Atom) -> false;
term_contains_atom(_Value, _Atom) -> false.

write_result(Binary) when is_binary(Binary) ->
    io:put_chars([Binary, "\n"]);
write_result(Result) ->
    case adk_json:normalize(Result) of
        {ok, Json} -> io:put_chars([jsx:encode(Json), "\n"]);
        {error, _} -> io:put_chars(["{\"status\":\"ok\"}\n"])
    end.

write_error(Reason) ->
    Error = #{<<"status">> => <<"error">>,
              <<"reason">> => public_reason(Reason)},
    io:put_chars(standard_error, [jsx:encode(Error), "\n"]).
