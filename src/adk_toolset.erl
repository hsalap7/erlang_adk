%% @doc Generic immutable/dynamic toolset descriptor.
%%
%% Toolsets let one provider-backed object advertise multiple model-visible
%% schemas while resolving execution out of band. The descriptor contains no
%% model arguments and is never sent to an LLM. OpenAPI and MCP implement the
%% same two callbacks without being special-cased by adk_agent or Runner.
-module(adk_toolset).

-export([new/2, is_descriptor/1, schemas/1, expand_tools/1,
         resolve/4]).

-type descriptor() :: {adk_toolset, module(), term()}.
-export_type([descriptor/0]).

-spec new(module(), term()) -> {ok, descriptor()} | {error, term()}.
new(Module, Handle) when is_atom(Module), Module =/= undefined ->
    Descriptor = {adk_toolset, Module, Handle},
    case schemas(Descriptor) of
        {ok, _Schemas} -> {ok, Descriptor};
        {error, _} = Error -> Error
    end;
new(_Module, _Handle) ->
    {error, invalid_toolset}.

-spec is_descriptor(term()) -> boolean().
is_descriptor({adk_toolset, Module, _Handle}) when is_atom(Module) -> true;
is_descriptor(_) -> false.

-spec schemas(descriptor()) -> {ok, [map()]} | {error, term()}.
schemas({adk_toolset, Module, Handle}) when is_atom(Module) ->
    case load_callbacks(Module) of
        ok ->
            try Module:schemas(Handle) of
                Schemas when is_list(Schemas) -> validate_schemas(Schemas);
                _ -> {error, invalid_toolset_schemas}
            catch
                _:_ -> {error, toolset_unavailable}
            end;
        {error, _} = Error -> Error
    end;
schemas(_Descriptor) ->
    {error, invalid_toolset}.

-spec expand_tools([module() | descriptor()]) ->
    {ok, [module() | map()]} | {error, term()}.
expand_tools(Tools) when is_list(Tools) ->
    expand_tools(Tools, []);
expand_tools(_Tools) ->
    {error, invalid_tools}.

expand_tools([], Acc) -> {ok, lists:reverse(Acc)};
expand_tools([Module | Rest], Acc) when is_atom(Module) ->
    case module_schema(Module) of
        {ok, _Schema} -> expand_tools(Rest, [Module | Acc]);
        {error, _} = Error -> Error
    end;
expand_tools([Descriptor | Rest], Acc) ->
    case schemas(Descriptor) of
        {ok, Schemas} ->
            expand_tools(Rest, lists:reverse(Schemas) ++ Acc);
        {error, _} = Error -> Error
    end;
expand_tools(_Improper, _Acc) ->
    {error, invalid_tools}.

%% @doc Resolve a model call to either a module or a bounded executor call.
-spec resolve([module() | descriptor()], binary(), map(), map()) ->
    {ok, {module, module()} | {resolved, adk_tool_executor:resolved_call()}} |
    {error, not_found | term()}.
resolve(Tools, Name, Args, Context)
  when is_list(Tools), is_binary(Name), is_map(Args), is_map(Context) ->
    resolve_tools(Tools, Name, Args, Context);
resolve(_Tools, _Name, _Args, _Context) ->
    {error, invalid_tool_resolution}.

resolve_tools([], _Name, _Args, _Context) -> {error, not_found};
resolve_tools([Module | Rest], Name, Args, Context) when is_atom(Module) ->
    case module_schema(Module) of
        {ok, Schema} ->
            case maps:get(<<"name">>, Schema) =:= Name of
                true -> {ok, {module, Module}};
                false -> resolve_tools(Rest, Name, Args, Context)
            end;
        {error, _} = Error -> Error
    end;
resolve_tools([{adk_toolset, Module, Handle} | Rest], Name, Args, Context) ->
    case safe_resolved_call(Module, Handle, Name, Args, Context) of
        {ok, Resolved} -> {ok, {resolved, Resolved}};
        {error, unknown_tool} -> resolve_tools(Rest, Name, Args, Context);
        {error, not_found} -> resolve_tools(Rest, Name, Args, Context);
        {error, _} = Error -> Error
    end;
resolve_tools([_Invalid | _Rest], _Name, _Args, _Context) ->
    {error, invalid_toolset}.

safe_resolved_call(Module, Handle, Name, Args, Context) ->
    case load_callbacks(Module) of
        ok ->
            try Module:resolved_call(Handle, Name, Args, Context) of
                {ok, Call} when is_map(Call) ->
                    validate_resolved_call(Call, Name, Args);
                {error, _} = Error -> Error;
                _ -> {error, invalid_resolved_tool_call}
            catch
                _:_ -> {error, toolset_unavailable}
            end;
        {error, _} = Error -> Error
    end.

validate_resolved_call(Call, Name, Args) ->
    case maps:get(name, Call, undefined) =:= Name andalso
         maps:get(args, Call, undefined) =:= Args andalso
         valid_executor(Call) andalso valid_optional_boolean(
                                      parallel_safe, Call) andalso
         valid_optional_boolean(pause_capable, Call) of
        true ->
            Allowed = [name, args, module, execute, parallel_safe,
                       pause_capable, timeout, deadline],
            {ok, maps:with(Allowed, Call)};
        false -> {error, invalid_resolved_tool_call}
    end.

valid_executor(Call) ->
    case {maps:find(execute, Call), maps:find(module, Call)} of
        {{ok, Fun}, error} -> is_function(Fun, 0);
        {error, {ok, Module}} -> is_atom(Module) andalso Module =/= undefined;
        _ -> false
    end.

valid_optional_boolean(Key, Map) ->
    case maps:find(Key, Map) of
        error -> true;
        {ok, Value} -> is_boolean(Value)
    end.

module_schema(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, schema, 0) andalso
                 erlang:function_exported(Module, execute, 2) of
                false -> {error, {invalid_tool_module, Module}};
                true ->
                    try Module:schema() of
                        Schema when is_map(Schema) -> validate_schema(Schema);
                        _ -> {error, {invalid_tool_schema, Module}}
                    catch
                        _:_ -> {error, {tool_module_unavailable, Module}}
                    end
            end;
        _ -> {error, {tool_module_unavailable, Module}}
    end.

load_callbacks(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, schemas, 1) andalso
                 erlang:function_exported(Module, resolved_call, 4) of
                true -> ok;
                false -> {error, {invalid_toolset_module, Module}}
            end;
        _ -> {error, {toolset_module_unavailable, Module}}
    end.

validate_schemas(Schemas) ->
    case validate_schema_list(Schemas, [], []) of
        {ok, Names, Validated} ->
            case length(Names) =:= length(lists:usort(Names)) of
                true -> {ok, lists:reverse(Validated)};
                false -> {error, duplicate_tool_name}
            end;
        {error, _} = Error -> Error
    end.

validate_schema_list([], Names, Acc) -> {ok, Names, Acc};
validate_schema_list([Schema | Rest], Names, Acc) when is_map(Schema) ->
    case validate_schema(Schema) of
        {ok, Validated} ->
            Name = maps:get(<<"name">>, Validated),
            validate_schema_list(Rest, [Name | Names], [Validated | Acc]);
        {error, _} = Error -> Error
    end;
validate_schema_list(_Invalid, _Names, _Acc) ->
    {error, invalid_toolset_schemas}.

validate_schema(#{<<"name">> := Name} = Schema)
  when is_binary(Name), byte_size(Name) > 0 ->
    {ok, Schema};
validate_schema(_Schema) -> {error, invalid_tool_schema}.
