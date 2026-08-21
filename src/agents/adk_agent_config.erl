%% @doc Versioned compiler for untrusted declarative agent configuration.
%%
%% Version 1 is JSON-compatible and deliberately contains only values which
%% can be checked without creating atoms or accepting caller-selected network
%% destinations, commands, headers, or credentials.  Trusted providers and
%% dynamic toolsets are selected by binary ID from one immutable
%% `adk_config_registry' snapshot.
%%
%% Version 2 retains that boundary and adds data-only composition references.
%% Agent Config files may be JSON or the strict YAML subset implemented by
%% `adk_agent_yaml'; both formats normalize to the same IR and therefore the
%% same fingerprint when compiled against the same registry snapshot.
-module(adk_agent_config).

-export([compile/1, compile/2, load_file/1, load_file/2,
         current_schema_version/0, fingerprint/1]).

-define(SCHEMA_VERSION, 2).
-define(LEGACY_SCHEMA_VERSION, 1).
-define(MAX_CONFIG_BYTES, 1048576).
-define(MAX_AGENT_NAME_BYTES, 256).
-define(MAX_TOOLSET_REFS, 64).
-define(DEFAULT_MODEL, <<"gemini-3.1-flash-lite">>).
-define(MAX_DECLARATIVE_RUN_TIMEOUT, 600000).
-define(MAX_DECLARATIVE_SERVICE_TIMEOUT, 60000).
-define(MAX_DECLARATIVE_LLM_CALLS, 64).
-define(MAX_DECLARATIVE_TOOL_ROUNDS, 32).
-define(MAX_DECLARATIVE_TOOL_CONCURRENCY, 16).
-define(MAX_DECLARATIVE_TOOL_TIMEOUT, 120000).
-define(MAX_DECLARATIVE_SUB_AGENTS, 64).
-define(MAX_DECLARATIVE_SUB_AGENT_DEPTH, 16).
-define(MAX_DECLARATIVE_WORKFLOWS, 64).

-type compiled() :: #{
    schema_version := pos_integer(),
    fingerprint := binary(),
    registry_generation := pos_integer(),
    registry_instance_id := binary(),
    registry_snapshot_revision_id := binary(),
    name := binary(),
    provider_name := binary(),
    provider := module() | binary(),
    model := binary(),
    config := map(),
    tools := [module() | adk_toolset:descriptor()],
    runner_options := map(),
    references => map()
}.

-export_type([compiled/0]).

-spec current_schema_version() -> pos_integer().
current_schema_version() -> ?SCHEMA_VERSION.

-spec load_file(file:filename_all()) ->
    {ok, compiled()} | {error, term()}.
load_file(Path) ->
    load_file(Path, #{}).

-spec load_file(file:filename_all(), map()) ->
    {ok, compiled()} | {error, term()}.
load_file(Path0, Options) when is_map(Options) ->
    case normalize_options(Options) of
        {ok, Normalized} ->
            case normalize_path(Path0) of
                {ok, Path} ->
                    case adk_bounded_file:read(
                           Path, ?MAX_CONFIG_BYTES) of
                        {ok, Binary} ->
                            Format = source_format(
                                       Path,
                                       maps:get(source_format, Normalized,
                                                auto)),
                            decode_and_compile(Binary, Format, Normalized);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
load_file(_Path, _Options) ->
    {error, invalid_agent_config_options}.

-spec compile(map()) -> {ok, compiled()} | {error, term()}.
compile(Json) ->
    compile(Json, #{}).

-spec compile(map(), map()) -> {ok, compiled()} | {error, term()}.
compile(Json, Options) when is_map(Json), is_map(Options) ->
    case validate_input_limits(Json) of
        ok ->
            case normalize_json_config(Json) of
                {ok, NormalizedJson} ->
                    case normalize_options(Options) of
                        {ok, Normalized} ->
                            compile_normalized(NormalizedJson, Normalized);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
compile(_Json, _Options) ->
    {error, agent_config_must_be_object}.

%% @doc Return the stored fingerprint of a compiled configuration.
-spec fingerprint(compiled()) -> {ok, binary()} | {error, term()}.
fingerprint(#{schema_version := Version,
              fingerprint := Fingerprint})
  when (Version =:= ?LEGACY_SCHEMA_VERSION orelse
        Version =:= ?SCHEMA_VERSION),
       is_binary(Fingerprint), byte_size(Fingerprint) =:= 64 ->
    {ok, Fingerprint};
fingerprint(_Config) ->
    {error, invalid_compiled_agent_config}.

decode_and_compile(Binary, json, Options) ->
    try jsx:decode(Binary, [return_maps]) of
        Json when is_map(Json) ->
            case validate_input_limits(Json) of
                ok ->
                    case normalize_json_config(Json) of
                        {ok, NormalizedJson} ->
                            compile_normalized(NormalizedJson, Options);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, agent_config_must_be_object}
    catch
        _:_ -> {error, invalid_json}
    end;
decode_and_compile(Binary, yaml, Options) ->
    case adk_agent_yaml:decode(Binary) of
        {ok, Json} when is_map(Json) ->
            case validate_input_limits(Json) of
                ok ->
                    case normalize_json_config(Json) of
                        {ok, NormalizedJson} ->
                            compile_normalized(NormalizedJson, Options);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {ok, _} -> {error, agent_config_must_be_object};
        {error, _} = Error -> Error
    end.

source_format(Path, auto) ->
    case string:lowercase(filename:extension(Path)) of
        ".yaml" -> yaml;
        ".yml" -> yaml;
        _ -> json
    end;
source_format(_Path, Format) -> Format.

normalize_path(Path0) ->
    try unicode:characters_to_list(Path0) of
        Path when is_list(Path) -> {ok, Path};
        _ -> {error, invalid_agent_config_path}
    catch
        _:_ -> {error, invalid_agent_config_path}
    end.

%% `compile/1,2' is a public boundary, not just an internal convenience for
%% already-decoded JSX values. Accept exactly JSON-shaped Erlang terms so a
%% pid, ref, fun, tuple, atom key, or improper list can never be smuggled into
%% provider configuration or its public fingerprint.
normalize_json_config(Json) ->
    case normalize_json_value(Json, []) of
        {ok, Normalized} when is_map(Normalized) -> {ok, Normalized};
        {ok, _} -> {error, agent_config_must_be_object};
        {error, Reason} -> {error, {invalid_agent_config_json, Reason}}
    end.

normalize_json_value(Value, Path) when is_binary(Value) ->
    adk_json:normalize(Value, Path);
normalize_json_value(Value, _Path) when is_integer(Value); is_float(Value) ->
    {ok, Value};
normalize_json_value(true, _Path) -> {ok, true};
normalize_json_value(false, _Path) -> {ok, false};
normalize_json_value(null, _Path) -> {ok, null};
normalize_json_value(Value, Path) when is_map(Value) ->
    normalize_json_pairs(maps:to_list(Value), Path, #{});
normalize_json_value(Value, Path) when is_list(Value) ->
    normalize_json_list(Value, Path, 0, []);
normalize_json_value(_Value, Path) ->
    {error, {unsupported_json_term, Path}}.

normalize_json_pairs([], _Path, Acc) -> {ok, Acc};
normalize_json_pairs([{Key, Value} | Rest], Path, Acc)
  when is_binary(Key) ->
    case adk_json:normalize(Key, Path) of
        {ok, Key} ->
            case normalize_json_value(Value, Path ++ [Key]) of
                {ok, Normalized} ->
                    normalize_json_pairs(Rest, Path,
                                         Acc#{Key => Normalized});
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, Reason}
    end;
normalize_json_pairs([{_Key, _Value} | _], Path, _Acc) ->
    {error, {invalid_map_key, Path}}.

normalize_json_list([], _Path, _Index, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_json_list([Value | Rest], Path, Index, Acc) ->
    case normalize_json_value(Value, Path ++ [Index]) of
        {ok, Normalized} ->
            normalize_json_list(Rest, Path, Index + 1,
                                [Normalized | Acc]);
        {error, _} = Error -> Error
    end;
normalize_json_list(_Improper, Path, Index, _Acc) ->
    {error, {improper_json_array, Path ++ [Index]}}.

normalize_options(Options) ->
    Allowed = [registry, allow_legacy_module_tools,
               allow_legacy_provider_modules, format],
    case maps:keys(maps:without(Allowed, Options)) of
        [] ->
            AllowTools = maps:get(
                           allow_legacy_module_tools, Options, false),
            AllowProviders = maps:get(
                               allow_legacy_provider_modules,
                               Options, false),
            SourceFormat = maps:get(format, Options, auto),
            case {is_boolean(AllowTools) andalso
                  is_boolean(AllowProviders),
                  valid_source_format(SourceFormat)} of
                {true, true} ->
                    case resolve_registry(maps:get(registry, Options,
                                                   default)) of
                        {ok, RegistryOptions} ->
                            {ok, RegistryOptions#{
                                   allow_legacy_module_tools => AllowTools,
                                   allow_legacy_provider_modules =>
                                       AllowProviders,
                                   source_format => SourceFormat}};
                        {error, _} = Error -> Error
                    end;
                {false, _} -> {error, invalid_legacy_module_option};
                {_, false} -> {error, invalid_agent_config_format}
            end;
        Unknown -> {error, {unknown_agent_config_options,
                            lists:sort(Unknown)}}
    end.

valid_source_format(auto) -> true;
valid_source_format(json) -> true;
valid_source_format(yaml) -> true;
valid_source_format(_) -> false.

resolve_registry(default) ->
    case application:get_env(erlang_adk, agent_config_registry) of
        {ok, Registry} when is_map(Registry), map_size(Registry) > 0 ->
            resolve_and_cache_default_registry();
        {ok, Registry} -> resolve_registry(Registry);
        undefined -> empty_registry()
    end;
resolve_registry(Registry) when is_map(Registry) ->
    case adk_config_registry:new(Registry) of
        {ok, CompiledRegistry} -> registry_options(CompiledRegistry);
        {error, _} = Error -> Error
    end;
resolve_registry(Registry) ->
    registry_options(Registry).

resolve_and_cache_default_registry() ->
    Lock = {{?MODULE, default_registry, node()}, self()},
    try global:trans(
          Lock,
          fun() ->
              case application:get_env(erlang_adk,
                                       agent_config_registry) of
                  {ok, Definitions}
                    when is_map(Definitions), map_size(Definitions) > 0 ->
                      case adk_config_registry:new(Definitions) of
                          {ok, Registry} ->
                              ok = application:set_env(
                                     erlang_adk, agent_config_registry,
                                     Registry),
                              registry_options(Registry);
                          {error, _} = Error -> Error
                      end;
                  {ok, Registry} -> resolve_registry(Registry);
                  undefined -> empty_registry()
              end
          end, [node()]) of
        aborted -> {error, agent_config_registry_initialization_unavailable};
        Result -> Result
    catch
        _:_ -> {error, agent_config_registry_initialization_unavailable}
    end.

empty_registry() ->
    {ok, Registry} = adk_config_registry:new(),
    registry_options(Registry).

registry_options(Registry) ->
    case {adk_config_registry:snapshot(Registry),
          adk_config_registry:generation(Registry),
          adk_config_registry:instance_id(Registry),
          adk_config_registry:snapshot_revision_id(Registry)} of
        {{ok, Snapshot}, {ok, Generation}, {ok, InstanceId},
         {ok, RevisionId}} ->
            {ok, #{registry => Snapshot,
                   registry_generation => Generation,
                   registry_instance_id => InstanceId,
                   registry_snapshot_revision_id => RevisionId}};
        {{error, _}, _, _, _} -> {error, invalid_agent_config_registry};
        {_, {error, _}, _, _} -> {error, invalid_agent_config_registry};
        {_, _, {error, _}, _} -> {error, invalid_agent_config_registry};
        {_, _, _, {error, _}} -> {error, invalid_agent_config_registry}
    end.

compile_normalized(Json, Options) ->
    case schema_version(Json) of
        {error, _} = Error -> Error;
        {ok, Version} ->
            Allowed = allowed_config_keys(Version),
            Unknown = maps:keys(maps:without(Allowed, Json)),
            case {Unknown, contains_forbidden_secret(Json),
                  contains_forbidden_transport(Json)} of
                {_, true, _} -> {error, secret_in_config_file};
                {_, false, true} -> {error, raw_transport_in_config_file};
                {[_ | _], false, false} ->
                    {error, {unknown_agent_config_keys,
                             lists:sort(Unknown)}};
                {[], false, false} ->
                    build_checked_agent(Version, Json, Options)
            end
    end.

allowed_config_keys(Version) ->
    Base = [<<"schema_version">>, <<"name">>, <<"provider">>,
            <<"model">>, <<"instructions">>,
            <<"global_instruction">>, <<"input_schema">>,
            <<"output_schema">>, <<"output_key">>,
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
            <<"toolsets">>, <<"runner_options">>],
    case Version of
        ?LEGACY_SCHEMA_VERSION -> Base;
        ?SCHEMA_VERSION ->
            Base ++ [<<"agent_template">>, <<"credential_profile">>,
                     <<"runtime_policy">>, <<"sub_agents">>,
                     <<"workflows">>]
    end.

schema_version(Json) ->
    case maps:get(<<"schema_version">>, Json,
                  ?LEGACY_SCHEMA_VERSION) of
        ?LEGACY_SCHEMA_VERSION -> {ok, ?LEGACY_SCHEMA_VERSION};
        ?SCHEMA_VERSION -> {ok, ?SCHEMA_VERSION};
        Value when is_integer(Value), Value > 0 ->
            {error, {unsupported_agent_config_version, Value}};
        _ -> {error, invalid_agent_config_version}
    end.

build_checked_agent(Version, Json, Options) ->
    Name = maps:get(<<"name">>, Json, <<"CliAgent">>),
    ProviderName = maps:get(<<"provider">>, Json, <<"gemini">>),
    Model = maps:get(<<"model">>, Json, ?DEFAULT_MODEL),
    Registry = maps:get(registry, Options),
    case {valid_agent_name(Name), valid_nonempty_binary(Model),
          provider_target(
            ProviderName, Registry,
            maps:get(allow_legacy_provider_modules, Options)),
          tools_from_json(maps:get(<<"tools">>, Json, []),
                          maps:get(allow_legacy_module_tools, Options)),
          toolsets_from_json(maps:get(<<"toolsets">>, Json, []), Registry),
          declarative_references(Version, Json, Registry, Name),
          runner_options_from_json(
            maps:get(<<"runner_options">>, Json, #{}))} of
        {true, true, {ok, Provider}, {ok, ModuleTools},
         {ok, TrustedTools, ToolRefs}, {ok, References},
         {ok, RunnerOptions}} ->
            Config0 = maps:fold(
                        fun agent_config_field/3,
                        #{provider => Provider, model => Model}, Json),
            Tools = ModuleTools ++ TrustedTools,
            validate_compiled_agent(
              Version, Json, Options, Name, ProviderName, Provider, Model,
              Config0, Tools, ToolRefs, References, RunnerOptions);
        {false, _, _, _, _, _, _} -> {error, invalid_agent_name};
        {_, false, _, _, _, _, _} -> {error, invalid_agent_model};
        {_, _, {error, _} = Error, _, _, _, _} -> Error;
        {_, _, _, {error, _} = Error, _, _, _} -> Error;
        {_, _, _, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, _, _, {error, _} = Error} -> Error
    end.

valid_agent_name(Name) when is_binary(Name),
                            byte_size(Name) =< ?MAX_AGENT_NAME_BYTES ->
    adk_agent_tree:validate_name(Name) =:= {ok, Name};
valid_agent_name(_Name) -> false.

validate_compiled_agent(Version, Json, Options, Name, ProviderName,
                        Provider, Model, Config0, Tools, ToolRefs,
                        References, RunnerOptions) ->
    case {adk_llm:validate_config(Config0),
          adk_toolset:expand_tools(Tools)} of
        {ok, {ok, _Schemas}} ->
            Generation = maps:get(registry_generation, Options),
            RegistryInstanceId = maps:get(registry_instance_id, Options),
            RegistryRevisionId = maps:get(
                                   registry_snapshot_revision_id, Options),
            FingerprintBase = #{schema_version => Version,
                                 name => Name,
                                 provider_name => ProviderName,
                                 provider => Provider,
                                 model => Model,
                                 config => Config0,
                                 module_tools => module_tool_names(
                                                   maps:get(<<"tools">>,
                                                            Json, [])),
                                 toolsets => ToolRefs,
                                 runner_options => RunnerOptions,
                                 registry_generation => Generation,
                                 registry_instance_id => RegistryInstanceId,
                                 registry_snapshot_revision_id =>
                                     RegistryRevisionId},
            FingerprintInput = case Version of
                ?LEGACY_SCHEMA_VERSION -> FingerprintBase;
                ?SCHEMA_VERSION ->
                    FingerprintBase#{references => References}
            end,
            Fingerprint = config_fingerprint(FingerprintInput),
            Compiled0 = #{schema_version => Version,
                   fingerprint => Fingerprint,
                   registry_generation => Generation,
                   registry_instance_id => RegistryInstanceId,
                   registry_snapshot_revision_id => RegistryRevisionId,
                   name => Name, provider_name => ProviderName,
                   provider => Provider, model => Model,
                   config => Config0, tools => Tools,
                   runner_options => RunnerOptions},
            case Version of
                ?LEGACY_SCHEMA_VERSION -> {ok, Compiled0};
                ?SCHEMA_VERSION ->
                    {ok, Compiled0#{references => References}}
            end;
        {{error, Reason}, _} ->
            {error, {invalid_provider_config, sanitize_reason(Reason)}};
        {_, {error, Reason}} -> {error, {invalid_tools, Reason}}
    end.

module_tool_names(Names) when is_list(Names) -> Names;
module_tool_names(_) -> [].

validate_input_limits(Json) ->
    Limits = #{max_depth => 64, max_nodes => 50000,
               max_binary_bytes => ?MAX_CONFIG_BYTES,
               max_total_binary_bytes => ?MAX_CONFIG_BYTES,
               max_list_length => 10000, max_map_size => 10000,
               max_external_bytes => ?MAX_CONFIG_BYTES},
    case adk_eval_limits:check(Json, Limits) of
        ok -> ok;
        {error, Reason} ->
            {error, {agent_config_limit_exceeded,
                     limit_reason(Reason)}}
    end.

limit_reason({Tag, _}) when is_atom(Tag) -> Tag;
limit_reason({Tag, _, _}) when is_atom(Tag) -> Tag;
limit_reason(Tag) when is_atom(Tag) -> Tag.

provider_target(Name, Registry, AllowLegacy) when is_binary(Name) ->
    case adk_config_registry:lookup(Registry, provider, Name) of
        {ok, #{provider := Provider}} -> validate_registry_provider(Provider);
        {ok, Provider} -> validate_registry_provider(Provider);
        {error, {unknown_registry_id, provider, Name}} ->
            provider_module(Name, AllowLegacy);
        {error, _} = Error -> Error
    end;
provider_target(_Name, _Registry, _AllowLegacy) ->
    {error, invalid_provider_name}.

validate_registry_provider(Provider) when is_atom(Provider) ->
    case adk_llm:capabilities(Provider) of
        {ok, _} -> {ok, Provider};
        {error, Reason} ->
            {error, {invalid_registry_provider, sanitize_reason(Reason)}}
    end;
validate_registry_provider(ProfileId) when is_binary(ProfileId) ->
    provider_module(ProfileId, true);
validate_registry_provider(_Provider) ->
    {error, invalid_registry_provider}.

declarative_references(?LEGACY_SCHEMA_VERSION, _Json, _Registry, _Name) ->
    {ok, #{}};
declarative_references(?SCHEMA_VERSION, Json, Registry, RootName) ->
    case {optional_registry_reference(
            agent_template, maps:find(<<"agent_template">>, Json)),
          optional_registry_reference(
            credential, maps:find(<<"credential_profile">>, Json)),
          optional_registry_reference(
            runtime_policy, maps:find(<<"runtime_policy">>, Json)),
          parse_sub_agents(maps:get(<<"sub_agents">>, Json, []),
                           #{RootName => true}, 0, 0, [], []),
          parse_workflows(maps:get(<<"workflows">>, Json, []))} of
        {{ok, AgentTemplate}, {ok, Credential}, {ok, RuntimePolicy},
         {ok, SubAgents, _SeenNames, _Count, SubAgentRefs},
         {ok, Workflows, WorkflowRefs}} ->
            Optional = optional_reference_map(
                         [{agent_template, AgentTemplate},
                          {credential_profile, Credential},
                          {runtime_policy, RuntimePolicy}]),
            References = Optional#{sub_agents => SubAgents,
                                   workflows => Workflows},
            RootRefs = optional_lookup_refs(
                         [{agent_template, AgentTemplate},
                          {credential, Credential},
                          {runtime_policy, RuntimePolicy}]),
            Lookups = lists:usort(
                        RootRefs ++ SubAgentRefs ++ WorkflowRefs),
            case adk_config_registry:lookup_many(Registry, Lookups) of
                {ok, _Descriptors} -> {ok, References};
                {error, {unknown_registry_id, Kind, Id}} ->
                    {error, {unknown_trusted_reference, Kind, Id}};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _, _, _, _} -> Error;
        {_, {error, _} = Error, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, {error, _} = Error} -> Error
    end.

optional_registry_reference(_Kind, error) -> {ok, undefined};
optional_registry_reference(_Kind, {ok, Id}) when is_binary(Id) ->
    case valid_registry_id(Id) of
        true -> {ok, Id};
        false -> {error, invalid_registry_id}
    end;
optional_registry_reference(Kind, {ok, _Invalid}) ->
    {error, {invalid_declarative_reference, Kind}}.

optional_reference_map(Pairs) ->
    lists:foldl(
      fun({_Key, undefined}, Acc) -> Acc;
         ({Key, Value}, Acc) -> Acc#{Key => Value}
      end, #{}, Pairs).

optional_lookup_refs(Pairs) ->
    [{Kind, Id} || {Kind, Id} <- Pairs, Id =/= undefined].

parse_sub_agents(SubAgents, _SeenNames, _Depth, _Count,
                 _Ancestors, _Refs) when not is_list(SubAgents) ->
    {error, sub_agents_must_be_array};
parse_sub_agents(_SubAgents, _SeenNames, Depth, _Count,
                 _Ancestors, _Refs)
  when Depth > ?MAX_DECLARATIVE_SUB_AGENT_DEPTH ->
    {error, {sub_agent_depth_limit_exceeded,
             ?MAX_DECLARATIVE_SUB_AGENT_DEPTH}};
parse_sub_agents(SubAgents, SeenNames, Depth, Count, Ancestors, Refs) ->
    parse_sub_agent_list(
      SubAgents, SeenNames, Depth, Count, Ancestors, Refs, []).

parse_sub_agent_list([], SeenNames, _Depth, Count, _Ancestors,
                     Refs, Acc) ->
    {ok, lists:reverse(Acc), SeenNames, Count, Refs};
parse_sub_agent_list([_ | _], _SeenNames, _Depth, Count,
                     _Ancestors, _Refs, _Acc)
  when Count >= ?MAX_DECLARATIVE_SUB_AGENTS ->
    {error, {sub_agent_count_limit_exceeded,
             ?MAX_DECLARATIVE_SUB_AGENTS}};
parse_sub_agent_list([
    #{<<"name">> := Name,
      <<"agent_template">> := TemplateId} = Entry | Rest],
    SeenNames, Depth, Count, Ancestors, Refs, Acc) ->
    Allowed = [<<"name">>, <<"agent_template">>, <<"sub_agents">>],
    Children = maps:get(<<"sub_agents">>, Entry, []),
    case {maps:keys(maps:without(Allowed, Entry)),
          valid_agent_name(Name), valid_registry_id(TemplateId),
          maps:is_key(Name, SeenNames),
          lists:member(TemplateId, Ancestors)} of
        {[], true, true, false, false} ->
            Seen1 = SeenNames#{Name => true},
            Refs1 = [{agent_template, TemplateId} | Refs],
            case parse_sub_agents(Children, Seen1, Depth + 1,
                                  Count + 1,
                                  [TemplateId | Ancestors], Refs1) of
                {ok, ParsedChildren, Seen2, Count2, Refs2} ->
                    Canonical = #{name => Name,
                                  agent_template => TemplateId,
                                  sub_agents => ParsedChildren},
                    parse_sub_agent_list(
                      Rest, Seen2, Depth, Count2, Ancestors,
                      Refs2, [Canonical | Acc]);
                {error, _} = Error -> Error
            end;
        {[_ | _], _, _, _, _} -> {error, invalid_sub_agent_reference};
        {_, false, _, _, _} -> {error, invalid_sub_agent_name};
        {_, _, false, _, _} -> {error, invalid_registry_id};
        {_, _, _, true, _} -> {error, {duplicate_sub_agent_name, Name}};
        {_, _, _, _, true} ->
            {error, {sub_agent_reference_cycle, TemplateId}}
    end;
parse_sub_agent_list([_Invalid | _Rest], _SeenNames, _Depth, _Count,
                     _Ancestors, _Refs, _Acc) ->
    {error, invalid_sub_agent_reference};
parse_sub_agent_list(_Improper, _SeenNames, _Depth, _Count,
                     _Ancestors, _Refs, _Acc) ->
    {error, sub_agents_must_be_array}.

parse_workflows(Workflows) when not is_list(Workflows) ->
    {error, workflows_must_be_array};
parse_workflows(Workflows) ->
    parse_workflow_list(Workflows, 0, #{}, [], []).

parse_workflow_list([], _Count, _Seen, Acc, Refs) ->
    {ok, lists:reverse(Acc), Refs};
parse_workflow_list([_ | _], Count, _Seen, _Acc, _Refs)
  when Count >= ?MAX_DECLARATIVE_WORKFLOWS ->
    {error, {workflow_reference_limit_exceeded,
             ?MAX_DECLARATIVE_WORKFLOWS}};
parse_workflow_list([
    #{<<"name">> := Name, <<"workflow">> := WorkflowId} = Entry | Rest],
    Count, Seen, Acc, Refs) ->
    case {lists:sort(maps:keys(Entry)),
          valid_registry_id(Name), valid_registry_id(WorkflowId),
          maps:is_key(Name, Seen)} of
        {[<<"name">>, <<"workflow">>], true, true, false} ->
            Canonical = #{name => Name, workflow => WorkflowId},
            parse_workflow_list(
              Rest, Count + 1, Seen#{Name => true},
              [Canonical | Acc], [{workflow, WorkflowId} | Refs]);
        {_, _, _, true} -> {error, {duplicate_workflow_name, Name}};
        {_, false, _, _} -> {error, invalid_workflow_name};
        {_, _, false, _} -> {error, invalid_registry_id};
        _ -> {error, invalid_workflow_reference}
    end;
parse_workflow_list([_Invalid | _Rest], _Count, _Seen, _Acc, _Refs) ->
    {error, invalid_workflow_reference};
parse_workflow_list(_Improper, _Count, _Seen, _Acc, _Refs) ->
    {error, workflows_must_be_array}.

toolsets_from_json(Refs, _Registry) when not is_list(Refs) ->
    {error, toolsets_must_be_array};
toolsets_from_json(Refs, Registry) ->
    case parse_toolset_refs(Refs, 0, #{}, []) of
        {ok, Parsed} ->
            Keys = [{Kind, Id} || {Kind, Id, _Canonical} <- Parsed],
            case adk_config_registry:lookup_many(Registry, Keys) of
                {ok, Descriptors} ->
                    expand_toolset_descriptors(
                      Parsed, Descriptors, [], []);
                {error, {unknown_registry_id, Kind, Id}} ->
                    {error, {unknown_trusted_toolset, Kind, Id}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

parse_toolset_refs([], _Count, _Seen, Acc) ->
    {ok, lists:reverse(Acc)};
parse_toolset_refs([_Ref | _Rest], Count, _Seen, _Acc)
  when Count >= ?MAX_TOOLSET_REFS ->
    {error, {toolset_reference_limit_exceeded, ?MAX_TOOLSET_REFS}};
parse_toolset_refs([#{<<"kind">> := Kind0, <<"id">> := Id} = Ref | Rest],
                   Count, Seen, Acc) ->
    case {lists:sort(maps:keys(Ref)),
          toolset_kind(Kind0), valid_registry_id(Id)} of
        {[<<"id">>, <<"kind">>], {ok, Kind}, true} ->
            Key = {Kind, Id},
            case maps:is_key(Key, Seen) of
                true -> {error, {duplicate_toolset_reference, Kind, Id}};
                false ->
                    Canonical = #{kind => Kind, id => Id},
                    parse_toolset_refs(
                      Rest, Count + 1, Seen#{Key => true},
                      [{Kind, Id, Canonical} | Acc])
            end;
        {[<<"id">>, <<"kind">>], {error, _} = Error, _} -> Error;
        {[<<"id">>, <<"kind">>], _, false} ->
            {error, invalid_registry_id};
        _ -> {error, invalid_toolset_reference}
    end;
parse_toolset_refs([_Invalid | _Rest], _Count, _Seen, _Acc) ->
    {error, invalid_toolset_reference};
parse_toolset_refs(_Improper, _Count, _Seen, _Acc) ->
    {error, invalid_toolset_reference}.

expand_toolset_descriptors([], [], ToolsAcc, RefsAcc) ->
    {ok, lists:reverse(ToolsAcc), lists:reverse(RefsAcc)};
expand_toolset_descriptors(
  [{Kind, _Id, Canonical} | Rest], [Descriptor | DescriptorRest],
  ToolsAcc, RefsAcc) ->
    case descriptor_tools(Kind, Descriptor) of
        {ok, Tools} ->
            expand_toolset_descriptors(
              Rest, DescriptorRest,
              lists:reverse(Tools) ++ ToolsAcc,
              [Canonical | RefsAcc]);
        {error, _} = Error -> Error
    end;
expand_toolset_descriptors(_Parsed, _Descriptors, _ToolsAcc, _RefsAcc) ->
    {error, invalid_agent_config_registry}.

toolset_kind(<<"mcp">>) -> {ok, mcp};
toolset_kind(<<"openapi">>) -> {ok, openapi};
toolset_kind(<<"tool_pack">>) -> {ok, tool_pack};
toolset_kind(_) -> {error, invalid_toolset_kind}.

descriptor_tools(mcp, Descriptor) -> one_toolset(Descriptor);
descriptor_tools(openapi, Descriptor) -> one_toolset(Descriptor);
descriptor_tools(tool_pack, #{tools := Tools}) when is_list(Tools) ->
    {ok, Tools};
descriptor_tools(tool_pack, Tools) when is_list(Tools) -> {ok, Tools};
descriptor_tools(Kind, _Descriptor) ->
    {error, {invalid_registry_tool_descriptor, Kind}}.

one_toolset(#{toolset := Toolset}) -> one_toolset(Toolset);
one_toolset(Toolset) ->
    case adk_toolset:is_descriptor(Toolset) of
        true -> {ok, [Toolset]};
        false -> {error, invalid_registry_toolset}
    end.

agent_config_field(<<"schema_version">>, _Value, Acc) -> Acc;
agent_config_field(<<"name">>, _Value, Acc) -> Acc;
agent_config_field(<<"provider">>, _Value, Acc) -> Acc;
agent_config_field(<<"tools">>, _Value, Acc) -> Acc;
agent_config_field(<<"toolsets">>, _Value, Acc) -> Acc;
agent_config_field(<<"runner_options">>, _Value, Acc) -> Acc;
agent_config_field(<<"agent_template">>, _Value, Acc) -> Acc;
agent_config_field(<<"credential_profile">>, _Value, Acc) -> Acc;
agent_config_field(<<"runtime_policy">>, _Value, Acc) -> Acc;
agent_config_field(<<"sub_agents">>, _Value, Acc) -> Acc;
agent_config_field(<<"workflows">>, _Value, Acc) -> Acc;
agent_config_field(<<"include_contents">>, Value, Acc) ->
    Acc#{include_contents => history_value(Value)};
agent_config_field(<<"history_policy">>, Value, Acc) ->
    Acc#{history_policy => history_value(Value)};
agent_config_field(<<"generation_config">>, Value, Acc) ->
    Acc#{generation_config => generation_config(Value)};
agent_config_field(<<"thinking_config">>, Value, Acc) ->
    Acc#{thinking_config => thinking_config(Value)};
agent_config_field(<<"safety_settings">>, Value, Acc) ->
    Acc#{safety_settings => safety_settings(Value)};
agent_config_field(<<"builtin_tools">>, Value, Acc) ->
    Acc#{builtin_tools => builtin_tools(Value)};
agent_config_field(<<"required_capabilities">>, Value, Acc) ->
    Acc#{required_capabilities => capabilities(Value)};
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

history_value(<<"default">>) -> default;
history_value(<<"none">>) -> none;
history_value(<<"include">>) -> include;
history_value(<<"exclude">>) -> exclude;
history_value(Value) -> Value.

generation_config(Value) when is_map(Value) ->
    maps:fold(
      fun(Key, NestedValue, Acc) ->
          case generation_key(Key) of
              undefined -> Acc#{Key => NestedValue};
              thinking_config ->
                  Acc#{thinking_config => thinking_config(NestedValue)};
              safety_settings ->
                  Acc#{safety_settings => safety_settings(NestedValue)};
              Atom -> Acc#{Atom => NestedValue}
          end
      end, #{}, Value);
generation_config(Value) -> Value.

generation_key(<<"temperature">>) -> temperature;
generation_key(<<"top_p">>) -> top_p;
generation_key(<<"top_k">>) -> top_k;
generation_key(<<"max_tokens">>) -> max_tokens;
generation_key(<<"max_output_tokens">>) -> max_output_tokens;
generation_key(<<"candidate_count">>) -> candidate_count;
generation_key(<<"seed">>) -> seed;
generation_key(<<"presence_penalty">>) -> presence_penalty;
generation_key(<<"frequency_penalty">>) -> frequency_penalty;
generation_key(<<"stop_sequences">>) -> stop_sequences;
generation_key(<<"response_mime_type">>) -> response_mime_type;
generation_key(<<"thinking_config">>) -> thinking_config;
generation_key(<<"safety_settings">>) -> safety_settings;
generation_key(_) -> undefined.

thinking_config(Value) when is_map(Value) ->
    maps:fold(
      fun(<<"thinking_level">>, Nested, Acc) ->
              Acc#{thinking_level => Nested};
         (<<"thinking_budget">>, Nested, Acc) ->
              Acc#{thinking_budget => Nested};
         (<<"include_thoughts">>, Nested, Acc) ->
              Acc#{include_thoughts => Nested};
         (Key, Nested, Acc) -> Acc#{Key => Nested}
      end, #{}, Value);
thinking_config(Value) -> Value.

safety_settings(Settings) when is_list(Settings) ->
    [safety_setting(Setting) || Setting <- Settings];
safety_settings(Value) -> Value.

safety_setting(Setting) when is_map(Setting) ->
    maps:fold(
      fun(<<"category">>, Value, Acc) -> Acc#{category => Value};
         (<<"threshold">>, Value, Acc) -> Acc#{threshold => Value};
         (Key, Value, Acc) -> Acc#{Key => Value}
      end, #{}, Setting);
safety_setting(Value) -> Value.

builtin_tools(Values) when is_list(Values) ->
    [builtin_tool(Value) || Value <- Values];
builtin_tools(Value) -> Value.

builtin_tool(<<"google_search">>) -> google_search;
builtin_tool(Value) -> Value.

capabilities(Values) when is_list(Values) ->
    [capability(Value) || Value <- Values];
capabilities(Value) -> Value.

capability(<<"streaming">>) -> streaming;
capability(<<"function_calling">>) -> function_calling;
capability(<<"structured_output">>) -> structured_output;
capability(<<"generation_config">>) -> generation_config;
capability(<<"multimodal">>) -> multimodal;
capability(<<"thinking">>) -> thinking;
capability(<<"safety_settings">>) -> safety_settings;
capability(<<"content_streaming">>) -> content_streaming;
capability(<<"google_search_grounding">>) -> google_search_grounding;
capability(Value) -> Value.

provider_module(Name, AllowLegacy) when is_binary(Name) ->
    case configured_provider_profile(Name) of
        true -> profile_provider_module(Name, AllowLegacy);
        false -> fallback_provider_module(Name, AllowLegacy)
    end.

configured_provider_profile(Name) ->
    case application:get_env(erlang_adk, provider_profiles, #{}) of
        Profiles when is_map(Profiles) -> maps:is_key(Name, Profiles);
        _InvalidProfiles -> false
    end.

profile_provider_module(Name, AllowLegacy) ->
    case adk_provider_registry:lookup(Name) of
        {ok, #{request_adapter := _}} -> {ok, Name};
        {ok, _LiveOnlyProfile} ->
            {error, {invalid_provider, Name,
                     request_capability_unavailable}};
        {error, unknown_provider_profile} ->
            legacy_provider_module(Name, AllowLegacy);
        {error, _} -> {error, {unknown_provider, Name}}
    end.

fallback_provider_module(<<"gemini">>, _AllowLegacy) ->
    {ok, adk_llm_gemini};
fallback_provider_module(<<"openai">>, _AllowLegacy) ->
    {ok, adk_llm_openai};
fallback_provider_module(<<"anthropic">>, _AllowLegacy) ->
    {ok, adk_llm_anthropic};
fallback_provider_module(<<"compatible">>, _AllowLegacy) ->
    {ok, adk_llm_compatible};
fallback_provider_module(<<"adk_llm_probe">> = Name, _AllowLegacy) ->
    checked_provider(adk_llm_probe, Name);
fallback_provider_module(Name, AllowLegacy) ->
    legacy_provider_module(Name, AllowLegacy).

legacy_provider_module(<<"adk_llm_", _/binary>>, false) ->
    {error, legacy_provider_modules_disabled};
legacy_provider_module(<<"adk_llm_", _/binary>> = Name, true) ->
    try binary_to_existing_atom(Name, utf8) of
        Module -> checked_provider(Module, Name)
    catch
        error:badarg -> {error, {unknown_provider, Name}}
    end;
legacy_provider_module(Name, _AllowLegacy) ->
    {error, {unknown_provider, Name}}.

checked_provider(Module, Name) ->
    case adk_llm:capabilities(Module) of
        {ok, _} -> {ok, Module};
        {error, Reason} ->
            {error, {invalid_provider, Name, sanitize_reason(Reason)}}
    end.

tools_from_json([], _AllowLegacy) ->
    {ok, []};
tools_from_json(Tools, false) when is_list(Tools) ->
    case lists:all(fun is_binary/1, Tools) of
        true -> {error, direct_module_tools_disabled};
        false -> {error, invalid_tool_name}
    end;
tools_from_json(Tools, true) when is_list(Tools) ->
    tools_from_names(Tools, []);
tools_from_json(_Tools, _AllowLegacy) ->
    {error, tools_must_be_array}.

tools_from_names([], Acc) -> {ok, lists:reverse(Acc)};
tools_from_names([Name | Rest], Acc) when is_binary(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        Module ->
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, schema, 0) andalso
                         erlang:function_exported(Module, execute, 2) of
                        true -> tools_from_names(Rest, [Module | Acc]);
                        false -> {error, {invalid_tool_module, Name}}
                    end;
                _ -> {error, {unknown_tool_module, Name}}
            end
    catch
        error:badarg -> {error, {unknown_tool_module, Name}}
    end;
tools_from_names([_ | _], _Acc) ->
    {error, invalid_tool_name}.

runner_options_from_json(Options) when is_map(Options) ->
    Allowed = [<<"run_timeout">>, <<"max_llm_calls">>,
               <<"max_tool_rounds">>, <<"service_timeout">>,
               <<"tool_execution">>],
    case maps:keys(maps:without(Allowed, Options)) of
        [] -> convert_runner_options(maps:to_list(Options), #{});
        Unknown -> {error, {unknown_runner_options, lists:sort(Unknown)}}
    end;
runner_options_from_json(_Options) ->
    {error, runner_options_must_be_object}.

convert_runner_options([], Acc) -> {ok, Acc};
convert_runner_options([{<<"run_timeout">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0,
       Value =< ?MAX_DECLARATIVE_RUN_TIMEOUT ->
    convert_runner_options(Rest, Acc#{run_timeout => Value});
convert_runner_options([{<<"max_llm_calls">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0,
       Value =< ?MAX_DECLARATIVE_LLM_CALLS ->
    convert_runner_options(Rest, Acc#{max_llm_calls => Value});
convert_runner_options([{<<"max_tool_rounds">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0,
       Value =< ?MAX_DECLARATIVE_TOOL_ROUNDS ->
    convert_runner_options(Rest, Acc#{max_tool_rounds => Value});
convert_runner_options([{<<"service_timeout">>, Value} | Rest], Acc)
  when is_integer(Value), Value > 0,
       Value =< ?MAX_DECLARATIVE_SERVICE_TIMEOUT ->
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
               Max =< ?MAX_DECLARATIVE_TOOL_CONCURRENCY,
               is_integer(Timeout), Timeout > 0,
               Timeout =< ?MAX_DECLARATIVE_TOOL_TIMEOUT ->
            {ok, #{mode => parallel, max_concurrency => Max,
                   tool_timeout => Timeout}};
        _ -> {error, invalid_parallel_tool_policy}
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
    Normalized = normalize_key(Key),
    lists:member(
      Normalized,
      [<<"api_key">>, <<"apikey">>, <<"authorization">>,
       <<"access_token">>, <<"refresh_token">>, <<"id_token">>,
       <<"password">>, <<"client_secret">>, <<"secret">>,
       <<"credential">>, <<"credentials">>, <<"private_key">>]);
forbidden_secret_key(_Key) -> false.

contains_forbidden_transport(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          forbidden_transport_key(Key) orelse
          (not schema_value_key(Key) andalso
           contains_forbidden_transport(Value))
      end, maps:to_list(Map));
contains_forbidden_transport(List) when is_list(List) ->
    lists:any(fun contains_forbidden_transport/1, List);
contains_forbidden_transport(_Value) -> false.

forbidden_transport_key(Key) when is_binary(Key) ->
    lists:member(normalize_key(Key),
                 [<<"command">>, <<"cmd">>, <<"executable">>,
                  <<"url">>, <<"base_url">>, <<"endpoint">>,
                  <<"headers">>, <<"http_headers">>, <<"target">>]);
forbidden_transport_key(_Key) -> false.

schema_value_key(<<"input_schema">>) -> true;
schema_value_key(<<"output_schema">>) -> true;
schema_value_key(<<"response_schema">>) -> true;
schema_value_key(_) -> false.

normalize_key(Key) ->
    Lower = string:lowercase(Key),
    binary:replace(Lower, <<"-">>, <<"_">>, [global]).

valid_registry_id(Id) when is_binary(Id), byte_size(Id) > 0,
                                   byte_size(Id) =< 128 ->
    [First | Rest] = binary_to_list(Id),
    valid_registry_id_first(First) andalso
    lists:all(
      fun(C) ->
          valid_registry_id_first(C) orelse
          C =:= $. orelse C =:= $_ orelse C =:= $-
      end, Rest);
valid_registry_id(_Id) -> false.

valid_registry_id_first(C) ->
    (C >= $a andalso C =< $z) orelse
    (C >= $A andalso C =< $Z) orelse
    (C >= $0 andalso C =< $9).

valid_nonempty_binary(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0.

sanitize_reason(Reason) ->
    Redacted = adk_secret_redactor:redact(Reason),
    case adk_json:normalize(Redacted) of
        {ok, Json} -> Json;
        {error, _} -> <<"operation_failed">>
    end.

config_fingerprint(Value) ->
    Digest = crypto:hash(sha256, term_to_binary(canonical(Value),
                                                [deterministic])),
    hex(Digest).

canonical(Map) when is_map(Map) ->
    Pairs = [{canonical(Key), canonical(Value)}
             || {Key, Value} <- maps:to_list(Map)],
    {map, lists:sort(Pairs)};
canonical(List) when is_list(List) ->
    {list, [canonical(Value) || Value <- List]};
canonical(Tuple) when is_tuple(Tuple) ->
    {tuple, [canonical(Value) || Value <- tuple_to_list(Tuple)]};
canonical(Value) -> Value.

hex(Binary) ->
    iolist_to_binary([[hex_digit(Byte bsr 4), hex_digit(Byte band 16#0f)]
                      || <<Byte>> <= Binary]).

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
