%% @doc Integrated command-line tooling for local Erlang ADK development.
%%
%% The CLI deliberately consumes JSON configuration with a small, checked key
%% set. It never accepts model API keys in files; providers read their normal
%% environment-backed credentials. `inspect' and stored evaluation reports use
%% the authenticated local Developer API, while `run' and `evaluate' execute
%% in the current VM.
-module(adk_cli).

-include("adk_eval_report.hrl").

-export([main/1, command/1, command/2, usage/0]).

-define(DEFAULT_MODEL, <<"gemini-3.1-flash-lite">>).
-define(DEFAULT_BASE_URL, <<"http://127.0.0.1:8080">>).
-define(DEFAULT_TIMEOUT, 120000).
-define(DEFAULT_EVAL_CASE_TIMEOUT, 30000).
-define(MAX_CONFIG_BYTES, 1048576).
-define(MAX_EVAL_FILE_BYTES, 16777216).
-define(MAX_DEVELOPER_RESPONSE_BYTES, 1048576).
-define(DEVELOPER_HTTP_TIMEOUT, 5000).

-spec main([string()]) -> no_return() | ok.
main(Args) ->
    case command(Args) of
        {ok, #{command := serve} = Result} ->
            write_result(Result),
            wait_for_shutdown();
        {ok, #{command := eval_run} = Result} ->
            write_eval_run_result(Result),
            case maps:get(ci_exit_code, Result) of
                0 -> ok;
                ExitCode -> erlang:halt(ExitCode)
            end;
        {ok, #{command := eval_report} = Result} ->
            write_eval_run_result(Result),
            ok;
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
command_noninteractive(["graph", "validate", Module, Function]) ->
    graph_validate_command(Module, Function);
command_noninteractive(["graph", "describe", Module, Function]) ->
    graph_describe_command(Module, Function);
command_noninteractive(["graph", "render", Module, Function | Args]) ->
    with_options(
      Args, #{"--format" => format},
      fun(Opts) -> graph_render_command(Module, Function, Opts) end);
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
command_noninteractive(["eval", "report", JobId | Args]) ->
    with_options(
      Args,
      #{"--url" => base_url,
        "--format" => format,
        "--output" => output,
        "--suite-name" => suite_name},
      fun(Opts) -> eval_report_command(JobId, Opts) end);
command_noninteractive(["eval", "run" | Args]) ->
    with_options(
      Args,
      #{"--config" => config,
        "--eval-set" => eval_set,
        "--criteria" => criteria,
        "--baseline" => baseline,
        "--format" => format,
        "--output" => output,
        "--samples" => samples,
        "--concurrency" => concurrency,
        "--sample-concurrency" => sample_concurrency,
        "--timeout" => timeout,
        "--case-timeout" => case_timeout,
        "--pass-rate-threshold" => pass_rate_threshold,
        "--sample-pass-rate-threshold" =>
            sample_pass_rate_threshold,
        "--min-successful-samples" => min_successful_samples,
        "--empty-criteria" => empty_criteria,
        "--capture-events" => capture_events,
        "--capture-tool-content" => capture_tool_content,
        "--max-heap-words" => max_heap_words,
        "--max-report-bytes" => max_report_bytes,
        "--max-pass-rate-drop" => max_pass_rate_drop,
        "--metric-tolerances" => metric_tolerances},
      fun eval_run_command/1);
command_noninteractive(["deploy", "cloud_run" | Args]) ->
    with_deploy_options(
      Args,
      #{"--manifest" => manifest,
        "--project" => project,
        "--region" => region},
      fun deploy_cloud_run_command/1);
command_noninteractive(["deploy", "gke" | Args]) ->
    with_deploy_options(
      Args,
      #{"--manifest" => manifest,
        "--context" => context,
        "--namespace" => namespace},
      fun deploy_gke_command/1);
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
command_noninteractive(["inspect", "observability" | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun inspect_observability/1);
command_noninteractive(["inspect", "live" | Args]) ->
    with_options(
      Args, #{"--url" => base_url},
      fun inspect_live_sessions/1);
command_noninteractive(["live", "send", SessionId | Args]) ->
    with_options(
      Args, #{"--url" => base_url, "--text" => text},
      fun(Opts) -> send_remote_live_text(SessionId, Opts) end);
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
      "  adk graph validate MODULE FUNCTION\n"
      "  adk graph describe MODULE FUNCTION\n"
      "  adk graph render MODULE FUNCTION [--format mermaid|dot|json]\n"
      "  adk run --config AGENT.json --message TEXT [--user ID --session ID]\n"
      "  adk console --config AGENT.json [--user ID --session ID]\n"
      "  adk evaluate --config AGENT.json --dataset DATASET.json\n"
      "  adk eval report JOB_ID [--format json|markdown|junit|sarif|annotations --output REPORT --url URL]\n"
      "  adk eval run --config AGENT.json --eval-set SET.json [--criteria CRITERIA.json]\n"
      "  adk deploy cloud_run --manifest FILE --project PROJECT --region REGION [--apply]\n"
      "  adk deploy gke --manifest FILE --context CONTEXT --namespace NS [--apply]\n"
      "  adk serve [--config AGENT.json] [--port 8080 --ip 127.0.0.1]\n"
      "  adk inspect agents [--url URL]\n"
      "  adk inspect diagnostics [--url URL]\n"
      "  adk inspect observability [--url URL]\n"
      "  adk inspect live [--url URL]\n"
      "  adk live send SESSION_ID --text TEXT [--url URL]\n"
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

with_deploy_options(Args, Allowed, Fun) ->
    case parse_deploy_options(Args, Allowed, #{apply => false}) of
        {ok, Opts} -> Fun(Opts);
        {error, _} = Error -> Error
    end.

parse_deploy_options([], _Allowed, Acc) -> {ok, Acc};
parse_deploy_options(["--apply" | Rest], Allowed, Acc) ->
    case maps:get(apply, Acc, false) of
        false -> parse_deploy_options(Rest, Allowed, Acc#{apply => true});
        true -> {error, {duplicate_option, "--apply"}}
    end;
parse_deploy_options([Flag, Value | Rest], Allowed, Acc) ->
    case maps:find(Flag, Allowed) of
        {ok, Key} ->
            case maps:is_key(Key, Acc) of
                true -> {error, {duplicate_option, Flag}};
                false ->
                    parse_deploy_options(Rest, Allowed, Acc#{Key => Value})
            end;
        error -> {error, {unknown_option, Flag}}
    end;
parse_deploy_options([Flag], _Allowed, _Acc) ->
    {error, {missing_option_value, Flag}}.

deploy_cloud_run_command(Options) ->
    case adk_deploy:cloud_run(Options) of
        {ok, Result} -> {ok, Result#{command => deploy_cloud_run}};
        {error, _} = Error -> Error
    end.

deploy_gke_command(Options) ->
    case adk_deploy:gke(Options) of
        {ok, Result} -> {ok, Result#{command => deploy_gke}};
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
    ProviderStatuses =
        #{gemini => ProviderStatus,
          vertex => module_status(adk_llm_vertex),
          openai => module_status(adk_llm_openai),
          anthropic => module_status(adk_llm_anthropic),
          compatible => module_status(adk_llm_compatible)},
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
    OpenAiKeyConfigured = valid_environment_secret("OPENAI_API_KEY"),
    AnthropicKeyConfigured = valid_environment_secret("ANTHROPIC_API_KEY"),
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
           providers => ProviderStatuses,
           dependencies => Dependencies,
           gemini_api_key_configured => ApiKeyConfigured,
           openai_api_key_configured => OpenAiKeyConfigured,
           anthropic_api_key_configured => AnthropicKeyConfigured,
           developer_token_configured => DevTokenConfigured,
           warnings => lists:reverse(Warnings)}}.

validate_config_command(Path) ->
    case load_agent_file(Path) of
        {ok, Agent} ->
            {ok, #{command => config_validate,
                   status => valid,
                   schema_version => maps:get(schema_version, Agent),
                   fingerprint => maps:get(fingerprint, Agent),
                   registry_generation => maps:get(registry_generation,
                                                   Agent),
                   registry_instance_id => maps:get(
                                             registry_instance_id, Agent),
                   registry_snapshot_revision_id => maps:get(
                                                     registry_snapshot_revision_id,
                                                     Agent),
                   name => maps:get(name, Agent),
                   provider => maps:get(provider_name, Agent),
                   model => maps:get(model, Agent),
                   tool_count => length(maps:get(tools, Agent))}};
        {error, _} = Error -> Error
    end.

graph_validate_command(ModuleText, FunctionText) ->
    case load_graph_factory(ModuleText, FunctionText) of
        {ok, Compiled} ->
            case adk_graph_inspect:describe(Compiled) of
                {ok, Descriptor} ->
                    Analysis = maps:get(<<"analysis">>, Descriptor),
                    {ok, #{command => graph_validate,
                           status => valid,
                           workflow_id => maps:get(<<"workflow_id">>,
                                                   Descriptor),
                           fingerprint => maps:get(
                                            <<"definition_fingerprint">>,
                                            Descriptor),
                           warnings => maps:get(<<"warnings">>, Analysis)}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

graph_describe_command(ModuleText, FunctionText) ->
    case load_graph_factory(ModuleText, FunctionText) of
        {ok, Compiled} ->
            case adk_graph_inspect:describe(Compiled) of
                {ok, Descriptor} ->
                    {ok, #{command => graph_describe,
                           graph => Descriptor}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

graph_render_command(ModuleText, FunctionText, Opts) ->
    FormatText = maps:get(format, Opts, "mermaid"),
    case normalize_graph_format(FormatText) of
        {error, _} = Error -> Error;
        {ok, Format} ->
            case load_graph_factory(ModuleText, FunctionText) of
                {error, _} = Error -> Error;
                {ok, Compiled} ->
                    render_graph_result(Compiled, Format)
            end
    end.

render_graph_result(Compiled, json) ->
    case adk_graph_inspect:describe(Compiled) of
        {ok, Descriptor} ->
            {ok, #{command => graph_render, format => json,
                   content => jsx:encode(Descriptor)}};
        {error, _} = Error -> Error
    end;
render_graph_result(Compiled, dot) ->
    render_graph_text(Compiled, dot, adk_graph_inspect:to_dot(Compiled));
render_graph_result(Compiled, mermaid) ->
    render_graph_text(
      Compiled, mermaid, adk_graph_inspect:to_mermaid(Compiled)).

render_graph_text(_Compiled, Format, {ok, Content}) ->
    {ok, #{command => graph_render, format => Format, content => Content}};
render_graph_text(_Compiled, _Format, {error, _} = Error) -> Error.

normalize_graph_format("mermaid") -> {ok, mermaid};
normalize_graph_format("dot") -> {ok, dot};
normalize_graph_format("json") -> {ok, json};
normalize_graph_format(_) -> {error, unsupported_graph_render_format}.

load_graph_factory(ModuleText, FunctionText) ->
    case resolve_available_module(ModuleText) of
        {error, _} = Error -> Error;
        {ok, Module} ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case resolve_exported_function(Module, FunctionText) of
                        {ok, Function} -> invoke_graph_factory(Module,
                                                               Function);
                        {error, _} = Error -> Error
                    end;
                _ -> {error, graph_factory_module_unavailable}
            end
    end.

resolve_available_module(ModuleText) when is_list(ModuleText) ->
    case [Candidate || {Candidate, _File, _Loaded} <- code:all_available(),
                       Candidate =:= ModuleText] of
        [Candidate | _] ->
            %% Candidate comes from the installed code path rather than
            %% caller text, so this creates at most the selected available
            %% module atom.
            {ok, list_to_atom(Candidate)};
        [] -> {error, graph_factory_module_unavailable}
    end;
resolve_available_module(_) -> {error, invalid_graph_factory_module}.

resolve_exported_function(Module, FunctionText) when is_list(FunctionText) ->
    case [Function || {Function, 0} <- Module:module_info(exports),
                      atom_to_list(Function) =:= FunctionText] of
        [Function | _] -> {ok, Function};
        [] -> {error, graph_factory_function_unavailable}
    end;
resolve_exported_function(_Module, _FunctionText) ->
    {error, invalid_graph_factory_function}.

invoke_graph_factory(Module, Function) ->
    try Module:Function() of
        {ok, Value} -> compile_graph_factory_value(Value);
        Value -> compile_graph_factory_value(Value)
    catch
        Class:Reason ->
            {error, {graph_factory_failed,
                     adk_failure:exception(
                       graph_cli, factory, Class, Reason)}}
    end.

compile_graph_factory_value(Value) when is_map(Value) ->
    case adk_workflow:is_compiled(Value) of
        true ->
            case maps:get(kind, Value) of
                graph -> {ok, Value};
                _ -> {error, graph_factory_not_graph_workflow}
            end;
        false ->
            case adk_workflow:compile(Value) of
                {ok, #{kind := graph} = Compiled} -> {ok, Compiled};
                {ok, _Other} -> {error, graph_factory_not_graph_workflow};
                {error, _} = Error -> Error
            end
    end;
compile_graph_factory_value(_Value) ->
    {error, invalid_graph_factory_result}.

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
    case spawn_cli_composition(Agent) of
        {error, Reason} -> {error, {agent_start_failed, public_reason(Reason)}};
        {ok, AgentPid, RunnerOptions0, Composition} ->
            try
                AppName = option_binary(Opts, app_name, <<"adk-cli">>),
                UserId = option_binary(Opts, user_id, <<"local-user">>),
                SessionId = option_binary(
                              Opts, session_id, generate_id(<<"session">>)),
                Message = unicode:characters_to_binary(
                            maps:get(message, Opts)),
                case build_runtime_runner(
                       AgentPid, AppName, RunnerOptions0,
                       #{run_timeout => Timeout}) of
                    {ok, Runner, _SessionService} ->
                        case adk_run:start(
                               Runner, UserId, SessionId, Message,
                               #{retention_ms =>
                                     erlang:max(60000, Timeout + 1000),
                                 max_buffered_events => 256}) of
                            {ok, RunId} ->
                                Outcome = adk_run:await(
                                            RunId, Timeout + 1000),
                                cli_run_result(RunId, SessionId, Outcome);
                            {error, Reason} ->
                                {error,
                                 {run_start_failed,
                                  public_reason(Reason)}}
                        end;
                    {error, Reason} ->
                        {error, {runner_start_failed,
                                 public_reason(Reason)}}
                end
            after
                _ = catch adk_agent_composition:stop(Composition)
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
    case spawn_cli_composition(Agent) of
        {error, Reason} ->
            {error, {agent_start_failed, public_reason(Reason)}};
        {ok, AgentPid, RunnerOptions, Composition} ->
            try
                AppName = option_binary(Opts, app_name, <<"adk-cli">>),
                UserId = option_binary(Opts, user_id, <<"local-user">>),
                SessionId = option_binary(
                              Opts, session_id,
                              generate_id(<<"session">>)),
                case build_runtime_runner(
                       AgentPid, AppName, RunnerOptions,
                       #{run_timeout => Timeout}) of
                    {ok, Runner, SessionService} ->
                        console_write(
                          Io,
                          <<"Erlang ADK console. /help lists commands; "
                            "/exit closes.\n">>),
                        console_loop(
                          #{runner => Runner, app_name => AppName,
                            user_id => UserId, session_id => SessionId,
                            session_service => SessionService,
                            timeout => Timeout, io => Io, turns => 0,
                            paused_run_id => undefined});
                    {error, Reason} ->
                        {error, {runner_start_failed,
                                 public_reason(Reason)}}
                end
            after
                _ = catch adk_agent_composition:stop(Composition)
            end
    end.

spawn_cli_composition(Agent) ->
    case adk_agent_composition:spawn(Agent) of
        {ok, Composition} ->
            case {adk_agent_composition:root(Composition),
                  adk_agent_composition:runner_options(Composition)} of
                {{ok, AgentPid}, {ok, RunnerOptions}} ->
                    {ok, AgentPid, RunnerOptions, Composition};
                _ ->
                    _ = adk_agent_composition:stop(Composition),
                    {error, invalid_agent_composition}
            end;
        {error, _} = Error -> Error
    end.

build_runtime_runner(AgentPid, AppName, AgentOptions, Overrides)
  when is_map(AgentOptions), is_map(Overrides) ->
    case erlang_adk:runtime_runner_spec() of
        {ok, #{session_service := SessionService,
               runner_options := ServiceOptions}}
          when is_atom(SessionService), is_map(ServiceOptions) ->
            %% Profile-owned service references are authoritative. Explicit
            %% command bounds (for example --timeout) are applied last.
            Options0 = maps:merge(AgentOptions, ServiceOptions),
            Options = maps:merge(Options0, Overrides),
            try adk_runner:new(
                  AgentPid, AppName, SessionService, Options) of
                Runner -> {ok, Runner, SessionService}
            catch
                _:_ -> {error, invalid_runtime_runner_options}
            end;
        {error, _} = Error -> Error;
        _ -> {error, invalid_runtime_runner_spec}
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
                  session_id := Session, session_service := SessionService,
                  io := Io}) ->
    case safe_session_call(
           SessionService, get_session, [App, User, Session]) of
        {ok, Stored} -> console_write_json(Io, Stored);
        {error, not_found} ->
            console_write_json(Io, #{status => not_found,
                                     session_id => Session});
        {error, Reason} ->
            console_write_json(Io, #{status => error,
                                     reason => public_reason(Reason)})
    end.

safe_session_call(Module, Function, Args) when is_atom(Module) ->
    try apply(Module, Function, Args) of
        Reply -> Reply
    catch
        _:_ -> {error, session_service_unavailable}
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

%% Render a result that is already persisted by the supervised evaluation
%% service. The Developer API returns the canonical bytes; the CLI preserves
%% them exactly for stdout and file delivery.
eval_report_command(JobId0, Opts) ->
    JobId = safe_binary(JobId0),
    case {adk_eval_store:valid_job_id(JobId),
          parse_eval_format(maps:get(format, Opts, "json")),
          parse_eval_output(maps:get(output, Opts, "-")),
          parse_eval_suite_name(Opts)} of
        {true, {ok, Format}, {ok, Output}, {ok, SuiteName}} ->
            FormatBin = atom_to_binary(Format, utf8),
            Query0 = [{<<"format">>, quote(FormatBin)}],
            Query = case SuiteName of
                undefined -> Query0;
                _ -> Query0 ++ [{<<"suite_name">>, quote(SuiteName)}]
            end,
            Path = <<"/dev/v1/evaluation/jobs/", (quote(JobId))/binary,
                     "/report", (query_parts(Query))/binary>>,
            case remote_binary(get, Path, undefined, Opts,
                               ?ADK_EVAL_REPORT_MAX_BYTES) of
                {error, _} = Error -> Error;
                {ok, Rendered} ->
                    case deliver_eval_report(Output, Rendered) of
                        {error, _} = Error -> Error;
                        {ok, Delivery, OutputPath} ->
                            Base = #{command => eval_report,
                                     job_id => JobId,
                                     format => Format,
                                     delivery => Delivery,
                                     report => Rendered},
                            case OutputPath of
                                undefined -> {ok, Base};
                                _ -> {ok, Base#{output_path => OutputPath}}
                            end
                    end
            end;
        {false, _, _, _} -> {error, invalid_eval_job_id};
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end.

parse_eval_suite_name(Opts) ->
    case maps:find(suite_name, Opts) of
        error -> {ok, undefined};
        {ok, Value0} ->
            Value = safe_binary(Value0),
            case valid_eval_suite_name(Value) of
                true -> {ok, Value};
                false -> {error, invalid_eval_suite_name}
            end
    end.

valid_eval_suite_name(Value)
  when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 256 ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end;
valid_eval_suite_name(_) -> false.

%% Versioned evaluation is a separate command so the historical evaluate
%% dataset contract and its output remain unchanged.
eval_run_command(Opts) ->
    with_required(
      Opts, [config, eval_set],
      fun() ->
          case prepare_eval_run(Opts) of
              {ok, Prepared} -> execute_eval_run(Prepared);
              {error, _} = Error -> Error
          end
      end).

prepare_eval_run(Opts) ->
    case {parse_eval_format(maps:get(format, Opts, "json")),
          parse_eval_output(maps:get(output, Opts, "-")),
          parse_eval_option_overrides(Opts),
          parse_comparison_overrides(Opts)} of
        {{ok, Format}, {ok, Output},
         {ok, EvalOptions}, {ok, ComparisonOptions}} ->
            case validate_comparison_usage(Opts, ComparisonOptions) of
                ok ->
                    load_eval_run_inputs(
                      Opts, Format, Output,
                      EvalOptions, ComparisonOptions);
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, _} = Error, _, _} -> Error;
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end.

load_eval_run_inputs(Opts, Format, Output,
                     EvalOptions, ComparisonOptions) ->
    case load_agent_file(maps:get(config, Opts)) of
        {error, _} = Error -> Error;
        {ok, Agent} ->
            case load_versioned_eval_set(maps:get(eval_set, Opts)) of
                {error, _} = Error -> Error;
                {ok, EvalSet} ->
                    case load_cli_eval_criteria(Opts) of
                        {error, _} = Error -> Error;
                        {ok, Criteria} ->
                            case load_optional_baseline(Opts) of
                                {error, _} = Error -> Error;
                                {ok, Baseline} ->
                                    {ok, #{agent => Agent,
                                           eval_set => EvalSet,
                                           criteria => Criteria,
                                           eval_options => EvalOptions,
                                           comparison_options =>
                                               ComparisonOptions,
                                           baseline => Baseline,
                                           format => Format,
                                           output => Output}}
                            end
                    end
            end
    end.

execute_eval_run(Prepared) ->
    case ensure_application_started() of
        {error, _} = Error -> Error;
        ok ->
            Agent = maps:get(agent, Prepared),
            EvalOptions = maps:get(eval_options, Prepared),
            CaseTimeout = maps:get(
                            case_timeout_ms, EvalOptions,
                            ?DEFAULT_EVAL_CASE_TIMEOUT),
            Adapter = #{
                module => adk_eval_agent_adapter,
                target => Agent,
                config => #{run_timeout_ms => CaseTimeout}
            },
            case adk_eval_set:run(
                   Adapter, maps:get(eval_set, Prepared),
                   maps:get(criteria, Prepared), EvalOptions) of
                {error, Reason} ->
                    {error, {evaluation_failed, Reason}};
                {ok, Current} ->
                    finish_eval_run(Prepared, Current)
            end
    end.

finish_eval_run(Prepared, Current) ->
    Baseline = maps:get(baseline, Prepared),
    ComparisonOptions = maps:get(comparison_options, Prepared),
    case eval_gate_report(Baseline, Current, ComparisonOptions) of
        {error, _} = Error -> Error;
        {ok, ReportValue, Comparison, Passed} ->
            Format = maps:get(format, Prepared),
            case render_eval_run_report(
                   Format, ReportValue, Current,
                   maps:get(eval_options, Prepared)) of
                {error, Reason} ->
                    {error, {report_render_failed, Reason}};
                {ok, Rendered0} ->
                    Rendered = trailing_newline(Rendered0),
                    case deliver_eval_report(
                           maps:get(output, Prepared), Rendered) of
                        {error, _} = Error -> Error;
                        {ok, Delivery, OutputPath} ->
                            ExitCode = case Passed of true -> 0; false -> 2 end,
                            Base = #{command => eval_run,
                                     delivery => Delivery,
                                     format => Format,
                                     report => Rendered,
                                     evaluation => Current,
                                     passed => Passed,
                                     ci_exit_code => ExitCode},
                            WithComparison = case Comparison of
                                undefined -> Base;
                                _ -> Base#{comparison => Comparison}
                            end,
                            Result = case OutputPath of
                                undefined -> WithComparison;
                                _ -> WithComparison#{
                                       output_path => OutputPath}
                            end,
                            {ok, Result}
                    end
            end
    end.

eval_gate_report(undefined, Current, _ComparisonOptions) ->
    Passed = maps:get(<<"passed">>, Current),
    {ok, Current, undefined, Passed};
eval_gate_report(Baseline, Current, ComparisonOptions) ->
    case adk_eval_set:compare(Baseline, Current, ComparisonOptions) of
        {error, Reason} ->
            {error, {baseline_comparison_failed, Reason}};
        {ok, Comparison} ->
            EvaluationPassed = maps:get(<<"passed">>, Current),
            ComparisonPassed = maps:get(<<"passed">>, Comparison),
            Passed = EvaluationPassed andalso ComparisonPassed,
            %% Keep the baseline comparison's validated public schema intact.
            %% The command result carries the combined CI outcome separately.
            {ok, Comparison, Comparison, Passed}
    end.

parse_eval_format("json") -> {ok, json};
parse_eval_format("markdown") -> {ok, markdown};
parse_eval_format("junit") -> {ok, junit};
parse_eval_format("sarif") -> {ok, sarif};
parse_eval_format("annotations") -> {ok, annotations};
parse_eval_format(_) -> {error, invalid_eval_report_format}.

render_eval_run_report(Format, ReportValue, Current, EvalOptions) ->
    Value = case Format of
        json -> ReportValue;
        markdown -> ReportValue;
        _ -> Current
    end,
    adk_eval_export:render(
      Value, Format,
      #{max_bytes => eval_report_byte_limit(EvalOptions)}).

eval_report_byte_limit(EvalOptions) ->
    maps:get(max_report_bytes, EvalOptions,
             ?ADK_EVAL_REPORT_MAX_BYTES).

parse_eval_output("-") -> {ok, stdout};
parse_eval_output(Path0) ->
    try unicode:characters_to_list(Path0) of
        Path when is_list(Path), Path =/= [] ->
            case lists:member(0, Path) of
                true -> {error, invalid_eval_output_path};
                false -> {ok, {file, Path}}
            end;
        _ -> {error, invalid_eval_output_path}
    catch
        _:_ -> {error, invalid_eval_output_path}
    end.

parse_eval_option_overrides(Opts) ->
    Specs = [
        {samples, sample_count, positive},
        {concurrency, concurrency, positive},
        {sample_concurrency, sample_concurrency, positive},
        {timeout, timeout_ms, positive},
        {case_timeout, case_timeout_ms, positive},
        {pass_rate_threshold, pass_rate_threshold, fraction},
        {sample_pass_rate_threshold, sample_pass_rate_threshold, fraction},
        {min_successful_samples, min_successful_samples, positive},
        {empty_criteria, empty_criteria, empty_policy},
        {capture_events, capture_events, boolean},
        {capture_tool_content, capture_tool_content, boolean},
        {max_heap_words, max_heap_words, positive},
        {max_report_bytes, max_report_bytes, positive}
    ],
    parse_override_specs(Specs, Opts, #{}).

parse_comparison_overrides(Opts) ->
    case parse_override_specs(
           [{max_pass_rate_drop, max_pass_rate_drop, fraction}],
           Opts, #{}) of
        {error, _} = Error -> Error;
        {ok, Acc} ->
            case maps:find(metric_tolerances, Opts) of
                error -> {ok, Acc};
                {ok, Path} ->
                    case load_metric_tolerances(Path) of
                        {ok, Tolerances} ->
                            {ok, Acc#{metric_tolerances => Tolerances}};
                        {error, _} = Error -> Error
                    end
            end
    end.

parse_override_specs([], _Opts, Acc) -> {ok, Acc};
parse_override_specs([{CliKey, EvalKey, Type} | Rest], Opts, Acc) ->
    case maps:find(CliKey, Opts) of
        error -> parse_override_specs(Rest, Opts, Acc);
        {ok, Value} ->
            case parse_override_value(Value, CliKey, Type) of
                {ok, Parsed} ->
                    parse_override_specs(
                      Rest, Opts, Acc#{EvalKey => Parsed});
                {error, _} = Error -> Error
            end
    end.

parse_override_value(Value, Name, positive) ->
    parse_positive_integer(Value, Name);
parse_override_value(Value, Name, fraction) ->
    parse_fraction(Value, Name);
parse_override_value("pass", _Name, empty_policy) -> {ok, pass};
parse_override_value("error", _Name, empty_policy) -> {ok, error};
parse_override_value(_Value, Name, empty_policy) ->
    {error, {invalid_empty_criteria_policy, Name}};
parse_override_value("true", _Name, boolean) -> {ok, true};
parse_override_value("false", _Name, boolean) -> {ok, false};
parse_override_value(_Value, Name, boolean) ->
    {error, {invalid_boolean, Name}}.

parse_fraction(Value, Name) ->
    try unicode:characters_to_binary(Value) of
        Binary ->
            case fraction_number(Binary) of
                Number when is_number(Number),
                            Number >= 0, Number =< 1 ->
                    {ok, Number};
                _ -> {error, {invalid_fraction, Name}}
            end
    catch
        _:_ -> {error, {invalid_fraction, Name}}
    end.

fraction_number(Binary) ->
    try binary_to_integer(Binary) of
        Integer -> Integer
    catch
        _:_ ->
            try binary_to_float(Binary) of
                Float -> Float
            catch
                _:_ -> invalid
            end
    end.

validate_comparison_usage(Opts, ComparisonOptions) ->
    case {maps:is_key(baseline, Opts), map_size(ComparisonOptions)} of
        {false, Size} when Size > 0 ->
            {error, baseline_required_for_comparison_options};
        _ -> ok
    end.

load_versioned_eval_set(Path) ->
    case read_eval_json_file(Path) of
        {ok, Value} when is_map(Value) ->
            case adk_eval_set:decode(Value) of
                {ok, EvalSet} -> {ok, EvalSet};
                {error, Reason} -> {error, {invalid_eval_set, Reason}}
            end;
        {ok, _} -> {error, eval_set_must_be_object};
        {error, _} = Error -> Error
    end.

load_cli_eval_criteria(Opts) ->
    case maps:find(criteria, Opts) of
        error ->
            {ok, [#{id => <<"response">>,
                    criterion => <<"exact_response">>,
                    threshold => 1.0}]};
        {ok, Path} ->
            case read_json_file(Path) of
                {ok, Criteria} when is_list(Criteria) ->
                    normalize_cli_criteria(Criteria, 0, []);
                {ok, #{<<"criteria">> := Criteria} = Wrapper}
                  when is_list(Criteria) ->
                    case maps:keys(
                           maps:without([<<"criteria">>], Wrapper)) of
                        [] -> normalize_cli_criteria(Criteria, 0, []);
                        Unknown ->
                            {error, {unknown_eval_criteria_keys, Unknown}}
                    end;
                {ok, _} -> {error, eval_criteria_must_be_array};
                {error, _} = Error -> Error
            end
    end.

normalize_cli_criteria([], _Index, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_cli_criteria([Criterion | Rest], Index, Acc)
  when is_map(Criterion) ->
    Allowed = [<<"id">>, <<"criterion">>, <<"threshold">>,
               <<"kind">>, <<"config">>],
    Unknown = maps:keys(maps:without(Allowed, Criterion)),
    Id = maps:get(<<"id">>, Criterion, undefined),
    Name = maps:get(<<"criterion">>, Criterion, undefined),
    Threshold = maps:get(<<"threshold">>, Criterion, 1.0),
    Kind0 = maps:get(<<"kind">>, Criterion, <<"metric">>),
    Config = maps:get(<<"config">>, Criterion, #{}),
    case {Unknown, valid_nonempty_binary(Id),
          builtin_criterion(Name), metric_kind(Kind0),
          valid_cli_score(Threshold), criterion_config(Config)} of
        {[], true, true, {ok, Kind}, true, ok} ->
            Descriptor = #{id => Id, criterion => Name,
                           threshold => Threshold, kind => Kind,
                           config => Config},
            normalize_cli_criteria(
              Rest, Index + 1, [Descriptor | Acc]);
        {[_ | _], _, _, _, _, _} ->
            {error, {unknown_eval_criterion_keys, Index, Unknown}};
        _ -> {error, {invalid_eval_criterion, Index}}
    end;
normalize_cli_criteria([_ | _], Index, _Acc) ->
    {error, {invalid_eval_criterion, Index}}.

builtin_criterion(<<"exact_response">>) -> true;
builtin_criterion(<<"trajectory_exact">>) -> true;
builtin_criterion(<<"trajectory_in_order">>) -> true;
builtin_criterion(<<"trajectory_any_order">>) -> true;
builtin_criterion(<<"trajectory_subset">>) -> true;
builtin_criterion(<<"tool_trajectory">>) -> true;
builtin_criterion(_) -> false.

metric_kind(<<"metric">>) -> {ok, metric};
metric_kind(<<"judge">>) -> {ok, judge};
metric_kind(_) -> error.

criterion_config(Config) when is_map(Config) ->
    Allowed = [<<"normalization">>, <<"args">>, <<"match">>],
    case maps:keys(maps:without(Allowed, Config)) of
        [] -> ok;
        _ -> error
    end;
criterion_config(_) -> error.

valid_cli_score(Value) when is_integer(Value) ->
    Value >= 0 andalso Value =< 1;
valid_cli_score(Value) when is_float(Value) ->
    Value =:= Value andalso Value >= 0.0 andalso Value =< 1.0;
valid_cli_score(_) -> false.

load_optional_baseline(Opts) ->
    case maps:find(baseline, Opts) of
        error -> {ok, undefined};
        {ok, Path} ->
            case read_eval_json_file(Path) of
                {ok, Value} when is_map(Value) ->
                    case adk_eval_set:decode_result(Value) of
                        {ok, Baseline} -> {ok, Baseline};
                        {error, Reason} ->
                            {error, {invalid_eval_baseline, Reason}}
                    end;
                {ok, _} -> {error, eval_baseline_must_be_object};
                {error, _} = Error -> Error
            end
    end.

load_metric_tolerances(Path) ->
    case read_json_file(Path) of
        {ok, Value} when is_map(Value) ->
            case lists:all(
                   fun({Id, Tolerance}) ->
                       valid_nonempty_binary(Id)
                           andalso valid_cli_score(Tolerance)
                   end, maps:to_list(Value)) of
                true -> {ok, Value};
                false -> {error, invalid_metric_tolerances}
            end;
        {ok, _} -> {error, metric_tolerances_must_be_object};
        {error, _} = Error -> Error
    end.

read_eval_json_file(Path0) ->
    Path = unicode:characters_to_list(Path0),
    case adk_bounded_file:read(Path, ?MAX_EVAL_FILE_BYTES) of
        {ok, Binary} ->
            decode_json_binary(Binary);
        {error, file_too_large} -> {error, eval_file_too_large};
        {error, _} = Error -> Error
    end.

deliver_eval_report(stdout, _Rendered) ->
    {ok, stdout, undefined};
deliver_eval_report({file, Path}, Rendered) ->
    case atomic_write_eval_report(Path, Rendered) of
        ok ->
            {ok, file, unicode:characters_to_binary(Path)};
        {error, Reason} ->
            {error, {report_write_failed, Reason}}
    end.

atomic_write_eval_report(Path, Rendered) ->
    Suffix = integer_to_list(
               erlang:unique_integer([positive, monotonic])),
    Temporary = Path ++ ".tmp-" ++ Suffix,
    case file:write_file(Temporary, Rendered, [binary, exclusive]) of
        ok ->
            case file:rename(Temporary, Path) of
                ok -> ok;
                {error, Reason} ->
                    _ = file:delete(Temporary),
                    {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

trailing_newline(<<>>) -> <<"\n">>;
trailing_newline(Binary) ->
    case binary:last(Binary) of
        $\n -> Binary;
        _ -> <<Binary/binary, "\n">>
    end.

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
    case spawn_cli_composition(Agent) of
        {error, Reason} -> {error, {agent_start_failed, public_reason(Reason)}};
        {ok, AgentPid, _RunnerOptions, Composition} ->
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
                _ = catch adk_agent_composition:stop(Composition)
            end
    end.

serve_command(Opts) ->
    case {parse_port(maps:get(port, Opts, "8080")),
          parse_loopback_ip(maps:get(ip, Opts, "127.0.0.1")),
          developer_token()} of
        {{ok, Port}, {ok, Ip}, ok} ->
            case load_optional_served_agent(Opts) of
                {ok, Agent, RunnerOptions} ->
                    case prepare_developer_application(
                           Port, Ip, RunnerOptions) of
                        ok -> start_served_agent(Agent, Port, Ip);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

load_optional_served_agent(Opts) ->
    case maps:find(config, Opts) of
        error -> {ok, undefined, #{}};
        {ok, Path} ->
            case load_agent_file(Path) of
                {error, _} = Error -> Error;
                {ok, Agent} ->
                    {ok, Agent, maps:get(runner_options, Agent, #{})}
            end
    end.

start_served_agent(undefined, Port, Ip) ->
    {ok, serve_result(Port, Ip, undefined)};
start_served_agent(Agent, Port, Ip) ->
    case spawn_cli_composition(Agent) of
        {ok, _Pid, _RunnerOptions, _Composition} ->
            {ok, serve_result(Port, Ip, maps:get(name, Agent))};
        {error, Reason} ->
            {error, {agent_start_failed, public_reason(Reason)}}
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

inspect_observability(Opts) ->
    remote_json(get, <<"/dev/v1/observability">>, undefined, Opts).

inspect_live_sessions(Opts) ->
    remote_json(get, <<"/dev/v1/live/sessions">>, undefined, Opts).

send_remote_live_text(SessionId0, Opts) ->
    with_required(
      Opts, [text],
      fun() ->
          SessionId = safe_binary(SessionId0),
          Text = option_binary(Opts, text, <<>>),
          case valid_nonempty_binary(SessionId)
               andalso valid_nonempty_binary(Text) of
              true ->
                  remote_json(
                    post,
                    <<"/dev/v1/live/sessions/",
                      (quote(SessionId))/binary, "/text">>,
                    jsx:encode(#{<<"text">> => Text}), Opts);
              false -> {error, invalid_live_text_command}
          end
      end).

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
    case remote_binary(Method, Path, Body, Opts) of
        {ok, ResponseBody} ->
            case decode_json_binary(ResponseBody) of
                {ok, Json} -> {ok, Json};
                {error, _} -> {error, invalid_developer_api_response}
            end;
        {error, _} = Error -> Error
    end.

remote_binary(Method, Path, Body, Opts) ->
    remote_binary(Method, Path, Body, Opts,
                  ?MAX_DEVELOPER_RESPONSE_BYTES).

remote_binary(Method, Path, Body, Opts, MaxResponseBytes)
  when is_integer(MaxResponseBytes), MaxResponseBytes > 0,
       MaxResponseBytes =< ?ADK_EVAL_REPORT_MAX_BYTES ->
    Base0 = option_binary(Opts, base_url, ?DEFAULT_BASE_URL),
    case validate_base_url(Base0) of
        {error, _} = Error -> Error;
        {ok, Base} ->
            case developer_token_value() of
                {error, _} = Error -> Error;
                {ok, Token} ->
                    case safe_developer_request(
                           Method, Base, Path, Body, Token,
                           MaxResponseBytes) of
                        {ok, Status, ResponseBody}
                          when Status >= 200, Status < 300 ->
                            {ok, ResponseBody};
                        {ok, Status, ResponseBody} ->
                            {error, {developer_api_http_error, Status,
                                     public_http_error(ResponseBody)}};
                        {error, {developer_response_too_large, Status}}
                          when Status >= 200, Status < 300 ->
                            {error, invalid_developer_api_response};
                        {error, {developer_response_too_large, Status}} ->
                            {error, {developer_api_http_error, Status,
                                     <<"developer_api_request_failed">>}};
                        {error, Reason} ->
                            {error, developer_api_transport_error(Reason)}
                    end
            end
    end.

%% `httpc' only streams 200 and 206 responses; all other status bodies are
%% accumulated internally before the caller can enforce a limit.  Gun's
%% per-stream flow credit lets the CLI apply the same hard cap to success and
%% error responses while retaining verified TLS for HTTPS endpoints.
safe_developer_request(Method, Base, Path, Body, Token,
                       MaxResponseBytes) ->
    try bounded_developer_request(Method, Base, Path, Body, Token,
                                  MaxResponseBytes) of
        Result -> Result
    catch
        Class:Reason:_Stacktrace ->
            {error, {http_client_exception, Class, Reason}}
    end.

bounded_developer_request(Method, Base, Path, Body, Token,
                          MaxResponseBytes) ->
    case application:ensure_all_started(gun) of
        {ok, _} ->
            case developer_endpoint(Base, Path) of
                {ok, Endpoint} ->
                    Deadline = developer_deadline(),
                    open_developer_connection(
                      Endpoint, Method, Body, Token, Deadline,
                      MaxResponseBytes);
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, {gun_start_failed, Reason}}
    end.

developer_endpoint(Base, Path) ->
    try uri_string:parse(Base) of
        #{scheme := Scheme0, host := Host0} = Parsed ->
            Scheme = safe_binary(Scheme0),
            Host = safe_binary(Host0),
            Port = maps:get(
                     port, Parsed,
                     case Scheme of
                         <<"https">> -> 443;
                         <<"http">> -> 80
                     end),
            BasePath = safe_binary(maps:get(path, Parsed, <<>>)),
            {ok, #{scheme => Scheme,
                   host => Host,
                   port => Port,
                   path => <<BasePath/binary, Path/binary>>}};
        _ -> {error, invalid_base_url}
    catch
        _:_ -> {error, invalid_base_url}
    end.

open_developer_connection(Endpoint, Method, Body, Token, Deadline,
                          MaxResponseBytes) ->
    case developer_gun_options(Endpoint, Deadline) of
        {error, _} = Error -> Error;
        {ok, GunOptions} ->
            Host = binary_to_list(maps:get(host, Endpoint)),
            case gun:open(Host, maps:get(port, Endpoint), GunOptions) of
                {ok, Connection} ->
                    try await_developer_connection(
                          Connection, Endpoint, Method, Body, Token,
                          Deadline, MaxResponseBytes)
                    after
                        _ = catch gun:close(Connection)
                    end;
                {error, Reason} -> {error, Reason}
            end
    end.

await_developer_connection(Connection, Endpoint, Method, Body, Token,
                           Deadline, MaxResponseBytes) ->
    case gun:await_up(Connection, developer_remaining(Deadline)) of
        {ok, http} ->
            Headers0 = [{<<"authorization">>,
                         <<"Bearer ", Token/binary>>},
                        {<<"accept">>, <<"application/json">>}],
            Headers = case Method of
                post -> [{<<"content-type">>, <<"application/json">>} |
                         Headers0];
                _ -> Headers0
            end,
            RequestBody = case Body of undefined -> <<>>; _ -> Body end,
            Stream = gun:request(
                       Connection, developer_method(Method),
                       maps:get(path, Endpoint), Headers, RequestBody,
                       #{flow => 1}),
            await_developer_response(Connection, Stream, Deadline,
                                     MaxResponseBytes);
        {ok, _OtherProtocol} -> {error, unsupported_protocol};
        {error, timeout} -> {error, timeout};
        {error, Reason} -> {error, Reason}
    end.

developer_method(get) -> <<"GET">>;
developer_method(delete) -> <<"DELETE">>;
developer_method(post) -> <<"POST">>.

await_developer_response(Connection, Stream, Deadline, MaxResponseBytes) ->
    case gun:await(Connection, Stream, developer_remaining(Deadline)) of
        {inform, _Status, _Headers} ->
            await_developer_response(Connection, Stream, Deadline,
                                     MaxResponseBytes);
        {response, fin, Status, _Headers} ->
            {ok, Status, <<>>};
        {response, nofin, Status, Headers} ->
            case declared_body_too_large(Headers, MaxResponseBytes) of
                true ->
                    cancel_developer_stream(Connection, Stream),
                    {error, {developer_response_too_large, Status}};
                false ->
                    collect_developer_body(
                      Connection, Stream, Status, Deadline, [], 0,
                      MaxResponseBytes)
            end;
        {error, timeout} ->
            cancel_developer_stream(Connection, Stream),
            {error, timeout};
        {error, Reason} -> {error, Reason};
        _ -> {error, invalid_http_response}
    end.

collect_developer_body(Connection, Stream, Status, Deadline, Acc, Size,
                       MaxResponseBytes) ->
    case gun:await(Connection, Stream, developer_remaining(Deadline)) of
        {data, Fin, Chunk} when is_binary(Chunk) ->
            NewSize = Size + byte_size(Chunk),
            case NewSize =< MaxResponseBytes of
                false ->
                    cancel_developer_stream(Connection, Stream),
                    {error, {developer_response_too_large, Status}};
                true when Fin =:= fin ->
                    {ok, Status,
                     iolist_to_binary(lists:reverse([Chunk | Acc]))};
                true ->
                    ok = gun:update_flow(Connection, Stream, 1),
                    collect_developer_body(
                      Connection, Stream, Status, Deadline,
                      [Chunk | Acc], NewSize, MaxResponseBytes)
            end;
        {trailers, _Headers} ->
            {ok, Status, iolist_to_binary(lists:reverse(Acc))};
        {error, timeout} ->
            cancel_developer_stream(Connection, Stream),
            {error, timeout};
        {error, Reason} -> {error, Reason};
        _ -> {error, invalid_http_response}
    end.

declared_body_too_large(Headers, MaxResponseBytes) ->
    lists:any(
      fun({Name0, Value0}) ->
              Name = string:lowercase(safe_binary(Name0)),
              case Name of
                  <<"content-length">> ->
                      case parse_content_length(safe_binary(Value0)) of
                          {ok, Length} ->
                              Length > MaxResponseBytes;
                          error -> false
                      end;
                  _ -> false
              end;
         (_) -> false
      end, Headers).

parse_content_length(Value) ->
    try binary_to_integer(string:trim(Value)) of
        Length when Length >= 0 -> {ok, Length};
        _ -> error
    catch
        _:_ -> error
    end.

cancel_developer_stream(Connection, Stream) ->
    _ = catch gun:cancel(Connection, Stream),
    ok.

developer_gun_options(#{scheme := <<"http">>}, Deadline) ->
    {ok, #{transport => tcp,
           protocols => [http],
           retry => 0,
           connect_timeout => developer_remaining(Deadline)}};
developer_gun_options(#{scheme := <<"https">>, host := Host}, Deadline) ->
    case developer_ca_options() of
        {ok, CaOptions} ->
            HostString = binary_to_list(Host),
            {ok, #{transport => tls,
                   protocols => [http],
                   retry => 0,
                   connect_timeout => developer_remaining(Deadline),
                   tls_handshake_timeout => developer_remaining(Deadline),
                   tls_opts =>
                       [{verify, verify_peer} | CaOptions] ++
                       [{server_name_indication, HostString},
                        {customize_hostname_check,
                         [{match_fun,
                           public_key:
                             pkix_verify_hostname_match_fun(https)}]}]}};
        {error, _} = Error -> Error
    end.

developer_ca_options() ->
    try public_key:cacerts_get() of
        Certs when is_list(Certs), Certs =/= [] ->
            {ok, [{cacerts, Certs}]};
        _ -> developer_fallback_ca_file()
    catch
        _:_ -> developer_fallback_ca_file()
    end.

developer_fallback_ca_file() ->
    Environment = case os:getenv("SSL_CERT_FILE") of
        false -> [];
        Value -> [Value]
    end,
    Candidates = Environment ++
        ["/etc/ssl/cert.pem",
         "/etc/ssl/certs/ca-certificates.crt",
         "/opt/homebrew/etc/ca-certificates/cert.pem",
         "/usr/local/etc/openssl@3/cert.pem",
         "/usr/local/etc/openssl/cert.pem"],
    case lists:dropwhile(
           fun(File) -> not filelib:is_regular(File) end, Candidates) of
        [File | _] -> {ok, [{cacertfile, File}]};
        [] -> {error, ca_certificates_unavailable}
    end.

developer_deadline() ->
    erlang:monotonic_time(millisecond) + ?DEVELOPER_HTTP_TIMEOUT.

developer_remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

load_agent_file(Path) ->
    %% Config compilation may resolve operator-owned registry IDs from the
    %% application environment. Commands intentionally compile before they
    %% start OTP services, so load the .app specification first in a fresh
    %% escript VM instead of silently compiling against an empty registry.
    case application:load(erlang_adk) of
        ok -> adk_agent_config:load_file(Path);
        {error, {already_loaded, erlang_adk}} ->
            adk_agent_config:load_file(Path);
        {error, _Reason} -> {error, application_config_unavailable}
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
    case adk_bounded_file:read(Path, ?MAX_CONFIG_BYTES) of
        {ok, Binary} ->
            decode_json_binary(Binary);
        {error, _} = Error -> Error
    end.

decode_json_binary(Binary) ->
    try jsx:decode(Binary, [return_maps]) of
        Json -> {ok, Json}
    catch
        _:_ -> {error, invalid_json}
    end.

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
prepare_developer_application(Port, Ip, AgentRunnerOptions) ->
    stop_application(),
    case application:load(erlang_adk) of
        ok -> configure_and_start_developer_application(
                Port, Ip, AgentRunnerOptions);
        {error, {already_loaded, erlang_adk}} ->
            configure_and_start_developer_application(
              Port, Ip, AgentRunnerOptions);
        {error, Reason} ->
            {error, #{code => application_load_failed,
                      reason => public_reason(Reason)}}
    end.

configure_and_start_developer_application(Port, Ip, AgentRunnerOptions)
  when is_map(AgentRunnerOptions) ->
    OperatorOptions = application:get_env(
                        erlang_adk, dev_runner_options, #{}),
    case is_map(OperatorOptions) of
        true ->
            %% Declarative options are bounded by adk_agent_config. Trusted
            %% operator settings win if both specify the same policy, while
            %% runtime-profile service refs are merged authoritatively later.
            DevRunnerOptions = maps:merge(
                                 AgentRunnerOptions, OperatorOptions),
            ok = application:set_env(erlang_adk, dev_enabled, true),
            ok = application:set_env(erlang_adk, a2a_ip, Ip),
            ok = application:set_env(erlang_adk, a2a_port, Port),
            ok = application:set_env(
                   erlang_adk, dev_runner_options, DevRunnerOptions),
            ensure_application_started();
        false -> {error, invalid_dev_runtime_config}
    end.

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

write_eval_run_result(#{delivery := stdout, report := Report}) ->
    io:put_chars(Report);
write_eval_run_result(#{delivery := file}) ->
    ok.

write_error(Reason) ->
    Error = #{<<"status">> => <<"error">>,
              <<"reason">> => public_reason(Reason)},
    io:put_chars(standard_error, [jsx:encode(Error), "\n"]).
