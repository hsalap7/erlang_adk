%% @doc Strict, internal policy manifest for first-party connector tools.
%%
%% A connector manifest is never copied into a provider-facing tool schema.
%% Every advertised tool must declare its least-authority permissions, side
%% effect class, confirmation policy, and concurrency safety. Unknown or
%% missing metadata is rejected rather than receiving a permissive default.
-module(adk_connector_manifest).

-export([validate/1, validate_schemas/2, tool/2,
         apply_execution_policy/2, describe/1]).

-define(SCHEMA_VERSION, 1).
-define(MAX_CONNECTOR_ID_BYTES, 128).
-define(MAX_TOOL_NAME_BYTES, 128).
-define(MAX_PERMISSION_BYTES, 128).
-define(MAX_TOOLS, 128).
-define(MAX_PERMISSIONS_PER_TOOL, 64).

-type side_effect() :: none | read | write | external_action | destructive.
-type confirmation() :: never | required | conditional.
-type tool_policy() :: #{
    name := binary(),
    permissions := [binary()],
    side_effect := side_effect(),
    confirmation := confirmation(),
    parallel_safe := boolean()
}.
-type manifest() :: #{
    schema_version := 1,
    connector_id := binary(),
    service := native | mcp | openapi,
    tools := [tool_policy()],
    tool_index := #{binary() => tool_policy()}
}.
-export_type([manifest/0, tool_policy/0, side_effect/0, confirmation/0]).

-spec validate(term()) -> {ok, manifest()} | {error, term()}.
validate(Manifest) when is_map(Manifest) ->
    Allowed = [schema_version, connector_id, service, tools],
    case exact_keys(Manifest, Allowed) of
        false -> {error, invalid_connector_manifest_keys};
        true -> validate_fields(Manifest)
    end;
validate(_Manifest) ->
    {error, invalid_connector_manifest}.

validate_fields(#{schema_version := ?SCHEMA_VERSION,
                  connector_id := ConnectorId,
                  service := Service,
                  tools := Tools}) ->
    case {valid_id(ConnectorId, ?MAX_CONNECTOR_ID_BYTES),
          valid_service(Service),
          is_list(Tools) andalso length(Tools) =< ?MAX_TOOLS} of
        {true, true, true} ->
            validate_tools(Tools, ConnectorId, Service, #{}, []);
        {false, _, _} -> {error, invalid_connector_id};
        {_, false, _} -> {error, invalid_connector_service};
        {_, _, false} -> {error, invalid_connector_tools}
    end;
validate_fields(#{schema_version := _Unsupported}) ->
    {error, unsupported_connector_manifest_version};
validate_fields(_Manifest) ->
    {error, incomplete_connector_manifest}.

validate_tools([], _ConnectorId, _Service, _Index, []) ->
    {error, empty_connector_manifest};
validate_tools([], ConnectorId, Service, Index, Acc) ->
    CanonicalTools = lists:reverse(Acc),
    {ok, #{tools => CanonicalTools,
           tool_index => Index,
           connector_id => ConnectorId,
           service => Service,
           schema_version => ?SCHEMA_VERSION}};
validate_tools([Tool | Rest], ConnectorId, Service, Index, Acc)
  when is_map(Tool) ->
    case validate_tool(Tool) of
        {ok, Canonical0} ->
            Name = maps:get(name, Canonical0),
            case maps:is_key(Name, Index) of
                true -> {error, {duplicate_connector_tool, Name}};
                false ->
                    validate_tools(Rest, ConnectorId, Service,
                                   Index#{Name => Canonical0},
                                   [Canonical0 | Acc])
            end;
        {error, _} = Error -> Error
    end;
validate_tools(_Improper, _ConnectorId, _Service, _Index, _Acc) ->
    {error, invalid_connector_tools}.

validate_tool(Tool) ->
    Allowed = [name, permissions, side_effect, confirmation, parallel_safe],
    case exact_keys(Tool, Allowed) of
        false -> {error, invalid_connector_tool_keys};
        true -> validate_tool_fields(Tool)
    end.

validate_tool_fields(#{name := Name,
                       permissions := Permissions,
                       side_effect := SideEffect,
                       confirmation := Confirmation,
                       parallel_safe := ParallelSafe}) ->
    case {valid_id(Name, ?MAX_TOOL_NAME_BYTES),
          validate_permissions(Permissions),
          valid_side_effect(SideEffect),
          valid_confirmation(Confirmation),
          is_boolean(ParallelSafe)} of
        {true, {ok, CanonicalPermissions}, true, true, true} ->
            case coherent_policy(SideEffect, Confirmation, ParallelSafe) of
                true ->
                    {ok, #{name => Name,
                           permissions => CanonicalPermissions,
                           side_effect => SideEffect,
                           confirmation => Confirmation,
                           parallel_safe => ParallelSafe}};
                false -> {error, unsafe_connector_tool_policy}
            end;
        {false, _, _, _, _} -> {error, invalid_connector_tool_name};
        {_, {error, _} = Error, _, _, _} -> Error;
        {_, _, false, _, _} -> {error, invalid_side_effect_class};
        {_, _, _, false, _} -> {error, invalid_confirmation_policy};
        {_, _, _, _, false} -> {error, invalid_concurrency_safety}
    end;
validate_tool_fields(_Tool) ->
    {error, incomplete_connector_tool_policy}.

validate_permissions(Permissions)
  when is_list(Permissions),
       length(Permissions) > 0,
       length(Permissions) =< ?MAX_PERMISSIONS_PER_TOOL ->
    case proper_permissions(Permissions, #{}, []) of
        {ok, Canonical} -> {ok, lists:sort(Canonical)};
        error -> {error, invalid_connector_permissions}
    end;
validate_permissions(_Permissions) ->
    {error, invalid_connector_permissions}.

proper_permissions([], _Seen, Acc) -> {ok, Acc};
proper_permissions([Permission | Rest], Seen, Acc) ->
    case valid_id(Permission, ?MAX_PERMISSION_BYTES) andalso
         not maps:is_key(Permission, Seen) of
        true -> proper_permissions(Rest, Seen#{Permission => true},
                                   [Permission | Acc]);
        false -> error
    end.

coherent_policy(destructive, required, false) -> true;
coherent_policy(destructive, _Confirmation, _ParallelSafe) -> false;
coherent_policy(SideEffect, Confirmation, ParallelSafe)
  when SideEffect =:= write; SideEffect =:= external_action ->
    ParallelSafe =:= false andalso Confirmation =/= never;
coherent_policy(SideEffect, _Confirmation, _ParallelSafe)
  when SideEffect =:= none; SideEffect =:= read -> true.

-spec validate_schemas(manifest(), term()) -> ok | {error, term()}.
validate_schemas(#{tool_index := Index}, Schemas)
  when is_map(Index), is_list(Schemas) ->
    case schema_names(Schemas, #{}, []) of
        {ok, Names} -> compare_names(lists:sort(maps:keys(Index)),
                                     lists:sort(Names));
        {error, _} = Error -> Error
    end;
validate_schemas(_Manifest, _Schemas) ->
    {error, invalid_connector_schema_catalog}.

schema_names([], _Seen, Acc) -> {ok, Acc};
schema_names([#{<<"name">> := Name} | Rest], Seen, Acc)
  when is_binary(Name) ->
    case valid_id(Name, ?MAX_TOOL_NAME_BYTES) andalso
         not maps:is_key(Name, Seen) of
        true -> schema_names(Rest, Seen#{Name => true}, [Name | Acc]);
        false -> {error, invalid_connector_schema_name}
    end;
schema_names([_Invalid | _Rest], _Seen, _Acc) ->
    {error, invalid_connector_schema_catalog};
schema_names(_Improper, _Seen, _Acc) ->
    {error, invalid_connector_schema_catalog}.

compare_names(Names, Names) -> ok;
compare_names(ManifestNames, SchemaNames) ->
    {error, {connector_manifest_schema_mismatch,
             #{manifest => ManifestNames, schemas => SchemaNames}}}.

-spec tool(manifest(), binary()) ->
    {ok, tool_policy()} | {error, unknown_connector_tool}.
tool(#{tool_index := Index}, Name) when is_map(Index), is_binary(Name) ->
    case maps:find(Name, Index) of
        {ok, Policy} -> {ok, Policy};
        error -> {error, unknown_connector_tool}
    end;
tool(_Manifest, _Name) ->
    {error, unknown_connector_tool}.

%% @doc Enforce the manifest on an adapter-created resolved call. Metadata
%% supplied by an adapter can make a call stricter, but cannot weaken the
%% manifest. Conditional confirmation must be decided explicitly per call.
-spec apply_execution_policy(map(), tool_policy()) ->
    {ok, map()} | {error, term()}.
apply_execution_policy(Call, Policy)
  when is_map(Call), is_map(Policy) ->
    Name = maps:get(name, Policy, undefined),
    case maps:get(name, Call, undefined) =:= Name of
        false -> {error, connector_resolved_call_name_mismatch};
        true -> apply_confirmation_policy(
                  Call#{parallel_safe =>
                            maps:get(parallel_safe, Policy)}, Policy)
    end;
apply_execution_policy(_Call, _Policy) ->
    {error, invalid_connector_resolved_call}.

apply_confirmation_policy(Call, #{confirmation := never}) ->
    case explicitly_requires_confirmation(Call) of
        true -> {error, connector_confirmation_policy_mismatch};
        false -> {ok, Call#{confirmation => false}}
    end;
apply_confirmation_policy(Call, #{confirmation := required}) ->
    {ok, Call#{confirmation => true}};
apply_confirmation_policy(Call, #{confirmation := conditional}) ->
    case maps:find(confirmation, Call) of
        error -> {error, connector_confirmation_decision_missing};
        {ok, Decision} when is_boolean(Decision); is_map(Decision) ->
            {ok, Call};
        {ok, _Invalid} -> {error, invalid_connector_confirmation_decision}
    end.

explicitly_requires_confirmation(#{confirmation := true}) -> true;
explicitly_requires_confirmation(
  #{confirmation := #{required := true}}) -> true;
explicitly_requires_confirmation(_) -> false.

-spec describe(manifest()) -> map().
describe(#{schema_version := Version,
           connector_id := ConnectorId,
           service := Service,
           tools := Tools}) ->
    #{<<"schema_version">> => Version,
      <<"connector_id">> => ConnectorId,
      <<"service">> => atom_to_binary(Service, utf8),
      <<"tools">> => [describe_tool(Tool) || Tool <- Tools]};
describe(_Manifest) ->
    #{<<"status">> => <<"invalid">>}.

describe_tool(#{name := Name, permissions := Permissions,
                side_effect := SideEffect,
                confirmation := Confirmation,
                parallel_safe := ParallelSafe}) ->
    #{<<"name">> => Name,
      <<"permissions">> => Permissions,
      <<"side_effect">> => atom_to_binary(SideEffect, utf8),
      <<"confirmation">> => atom_to_binary(Confirmation, utf8),
      <<"parallel_safe">> => ParallelSafe}.

valid_service(native) -> true;
valid_service(mcp) -> true;
valid_service(openapi) -> true;
valid_service(_) -> false.

valid_side_effect(none) -> true;
valid_side_effect(read) -> true;
valid_side_effect(write) -> true;
valid_side_effect(external_action) -> true;
valid_side_effect(destructive) -> true;
valid_side_effect(_) -> false.

valid_confirmation(never) -> true;
valid_confirmation(required) -> true;
valid_confirmation(conditional) -> true;
valid_confirmation(_) -> false.

valid_id(Value, MaxBytes)
  when is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< MaxBytes ->
    case binary:bin_to_list(Value) of
        [First | Rest] -> valid_first(First) andalso
                          lists:all(fun valid_rest/1, Rest);
        [] -> false
    end;
valid_id(_Value, _MaxBytes) -> false.

valid_first(C) ->
    (C >= $a andalso C =< $z) orelse
    (C >= $A andalso C =< $Z) orelse
    (C >= $0 andalso C =< $9).

valid_rest(C) ->
    valid_first(C) orelse C =:= $. orelse C =:= $_ orelse
    C =:= $- orelse C =:= $:.

exact_keys(Map, Allowed) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Allowed).
