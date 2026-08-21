%% @doc Policy-enforcing bridge from connector adapters to `adk_toolset'.
%%
%% Connector packages implement the normal `schemas/1' and `resolved_call/4'
%% callbacks. This bridge snapshots their schemas only after a complete
%% manifest has been validated against the advertised catalog, and applies
%% manifest execution policy to every resolved call.
-module(adk_connector_toolset).

-export([new/3, schemas/1, resolved_call/4]).

-spec new(module(), term(), map()) ->
    {ok, adk_toolset:descriptor()} | {error, term()}.
new(Adapter, Handle, Manifest0) when is_atom(Adapter) ->
    case ensure_adapter(Adapter) of
        ok ->
            case adk_connector_manifest:validate(Manifest0) of
                {ok, Manifest} -> build(Adapter, Handle, Manifest);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
new(_Adapter, _Handle, _Manifest) ->
    {error, invalid_connector_adapter}.

build(Adapter, Handle, Manifest) ->
    case safe_schemas(Adapter, Handle) of
        {ok, Schemas} ->
            case adk_connector_manifest:validate_schemas(Manifest, Schemas) of
                ok ->
                    State = #{adapter => {Adapter, Handle},
                              manifest => Manifest,
                              schemas => Schemas},
                    adk_toolset:new(?MODULE, State);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

-spec schemas(map()) -> [map()].
schemas(#{schemas := Schemas}) when is_list(Schemas) -> Schemas;
schemas(_State) -> erlang:error(invalid_connector_state).

-spec resolved_call(map(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
resolved_call(#{adapter := {Adapter, Handle}, manifest := Manifest},
              Name, Args, Context)
  when is_atom(Adapter), is_binary(Name), is_map(Args), is_map(Context) ->
    case adk_connector_manifest:tool(Manifest, Name) of
        {ok, Policy} ->
            case safe_resolve(Adapter, Handle, Name, Args, Context) of
                {ok, Call} ->
                    adk_connector_manifest:apply_execution_policy(
                      Call, Policy);
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, unknown_tool}
    end;
resolved_call(_State, _Name, _Args, _Context) ->
    {error, invalid_connector_tool_call}.

ensure_adapter(Adapter) ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            case erlang:function_exported(Adapter, schemas, 1) andalso
                 erlang:function_exported(Adapter, resolved_call, 4) of
                true -> ok;
                false -> {error, {invalid_connector_adapter, Adapter}}
            end;
        _ -> {error, {connector_adapter_unavailable, Adapter}}
    end.

safe_schemas(Adapter, Handle) ->
    try Adapter:schemas(Handle) of
        Schemas when is_list(Schemas) -> {ok, Schemas};
        _ -> {error, invalid_connector_schema_catalog}
    catch
        _:_ -> {error, connector_adapter_unavailable}
    end.

safe_resolve(Adapter, Handle, Name, Args, Context) ->
    try Adapter:resolved_call(Handle, Name, Args, Context) of
        {ok, Call} when is_map(Call) -> {ok, Call};
        {error, _} = Error -> Error;
        _ -> {error, invalid_connector_resolved_call}
    catch
        _:_ -> {error, connector_adapter_unavailable}
    end.
