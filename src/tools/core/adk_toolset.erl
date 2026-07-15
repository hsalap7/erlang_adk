%% @doc Generic immutable/dynamic toolset descriptor.
%%
%% Toolsets let one provider-backed object advertise multiple model-visible
%% schemas while resolving execution out of band. The descriptor contains no
%% model arguments and is never sent to an LLM. OpenAPI and MCP implement the
%% same two callbacks without being special-cased by adk_agent or Runner.
%% A descriptor owns an immutable, compiled schema snapshot; `refresh/1'
%% deliberately replaces that snapshot for a mutable backend. Plain module
%% tools are immutable for the lifetime of their loaded BEAM code version.
-module(adk_toolset).

-export([new/2, refresh/1, is_descriptor/1, schemas/1, expand_tools/1,
         preflight/3, materialize/4, resolve/4,
         validate_arguments/2, invalid_arguments_response/1]).

-type descriptor() :: {adk_toolset, module(), term()}.
-export_type([descriptor/0]).

-define(CATALOG_TAG, '$adk_toolset_catalog').
-define(CATALOG_VERSION, 1).
-define(MAX_CONFIRMATION_HINT_BYTES, 4096).

-spec new(module(), term()) -> {ok, descriptor()} | {error, term()}.
new(Module, Handle) when is_atom(Module), Module =/= undefined ->
    case load_toolset_catalog(Module, Handle) of
        {ok, Catalog} ->
            {ok, {adk_toolset, Module,
                  {?CATALOG_TAG, ?CATALOG_VERSION, Handle, Catalog}}};
        {error, _} = Error -> Error
    end;
new(_Module, _Handle) ->
    {error, invalid_toolset}.

%% @doc Re-read and compile the advertised schemas of a descriptor.
%%
%% Descriptors created by `new/2' are immutable catalog snapshots. Dynamic
%% backends remain live when a call is resolved, while a deliberate refresh
%% creates a new snapshot if the set of advertised tools has changed.
-spec refresh(descriptor()) -> {ok, descriptor()} | {error, term()}.
refresh({adk_toolset, Module,
         {?CATALOG_TAG, ?CATALOG_VERSION, Handle, _Catalog}})
  when is_atom(Module) ->
    new(Module, Handle);
refresh({adk_toolset, Module, Handle}) when is_atom(Module) ->
    new(Module, Handle);
refresh(_Descriptor) ->
    {error, invalid_toolset}.

-spec is_descriptor(term()) -> boolean().
is_descriptor({adk_toolset, Module, _Handle}) when is_atom(Module) -> true;
is_descriptor(_) -> false.

-spec schemas(descriptor()) -> {ok, [map()]} | {error, term()}.
schemas({adk_toolset, _Module,
         {?CATALOG_TAG, ?CATALOG_VERSION, _Handle,
          #{schemas := Schemas, index := Index}}})
  when is_list(Schemas), is_map(Index) ->
    {ok, Schemas};
schemas({adk_toolset, Module, Handle}) when is_atom(Module) ->
    case load_toolset_catalog(Module, Handle) of
        {ok, Catalog} -> {ok, maps:get(schemas, Catalog)};
        {error, _} = Error -> Error
    end;
schemas(_Descriptor) ->
    {error, invalid_toolset}.

-spec expand_tools([module() | descriptor()]) ->
    {ok, [map()]} | {error, term()}.
expand_tools(Tools) when is_list(Tools) ->
    expand_tools(Tools, [], #{}, 1);
expand_tools(_Tools) ->
    {error, invalid_tools}.

expand_tools([], Acc, _Names, _EntryIndex) ->
    {ok, lists:reverse(Acc)};
expand_tools([Module | Rest], Acc, Names, EntryIndex)
  when is_atom(Module) ->
    case module_catalog_entry(Module) of
        {ok, Entry} ->
            Schema = maps:get(schema, Entry),
            Name = maps:get(<<"name">>, Schema),
            Source = {module, EntryIndex, Module},
            case add_tool_name(Name, Source, Names) of
                {ok, Names1} ->
                    expand_tools(
                      Rest, [Schema | Acc], Names1, EntryIndex + 1);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
expand_tools([Descriptor | Rest], Acc, Names, EntryIndex) ->
    case schemas(Descriptor) of
        {ok, Schemas} ->
            Source = descriptor_source(Descriptor, EntryIndex),
            case add_tool_schemas(Schemas, Source, Names, 1) of
                {ok, Names1} ->
                    expand_tools(
                      Rest, lists:reverse(Schemas) ++ Acc, Names1,
                      EntryIndex + 1);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
expand_tools(_Improper, _Acc, _Names, _EntryIndex) ->
    {error, invalid_tools}.

descriptor_source({adk_toolset, Module, _Handle}, EntryIndex) ->
    {toolset, EntryIndex, Module}.

add_tool_schemas([], _Source, Names, _SchemaIndex) -> {ok, Names};
add_tool_schemas([Schema | Rest], Source, Names0, SchemaIndex) ->
    Name = maps:get(<<"name">>, Schema),
    SchemaSource = erlang:append_element(Source, SchemaIndex),
    case add_tool_name(Name, SchemaSource, Names0) of
        {ok, Names1} ->
            add_tool_schemas(
              Rest, Source, Names1, SchemaIndex + 1);
        {error, _} = Error -> Error
    end.

add_tool_name(Name, Source, Names) ->
    case maps:find(Name, Names) of
        {ok, PreviousSource} ->
            {error, {duplicate_tool_name, Name,
                     PreviousSource, Source}};
        error -> {ok, Names#{Name => Source}}
    end.

%% @doc Resolve a model call to either a module or a bounded executor call.
-spec resolve([module() | descriptor()], binary(), map(), map()) ->
    {ok, {module, module()} | {resolved, adk_tool_executor:resolved_call()}} |
    {error, not_found | term()}.
resolve(Tools, Name, Args, Context)
  when is_list(Tools), is_binary(Name), is_map(Args), is_map(Context) ->
    resolve_tools(Tools, Name, Args, Context);
resolve(_Tools, _Name, _Args, _Context) ->
    {error, invalid_tool_resolution}.

%% @doc Locate a catalog entry and validate arguments without calling a live
%% dynamic resolver. Runner uses this boundary to enforce runtime policy before
%% resolved_call/4 can consult credentials, transports, or mutable backends.
-spec preflight([module() | descriptor()], binary(), map()) ->
    {ok, term()} | {error, not_found | term()}.
preflight(Tools, Name, Args)
  when is_list(Tools), is_binary(Name), is_map(Args) ->
    preflight_tools(Tools, Name, Args);
preflight(_Tools, _Name, _Args) ->
    {error, invalid_tool_resolution}.

preflight_tools([], _Name, _Args) -> {error, not_found};
preflight_tools([Module | Rest], Name, Args) when is_atom(Module) ->
    case module_catalog_entry(Module) of
        {ok, Entry} ->
            Schema = maps:get(schema, Entry),
            case maps:get(<<"name">>, Schema) =:= Name of
                true ->
                    case validate_catalog_arguments(Entry, Args) of
                        {ok, _CanonicalArgs} ->
                            {ok, {module_target, Module}};
                        {error, _} = Error -> Error
                    end;
                false ->
                    preflight_tools(Rest, Name, Args)
            end;
        {error, _} = Error -> Error
    end;
preflight_tools([{adk_toolset, Module,
                  {?CATALOG_TAG, ?CATALOG_VERSION, Handle, Catalog}}
                 | Rest], Name, Args) ->
    preflight_toolset_catalog(
      Module, Handle, Catalog, Rest, Name, Args);
preflight_tools([{adk_toolset, Module, Handle} | Rest], Name, Args) ->
    case load_toolset_catalog(Module, Handle) of
        {ok, Catalog} ->
            preflight_toolset_catalog(
              Module, Handle, Catalog, Rest, Name, Args);
        {error, _} = Error -> Error
    end;
preflight_tools([_Invalid | _Rest], _Name, _Args) ->
    {error, invalid_toolset}.

preflight_toolset_catalog(Module, Handle, #{index := Index}, Rest,
                          Name, Args) when is_map(Index) ->
    case maps:find(Name, Index) of
        error -> preflight_tools(Rest, Name, Args);
        {ok, Entry} ->
            case validate_catalog_arguments(Entry, Args) of
                {ok, _CanonicalArgs} ->
                    {ok, {toolset_target, Module, Handle}};
                {error, _} = Error -> Error
            end
    end;
preflight_toolset_catalog(_Module, _Handle, _Catalog, _Rest,
                          _Name, _Args) ->
    {error, invalid_toolset}.

%% @doc Materialize a preflighted target after the caller's policy gate.
-spec materialize(term(), binary(), map(), map()) ->
    {ok, {module, module()} | {resolved, adk_tool_executor:resolved_call()}}
    | {error, term()}.
materialize({module_target, Module}, _Name, _Args, _Context)
  when is_atom(Module) ->
    {ok, {module, Module}};
materialize({toolset_target, Module, Handle}, Name, Args, Context)
  when is_atom(Module), is_binary(Name), is_map(Args), is_map(Context) ->
    case safe_resolved_call(Module, Handle, Name, Args, Context) of
        {ok, Resolved} -> {ok, {resolved, Resolved}};
        {error, unknown_tool} -> {error, tool_catalog_changed};
        {error, not_found} -> {error, tool_catalog_changed};
        {error, _} = Error -> Error
    end;
materialize(_Target, _Name, _Args, _Context) ->
    {error, invalid_tool_resolution}.

resolve_tools([], _Name, _Args, _Context) -> {error, not_found};
resolve_tools([Module | Rest], Name, Args, Context) when is_atom(Module) ->
    case module_catalog_entry(Module) of
        {ok, Entry} ->
            Schema = maps:get(schema, Entry),
            case maps:get(<<"name">>, Schema) =:= Name of
                true ->
                    case validate_catalog_arguments(Entry, Args) of
                        {ok, _CanonicalArgs} -> {ok, {module, Module}};
                        {error, _} = Error -> Error
                    end;
                false -> resolve_tools(Rest, Name, Args, Context)
            end;
        {error, _} = Error -> Error
    end;
resolve_tools([{adk_toolset, Module,
                {?CATALOG_TAG, ?CATALOG_VERSION, Handle, Catalog}}
               | Rest], Name, Args, Context) ->
    resolve_toolset_catalog(
      Module, Handle, Catalog, Rest, Name, Args, Context);
resolve_tools([{adk_toolset, Module, Handle} | Rest], Name, Args, Context) ->
    case load_toolset_catalog(Module, Handle) of
        {ok, Catalog} ->
            resolve_toolset_catalog(
              Module, Handle, Catalog, Rest, Name, Args, Context);
        {error, _} = Error -> Error
    end;
resolve_tools([_Invalid | _Rest], _Name, _Args, _Context) ->
    {error, invalid_toolset}.

resolve_toolset_catalog(Module, Handle, Catalog, Rest,
                        Name, Args, Context) ->
    case Catalog of
        #{index := Index} when is_map(Index) ->
            resolve_toolset_index(
              Module, Handle, Index, Rest, Name, Args, Context);
        _ -> {error, invalid_toolset}
    end.

resolve_toolset_index(Module, Handle, Index, Rest,
                      Name, Args, Context) ->
    case maps:find(Name, Index) of
        error -> resolve_tools(Rest, Name, Args, Context);
        {ok, Entry} ->
            case validate_catalog_arguments(Entry, Args) of
                {ok, _CanonicalArgs} ->
                    case safe_resolved_call(
                           Module, Handle, Name, Args, Context) of
                        {ok, Resolved} -> {ok, {resolved, Resolved}};
                        {error, unknown_tool} ->
                            {error, tool_catalog_changed};
                        {error, not_found} ->
                            {error, tool_catalog_changed};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

validate_catalog_arguments(#{parameters := Parameters}, Args)
  when is_map(Args) ->
    normalize_argument_result(
      adk_json_schema:validate_compiled(Parameters, Args));
validate_catalog_arguments(_Entry, _Args) ->
    {error, {invalid_tool_arguments, expected_object}}.

%% @doc Validate model-generated arguments against one already checked tool
%% schema. Validation errors contain only structural paths and constraints;
%% rejected argument values are never copied into the reason.
-spec validate_arguments(map(), map()) ->
    {ok, map()} | {error, {invalid_tool_arguments, term()}}.
validate_arguments(Schema, Args) when is_map(Schema), is_map(Args) ->
    case maps:find(<<"parameters">>, Schema) of
        {ok, Parameters} ->
            case adk_json_schema:compile(
                   normalize_schema_types(Parameters)) of
                {ok, Compiled} ->
                    normalize_argument_result(
                      adk_json_schema:validate_compiled(Compiled, Args));
                {error, Reason} ->
                    {error, {invalid_tool_arguments, Reason}}
            end;
        error ->
            {error, {invalid_tool_arguments, missing_parameter_schema}}
    end;
validate_arguments(_Schema, _Args) ->
    {error, {invalid_tool_arguments, expected_object}}.

normalize_argument_result({ok, CanonicalArgs}) when is_map(CanonicalArgs) ->
    {ok, CanonicalArgs};
normalize_argument_result({ok, _NonObject}) ->
    {error, {invalid_tool_arguments, expected_object}};
normalize_argument_result({error, Reason}) ->
    {error, {invalid_tool_arguments, Reason}}.

%% @doc Produce a JSON-safe correction response for a rejected model call.
%% Only schema structure is included; model-provided values are deliberately
%% excluded so validation failures cannot reflect secrets into history.
-spec invalid_arguments_response(term()) -> map().
invalid_arguments_response({invalid_tool_arguments, Reason}) ->
    #{<<"success">> => false,
      <<"error">> =>
          #{<<"type">> => <<"invalid_tool_arguments">>,
            <<"validation">> => validation_detail(Reason)}};
invalid_arguments_response(_Reason) ->
    #{<<"success">> => false,
      <<"error">> => #{<<"type">> => <<"invalid_tool_arguments">>}}.

validation_detail({schema_validation_failed, Path, Constraint})
  when is_list(Path) ->
    #{<<"kind">> => <<"schema_validation_failed">>,
      <<"path">> => structural_path(Path),
      <<"constraint">> => constraint_detail(Constraint)};
validation_detail({invalid_json_value, Reason}) ->
    #{<<"kind">> => <<"invalid_json_value">>,
      <<"constraint">> => constraint_detail(Reason)};
validation_detail(expected_object) ->
    #{<<"kind">> => <<"expected_object">>};
validation_detail(missing_parameter_schema) ->
    #{<<"kind">> => <<"missing_parameter_schema">>};
validation_detail(_Reason) ->
    #{<<"kind">> => <<"invalid">>}.

structural_path(Path) ->
    [Part || Part <- Path, is_binary(Part) orelse is_integer(Part)].

constraint_detail({Tag, Value}) when is_atom(Tag) ->
    #{<<"kind">> => atom_to_binary(Tag, utf8),
      <<"value">> => structural_value(Value)};
constraint_detail(Tag) when is_atom(Tag) ->
    #{<<"kind">> => atom_to_binary(Tag, utf8)};
constraint_detail(_Constraint) ->
    #{<<"kind">> => <<"invalid">>}.

structural_value(Value) when is_binary(Value); is_integer(Value);
                             is_float(Value); is_boolean(Value) -> Value;
structural_value(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
structural_value(Values) when is_list(Values) ->
    [structural_value(Value) || Value <- Values,
                                is_binary(Value) orelse is_atom(Value) orelse
                                is_integer(Value) orelse is_float(Value) orelse
                                is_boolean(Value)];
structural_value(_Value) -> <<"invalid">>.

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
            case normalize_confirmation(Call) of
                {ok, Call1} ->
                    Allowed = [name, args, module, execute, parallel_safe,
                               pause_capable, timeout, deadline,
                               confirmation],
                    {ok, maps:with(Allowed, Call1)};
                {error, _} = Error -> Error
            end;
        false -> {error, invalid_resolved_tool_call}
    end.

normalize_confirmation(Call) ->
    case maps:find(confirmation, Call) of
        error -> {ok, Call};
        {ok, true} ->
            {ok, Call#{confirmation => #{required => true}}};
        {ok, false} ->
            {ok, Call#{confirmation => #{required => false}}};
        {ok, Confirmation} when is_map(Confirmation) ->
            normalize_confirmation_map(Call, Confirmation);
        {ok, _Invalid} ->
            {error, invalid_resolved_tool_call}
    end.

normalize_confirmation_map(Call, Confirmation) ->
    Unknown = maps:without([required, hint], Confirmation),
    Required = maps:get(required, Confirmation, true),
    Hint = maps:get(hint, Confirmation, undefined),
    case map_size(Unknown) =:= 0 andalso is_boolean(Required) andalso
         valid_confirmation_hint(Hint) of
        true ->
            Base = #{required => Required},
            Canonical = case Hint of
                undefined -> Base;
                _ -> Base#{hint => Hint}
            end,
            {ok, Call#{confirmation => Canonical}};
        false ->
            {error, invalid_resolved_tool_call}
    end.

valid_confirmation_hint(undefined) -> true;
valid_confirmation_hint(Hint) when is_binary(Hint),
                                   byte_size(Hint) =<
                                       ?MAX_CONFIRMATION_HINT_BYTES ->
    case unicode:characters_to_binary(Hint, utf8, utf8) of
        Hint -> true;
        _ -> false
    end;
valid_confirmation_hint(_Hint) -> false.

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

module_catalog_entry(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, schema, 0) andalso
                 erlang:function_exported(Module, execute, 2) of
                false -> {error, {invalid_tool_module, Module}};
                true ->
                    cached_module_catalog_entry(Module)
            end;
        _ -> {error, {tool_module_unavailable, Module}}
    end.

cached_module_catalog_entry(Module) ->
    Fingerprint = Module:module_info(md5),
    CacheKey = {?MODULE, module_catalog, Module},
    case persistent_term:get(CacheKey, undefined) of
        {?CATALOG_VERSION, Fingerprint, Entry} when is_map(Entry) ->
            {ok, Entry};
        _ ->
            case compile_module_catalog_entry(Module) of
                {ok, Entry} = Ok ->
                    persistent_term:put(
                      CacheKey, {?CATALOG_VERSION, Fingerprint, Entry}),
                    Ok;
                {error, _} = Error -> Error
            end
    end.

compile_module_catalog_entry(Module) ->
    try Module:schema() of
        Schema when is_map(Schema) ->
            case validate_schema(Schema) of
                {ok, Validated} -> {ok, catalog_entry(Validated)};
                {error, Reason} ->
                    {error, {invalid_tool_schema,
                             {module, Module}, Reason}}
            end;
        _ ->
            {error, {invalid_tool_schema,
                     {module, Module}, invalid_schema}}
    catch
        _:_ -> {error, {tool_module_unavailable, Module}}
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

load_toolset_catalog(Module, Handle) ->
    case load_callbacks(Module) of
        ok ->
            try Module:schemas(Handle) of
                Schemas when is_list(Schemas) ->
                    compile_toolset_catalog(Schemas, Module);
                _ -> {error, invalid_toolset_schemas}
            catch
                _:_ -> {error, toolset_unavailable}
            end;
        {error, _} = Error -> Error
    end.

compile_toolset_catalog(Schemas, Module) ->
    validate_schema_list(Schemas, Module, 1, #{}, [], #{}).

validate_schema_list([], _Module, _SchemaIndex, _Names,
                     SchemasAcc, IndexAcc) ->
    {ok, #{schemas => lists:reverse(SchemasAcc), index => IndexAcc}};
validate_schema_list([Schema | Rest], Module, SchemaIndex, Names,
                     SchemasAcc, IndexAcc) when is_map(Schema) ->
    case validate_schema(Schema) of
        {ok, Validated} ->
            Name = maps:get(<<"name">>, Validated),
            Source = {toolset, Module, SchemaIndex},
            case maps:find(Name, Names) of
                {ok, PreviousSource} ->
                    {error, {duplicate_tool_name, Name,
                             PreviousSource, Source}};
                error ->
                    Entry = catalog_entry(Validated),
                    validate_schema_list(
                      Rest, Module, SchemaIndex + 1,
                      Names#{Name => Source},
                      [Validated | SchemasAcc],
                      IndexAcc#{Name => Entry})
            end;
        {error, Reason} ->
            Identity = {toolset, Module, SchemaIndex,
                        diagnostic_schema_name(Schema)},
            {error, {invalid_tool_schema, Identity, Reason}}
    end;
validate_schema_list(_Invalid, Module, SchemaIndex, _Names,
                     _SchemasAcc, _IndexAcc) ->
    {error, {invalid_toolset_schemas,
             {toolset, Module, SchemaIndex}}}.

catalog_entry(Schema) ->
    #{schema => Schema,
      parameters => maps:get(<<"parameters">>, Schema)}.

diagnostic_schema_name(Schema) ->
    case maps:find(<<"name">>, Schema) of
        {ok, Name} when is_binary(Name) -> Name;
        _ ->
            case maps:find(name, Schema) of
                {ok, Name} when is_binary(Name) -> Name;
                {ok, Name} when is_atom(Name) -> atom_to_binary(Name, utf8);
                _ -> undefined
            end
    end.

validate_schema(Schema0) when is_map(Schema0) ->
    case adk_json:normalize(Schema0) of
        {ok, Schema} -> validate_normalized_schema(Schema);
        {error, _} -> {error, invalid_tool_schema}
    end.

validate_normalized_schema(#{<<"name">> := Name} = Schema0)
  when is_binary(Name), byte_size(Name) > 0 ->
    case valid_description(Schema0) of
        false -> {error, invalid_tool_schema};
        true ->
            Parameters0 = maps:get(
                            <<"parameters">>, Schema0,
                            #{<<"type">> => <<"object">>}),
            Parameters = normalize_schema_types(Parameters0),
            case adk_json_schema:compile(Parameters) of
                {ok, Compiled} ->
                    {ok, Schema0#{<<"parameters">> => Compiled}};
                {error, Reason} ->
                    {error, {invalid_tool_parameter_schema, Reason}}
            end
    end;
validate_normalized_schema(_Schema) -> {error, invalid_tool_schema}.

valid_description(Schema) ->
    case maps:find(<<"description">>, Schema) of
        error -> true;
        {ok, Description} -> is_binary(Description)
    end.

normalize_schema_types(Map) when is_map(Map) ->
    maps:from_list(
      [case Key of
           <<"type">> -> {Key, normalize_type_value(Value)};
           _ -> {Key, normalize_schema_types(Value)}
       end || {Key, Value} <- maps:to_list(Map)]);
normalize_schema_types(List) when is_list(List) ->
    [normalize_schema_types(Value) || Value <- List];
normalize_schema_types(Value) -> Value.

normalize_type_value(Types) when is_list(Types) ->
    [normalize_type_value(Type) || Type <- Types];
normalize_type_value(<<"OBJECT">>) -> <<"object">>;
normalize_type_value(<<"ARRAY">>) -> <<"array">>;
normalize_type_value(<<"STRING">>) -> <<"string">>;
normalize_type_value(<<"NUMBER">>) -> <<"number">>;
normalize_type_value(<<"INTEGER">>) -> <<"integer">>;
normalize_type_value(<<"BOOLEAN">>) -> <<"boolean">>;
normalize_type_value(<<"NULL">>) -> <<"null">>;
normalize_type_value(Type) -> Type.
