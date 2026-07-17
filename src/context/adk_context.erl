%% @doc Public, least-authority helpers for invocation and tool contexts.
-module(adk_context).

-export([capabilities/0, identity/1, state/1,
         save_artifact/4, load_artifact/3, attach_artifact/3,
         list_artifacts/2, list_artifact_versions/3, delete_artifact/3,
         search_memory/3, add_memory/3, delete_memory/2,
         project_tool/3, take_effects/2,
         prepare_effects/2, commit_effects/2, abort_effects/2,
         resolve_attachment/4]).

-define(DEFAULT_TIMEOUT, 5000).

-spec capabilities() -> [atom()].
capabilities() ->
    [identity, state_read,
     artifact_put, artifact_get, artifact_list, artifact_list_versions,
     artifact_delete, artifact_attach,
     memory_search, memory_add, memory_delete].

-spec identity(map()) -> {ok, map()} | {error, term()}.
identity(Context) -> invoke(Context, identity, undefined).

-spec state(map()) -> {ok, map()} | {error, term()}.
state(Context) -> invoke(Context, state_read, undefined).

-spec save_artifact(map(), binary(), binary(), map()) -> term().
save_artifact(Context, Name, Data, Options) ->
    invoke(Context, artifact_put,
           #{name => Name, data => Data, options => Options}).

-spec load_artifact(map(), binary(), latest | pos_integer()) -> term().
load_artifact(Context, Name, Selector) ->
    invoke(Context, artifact_get, #{name => Name, selector => Selector}).

-spec attach_artifact(map(), binary(), latest | pos_integer()) -> term().
attach_artifact(Context, Name, Selector) ->
    invoke(Context, artifact_attach,
           #{name => Name, selector => Selector}).

-spec list_artifacts(map(), map()) -> term().
list_artifacts(Context, Options) ->
    invoke(Context, artifact_list, Options).

-spec list_artifact_versions(map(), binary(), map()) -> term().
list_artifact_versions(Context, Name, Options) ->
    invoke(Context, artifact_list_versions,
           Options#{name => Name}).

-spec delete_artifact(map(), binary(), all | latest | pos_integer()) -> term().
delete_artifact(Context, Name, Selector) ->
    invoke(Context, artifact_delete,
           #{name => Name, selector => Selector}).

-spec search_memory(map(), binary(), map()) -> term().
search_memory(Context, Query, Options) ->
    invoke(Context, memory_search,
           #{query => Query, options => Options}).

-spec add_memory(map(), map(), map()) -> term().
add_memory(Context, Entry, Options) ->
    invoke(Context, memory_add,
           #{entry => Entry, options => Options}).

-spec delete_memory(map(), binary()) -> term().
delete_memory(Context, Id) ->
    invoke(Context, memory_delete, #{id => Id}).

%% @doc Project a raw internal context for a local tool module. Modules which
%% do not declare context_capabilities/0 remain on the explicit legacy path.
-spec project_tool(module(), map(), map()) -> {ok, map()} | {error, term()}.
project_tool(Module, Context, Runtime) when is_atom(Module), is_map(Context),
                                           is_map(Runtime) ->
    case declared_capabilities(Module) of
        legacy -> {ok, Context};
        {error, _} = Error -> Error;
        {ok, Declared} ->
            case maps:find(context_capability, Runtime) of
                {ok, RootCapability} ->
                    EffectId = maps:get('$adk_effect_id', Context,
                                        maps:get(call_id, Context,
                                                 undefined)),
                    Timeout = maps:get(service_timeout, Runtime,
                                       ?DEFAULT_TIMEOUT),
                    case adk_context_capability:delegate(
                           RootCapability, Declared, EffectId, Timeout) of
                        {ok, Capability} ->
                            Public = maps:with(
                                       [app_name, user_id, session_id,
                                        invocation_id, call_id,
                                        '$adk_agent_path',
                                        '$adk_effect_id'], Context),
                            {ok, Public#{context_capability => Capability,
                                        context_capabilities => Declared,
                                        %% The service coordinator owns the
                                        %% inner deadline and has a small
                                        %% cleanup guard. Do not let the outer
                                        %% capability call time out first.
                                        context_timeout => Timeout + 250}};
                        {error, _} = Error -> Error
                    end;
                error ->
                    {error, context_capability_unavailable}
            end
    end;
project_tool(_Module, _Context, _Runtime) ->
    {error, invalid_tool_context_projection}.

-spec take_effects(map(), term()) -> {ok, [map()]} | {error, term()}.
take_effects(Runtime, CallId) when is_map(Runtime) ->
    case maps:find(context_capability, Runtime) of
        {ok, RootCapability} ->
            adk_context_capability:take_effects(RootCapability, CallId);
        error -> {ok, []}
    end;
take_effects(_, _) -> {error, invalid_runtime_context}.

-spec prepare_effects(map(), term()) ->
    {ok, none | reference(), [map()]} | {error, term()}.
prepare_effects(Runtime, CallId) when is_map(Runtime) ->
    case maps:find(context_capability, Runtime) of
        {ok, RootCapability} ->
            adk_context_capability:prepare_effects(
              RootCapability, CallId);
        error -> {ok, none, []}
    end;
prepare_effects(_, _) -> {error, invalid_runtime_context}.

-spec commit_effects(map(), none | reference()) -> ok | {error, term()}.
commit_effects(_Runtime, none) -> ok;
commit_effects(Runtime, Receipt) when is_map(Runtime) ->
    case maps:find(context_capability, Runtime) of
        {ok, RootCapability} ->
            adk_context_capability:commit_effects(
              RootCapability, Receipt);
        error -> {error, context_capability_unavailable}
    end;
commit_effects(_, _) -> {error, invalid_runtime_context}.

-spec abort_effects(map(), none | reference()) -> ok | {error, term()}.
abort_effects(_Runtime, none) -> ok;
abort_effects(Runtime, Receipt) when is_map(Runtime) ->
    case maps:find(context_capability, Runtime) of
        {ok, RootCapability} ->
            adk_context_capability:abort_effects(
              RootCapability, Receipt);
        error -> {error, context_capability_unavailable}
    end;
abort_effects(_, _) -> {error, invalid_runtime_context}.

%% @private Resolve invocation-private attachment bytes for the Runner. The
%% capability owner check prevents tools from turning a public attachment
%% reference into byte access after their delegated token is revoked.
-spec resolve_attachment(map(), binary(), pos_integer(), pos_integer()) ->
    {ok, map()} | {error, term()}.
resolve_attachment(Runtime, Name, Version, Timeout)
  when is_map(Runtime), is_binary(Name),
       is_integer(Version), Version > 0,
       is_integer(Timeout), Timeout > 0 ->
    case maps:find(context_capability, Runtime) of
        {ok, RootCapability} ->
            adk_context_capability:resolve_attachment(
              RootCapability, Name, Version, Timeout);
        error -> {error, context_capability_unavailable}
    end;
resolve_attachment(_, _, _, _) ->
    {error, invalid_attachment_resolution}.

invoke(Context, Operation, Request) when is_map(Context) ->
    case maps:find(context_capability, Context) of
        {ok, Capability} ->
            Timeout = maps:get(context_timeout, Context, ?DEFAULT_TIMEOUT),
            adk_context_capability:call(
              Capability, Operation, Request, Timeout);
        error -> {error, context_capability_unavailable}
    end;
invoke(_, _, _) -> {error, invalid_context}.

declared_capabilities(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(
                   Module, context_capabilities, 0) of
                false -> legacy;
                true -> normalize_declared(Module:context_capabilities())
            end;
        _ -> {error, {tool_module_unavailable, Module}}
    end.

normalize_declared(Declared) when is_list(Declared) ->
    Allowed = capabilities(),
    case lists:all(fun(Value) -> lists:member(Value, Allowed) end,
                   Declared) of
        true -> {ok, lists:usort([identity | Declared])};
        false -> {error, invalid_tool_context_capabilities}
    end;
normalize_declared(_) -> {error, invalid_tool_context_capabilities}.
