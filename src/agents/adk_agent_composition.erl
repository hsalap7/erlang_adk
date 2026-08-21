%% @doc Runtime materializer for a compiled declarative Agent Config.
%%
%% The compiler persists IDs only. This module resolves those IDs against the
%% exact sealed registry snapshot named by the compiled fingerprint, spawns
%% sub-agents bottom-up, and injects only process references into the parent.
%% Credential descriptors are never returned; callers receive only the opaque
%% credential profile ID already present in the compiled public IR.
-module(adk_agent_composition).
-compile({no_auto_import, [spawn/1, spawn/2]}).

-export([resolve/1, resolve/2,
         spawn/1, spawn/2, spawn_scoped/2, spawn_scoped/3,
         root/1, runner_options/1, workflows/1, credential_profiles/1,
         stop/1]).

-define(HANDLE_TAG, '$adk_agent_composition').

-type handle() :: #{tag := ?HANDLE_TAG, root := pid(), agents := [pid()],
                    runner_options := map(), workflows := map(),
                    credential_profiles := map()}.
-export_type([handle/0]).

-spec resolve(map()) -> {ok, map()} | {error, term()}.
resolve(Compiled) ->
    case default_registry(Compiled) of
        {ok, Registry} -> resolve(Compiled, Registry);
        {error, _} = Error -> Error
    end.

-spec resolve(map(), term()) -> {ok, map()} | {error, term()}.
resolve(Compiled, Registry) when is_map(Compiled) ->
    case validate_compiled(Compiled, Registry) of
        ok -> resolve_node(Compiled, Registry, []);
        {error, _} = Error -> Error
    end;
resolve(_Compiled, _Registry) -> {error, invalid_compiled_agent_config}.

-spec spawn(map()) -> {ok, handle()} | {error, term()}.
spawn(Compiled) ->
    case default_registry(Compiled) of
        {ok, Registry} -> spawn(Compiled, Registry);
        {error, _} = Error -> Error
    end.

-spec spawn(map(), term()) -> {ok, handle()} | {error, term()}.
spawn(Compiled, Registry) ->
    case resolve(Compiled, Registry) of
        {error, _} = Error -> Error;
        {ok, Resolved} -> spawn_resolved(Resolved)
    end.

%% @doc Spawn a composition in an invocation-local namespace. This is used by
%% concurrent evaluation samples so roots and every generated sub-agent retain
%% their declarative identity without colliding in the process registry.
-spec spawn_scoped(map(), binary()) -> {ok, handle()} | {error, term()}.
spawn_scoped(Compiled, Scope) ->
    case default_registry(Compiled) of
        {ok, Registry} -> spawn_scoped(Compiled, Registry, Scope);
        {error, _} = Error -> Error
    end.

-spec spawn_scoped(map(), term(), binary()) ->
    {ok, handle()} | {error, term()}.
spawn_scoped(Compiled, Registry, Scope) ->
    case valid_scope(Scope) of
        false -> {error, invalid_agent_composition_scope};
        true ->
            case resolve(Compiled, Registry) of
                {error, _} = Error -> Error;
                {ok, Resolved} ->
                    spawn_resolved(scope_resolved(Resolved, Scope))
            end
    end.

spawn_resolved(Resolved) ->
    case spawn_node(Resolved, []) of
        {ok, RootPid, Pids, Workflows, Credentials} ->
            RootCompiled = maps:get(compiled, Resolved),
            {ok, #{tag => ?HANDLE_TAG, root => RootPid,
                   agents => Pids,
                   runner_options =>
                       maps:get(runner_options, RootCompiled, #{}),
                   workflows => Workflows,
                   credential_profiles => Credentials}};
        {error, Reason, Pids} ->
            stop_pids(Pids),
            {error, Reason}
    end.

-spec root(handle()) -> {ok, pid()} | {error, term()}.
root(#{tag := ?HANDLE_TAG, root := Root}) when is_pid(Root) -> {ok, Root};
root(_) -> {error, invalid_agent_composition}.

-spec runner_options(handle()) -> {ok, map()} | {error, term()}.
runner_options(#{tag := ?HANDLE_TAG, runner_options := Options})
  when is_map(Options) -> {ok, Options};
runner_options(_) -> {error, invalid_agent_composition}.

-spec workflows(handle()) -> {ok, map()} | {error, term()}.
workflows(#{tag := ?HANDLE_TAG, workflows := Values}) when is_map(Values) ->
    {ok, Values};
workflows(_) -> {error, invalid_agent_composition}.

-spec credential_profiles(handle()) -> {ok, map()} | {error, term()}.
credential_profiles(#{tag := ?HANDLE_TAG, credential_profiles := Values})
  when is_map(Values) -> {ok, Values};
credential_profiles(_) -> {error, invalid_agent_composition}.

-spec stop(handle()) -> ok.
stop(#{tag := ?HANDLE_TAG, agents := Pids}) when is_list(Pids) ->
    stop_pids(Pids),
    ok;
stop(_) -> ok.

scope_resolved(#{compiled := Compiled, children := Children} = Resolved,
               Scope) ->
    Name = scoped_name(maps:get(name, Compiled), Scope),
    Resolved#{compiled => Compiled#{name => Name},
              children => [scope_resolved(Child, Scope)
                           || Child <- Children]}.

valid_scope(Scope) when is_binary(Scope), byte_size(Scope) > 0,
                         byte_size(Scope) =< 64 ->
    case adk_agent_tree:validate_name(<<"scope_", Scope/binary>>) of
        {ok, _} -> true;
        _ -> false
    end;
valid_scope(_) -> false.

scoped_name(Base, Scope) ->
    Suffix = <<"_", Scope/binary>>,
    case byte_size(Base) + byte_size(Suffix) =< 256 of
        true -> <<Base/binary, Suffix/binary>>;
        false ->
            Digest0 = binary:encode_hex(crypto:hash(sha256, Base), lowercase),
            Digest = binary:part(Digest0, 0, 12),
            PrefixBytes = 256 - byte_size(Suffix) - 13,
            Prefix = binary:part(Base, 0, PrefixBytes),
            <<Prefix/binary, "_", Digest/binary, Suffix/binary>>
    end.

resolve_node(Compiled, Registry, Path) ->
    Name = maps:get(name, Compiled),
    References = maps:get(references, Compiled, #{}),
    case {resolve_runtime_policy(References, Registry),
          resolve_workflows(References, Registry),
          resolve_children(maps:get(sub_agents, References, []),
                           Registry, [Name | Path], [])} of
        {{ok, Policy}, {ok, Workflows}, {ok, Children}} ->
            Runner0 = maps:get(runner_options, Compiled, #{}),
            Runner = case Policy of
                disabled -> Runner0;
                _ -> Runner0#{runtime_policy => Policy}
            end,
            Credential = maps:get(credential_profile, References, undefined),
            {ok, #{compiled => Compiled#{runner_options => Runner},
                   children => Children, workflows => Workflows,
                   credential_profile => Credential}};
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

resolve_children([], _Registry, _Path, Acc) ->
    {ok, lists:reverse(Acc)};
resolve_children([#{name := Name, agent_template := TemplateId,
                    sub_agents := Children} | Rest], Registry, Path, Acc) ->
    case lists:member(Name, Path) of
        true -> {error, {agent_composition_cycle, Name}};
        false ->
            case adk_config_registry:lookup(
                   Registry, agent_template, TemplateId) of
                {ok, Descriptor} ->
                    case compile_template(Name, Children, Descriptor,
                                          Registry) of
                        {ok, Compiled} ->
                            case resolve_node(Compiled, Registry, Path) of
                                {ok, Resolved} ->
                                    resolve_children(
                                      Rest, Registry, Path,
                                      [Resolved | Acc]);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} -> {error, {unknown_agent_template, TemplateId}}
            end
    end;
resolve_children(_Invalid, _Registry, _Path, _Acc) ->
    {error, invalid_agent_composition_children}.

compile_template(Name, ExplicitChildren,
                 #{template := Template0} = Descriptor, Registry)
  when is_map(Template0) ->
    Dependencies = maps:get(sub_agents, Descriptor, []),
    Template1 = Template0#{<<"schema_version">> => 2,
                           <<"name">> => Name},
    Template = case maps:is_key(<<"sub_agents">>, Template1) of
        true -> Template1;
        false when ExplicitChildren =/= [] ->
            Template1#{<<"sub_agents">> => child_json(ExplicitChildren)};
        false when Dependencies =/= [] ->
            Template1#{<<"sub_agents">> => dependency_json(Dependencies)};
        false -> Template1
    end,
    adk_agent_config:compile(Template, #{registry => Registry});
compile_template(_Name, _Children, _Descriptor, _Registry) ->
    {error, invalid_agent_template_descriptor}.

child_json(Children) ->
    [#{<<"name">> => maps:get(name, Child),
       <<"agent_template">> => maps:get(agent_template, Child),
       <<"sub_agents">> => child_json(maps:get(sub_agents, Child, []))}
     || Child <- Children].

dependency_json(Dependencies) ->
    [#{<<"name">> => dependency_name(Id, Index),
       <<"agent_template">> => Id}
     || {Id, Index} <- lists:zip(Dependencies,
                                lists:seq(1, length(Dependencies)))].

dependency_name(Id, Index) ->
    Base0 = <<"sub_", (integer_to_binary(Index))/binary, "_", Id/binary>>,
    case byte_size(Base0) =< 256 of
        true -> sanitize_name(Base0);
        false -> sanitize_name(binary:part(Base0, 0, 256))
    end.

sanitize_name(Binary) ->
    << <<(sanitize_char(Char))>> || <<Char>> <= Binary >>.

sanitize_char(Char) when Char >= $a, Char =< $z -> Char;
sanitize_char(Char) when Char >= $A, Char =< $Z -> Char;
sanitize_char(Char) when Char >= $0, Char =< $9 -> Char;
sanitize_char($_) -> $_;
sanitize_char(_) -> $_.

resolve_runtime_policy(References, Registry) ->
    case maps:find(runtime_policy, References) of
        error -> {ok, disabled};
        {ok, Id} ->
            case adk_config_registry:lookup(Registry, runtime_policy, Id) of
                {ok, #{policy := Policy}} -> {ok, Policy};
                _ -> {error, {unknown_runtime_policy, Id}}
            end
    end.

resolve_workflows(References, Registry) ->
    resolve_workflows(maps:get(workflows, References, []), Registry, #{}).

resolve_workflows([], _Registry, Acc) -> {ok, Acc};
resolve_workflows([#{name := Name, workflow := Id} | Rest], Registry, Acc) ->
    case adk_config_registry:lookup(Registry, workflow, Id) of
        {ok, #{workflow := Workflow}} ->
            resolve_workflows(Rest, Registry, Acc#{Name => Workflow});
        _ -> {error, {unknown_workflow, Id}}
    end;
resolve_workflows(_Invalid, _Registry, _Acc) ->
    {error, invalid_agent_composition_workflows}.

spawn_node(#{compiled := Compiled, children := Children,
             workflows := OwnWorkflows,
             credential_profile := Credential}, Existing) ->
    case spawn_children(Children, Existing, #{}, #{}, #{}) of
        {error, Reason, Pids} -> {error, Reason, Pids};
        {ok, ChildSpecs, Pids0, Workflows0, Credentials0} ->
            Config0 = maps:get(config, Compiled),
            Config = case map_size(ChildSpecs) of
                0 -> Config0;
                _ -> Config0#{sub_agents => ChildSpecs}
            end,
            Name = maps:get(name, Compiled),
            case erlang_adk:spawn_agent(
                   Name, Config, maps:get(tools, Compiled)) of
                {ok, Pid} ->
                    Workflows = Workflows0#{Name => OwnWorkflows},
                    Credentials = case Credential of
                        undefined -> Credentials0;
                        _ -> Credentials0#{Name => Credential}
                    end,
                    {ok, Pid, [Pid | Pids0], Workflows, Credentials};
                {error, Reason} ->
                    {error, {agent_start_failed, safe_reason(Reason)}, Pids0}
            end
    end.

spawn_children([], Pids, Specs, Workflows, Credentials) ->
    {ok, Specs, Pids, Workflows, Credentials};
spawn_children([Child | Rest], Pids0, Specs0, Workflows0, Credentials0) ->
    case spawn_node(Child, Pids0) of
        {ok, Pid, Pids1, ChildWorkflows, ChildCredentials} ->
            ChildCompiled = maps:get(compiled, Child),
            Name = maps:get(name, ChildCompiled),
            Description = maps:get(description,
                                   maps:get(config, ChildCompiled),
                                   <<"Delegate to this specialist agent.">>),
            Spec = #{pid => Pid, description => Description},
            spawn_children(
              Rest, Pids1, Specs0#{Name => Spec},
              maps:merge(Workflows0, ChildWorkflows),
              maps:merge(Credentials0, ChildCredentials));
        {error, Reason, Pids1} -> {error, Reason, Pids1}
    end.

validate_compiled(#{schema_version := 1}, _Registry) -> ok;
validate_compiled(#{schema_version := 2} = Compiled, Registry) ->
    ExpectedGeneration = maps:get(registry_generation, Compiled, undefined),
    ExpectedInstance = maps:get(registry_instance_id, Compiled, undefined),
    ExpectedRevision = maps:get(
                         registry_snapshot_revision_id, Compiled, undefined),
    case {adk_config_registry:generation(Registry),
          adk_config_registry:instance_id(Registry),
          adk_config_registry:snapshot_revision_id(Registry),
          ExpectedGeneration, ExpectedInstance, ExpectedRevision} of
        {{ok, Generation}, {ok, Instance}, {ok, Revision},
         Generation, Instance, Revision} -> ok;
        _ -> {error, agent_config_registry_provenance_mismatch}
    end;
validate_compiled(_Compiled, _Registry) ->
    {error, invalid_compiled_agent_config}.

default_registry(#{schema_version := 1}) ->
    %% Legacy configs contain no registry-backed composition values.
    adk_config_registry:new();
default_registry(Compiled) ->
    case application:get_env(erlang_adk, agent_config_registry) of
        {ok, Registry} when is_tuple(Registry) ->
            case validate_compiled(Compiled, Registry) of
                ok -> {ok, Registry};
                {error, _} = Error -> Error
            end;
        {ok, Definitions} when is_map(Definitions) ->
            case adk_config_registry:new(Definitions) of
                {ok, Registry} ->
                    case validate_compiled(Compiled, Registry) of
                        ok -> {ok, Registry};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, agent_config_registry_unavailable}
    end.

stop_pids(Pids) ->
    lists:foreach(
      fun(Pid) when is_pid(Pid) -> _ = catch erlang_adk:stop_agent(Pid);
         (_) -> ok
      end, Pids).

safe_reason(Reason) ->
    try adk_secret_redactor:redact(Reason) of
        Safe -> Safe
    catch
        _:_ -> agent_start_failed
    end.
