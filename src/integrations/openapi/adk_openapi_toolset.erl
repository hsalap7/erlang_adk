%% @doc Immutable OpenAPI 3.0/3.1 toolset compiler and bounded executor.
%%
%% Supported documents are OpenAPI `3.0.x' and `3.1.x'. Supported security is
%% `apiKey' in header or query, HTTP `bearer', and OAuth 2.0 (implicit,
%% password, client-credentials, or authorization-code flows); OAuth token
%% acquisition remains the injected auth manager's responsibility. Cookie API
%% keys, HTTP Basic/Digest, mutual TLS, and OpenID Connect are not accepted.
%%
%% The request subset is path/query/header parameters using OpenAPI simple or
%% form serialization, JSON request bodies, and JSON responses. Multipart,
%% form-urlencoded, cookie parameters, callbacks, and remote `$ref' values are
%% intentionally rejected rather than silently weakened.
%%
%% The compiler accepts an already-decoded JSON map, resolves only local
%% references, and emits deterministic `adk_tool' schema maps. Network and
%% credential access are injected behaviours. Credentials are resolved only in
%% the short-lived execution worker and are never accepted as tool arguments or
%% copied from the agent context.
-module(adk_openapi_toolset).

-export([compile/2, capabilities/0, schemas/1, schema/2,
         execute/3, execute/4, resolved_call/4]).

-record(toolset, {
    operations = #{} :: map(),
    schemas = [] :: [map()],
    transport :: {module(), adk_openapi_http_transport:handle()},
    auth = undefined :: undefined |
                         {module(), adk_openapi_auth_manager:handle()},
    policy = #{} :: map()
}).

-opaque toolset() :: #toolset{}.
-export_type([toolset/0]).

-define(DEFAULT_TIMEOUT_MS, 10000).
-define(DEFAULT_MAX_REQUEST_BYTES, 1048576).
-define(DEFAULT_MAX_RESPONSE_BYTES, 4194304).
-define(DEFAULT_MAX_SPEC_BYTES, 2097152).
-define(DEFAULT_MAX_OPERATIONS, 100).
-define(DEFAULT_MAX_PARAMETERS, 64).
-define(DEFAULT_MAX_RESPONSES, 32).
-define(DEFAULT_MAX_SCHEMA_DEPTH, 32).
-define(EXECUTION_MAX_HEAP_WORDS, 4000000).
-define(EXECUTION_MAX_RESULT_BYTES, 16777216).
-define(EXECUTION_WATCHDOG_MAX_HEAP_WORDS, 8192).

-spec capabilities() -> map().
capabilities() ->
    #{openapi_versions => [<<"3.0">>, <<"3.1">>],
      references => local_only,
      parameter_locations => [path, query, header],
      request_media_types => [<<"application/json">>,
                              <<"application/*+json">>],
      security => [api_key, http_bearer, oauth2],
      security_details => #{api_key_locations => [header, query],
                            http_schemes => [bearer],
                            oauth2_flows => [implicit, password,
                                             client_credentials,
                                             authorization_code]},
      execution => #{bounded_worker => true,
                     redirects => disabled,
                     host_allowlist => required,
                     response_stream_limit_required => true},
      tool_schema => adk_tool_compatible}.

%% @doc Compile a strict OpenAPI document. Required options are:
%% `transport => {Module, OpaqueHandle}' and a non-empty `allowed_hosts' list.
%% `base_url' is required only when the document has no usable server URL.
-spec compile(map(), map()) -> {ok, toolset()} | {error, term()}.
compile(Spec, Opts) when is_map(Spec), is_map(Opts) ->
    case normalize_options(Opts) of
        {ok, Policy, Transport, Auth} ->
            case validate_spec_boundary(Spec, Policy) of
                ok -> compile_spec(Spec, Policy, Transport, Auth);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
compile(_Spec, _Opts) ->
    {error, invalid_openapi_document}.

-spec schemas(toolset()) -> [map()].
schemas(#toolset{schemas = Schemas}) -> Schemas.

-spec schema(toolset(), binary()) -> {ok, map()} | {error, unknown_tool}.
schema(#toolset{operations = Operations}, Name) when is_binary(Name) ->
    case maps:find(Name, Operations) of
        {ok, Operation} -> {ok, maps:get(tool_schema, Operation)};
        error -> {error, unknown_tool}
    end;
schema(_Toolset, _Name) ->
    {error, unknown_tool}.

-spec execute(toolset(), binary(), map()) -> {ok, map()} | {error, term()}.
execute(Toolset, Name, Args) ->
    execute(Toolset, Name, Args, #{}).

%% @doc Execute one operation. Context is deliberately not forwarded to the
%% auth manager or transport; this prevents session credentials from becoming
%% network metadata by accident.
-spec execute(toolset(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
execute(Toolset = #toolset{operations = Operations,
                          policy = Policy}, Name, Args, Context)
  when is_binary(Name), is_map(Args), is_map(Context) ->
    case maps:find(Name, Operations) of
        {ok, Operation} ->
            Timeout = maps:get(timeout_ms, Policy),
            run_bounded(Toolset, Operation, Args, Timeout);
        error -> {error, unknown_tool}
    end;
execute(_Toolset, _Name, _Args, _Context) ->
    {error, invalid_openapi_execution}.

%% @doc Build an `adk_tool_executor' compatible resolved call without exposing
%% the toolset's transport/auth handles to model-visible arguments.
-spec resolved_call(toolset(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
resolved_call(Toolset = #toolset{operations = Operations}, Name, Args, _Context)
  when is_binary(Name), is_map(Args), is_map(_Context) ->
    case maps:find(Name, Operations) of
        {ok, Operation} ->
            {ok, #{name => Name,
                   args => Args,
                   execute => fun() -> execute(Toolset, Name, Args, #{}) end,
                   parallel_safe => maps:get(parallel_safe, Operation),
                   pause_capable => false}};
        error -> {error, unknown_tool}
    end;
resolved_call(_Toolset, _Name, _Args, _Context) ->
    {error, invalid_openapi_execution}.

normalize_options(Opts) ->
    case validate_ref(transport, maps:get(transport, Opts, undefined)) of
        {ok, Transport} ->
            case validate_optional_ref(auth, maps:get(auth, Opts, undefined)) of
                {ok, Auth} -> normalize_policy(Opts, Transport, Auth);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

normalize_policy(Opts, Transport, Auth) ->
    case allowed_schemes(maps:get(allowed_schemes, Opts, [<<"https">>])) of
        {ok, Schemes} ->
            AllowPrivate = maps:get(allow_private_hosts, Opts, false),
            case is_boolean(AllowPrivate) of
                false -> {error, {invalid_openapi_option, allow_private_hosts}};
                true ->
                    case allowed_hosts(maps:get(allowed_hosts, Opts, undefined),
                                       AllowPrivate) of
                        {ok, Hosts} ->
                            normalize_limits(Opts, Transport, Auth, Schemes,
                                             Hosts, AllowPrivate);
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} = Error -> Error
    end.

normalize_limits(Opts, Transport, Auth, Schemes, Hosts, AllowPrivate) ->
    LimitDefs = [
        {timeout_ms, ?DEFAULT_TIMEOUT_MS},
        {max_request_body_bytes, ?DEFAULT_MAX_REQUEST_BYTES},
        {max_response_bytes, ?DEFAULT_MAX_RESPONSE_BYTES},
        {max_spec_bytes, ?DEFAULT_MAX_SPEC_BYTES},
        {max_operations, ?DEFAULT_MAX_OPERATIONS},
        {max_parameters, ?DEFAULT_MAX_PARAMETERS},
        {max_responses, ?DEFAULT_MAX_RESPONSES},
        {max_schema_depth, ?DEFAULT_MAX_SCHEMA_DEPTH}
    ],
    case positive_limits(LimitDefs, Opts, #{}) of
        {ok, Limits} ->
            BaseUrl = maps:get(base_url, Opts, undefined),
            case optional_binary(base_url, BaseUrl) of
                {ok, NormalizedBase} ->
                    Policy0 = Limits#{allowed_schemes => Schemes,
                                      allowed_hosts => Hosts,
                                      allow_private_hosts => AllowPrivate,
                                      base_url => NormalizedBase,
                                      follow_redirects => false},
                    case validate_configured_base_url(Policy0) of
                        {ok, Policy} ->
                            {ok, Policy, Transport, Auth};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_ref(_Key, {Module, Handle})
  when is_atom(Module),
       (is_pid(Handle) orelse is_atom(Handle) orelse is_reference(Handle)) ->
    {ok, {Module, Handle}};
validate_ref(Key, _Invalid) ->
    {error, {invalid_openapi_option, Key}}.

validate_optional_ref(_Key, undefined) -> {ok, undefined};
validate_optional_ref(Key, Value) -> validate_ref(Key, Value).

positive_limits([], _Opts, Acc) -> {ok, Acc};
positive_limits([{Key, Default} | Rest], Opts, Acc) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value > 0 ->
            positive_limits(Rest, Opts, Acc#{Key => Value});
        _ -> {error, {invalid_openapi_option, Key}}
    end.

optional_binary(_Key, undefined) -> {ok, undefined};
optional_binary(_Key, Value) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
optional_binary(Key, _Value) -> {error, {invalid_openapi_option, Key}}.

allowed_schemes(Values) when is_list(Values), Values =/= [] ->
    Normalized = lists:usort([lower_binary(Value) || Value <- Values,
                                                    is_binary(Value)]),
    case length(Normalized) =:= length(Values) andalso
         lists:all(fun(Scheme) ->
                       Scheme =:= <<"https">> orelse Scheme =:= <<"http">>
                   end, Normalized) of
        true -> {ok, Normalized};
        false -> {error, {invalid_openapi_option, allowed_schemes}}
    end;
allowed_schemes(_) ->
    {error, {invalid_openapi_option, allowed_schemes}}.

allowed_hosts(Values, AllowPrivate) when is_list(Values), Values =/= [] ->
    normalize_allowed_hosts(Values, AllowPrivate, []);
allowed_hosts(_Values, _AllowPrivate) ->
    {error, {invalid_openapi_option, allowed_hosts}}.

normalize_allowed_hosts([], _AllowPrivate, Acc) ->
    {ok, lists:usort(Acc)};
normalize_allowed_hosts([Host | Rest], AllowPrivate, Acc)
  when is_binary(Host) ->
    case canonical_host(Host) of
        {ok, Canonical} ->
            case private_host(Canonical) andalso not AllowPrivate of
                true -> {error, private_host_not_allowed};
                false -> normalize_allowed_hosts(Rest, AllowPrivate,
                                                 [Canonical | Acc])
            end;
        error -> {error, {invalid_openapi_option, allowed_hosts}}
    end;
normalize_allowed_hosts(_Values, _AllowPrivate, _Acc) ->
    {error, {invalid_openapi_option, allowed_hosts}}.

validate_configured_base_url(#{base_url := undefined} = Policy) ->
    {ok, Policy};
validate_configured_base_url(#{base_url := Url} = Policy) ->
    case validate_base_url(Url, Policy) of
        {ok, Normalized} -> {ok, Policy#{base_url => Normalized}};
        {error, _} = Error -> Error
    end.

validate_spec_boundary(Spec, Policy) ->
    MaxDepth = maps:get(max_schema_depth, Policy) * 4,
    case adk_openapi_schema:validate_json(Spec, MaxDepth) of
        ok ->
            try jsx:encode(Spec) of
                Encoded ->
                    case byte_size(Encoded) =<
                         maps:get(max_spec_bytes, Policy) of
                        true ->
                            adk_openapi_schema:reject_remote_refs(
                              Spec, MaxDepth);
                        false -> {error, openapi_document_too_large}
                    end
            catch
                _:_ -> {error, invalid_openapi_document}
            end;
        {error, _} -> {error, invalid_openapi_document}
    end.

compile_spec(Spec, Policy, Transport, Auth) ->
    case openapi_version(Spec) of
        {ok, Version} ->
            case compile_security_schemes(Spec, Policy) of
                {ok, SecuritySchemes} ->
                    case compile_security(
                           maps:get(<<"security">>, Spec, []),
                           SecuritySchemes) of
                        {ok, RootSecurity} ->
                            case root_paths(Spec) of
                                {ok, Paths} ->
                                    compile_paths(
                                      lists:sort(maps:to_list(Paths)),
                                      Spec, Version, SecuritySchemes,
                                      RootSecurity, Policy, #{}, [] ,0,
                                      Transport, Auth);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

openapi_version(#{<<"openapi">> := Version}) when is_binary(Version) ->
    %% The OpenAPI field is a semantic version, not a prefix.  Accept only
    %% released numeric 3.0.x/3.1.x versions so values such as `3.1.latest'
    %% cannot silently select a different parser contract.
    case re:run(Version,
                <<"^3\\.(0|1)\\.(0|[1-9][0-9]*)$">>,
                [{capture, [1], binary}]) of
        {match, [<<"0">>]} -> {ok, openapi_3_0};
        {match, [<<"1">>]} -> {ok, openapi_3_1};
        nomatch -> {error, unsupported_openapi_version}
    end;
openapi_version(_) -> {error, invalid_openapi_version}.

root_paths(#{<<"paths">> := Paths}) when is_map(Paths), map_size(Paths) > 0 ->
    {ok, Paths};
root_paths(_) -> {error, invalid_openapi_paths}.

compile_paths([], _Spec, _Version, _Schemes, _RootSecurity, Policy,
              Operations, Schemas, Count, Transport, Auth) ->
    case Count > 0 of
        true ->
            SortedSchemas = lists:sort(
                              fun(A, B) ->
                                  maps:get(<<"name">>, A) <
                                      maps:get(<<"name">>, B)
                              end, Schemas),
            {ok, #toolset{operations = Operations,
                          schemas = SortedSchemas,
                          transport = Transport,
                          auth = Auth,
                          policy = Policy}};
        false -> {error, openapi_has_no_operations}
    end;
compile_paths([{Path, PathItem0} | Rest], Spec, Version, Schemes,
              RootSecurity, Policy, Operations, Schemas, Count,
              Transport, Auth) ->
    case extension_key(Path) of
        true ->
            compile_paths(Rest, Spec, Version, Schemes, RootSecurity,
                          Policy, Operations, Schemas, Count,
                          Transport, Auth);
        false -> compile_path_entry(
                   Path, PathItem0, Rest, Spec, Version, Schemes,
                   RootSecurity, Policy, Operations, Schemas, Count,
                   Transport, Auth)
    end.

compile_path_entry(Path, PathItem0, Rest, Spec, Version, Schemes,
                   RootSecurity, Policy, Operations, Schemas, Count,
                   Transport, Auth) ->
    case valid_path_template(Path) of
        false -> {error, invalid_openapi_path};
        true ->
            case adk_openapi_schema:resolve_object(Spec, PathItem0, Policy) of
                {ok, PathItem} ->
                    case validate_path_item_keys(PathItem) of
                        ok ->
                            case compile_parameter_list(
                                   maps:get(<<"parameters">>, PathItem, []),
                                   Spec, Policy) of
                                {ok, PathParameters} ->
                                    case compile_path_operations(
                                           method_keys(), Path, PathItem,
                                           PathParameters, Spec, Version,
                                           Schemes, RootSecurity, Policy,
                                           Operations, Schemas, Count) of
                                        {ok, Ops1, Schemas1, Count1} ->
                                            compile_paths(
                                              Rest, Spec, Version, Schemes,
                                              RootSecurity, Policy, Ops1,
                                              Schemas1, Count1,
                                              Transport, Auth);
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} -> {error, invalid_openapi_path_item}
            end
    end.

compile_path_operations([], _Path, _PathItem, _PathParameters, _Spec,
                        _Version, _Schemes, _RootSecurity, _Policy,
                        Operations, Schemas, Count) ->
    {ok, Operations, Schemas, Count};
compile_path_operations([{MethodKey, Method} | Rest], Path, PathItem,
                        PathParameters, Spec, Version, Schemes,
                        RootSecurity, Policy, Operations, Schemas, Count) ->
    case maps:find(MethodKey, PathItem) of
        error ->
            compile_path_operations(Rest, Path, PathItem, PathParameters,
                                    Spec, Version, Schemes, RootSecurity,
                                    Policy, Operations, Schemas, Count);
        {ok, Operation0} when is_map(Operation0) ->
            case Count < maps:get(max_operations, Policy) of
                false -> {error, too_many_openapi_operations};
                true ->
                    case compile_operation(
                           Method, Path, PathItem, PathParameters,
                           Operation0, Spec, Version, Schemes,
                           RootSecurity, Policy) of
                        {ok, Name, Operation, ToolSchema} ->
                            case maps:is_key(Name, Operations) of
                                true -> {error, duplicate_operation_id};
                                false ->
                                    compile_path_operations(
                                      Rest, Path, PathItem, PathParameters,
                                      Spec, Version, Schemes, RootSecurity,
                                      Policy, Operations#{Name => Operation},
                                      [ToolSchema | Schemas], Count + 1)
                            end;
                        {error, _} = Error -> Error
                    end
            end;
        {ok, _} -> {error, invalid_openapi_operation}
    end.

compile_operation(Method, Path, PathItem, PathParameters, Operation,
                  Spec, _Version, Schemes, RootSecurity, Policy) ->
    case validate_operation_keys(Operation) of
        ok ->
            case operation_id(Operation) of
                {ok, Name} ->
                    case compile_parameter_list(
                           maps:get(<<"parameters">>, Operation, []),
                           Spec, Policy) of
                        {ok, OperationParameters} ->
                            compile_operation_parts(
                              Name, Method, Path, PathItem,
                              merge_parameters(PathParameters,
                                               OperationParameters),
                              Operation, Spec, Schemes, RootSecurity,
                              Policy);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

compile_operation_parts(Name, Method, Path, PathItem, ParametersResult,
                        Operation, Spec, Schemes, RootSecurity, Policy) ->
    case ParametersResult of
        {ok, Parameters} ->
            case length(Parameters) =< maps:get(max_parameters, Policy) of
                false -> {error, too_many_openapi_parameters};
                true ->
                    case validate_path_parameters(Path, Parameters) of
                        ok ->
                            SecurityValue = maps:get(
                                              <<"security">>, Operation,
                                              inherited),
                            case operation_security(SecurityValue,
                                                    RootSecurity, Schemes) of
                                {ok, Security} ->
                                    compile_body_responses_server(
                                      Name, Method, Path, PathItem,
                                      Parameters, Operation, Spec, Security,
                                      Policy);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} = Error -> Error
    end.

compile_body_responses_server(Name, Method, Path, PathItem, Parameters,
                              Operation, Spec, Security, Policy) ->
    case security_parameter_conflicts(Security, Parameters) of
        [] ->
            case compile_request_body(Operation, Spec, Policy, Parameters) of
                {ok, Body} ->
                    case compile_responses(Operation, Spec, Policy) of
                        {ok, Responses} ->
                            case operation_base_url(
                                   Operation, PathItem, Spec, Policy) of
                                {ok, BaseUrl} ->
                                    finish_operation(
                                      Name, Method, Path, Parameters, Body,
                                      Responses, Security, BaseUrl,
                                      Operation, Policy);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, security_parameter_conflict}
    end.

finish_operation(Name, Method, Path, Parameters, Body, Responses,
                 Security, BaseUrl, Operation, Policy) ->
    case build_tool_schema(Name, Parameters, Body, Operation) of
        {ok, ToolSchema, InputSchema} ->
            ParallelSafe = Method =:= <<"GET">> orelse
                           Method =:= <<"HEAD">>,
            Compiled = #{name => Name,
                         method => Method,
                         path => Path,
                         parameters => Parameters,
                         body => Body,
                         responses => Responses,
                         security => Security,
                         base_url => BaseUrl,
                         input_schema => InputSchema,
                         tool_schema => ToolSchema,
                         parallel_safe => ParallelSafe,
                         policy => maps:with(
                           [timeout_ms, max_request_body_bytes,
                            max_response_bytes, allowed_schemes,
                            allowed_hosts, allow_private_hosts,
                            follow_redirects], Policy)},
            {ok, Name, Compiled, ToolSchema};
        {error, _} = Error -> Error
    end.

method_keys() ->
    [{<<"get">>, <<"GET">>}, {<<"put">>, <<"PUT">>},
     {<<"post">>, <<"POST">>}, {<<"delete">>, <<"DELETE">>},
     {<<"options">>, <<"OPTIONS">>}, {<<"head">>, <<"HEAD">>},
     {<<"patch">>, <<"PATCH">>}].

validate_path_item_keys(PathItem) ->
    Allowed = [Key || {Key, _} <- method_keys()] ++
              [<<"parameters">>, <<"summary">>, <<"description">>,
               <<"servers">>, <<"trace">>],
    case validate_keys(PathItem, Allowed, invalid_openapi_path_item_key) of
        ok ->
            %% TRACE commonly reflects request headers and therefore must not
            %% receive an out-of-band bearer/API key from an agent tool.
            case maps:is_key(<<"trace">>, PathItem) of
                true -> {error, unsupported_openapi_method};
                false ->
                    valid_optional_binaries(
                      PathItem, [<<"summary">>, <<"description">>],
                      invalid_openapi_path_item)
            end;
        {error, _} = Error -> Error
    end.

validate_operation_keys(Operation) ->
    Allowed = [<<"operationId">>, <<"summary">>, <<"description">>,
               <<"parameters">>, <<"requestBody">>, <<"responses">>,
               <<"security">>, <<"servers">>, <<"tags">>,
               <<"deprecated">>, <<"externalDocs">>],
    case validate_keys(Operation, Allowed, invalid_openapi_operation_key) of
        ok -> validate_operation_annotations(Operation);
        {error, _} = Error -> Error
    end.

validate_operation_annotations(Operation) ->
    case valid_optional_binaries(
           Operation, [<<"summary">>, <<"description">>],
           invalid_openapi_operation) of
        ok ->
            Tags = maps:get(<<"tags">>, Operation, []),
            Deprecated = maps:get(<<"deprecated">>, Operation, false),
            ExternalDocs = maps:get(<<"externalDocs">>, Operation, #{}),
            case is_list(Tags) andalso lists:all(fun is_binary/1, Tags) andalso
                 is_boolean(Deprecated) andalso is_map(ExternalDocs) of
                true -> ok;
                false -> {error, invalid_openapi_operation}
            end;
        {error, _} = Error -> Error
    end.

valid_optional_binaries(_Map, [], _Error) -> ok;
valid_optional_binaries(Map, [Key | Rest], Error) ->
    case maps:find(Key, Map) of
        error -> valid_optional_binaries(Map, Rest, Error);
        {ok, Value} when is_binary(Value) ->
            valid_optional_binaries(Map, Rest, Error);
        {ok, _} -> {error, Error}
    end.

validate_keys(Map, Allowed, Error) ->
    Unknown = [Key || Key <- maps:keys(Map),
                      not lists:member(Key, Allowed),
                      not extension_key(Key)],
    case Unknown of [] -> ok; _ -> {error, Error} end.

extension_key(<<"x-", _/binary>>) -> true;
extension_key(_) -> false.

operation_id(#{<<"operationId">> := Name}) when is_binary(Name) ->
    case byte_size(Name) =< 64 andalso
         re:run(Name, <<"^[A-Za-z_][A-Za-z0-9_.-]*$">>,
                [{capture, none}]) =:= match of
        true -> {ok, Name};
        false -> {error, invalid_operation_id}
    end;
operation_id(_) -> {error, missing_operation_id}.

compile_parameter_list([], _Spec, _Policy) -> {ok, []};
compile_parameter_list(List, Spec, Policy) when is_list(List) ->
    compile_parameters(List, Spec, Policy, #{}, []);
compile_parameter_list(_List, _Spec, _Policy) ->
    {error, invalid_openapi_parameters}.

compile_parameters([], _Spec, _Policy, _Seen, Acc) ->
    {ok, lists:reverse(Acc)};
compile_parameters([Parameter0 | Rest], Spec, Policy, Seen, Acc) ->
    case adk_openapi_schema:resolve_object(Spec, Parameter0, Policy) of
        {ok, Parameter} ->
            case compile_parameter(Parameter, Spec, Policy) of
                {ok, Descriptor} ->
                    Key = parameter_identity(Descriptor),
                    case maps:is_key(Key, Seen) of
                        true -> {error, duplicate_openapi_parameter};
                        false ->
                            compile_parameters(
                              Rest, Spec, Policy, Seen#{Key => true},
                              [Descriptor | Acc])
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, invalid_openapi_parameter}
    end.

compile_parameter(Parameter, Spec, Policy) ->
    case {maps:find(<<"name">>, Parameter),
          maps:find(<<"in">>, Parameter),
          maps:find(<<"schema">>, Parameter)} of
        {{ok, Name}, {ok, LocationBin}, {ok, RawSchema}}
          when is_binary(Name), byte_size(Name) > 0,
               is_binary(LocationBin) ->
            case parameter_location(LocationBin) of
                {ok, Location} ->
                    compile_parameter_schema(Parameter, Name, Location,
                                             RawSchema, Spec, Policy);
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_openapi_parameter}
    end.

compile_parameter_schema(Parameter, Name, Location, RawSchema,
                         Spec, Policy) ->
    Required0 = maps:get(<<"required">>, Parameter, false),
    Required = Location =:= path orelse Required0 =:= true,
    case valid_parameter_flags(Parameter, Location, Required0) of
        false -> {error, invalid_openapi_parameter};
        true ->
            case valid_parameter_name(Name, Location) of
                false -> {error, unsafe_openapi_parameter};
                true ->
                    case adk_openapi_schema:compile(
                           Spec, RawSchema, Policy) of
                        {ok, Schema} ->
                            case supported_parameter_schema(Schema) of
                                true ->
                                    {Style, Explode} = parameter_encoding(
                                                         Parameter, Location),
                                    {ok, #{name => Name,
                                           request_name => request_name(
                                                             Name, Location),
                                           location => Location,
                                           required => Required,
                                           schema => Schema,
                                           style => Style,
                                           explode => Explode}};
                                false ->
                                    {error, unsupported_parameter_schema}
                            end;
                        {error, _} -> {error, invalid_parameter_schema}
                    end
            end
    end.

valid_parameter_flags(Parameter, path, Required0) ->
    Required0 =:= true andalso valid_style(Parameter, path);
valid_parameter_flags(Parameter, Location, Required0) ->
    is_boolean(Required0) andalso valid_style(Parameter, Location).

valid_style(Parameter, path) ->
    maps:get(<<"style">>, Parameter, <<"simple">>) =:= <<"simple">> andalso
    is_boolean(maps:get(<<"explode">>, Parameter, false));
valid_style(Parameter, query) ->
    maps:get(<<"style">>, Parameter, <<"form">>) =:= <<"form">> andalso
    is_boolean(maps:get(<<"explode">>, Parameter, true));
valid_style(Parameter, header) ->
    maps:get(<<"style">>, Parameter, <<"simple">>) =:= <<"simple">> andalso
    is_boolean(maps:get(<<"explode">>, Parameter, false)).

parameter_encoding(Parameter, path) ->
    {simple, maps:get(<<"explode">>, Parameter, false)};
parameter_encoding(Parameter, query) ->
    {form, maps:get(<<"explode">>, Parameter, true)};
parameter_encoding(Parameter, header) ->
    {simple, maps:get(<<"explode">>, Parameter, false)}.

parameter_location(<<"path">>) -> {ok, path};
parameter_location(<<"query">>) -> {ok, query};
parameter_location(<<"header">>) -> {ok, header};
parameter_location(_) -> {error, unsupported_parameter_location}.

valid_parameter_name(<<"body">>, _Location) -> false;
valid_parameter_name(Name, header) ->
    valid_header_name(Name) andalso not forbidden_header(Name) andalso
    not credential_parameter_name(Name);
valid_parameter_name(Name, _Location) ->
    valid_parameter_token(Name) andalso
    not credential_parameter_name(Name).

%% Credentials declared by OpenAPI security schemes are resolved out of band
%% by the auth manager.  Reject credential-looking ordinary parameters so a
%% model can never be invited to supply them as tool arguments.  The shared
%% context guard intentionally does not classify generic keys; this extra
%% substring check covers common prefixed API-key headers such as X-API-Key.
credential_parameter_name(Name) ->
    adk_context_guard:sensitive_key(Name) orelse
    binary:match(normalized_parameter_name(Name), <<"apikey">>) =/= nomatch.

normalized_parameter_name(Name) ->
    lists:foldl(
      fun(Separator, Acc) ->
          binary:replace(Acc, Separator, <<>>, [global])
      end,
      lower_binary(Name),
      [<<"_">>, <<"-">>, <<" ">>, <<".">>, <<":">>]).

valid_security_parameter_name(Name, header) ->
    valid_header_name(Name) andalso not forbidden_header(Name);
valid_security_parameter_name(Name, query) ->
    valid_parameter_token(Name).

valid_parameter_token(Name) ->
    byte_size(Name) =< 128 andalso
    re:run(Name, <<"^[A-Za-z0-9_.-]+$">>, [{capture, none}]) =:= match.

valid_header_name(Name) ->
    byte_size(Name) =< 128 andalso
    re:run(Name, <<"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$">>,
           [{capture, none}]) =:= match.

forbidden_header(Name) ->
    lists:member(lower_binary(Name),
                 [<<"authorization">>, <<"proxy-authorization">>,
                  <<"cookie">>, <<"set-cookie">>, <<"host">>,
                  <<"content-type">>, <<"content-length">>,
                  <<"transfer-encoding">>,
                  <<"connection">>]).

request_name(Name, header) -> lower_binary(Name);
request_name(Name, _Location) -> Name.

supported_parameter_schema(true) -> false;
supported_parameter_schema(false) -> false;
supported_parameter_schema(Schema) when is_map(Schema) ->
    case maps:get(<<"type">>, Schema, undefined) of
        undefined -> false;
        Type when Type =:= <<"string">>; Type =:= <<"integer">>;
                  Type =:= <<"number">>; Type =:= <<"boolean">> -> true;
        Types when is_list(Types) ->
            lists:all(fun primitive_or_null_type/1, Types);
        <<"array">> ->
            case maps:get(<<"items">>, Schema, undefined) of
                Items when is_map(Items) -> supported_array_items(Items);
                _ -> false
            end;
        _ -> false
    end;
supported_parameter_schema(_) -> false.

primitive_or_null_type(Type) ->
    lists:member(Type, [<<"string">>, <<"integer">>, <<"number">>,
                        <<"boolean">>, <<"null">>]).

supported_array_items(Items) ->
    case maps:get(<<"type">>, Items, undefined) of
        Type when Type =:= <<"string">>; Type =:= <<"integer">>;
                  Type =:= <<"number">>; Type =:= <<"boolean">> -> true;
        _ -> false
    end.

parameter_identity(#{location := header, request_name := Name}) ->
    {header, Name};
parameter_identity(#{location := Location, name := Name}) ->
    {Location, Name}.

merge_parameters(PathParameters, OperationParameters) ->
    PathMap = maps:from_list([{parameter_identity(P), P}
                              || P <- PathParameters]),
    OperationMap = maps:from_list([{parameter_identity(P), P}
                                   || P <- OperationParameters]),
    Merged = maps:merge(PathMap, OperationMap),
    Parameters = [P || {_Key, P} <- lists:sort(maps:to_list(Merged))],
    Names = [maps:get(name, P) || P <- Parameters],
    case length(Names) =:= length(lists:usort(Names)) of
        true -> {ok, Parameters};
        false -> {error, ambiguous_parameter_name}
    end.

validate_path_parameters(Path, Parameters) ->
    Placeholders = path_placeholders(Path),
    Declared = lists:sort([maps:get(name, P) || P <- Parameters,
                                              maps:get(location, P) =:= path]),
    case Placeholders of
        {ok, Names} ->
            case lists:sort(Names) =:= Declared of
                true -> ok;
                false -> {error, path_parameter_mismatch}
            end;
        _ -> {error, path_parameter_mismatch}
    end.

path_placeholders(Path) ->
    case re:run(Path, <<"\\{([^{}]+)\\}">>,
                [global, {capture, [1], binary}]) of
        nomatch -> {ok, []};
        {match, Matches} ->
            Names = [Name || [Name] <- Matches],
            case length(Names) =:= length(lists:usort(Names)) andalso
                 lists:all(fun valid_parameter_token/1, Names) of
                true -> {ok, Names};
                false -> {error, invalid_path_template}
            end
    end.

valid_path_template(<<"/", _/binary>> = Path) ->
    byte_size(Path) =< 2048 andalso
    binary:match(Path, <<"?">>) =:= nomatch andalso
    binary:match(Path, <<"#">>) =:= nomatch;
valid_path_template(_) -> false.

compile_request_body(Operation, Spec, Policy, Parameters) ->
    case maps:find(<<"requestBody">>, Operation) of
        error -> {ok, undefined};
        {ok, Body0} ->
            case length(Parameters) >= maps:get(max_parameters, Policy) of
                true -> {error, too_many_openapi_parameters};
                false ->
                    case adk_openapi_schema:resolve_object(
                           Spec, Body0, Policy) of
                        {ok, Body} ->
                            compile_request_body_object(Body, Spec, Policy);
                        {error, _} -> {error, invalid_request_body}
                    end
            end
    end.

compile_request_body_object(Body, Spec, Policy) ->
    Required = maps:get(<<"required">>, Body, false),
    Content = maps:get(<<"content">>, Body, undefined),
    case is_boolean(Required) andalso is_map(Content) of
        false -> {error, invalid_request_body};
        true ->
            case select_json_media(Content) of
                {ok, MediaType, Media} when is_map(Media) ->
                    RawSchema = maps:get(<<"schema">>, Media, #{}),
                    case adk_openapi_schema:compile(
                           Spec, RawSchema, Policy) of
                        {ok, Schema} ->
                            {ok, #{required => Required,
                                   media_type => MediaType,
                                   schema => Schema}};
                        {error, _} -> {error, invalid_request_body_schema}
                    end;
                error -> {error, unsupported_request_media_type}
            end
    end.

select_json_media(Content) ->
    case maps:find(<<"application/json">>, Content) of
        {ok, Media} -> {ok, <<"application/json">>, Media};
        error ->
            Candidates = lists:sort(
                           [{lower_binary(Type), Media}
                            || {Type, Media} <- maps:to_list(Content),
                               is_binary(Type), json_media_type(Type)]),
            case Candidates of
                [{Type, Media} | _] -> {ok, Type, Media};
                [] -> error
            end
    end.

json_media_type(Type0) ->
    Type = lower_binary(hd(binary:split(Type0, <<";">>))),
    Type =:= <<"application/json">> orelse
    (binary:match(Type, <<"application/">>) =:= {0, 12} andalso
     has_suffix(Type, <<"+json">>)).

compile_responses(Operation, Spec, Policy) ->
    case maps:get(<<"responses">>, Operation, undefined) of
        Responses when is_map(Responses), map_size(Responses) > 0 ->
            case map_size(Responses) =< maps:get(max_responses, Policy) of
                false -> {error, invalid_openapi_responses};
                true ->
                    case compile_response_pairs(
                           lists:sort(maps:to_list(Responses)),
                           Spec, Policy, #{}) of
                        {ok, Compiled} ->
                            case has_success_response(maps:keys(Compiled)) of
                                true -> {ok, Compiled};
                                false -> {error, missing_success_response}
                            end;
                        {error, _} = Error -> Error
                    end
            end;
        _ -> {error, invalid_openapi_responses}
    end.

compile_response_pairs([], _Spec, _Policy, Acc) -> {ok, Acc};
compile_response_pairs([{StatusKey, Response0} | Rest], Spec, Policy, Acc) ->
    case valid_response_key(StatusKey) of
        false -> {error, invalid_response_status};
        true ->
            case adk_openapi_schema:resolve_object(Spec, Response0, Policy) of
                {ok, Response} ->
                    case compile_response(Response, Spec, Policy) of
                        {ok, Compiled} ->
                            compile_response_pairs(
                              Rest, Spec, Policy, Acc#{StatusKey => Compiled});
                        {error, _} = Error -> Error
                    end;
                {error, _} -> {error, invalid_openapi_response}
            end
    end.

compile_response(#{<<"description">> := Description} = Response,
                 Spec, Policy) when is_binary(Description) ->
    case maps:find(<<"content">>, Response) of
        error -> {ok, #{media_type => undefined, schema => undefined}};
        {ok, Content} when is_map(Content) ->
            case select_json_media(Content) of
                {ok, MediaType, Media} when is_map(Media) ->
                    RawSchema = maps:get(<<"schema">>, Media, #{}),
                    case adk_openapi_schema:compile(
                           Spec, RawSchema, Policy) of
                        {ok, Schema} ->
                            {ok, #{media_type => MediaType,
                                   schema => Schema}};
                        {error, _} -> {error, invalid_response_schema}
                    end;
                error ->
                    {ok, #{media_type => non_json, schema => undefined}}
            end;
        _ -> {error, invalid_openapi_response}
    end;
compile_response(_Response, _Spec, _Policy) ->
    {error, invalid_openapi_response}.

valid_response_key(<<A, B, C>>)
  when A >= $1, A =< $5,
       B >= $0, B =< $9, C >= $0, C =< $9 -> true;
valid_response_key(<<A, $X, $X>>) when A >= $1, A =< $5 -> true;
valid_response_key(<<"default">>) -> true;
valid_response_key(_) -> false.

has_success_response(Keys) ->
    lists:any(fun(<<"2", _/binary>>) -> true;
                 (<<"default">>) -> true;
                 (_) -> false
              end, Keys).

build_tool_schema(Name, Parameters, Body, Operation) ->
    ParamProperties = maps:from_list(
      [{maps:get(name, P), maps:get(schema, P)} || P <- Parameters]),
    BodyProperties = case Body of
        undefined -> #{};
        _ -> #{<<"body">> => maps:get(schema, Body)}
    end,
    Properties = maps:merge(ParamProperties, BodyProperties),
    ParamRequired = [maps:get(name, P) || P <- Parameters,
                                          maps:get(required, P)],
    Required = case Body of
        #{required := true} -> ParamRequired ++ [<<"body">>];
        _ -> ParamRequired
    end,
    InputSchema0 = #{<<"type">> => <<"object">>,
                     <<"properties">> => Properties,
                     <<"additionalProperties">> => false},
    InputSchema = case Required of
        [] -> InputSchema0;
        _ -> InputSchema0#{<<"required">> => lists:sort(Required)}
    end,
    case adk_json_schema:compile(InputSchema) of
        {ok, Checked} ->
            Description = operation_description(Operation, Name),
            ToolSchema = #{<<"name">> => Name,
                           <<"description">> => Description,
                           <<"parameters">> => Checked},
            {ok, ToolSchema, Checked};
        {error, _} -> {error, invalid_generated_tool_schema}
    end.

operation_description(Operation, Name) ->
    case maps:get(<<"description">>, Operation,
                  maps:get(<<"summary">>, Operation, Name)) of
        Value when is_binary(Value), byte_size(Value) > 0 -> Value;
        _ -> Name
    end.

compile_security_schemes(Spec, Policy) ->
    Components = maps:get(<<"components">>, Spec, #{}),
    case Components of
        Map when is_map(Map) ->
            Schemes = maps:get(<<"securitySchemes">>, Map, #{}),
            case is_map(Schemes) of
                true -> compile_security_scheme_pairs(
                          lists:sort(maps:to_list(Schemes)),
                          Spec, Policy, #{});
                false -> {error, invalid_security_schemes}
            end;
        _ -> {error, invalid_openapi_components}
    end.

compile_security_scheme_pairs([], _Spec, _Policy, Acc) -> {ok, Acc};
compile_security_scheme_pairs([{Name, Scheme0} | Rest], Spec, Policy, Acc)
  when is_binary(Name), byte_size(Name) > 0 ->
    case adk_openapi_schema:resolve_object(Spec, Scheme0, Policy) of
        {ok, Scheme} ->
            case compile_security_scheme(Name, Scheme) of
                {ok, Compiled} ->
                    compile_security_scheme_pairs(
                      Rest, Spec, Policy, Acc#{Name => Compiled});
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, invalid_security_scheme}
    end;
compile_security_scheme_pairs(_Pairs, _Spec, _Policy, _Acc) ->
    {error, invalid_security_scheme}.

compile_security_scheme(Name, #{<<"type">> := <<"apiKey">>,
                                <<"name">> := ParameterName,
                                <<"in">> := LocationBin})
  when is_binary(ParameterName), byte_size(ParameterName) > 0 ->
    case parameter_location(LocationBin) of
        {ok, Location} when Location =:= header; Location =:= query ->
            case valid_security_parameter_name(ParameterName, Location) of
                true -> {ok, #{name => Name, type => api_key,
                               location => Location,
                               parameter_name => request_name(
                                                   ParameterName, Location)}};
                false -> {error, unsafe_security_parameter}
            end;
        _ -> {error, unsupported_security_scheme}
    end;
compile_security_scheme(Name, #{<<"type">> := <<"http">>,
                                <<"scheme">> := Scheme})
  when is_binary(Scheme) ->
    case lower_binary(Scheme) of
        <<"bearer">> -> {ok, #{name => Name, type => bearer,
                                location => header,
                                parameter_name => <<"authorization">>}};
        _ -> {error, unsupported_security_scheme}
    end;
compile_security_scheme(Name, #{<<"type">> := <<"oauth2">>,
                                <<"flows">> := Flows})
  when is_map(Flows), map_size(Flows) > 0 ->
    case oauth_scopes(Flows) of
        {ok, Scopes} ->
            {ok, #{name => Name, type => oauth2,
                   location => header,
                   parameter_name => <<"authorization">>,
                   declared_scopes => Scopes}};
        {error, _} = Error -> Error
    end;
compile_security_scheme(_Name, _Scheme) ->
    {error, unsupported_security_scheme}.

oauth_scopes(Flows) ->
    Allowed = [<<"implicit">>, <<"password">>, <<"clientCredentials">>,
               <<"authorizationCode">>],
    case [Key || Key <- maps:keys(Flows), not lists:member(Key, Allowed)] of
        [] -> oauth_flow_pairs(maps:to_list(Flows), []);
        _ -> {error, unsupported_oauth_flow}
    end.

oauth_flow_pairs([], Acc) -> {ok, lists:usort(Acc)};
oauth_flow_pairs([{_Name, Flow} | Rest], Acc) when is_map(Flow) ->
    case maps:get(<<"scopes">>, Flow, undefined) of
        Scopes when is_map(Scopes) ->
            case lists:all(fun({Scope, Description}) ->
                               is_binary(Scope) andalso
                               is_binary(Description)
                           end, maps:to_list(Scopes)) of
                true -> oauth_flow_pairs(Rest, maps:keys(Scopes) ++ Acc);
                false -> {error, invalid_oauth_scopes}
            end;
        _ -> {error, invalid_oauth_flow}
    end;
oauth_flow_pairs(_Flows, _Acc) -> {error, invalid_oauth_flow}.

operation_security(inherited, RootSecurity, _Schemes) ->
    {ok, RootSecurity};
operation_security(Value, _RootSecurity, Schemes) ->
    compile_security(Value, Schemes).

compile_security(Security, Schemes) when is_list(Security) ->
    compile_security_requirements(Security, Schemes, []);
compile_security(_Security, _Schemes) ->
    {error, invalid_security_requirement}.

compile_security_requirements([], _Schemes, Acc) ->
    {ok, lists:reverse(Acc)};
compile_security_requirements([Requirement | Rest], Schemes, Acc)
  when is_map(Requirement) ->
    case compile_security_requirement(
           lists:sort(maps:to_list(Requirement)), Schemes, []) of
        {ok, Compiled} ->
            case valid_security_combination(Compiled) of
                true -> compile_security_requirements(
                          Rest, Schemes, [Compiled | Acc]);
                false -> {error, conflicting_security_requirement}
            end;
        {error, _} = Error -> Error
    end;
compile_security_requirements(_Security, _Schemes, _Acc) ->
    {error, invalid_security_requirement}.

compile_security_requirement([], _Schemes, Acc) ->
    {ok, lists:reverse(Acc)};
compile_security_requirement([{Name, Scopes} | Rest], Schemes, Acc)
  when is_binary(Name), is_list(Scopes) ->
    case maps:find(Name, Schemes) of
        {ok, Scheme} ->
            case valid_required_scopes(Scheme, Scopes) of
                true ->
                    compile_security_requirement(
                      Rest, Schemes,
                      [#{scheme => Scheme,
                         scopes => lists:usort(Scopes)} | Acc]);
                false -> {error, invalid_security_scopes}
            end;
        error -> {error, unknown_security_scheme}
    end;
compile_security_requirement(_Requirement, _Schemes, _Acc) ->
    {error, invalid_security_requirement}.

valid_required_scopes(#{type := oauth2, declared_scopes := Declared}, Scopes) ->
    lists:all(fun is_binary/1, Scopes) andalso
    lists:all(fun(Scope) -> lists:member(Scope, Declared) end, Scopes);
valid_required_scopes(_Scheme, []) -> true;
valid_required_scopes(_Scheme, _Scopes) -> false.

valid_security_combination(Requirement) ->
    Placements = [{maps:get(location, maps:get(scheme, Item)),
                   maps:get(parameter_name, maps:get(scheme, Item))}
                  || Item <- Requirement],
    length(Placements) =:= length(lists:usort(Placements)).

security_parameter_conflicts(Security, Parameters) ->
    SecurityPlacements = lists:usort(
      lists:flatmap(
        fun(Requirement) ->
            [{maps:get(location, maps:get(scheme, Item)),
              maps:get(parameter_name, maps:get(scheme, Item))}
             || Item <- Requirement]
        end, Security)),
    ParameterPlacements = [{maps:get(location, P), maps:get(request_name, P)}
                           || P <- Parameters],
    [Placement || Placement <- SecurityPlacements,
                  lists:member(Placement, ParameterPlacements)].

operation_base_url(Operation, PathItem, Spec, Policy) ->
    Servers = case maps:find(<<"servers">>, Operation) of
        {ok, Value} -> Value;
        error ->
            case maps:find(<<"servers">>, PathItem) of
                {ok, Value} -> Value;
                error -> maps:get(<<"servers">>, Spec, undefined)
            end
    end,
    server_url(Servers, Policy).

server_url(undefined, #{base_url := undefined}) ->
    {error, missing_openapi_server};
server_url(undefined, #{base_url := BaseUrl}) -> {ok, BaseUrl};
server_url([#{<<"url">> := Url}], Policy) when is_binary(Url) ->
    case binary:match(Url, <<"{">>) =:= nomatch andalso
         binary:match(Url, <<"}">>) =:= nomatch of
        true -> resolve_server_url(Url, Policy);
        false -> {error, server_variables_not_supported}
    end;
server_url(_Servers, _Policy) ->
    {error, multiple_or_invalid_servers}.

resolve_server_url(Url, Policy) ->
    case uri_string:parse(Url) of
        #{scheme := _, host := _} -> validate_base_url(Url, Policy);
        #{path := _} ->
            case maps:get(base_url, Policy) of
                undefined -> {error, relative_server_without_base_url};
                Base ->
                    try uri_string:resolve(Url, Base) of
                        Resolved -> validate_base_url(Resolved, Policy)
                    catch
                        _:_ -> {error, invalid_openapi_server}
                    end
            end;
        _ -> {error, invalid_openapi_server}
    end.

validate_base_url(Url, Policy) when is_binary(Url) ->
    case safe_parse_url(Url) of
        {ok, Uri} ->
            case maps:is_key(userinfo, Uri) orelse
                 maps:is_key(query, Uri) orelse maps:is_key(fragment, Uri) of
                true -> {error, unsafe_openapi_server};
                false ->
                    case validate_uri_policy(Uri, Policy) of
                        {ok, SafeUri} ->
                            Path = maps:get(path, SafeUri, <<>>),
                            {ok, uri_string:recompose(SafeUri#{path => Path})};
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} = Error -> Error
    end.

safe_parse_url(Url) ->
    try uri_string:parse(Url) of
        Uri when is_map(Uri) -> {ok, Uri};
        _ -> {error, invalid_url}
    catch
        _:_ -> {error, invalid_url}
    end.

validate_uri_policy(#{scheme := Scheme0, host := Host0} = Uri, Policy)
  when is_binary(Scheme0), is_binary(Host0) ->
    Scheme = lower_binary(Scheme0),
    case canonical_host(Host0) of
        {ok, Host} ->
            AllowedSchemes = maps:get(allowed_schemes, Policy),
            AllowedHosts = maps:get(allowed_hosts, Policy),
            AllowPrivate = maps:get(allow_private_hosts, Policy),
            case lists:member(Scheme, AllowedSchemes) andalso
                 lists:member(Host, AllowedHosts) andalso
                 (AllowPrivate orelse not private_host(Host)) of
                true -> {ok, Uri#{scheme => Scheme, host => Host}};
                false -> {error, openapi_target_not_allowed}
            end;
        error -> {error, openapi_target_not_allowed}
    end;
validate_uri_policy(_Uri, _Policy) ->
    {error, invalid_url}.

canonical_host(Host0) ->
    Host1 = lower_binary(Host0),
    Host = strip_trailing_dot(Host1),
    case byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
         re:run(Host, <<"^[a-z0-9.-]+$">>, [{capture, none}]) =:= match andalso
         binary:match(Host, <<"..">>) =:= nomatch of
        true -> {ok, Host};
        false ->
            %% IP literals are parsed separately; they are allowed only behind
            %% the explicit private-host override.
            case inet:parse_address(binary_to_list(Host)) of
                {ok, _} -> {ok, Host};
                _ -> error
            end
    end.

strip_trailing_dot(<<>>) -> <<>>;
strip_trailing_dot(Binary) ->
    case binary:last(Binary) of
        $. -> binary:part(Binary, 0, byte_size(Binary) - 1);
        _ -> Binary
    end.

private_host(Host) ->
    Host =:= <<"localhost">> orelse has_suffix(Host, <<".localhost">>) orelse
    has_suffix(Host, <<".local">>) orelse
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _Address} -> true;
        _ -> false
    end.

run_bounded(Toolset, Operation, Args, Timeout) ->
    Owner = self(),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    ReplyAlias = erlang:alias([explicit_unalias]),
    ReplyRef = make_ref(),
    Worker = fun() ->
        ok = start_execution_owner_watchdog(Owner, self()),
        Outcome = try execute_operation(Toolset, Operation, Args) of
            Result -> Result
        catch
            _Class:_Reason -> {error, openapi_execution_failed}
        end,
        SafeOutcome = bounded_execution_outcome(Outcome),
        CompletedAt = erlang:monotonic_time(millisecond),
        _ = erlang:send(
              ReplyAlias,
              {openapi_execution_result, ReplyRef, self(),
               CompletedAt, SafeOutcome},
              [noconnect, nosuspend]),
        ok
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?EXECUTION_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try erlang:spawn_opt(Worker, SpawnOptions) of
        {Pid, MonitorRef} ->
            await_bounded_execution(
              Pid, MonitorRef, ReplyAlias, ReplyRef, Deadline)
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            {error, openapi_execution_failed}
    end.

await_bounded_execution(Pid, MonitorRef, ReplyAlias, ReplyRef, Deadline) ->
    receive
        {openapi_execution_result, ReplyRef, Pid, CompletedAt, Result} ->
            _ = erlang:unalias(ReplyAlias),
            _ = erlang:demonitor(MonitorRef, [flush]),
            completed_execution_result(CompletedAt, Deadline, Result);
        {'DOWN', MonitorRef, process, Pid, _OpaqueReason} ->
            _ = erlang:unalias(ReplyAlias),
            {error, openapi_execution_failed}
    after remaining_deadline(Deadline) ->
        _ = erlang:unalias(ReplyAlias),
        exit(Pid, kill),
        _ = erlang:demonitor(MonitorRef, [flush]),
        {error, timeout}
    end.

completed_execution_result(CompletedAt, Deadline, _Result)
  when CompletedAt > Deadline ->
    {error, timeout};
completed_execution_result(_CompletedAt, _Deadline, Result) ->
    Result.

bounded_execution_outcome(Outcome) ->
    try erlang:external_size(Outcome) =< ?EXECUTION_MAX_RESULT_BYTES of
        true -> Outcome;
        false -> {error, openapi_execution_failed}
    catch
        _:_ -> {error, openapi_execution_failed}
    end.

start_execution_owner_watchdog(Owner, ExecutionWorker) ->
    Watchdog = fun() -> execution_owner_watchdog(Owner, ExecutionWorker) end,
    SpawnOptions =
        [{message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?EXECUTION_WATCHDOG_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try erlang:spawn_opt(Watchdog, SpawnOptions) of
        WatchdogPid when is_pid(WatchdogPid) -> ok
    catch
        _:_ -> error
    end.

execution_owner_watchdog(Owner, ExecutionWorker) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, ExecutionWorker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(ExecutionWorker, kill),
            _ = erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', WorkerMonitor, process, ExecutionWorker, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

remaining_deadline(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

execute_operation(#toolset{transport = Transport, auth = Auth},
                  Operation, Args) ->
    InputSchema = maps:get(input_schema, Operation),
    case adk_json_schema:validate(InputSchema, Args) of
        {ok, CanonicalArgs} when is_map(CanonicalArgs) ->
            case build_unauthorized_request(Operation, CanonicalArgs) of
                {ok, Url0, Headers0, Query0, Body} ->
                    case apply_security(maps:get(security, Operation), Auth,
                                        maps:get(name, Operation),
                                        Headers0, Query0) of
                        {ok, Headers, Query, Seeds} ->
                            send_openapi_request(
                              Transport, Operation, Url0, Headers, Query,
                              Body, Seeds);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, invalid_arguments};
        _ -> {error, invalid_arguments}
    end.

build_unauthorized_request(Operation, Args) ->
    Parameters = maps:get(parameters, Operation),
    case encode_parameters(Parameters, Args,
                           maps:get(path, Operation), [], []) of
        {ok, Path, Headers, Query} ->
            case encode_body(maps:get(body, Operation), Args,
                             maps:get(policy, Operation)) of
                {ok, Body, BodyHeaders} ->
                    BaseUrl = maps:get(base_url, Operation),
                    case join_base_path(BaseUrl, Path) of
                        {ok, Url} ->
                            {ok, Url, BodyHeaders ++ Headers, Query, Body};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

encode_parameters([], _Args, Path, Headers, Query) ->
    {ok, Path, lists:reverse(Headers), lists:reverse(Query)};
encode_parameters([Parameter | Rest], Args, Path, Headers, Query) ->
    Name = maps:get(name, Parameter),
    case maps:find(Name, Args) of
        error -> encode_parameters(Rest, Args, Path, Headers, Query);
        {ok, Value} ->
            case encode_parameter(Parameter, Value, Path, Headers, Query) of
                {ok, Path1, Headers1, Query1} ->
                    encode_parameters(Rest, Args, Path1,
                                      Headers1, Query1);
                {error, _} = Error -> Error
            end
    end.

encode_parameter(#{location := path, name := Name}, Value,
                 Path, Headers, Query) ->
    case path_value(Value) of
        {ok, Quoted} ->
            Placeholder = <<"{", Name/binary, "}">>,
            {ok, binary:replace(Path, Placeholder, Quoted, [global]),
             Headers, Query};
        error -> {error, invalid_arguments}
    end;
encode_parameter(#{location := header, request_name := Name}, Value,
                 Path, Headers, Query) ->
    case simple_value(Value) of
        {ok, Encoded} ->
            case safe_header_value(Encoded) of
                true -> {ok, Path, [{Name, Encoded} | Headers], Query};
                false -> {error, invalid_arguments}
            end;
        error -> {error, invalid_arguments}
    end;
encode_parameter(#{location := query, request_name := Name,
                   explode := Explode}, Value,
                 Path, Headers, Query) ->
    case query_values(Name, Value, Explode) of
        {ok, Pairs} -> {ok, Path, Headers, lists:reverse(Pairs) ++ Query};
        error -> {error, invalid_arguments}
    end.

simple_value(Value) when is_list(Value) ->
    simple_list(Value, []);
simple_value(Value) -> scalar_binary(Value).

path_value(Values) when is_list(Values) ->
    path_list(Values, []);
path_value(Value) ->
    case scalar_binary(Value) of
        {ok, Binary} -> {ok, uri_string:quote(Binary)};
        error -> error
    end.

path_list([], Acc) ->
    {ok, join_binary(lists:reverse(Acc), <<",">>)};
path_list([Value | Rest], Acc) ->
    case scalar_binary(Value) of
        {ok, Binary} -> path_list(Rest, [uri_string:quote(Binary) | Acc]);
        error -> error
    end;
path_list(_Improper, _Acc) -> error.

simple_list([], Acc) -> {ok, join_binary(lists:reverse(Acc), <<",">>)};
simple_list([Value | Rest], Acc) ->
    case scalar_binary(Value) of
        {ok, Binary} -> simple_list(Rest, [Binary | Acc]);
        error -> error
    end;
simple_list(_Improper, _Acc) -> error.

scalar_binary(Value) when is_binary(Value) -> {ok, Value};
scalar_binary(Value) when is_integer(Value) -> {ok, integer_to_binary(Value)};
scalar_binary(Value) when is_float(Value) ->
    {ok, float_to_binary(Value, [short])};
scalar_binary(true) -> {ok, <<"true">>};
scalar_binary(false) -> {ok, <<"false">>};
scalar_binary(null) -> {ok, <<"null">>};
scalar_binary(_) -> error.

query_values(Name, Values, true) when is_list(Values) ->
    query_value_pairs(Name, Values, []);
query_values(Name, Values, false) when is_list(Values) ->
    case simple_value(Values) of
        {ok, Joined} -> {ok, [{Name, Joined}]};
        error -> error
    end;
query_values(Name, Value, _Explode) ->
    case scalar_binary(Value) of
        {ok, Binary} -> {ok, [{Name, Binary}]};
        error -> error
    end.

query_value_pairs(_Name, [], Acc) -> {ok, lists:reverse(Acc)};
query_value_pairs(Name, [Value | Rest], Acc) ->
    case scalar_binary(Value) of
        {ok, Binary} -> query_value_pairs(Name, Rest,
                                         [{Name, Binary} | Acc]);
        error -> error
    end;
query_value_pairs(_Name, _Improper, _Acc) -> error.

encode_body(undefined, _Args, _Policy) -> {ok, <<>>, []};
encode_body(#{media_type := MediaType}, Args, Policy) ->
    case maps:find(<<"body">>, Args) of
        error -> {ok, <<>>, []};
        {ok, Value} ->
            try jsx:encode(Value) of
                Body ->
                    case byte_size(Body) =<
                         maps:get(max_request_body_bytes, Policy) of
                        true ->
                            {ok, Body,
                             [{<<"content-type">>, MediaType}]};
                        false -> {error, request_body_too_large}
                    end
            catch
                _:_ -> {error, invalid_arguments}
            end
    end.

join_base_path(BaseUrl, OperationPath) ->
    case safe_parse_url(BaseUrl) of
        {ok, Uri} ->
            BasePath = maps:get(path, Uri, <<>>),
            Path = join_paths(BasePath, OperationPath),
            {ok, uri_string:recompose(Uri#{path => Path})};
        {error, _} = Error -> Error
    end.

join_paths(<<>>, OperationPath) -> OperationPath;
join_paths(<<"/">>, OperationPath) -> OperationPath;
join_paths(BasePath, OperationPath) ->
    Base = strip_trailing_slash(BasePath),
    <<Base/binary, OperationPath/binary>>.

strip_trailing_slash(<<>>) -> <<>>;
strip_trailing_slash(Binary) ->
    case binary:last(Binary) of
        $/ -> binary:part(Binary, 0, byte_size(Binary) - 1);
        _ -> Binary
    end.

apply_security([], _Auth, _OperationId, Headers, Query) ->
    {ok, Headers, Query, []};
apply_security(Alternatives, undefined, _OperationId, Headers, Query) ->
    case lists:any(fun(Requirement) -> Requirement =:= [] end,
                   Alternatives) of
        true -> {ok, Headers, Query, []};
        false -> {error, authentication_required}
    end;
apply_security(Alternatives, Auth, OperationId, Headers, Query) ->
    try_security_alternatives(Alternatives, Auth, OperationId,
                              Headers, Query).

try_security_alternatives([], _Auth, _OperationId, _Headers, _Query) ->
    {error, authentication_failed};
try_security_alternatives([Requirement | Rest], Auth, OperationId,
                          Headers, Query) ->
    case resolve_security_requirement(Requirement, Auth, OperationId,
                                      Headers, Query, []) of
        {ok, _Headers, _Query, _Seeds} = Ok -> Ok;
        {error, _} -> try_security_alternatives(
                        Rest, Auth, OperationId, Headers, Query)
    end.

resolve_security_requirement([], _Auth, _OperationId,
                             Headers, Query, Seeds) ->
    {ok, Headers, Query, lists:usort(Seeds)};
resolve_security_requirement([Item | Rest], {Module, Handle} = Auth,
                             OperationId, Headers, Query, Seeds) ->
    Scheme = maps:get(scheme, Item),
    Request = auth_request(OperationId, Scheme, maps:get(scopes, Item)),
    Result = try Module:resolve(Handle, Request) of
        Value -> Value
    catch
        _:_ -> {error, auth_manager_failed}
    end,
    case apply_credential(Scheme, Result, Headers, Query) of
        {ok, Headers1, Query1, Secret} ->
            resolve_security_requirement(Rest, Auth, OperationId,
                                         Headers1, Query1,
                                         [Secret | Seeds]);
        {error, _} = Error -> Error
    end.

auth_request(OperationId, Scheme, Scopes) ->
    Base = #{operation_id => OperationId,
             scheme_name => maps:get(name, Scheme),
             scheme_type => maps:get(type, Scheme),
             scopes => Scopes},
    case maps:get(type, Scheme) of
        api_key -> Base#{location => maps:get(location, Scheme),
                        parameter_name => maps:get(parameter_name, Scheme)};
        _ -> Base
    end.

apply_credential(#{type := api_key, location := header,
                   parameter_name := Name},
                 {ok, {api_key, Secret}}, Headers, Query)
  when is_binary(Secret), byte_size(Secret) > 0 ->
    case safe_header_value(Secret) andalso
         not header_exists(Name, Headers) of
        true -> {ok, [{Name, Secret} | Headers], Query, Secret};
        false -> {error, invalid_auth_credential}
    end;
apply_credential(#{type := api_key, location := query,
                   parameter_name := Name},
                 {ok, {api_key, Secret}}, Headers, Query)
  when is_binary(Secret), byte_size(Secret) > 0 ->
    case valid_utf8(Secret) andalso not lists:keymember(Name, 1, Query) of
        true -> {ok, Headers, [{Name, Secret} | Query], Secret};
        false -> {error, invalid_auth_credential}
    end;
apply_credential(#{type := Type}, {ok, {bearer, Secret}}, Headers, Query)
  when (Type =:= bearer orelse Type =:= oauth2),
       is_binary(Secret), byte_size(Secret) > 0 ->
    case safe_header_value(Secret) andalso
         binary:match(Secret, <<" ">>) =:= nomatch andalso
         not header_exists(<<"authorization">>, Headers) of
        true ->
            Value = <<"Bearer ", Secret/binary>>,
            {ok, [{<<"authorization">>, Value} | Headers],
             Query, Secret};
        false -> {error, invalid_auth_credential}
    end;
apply_credential(_Scheme, {error, _Reason}, _Headers, _Query) ->
    {error, authentication_failed};
apply_credential(_Scheme, _Result, _Headers, _Query) ->
    {error, invalid_auth_credential}.

header_exists(Name, Headers) ->
    Lower = lower_binary(Name),
    lists:any(fun({HeaderName, _}) -> lower_binary(HeaderName) =:= Lower end,
              Headers).

safe_header_value(Value) ->
    safe_header_bytes(Value).

safe_header_bytes(<<>>) -> true;
safe_header_bytes(<<Byte, Rest/binary>>)
  when Byte >= 32, Byte =/= 127 ->
    safe_header_bytes(Rest);
safe_header_bytes(_) -> false.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

send_openapi_request({TransportModule, TransportHandle}, Operation,
                     Url0, Headers0, Query, Body, Seeds) ->
    Url = append_query(Url0, Query),
    Policy = maps:get(policy, Operation),
    case safe_parse_url(Url) of
        {ok, Uri} ->
            case validate_uri_policy(Uri, Policy) of
                {ok, _} ->
                    Headers = lists:sort(Headers0),
                    Request = #{method => maps:get(method, Operation),
                                url => Url,
                                headers => Headers,
                                body => Body,
                                timeout_ms => maps:get(timeout_ms, Policy),
                                max_response_bytes =>
                                    maps:get(max_response_bytes, Policy),
                                follow_redirects => false,
                                allowed_schemes =>
                                    maps:get(allowed_schemes, Policy),
                                allowed_hosts =>
                                    maps:get(allowed_hosts, Policy),
                                allow_private_hosts =>
                                    maps:get(allow_private_hosts, Policy)},
                    TransportResult = try
                        TransportModule:request(TransportHandle, Request)
                    catch
                        _:_ -> {error, transport_failed}
                    end,
                    handle_transport_result(TransportResult, Operation,
                                            Seeds);
                {error, _} -> {error, openapi_target_not_allowed}
            end;
        {error, _} -> {error, invalid_url}
    end.

append_query(Url, []) -> Url;
append_query(Url, Pairs) ->
    Encoded = join_binary(
                [<<(uri_string:quote(Name))/binary, "=",
                   (uri_string:quote(Value))/binary>>
                 || {Name, Value} <- Pairs], <<"&">>),
    <<Url/binary, "?", Encoded/binary>>.

handle_transport_result({ok, Response}, Operation, Seeds)
  when is_map(Response) ->
    case {maps:get(status, Response, undefined),
          maps:get(body, Response, undefined)} of
        {Status, Body} when is_integer(Status), Status >= 100, Status =< 599,
                            is_binary(Body) ->
            Policy = maps:get(policy, Operation),
            case byte_size(Body) =< maps:get(max_response_bytes, Policy) of
                false -> {error, response_too_large};
                true -> handle_http_status(Status, Body,
                                           maps:get(headers, Response, []),
                                           Operation, Seeds)
            end;
        _ -> {error, invalid_transport_response}
    end;
handle_transport_result({error, timeout}, _Operation, _Seeds) ->
    {error, timeout};
handle_transport_result({error, _Reason}, _Operation, _Seeds) ->
    {error, transport_error};
handle_transport_result(_Result, _Operation, _Seeds) ->
    {error, invalid_transport_response}.

handle_http_status(Status, _Body, _Headers, _Operation, _Seeds)
  when Status >= 300, Status < 400 ->
    {error, {redirect_rejected, Status}};
handle_http_status(Status, Body, Headers, Operation, Seeds)
  when Status >= 200, Status < 300 ->
    case response_contract(Status, maps:get(responses, Operation)) of
        {ok, Contract} ->
            decode_success_response(Status, Body, Headers, Contract, Seeds);
        error -> {error, {unexpected_http_status, Status}}
    end;
handle_http_status(Status, _Body, _Headers, _Operation, _Seeds) ->
    {error, {http_status, Status}}.

response_contract(Status, Responses) ->
    Exact = integer_to_binary(Status),
    Class = <<(integer_to_binary(Status div 100))/binary, "XX">>,
    case maps:find(Exact, Responses) of
        {ok, Contract} -> {ok, Contract};
        error ->
            case maps:find(Class, Responses) of
                {ok, Contract} -> {ok, Contract};
                error -> maps:find(<<"default">>, Responses)
            end
    end.

decode_success_response(Status, <<>>, _Headers,
                        #{schema := undefined}, _Seeds) ->
    {ok, #{<<"status">> => Status, <<"data">> => null}};
decode_success_response(Status, Body, Headers, Contract, Seeds) ->
    case response_is_json(Contract, Headers) of
        false -> {error, unsupported_response_content_type};
        true ->
            try jsx:decode(Body, [return_maps]) of
                Decoded -> validate_response_data(Status, Decoded,
                                                  Contract, Seeds)
            catch
                _:_ -> {error, invalid_json_response}
            end
    end.

response_is_json(#{media_type := MediaType}, _Headers)
  when is_binary(MediaType) -> json_media_type(MediaType);
response_is_json(#{media_type := non_json}, _Headers) -> false;
response_is_json(_Contract, Headers) ->
    case response_header(<<"content-type">>, Headers) of
        {ok, Type} -> json_media_type(Type);
        error -> false
    end.

response_header(Name, Headers) when is_list(Headers) ->
    Lower = lower_binary(Name),
    case lists:search(
           fun({Key, Value}) ->
               is_binary(Key) andalso is_binary(Value) andalso
               lower_binary(Key) =:= Lower;
              (_) -> false
           end, Headers) of
        {value, {_Key, Value}} -> {ok, Value};
        false -> error
    end;
response_header(Name, Headers) when is_map(Headers) ->
    response_header(Name, maps:to_list(Headers));
response_header(_Name, _Headers) -> error.

validate_response_data(Status, Decoded, #{schema := undefined}, Seeds) ->
    safe_response_result(Status, Decoded, Seeds);
validate_response_data(Status, Decoded, #{schema := Schema}, Seeds) ->
    case adk_json_schema:validate(Schema, Decoded) of
        {ok, Checked} -> safe_response_result(Status, Checked, Seeds);
        {error, _} -> {error, response_schema_mismatch}
    end.

safe_response_result(Status, Data, Seeds) ->
    case adk_context_guard:sanitize_value(Data) of
        {ok, Safe0} ->
            Safe = adk_secret_redactor:redact(Safe0, Seeds),
            {ok, #{<<"status">> => Status, <<"data">> => Safe}};
        {error, _} -> {error, invalid_json_response}
    end.

join_binary([], _Separator) -> <<>>;
join_binary([Only], _Separator) -> Only;
join_binary([First | Rest], Separator) ->
    lists:foldl(fun(Value, Acc) ->
                    <<Acc/binary, Separator/binary, Value/binary>>
                end, First, Rest).

lower_binary(Binary) when is_binary(Binary) ->
    try string:lowercase(Binary) of
        Lower when is_binary(Lower) -> Lower
    catch
        _:_ -> Binary
    end.

has_suffix(Binary, Suffix) when byte_size(Binary) >= byte_size(Suffix) ->
    Start = byte_size(Binary) - byte_size(Suffix),
    binary:part(Binary, Start, byte_size(Suffix)) =:= Suffix;
has_suffix(_Binary, _Suffix) -> false.
