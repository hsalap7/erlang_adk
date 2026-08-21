%% @doc Immutable, operator-owned registry for trusted agent configuration.
%%
%% Untrusted agent files carry only binary IDs.  The corresponding provider,
%% MCP, OpenAPI, tool-pack, credential-profile, runtime-policy, workflow, and
%% agent-template descriptors live in this registry
%% and may therefore contain opaque runtime handles which must never be decoded
%% from model or user input.
%%
%% `replace/2' creates a new generation.  A snapshot obtained before the
%% replacement remains immutable and continues resolving the old generation,
%% so one config compilation can never observe a mixed catalog.
-module(adk_config_registry).

-export([new/0, new/1, replace/2, snapshot/1, generation/1,
         instance_id/1, snapshot_revision_id/1,
         lookup/3, lookup_many/2, describe/1, kinds/0]).

-define(REGISTRY_TAG, adk_config_registry).
-define(SNAPSHOT_TAG, adk_config_registry_snapshot).
-define(VERSION, 1).
-define(MAX_ENTRIES_PER_KIND, 1024).
-define(MAX_ID_BYTES, 128).
-define(MAX_REGISTRY_BYTES, 16777216).
-define(MAX_LOOKUPS, 1024).
-define(MAX_TEMPLATE_DEPENDENCIES, 64).
-define(MAX_TEMPLATE_DEPTH, 16).
-define(MAX_TEMPLATE_NODES, 64).
-define(MAX_TEMPLATE_BYTES, 1048576).
-define(EMPTY_INSTANCE_SEED, <<"erlang-adk-empty-config-registry-v1">>).
-define(EMPTY_REVISION_SEED, <<"erlang-adk-empty-config-snapshot-v1">>).
-define(SEAL_KEY, {?MODULE, snapshot_seal_key}).

-type kind() :: provider | mcp | openapi | tool_pack | credential |
                runtime_policy | workflow | agent_template.
-type registry() ::
    {?REGISTRY_TAG, ?VERSION, pos_integer(), binary(), binary(), binary(),
     snapshot()}.
-opaque snapshot() ::
    {?SNAPSHOT_TAG, ?VERSION, pos_integer(), binary(), binary(), binary(),
     #{kind() => map()}}.

-export_type([kind/0, registry/0, snapshot/0]).

-spec new() -> {ok, registry()}.
new() ->
    new(#{}).

-spec new(map()) -> {ok, registry()} | {error, term()}.
new(Definitions) ->
    build_registry(1, new_instance, Definitions).

-spec replace(registry(), map()) -> {ok, registry()} | {error, term()}.
replace({?REGISTRY_TAG, ?VERSION, _Generation, _InstanceId,
         _RevisionId, _Seal, _Snapshot} = Registry, Definitions) ->
    case snapshot(Registry) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId,
              _SnapshotRevision, _SnapshotSeal, _Entries}} ->
            build_registry(Generation + 1, InstanceId, Definitions);
        {error, _} -> {error, invalid_config_registry}
    end;
replace(_Registry, _Definitions) ->
    {error, invalid_config_registry}.

-spec snapshot(registry() | snapshot()) ->
    {ok, snapshot()} | {error, invalid_config_registry}.
snapshot({?REGISTRY_TAG, ?VERSION, Generation, InstanceId, RevisionId, Seal,
          {?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId, RevisionId,
           Seal, _Entries} = Snapshot})
  when is_integer(Generation), Generation > 0 ->
    snapshot(Snapshot);
snapshot({?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId, RevisionId,
          Seal, Entries} = Snapshot)
  when is_integer(Generation), Generation > 0, is_map(Entries) ->
    case valid_token(InstanceId) andalso valid_token(RevisionId) andalso
         valid_seal(Seal) andalso valid_snapshot_entries(Entries) andalso
         seal_matches(Seal, Entries) of
        true -> {ok, Snapshot};
        false -> {error, invalid_config_registry}
    end;
snapshot(_Registry) ->
    {error, invalid_config_registry}.

-spec generation(registry() | snapshot()) ->
    {ok, pos_integer()} | {error, invalid_config_registry}.
generation(Registry) ->
    case snapshot(Registry) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, Generation, _InstanceId,
              _RevisionId, _Seal, _Entries}} ->
            {ok, Generation};
        {error, _} = Error -> Error
    end.

-spec instance_id(registry() | snapshot()) ->
    {ok, binary()} | {error, invalid_config_registry}.
instance_id(Registry) ->
    case snapshot(Registry) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, _Generation, InstanceId,
              _RevisionId, _Seal, _Entries}} ->
            {ok, InstanceId};
        {error, _} = Error -> Error
    end.

-spec snapshot_revision_id(registry() | snapshot()) ->
    {ok, binary()} | {error, invalid_config_registry}.
snapshot_revision_id(Registry) ->
    case snapshot(Registry) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, _Generation, _InstanceId,
              RevisionId, _Seal, _Entries}} ->
            {ok, RevisionId};
        {error, _} = Error -> Error
    end.

-spec lookup(registry() | snapshot(), kind(), binary()) ->
    {ok, term()} | {error, term()}.
lookup(Registry, Kind, Id) ->
    case {snapshot(Registry), valid_kind(Kind), valid_id(Id)} of
        {{error, _} = Error, _, _} -> Error;
        {_, false, _} -> {error, {invalid_registry_kind, Kind}};
        {_, _, false} -> {error, invalid_registry_id};
        {{ok, {?SNAPSHOT_TAG, ?VERSION, _Generation, _InstanceId,
               _RevisionId, _Seal, Entries}},
         true, true} ->
            case maps:find(Id, maps:get(Kind, Entries)) of
                {ok, Descriptor} -> {ok, Descriptor};
                error -> {error, {unknown_registry_id, Kind, Id}}
            end
    end.

%% @doc Resolve a bounded list of trusted IDs after authenticating the
%% immutable snapshot once. This is the bulk boundary used by declarative
%% configuration so N references never trigger N full registry/HMAC scans.
-spec lookup_many(registry() | snapshot(), [{kind(), binary()}]) ->
    {ok, [term()]} | {error, term()}.
lookup_many(Registry, References) when is_list(References) ->
    case validate_lookup_references(References, 0, []) of
        {ok, Validated} ->
            case snapshot(Registry) of
                {ok, {?SNAPSHOT_TAG, ?VERSION, _Generation, _InstanceId,
                      _RevisionId, _Seal, Entries}} ->
                    lookup_many_entries(Validated, Entries, []);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
lookup_many(_Registry, _References) ->
    {error, invalid_registry_lookup_references}.

validate_lookup_references([], _Count, Acc) ->
    {ok, lists:reverse(Acc)};
validate_lookup_references([_Reference | _Rest], Count, _Acc)
  when Count >= ?MAX_LOOKUPS ->
    {error, registry_lookup_capacity_exceeded};
validate_lookup_references([{Kind, Id} = Reference | Rest], Count, Acc) ->
    case {valid_kind(Kind), valid_id(Id)} of
        {true, true} ->
            validate_lookup_references(Rest, Count + 1,
                                       [Reference | Acc]);
        {false, _} -> {error, {invalid_registry_kind, Kind}};
        {_, false} -> {error, invalid_registry_id}
    end;
validate_lookup_references([_Invalid | _Rest], _Count, _Acc) ->
    {error, invalid_registry_lookup_reference};
validate_lookup_references(_Improper, _Count, _Acc) ->
    {error, invalid_registry_lookup_references}.

lookup_many_entries([], _Entries, Acc) ->
    {ok, lists:reverse(Acc)};
lookup_many_entries([{Kind, Id} | Rest], Entries, Acc) ->
    case maps:find(Id, maps:get(Kind, Entries)) of
        {ok, Descriptor} ->
            lookup_many_entries(Rest, Entries, [Descriptor | Acc]);
        error -> {error, {unknown_registry_id, Kind, Id}}
    end.

%% @doc Return content-free catalog metadata suitable for diagnostics.
-spec describe(registry() | snapshot()) -> {ok, map()} | {error, term()}.
describe(Registry) ->
    case snapshot(Registry) of
        {ok, {?SNAPSHOT_TAG, ?VERSION, Generation, InstanceId,
              RevisionId, _Seal, Entries}} ->
            Counts = maps:map(fun(_Kind, Values) -> map_size(Values) end,
                              Entries),
            {ok, #{version => ?VERSION, generation => Generation,
                   instance_id => InstanceId,
                   snapshot_revision_id => RevisionId,
                   counts => Counts}};
        {error, _} = Error -> Error
    end.

-spec kinds() -> [kind()].
kinds() -> [provider, mcp, openapi, tool_pack, credential,
            runtime_policy, workflow, agent_template].

build_registry(Generation, Instance0, Definitions) when is_map(Definitions) ->
    Allowed = [providers, mcp, openapi, tool_packs, credentials,
               runtime_policies, workflows, agent_templates],
    case maps:keys(maps:without(Allowed, Definitions)) of
        [] ->
            case compile_kinds(Definitions, kind_definitions(), #{}) of
                {ok, Entries} ->
                    case validate_registry_entries(Entries) of
                        ok ->
                            InstanceId = registry_instance_id(
                                           Instance0, Entries),
                            RevisionId = registry_snapshot_revision_id(
                                           Generation, Instance0, Entries),
                            Seal = seal_entries(Entries),
                            Snapshot = {?SNAPSHOT_TAG, ?VERSION, Generation,
                                        InstanceId, RevisionId, Seal, Entries},
                            {ok, {?REGISTRY_TAG, ?VERSION, Generation,
                                  InstanceId, RevisionId, Seal, Snapshot}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        Unknown -> {error, {unknown_registry_keys, lists:sort(Unknown)}}
    end;
build_registry(_Generation, _Instance, _Definitions) ->
    {error, invalid_config_registry_definitions}.

kind_definitions() ->
    [{provider, providers}, {mcp, mcp}, {openapi, openapi},
     {tool_pack, tool_packs}, {credential, credentials},
     {runtime_policy, runtime_policies}, {workflow, workflows},
     {agent_template, agent_templates}].

compile_kinds(_Definitions, [], Acc) ->
    {ok, Acc};
compile_kinds(Definitions, [{Kind, Key} | Rest], Acc) ->
    case compile_entries(Kind, maps:get(Key, Definitions, #{})) of
        {ok, Entries} ->
            compile_kinds(Definitions, Rest, Acc#{Kind => Entries});
        {error, _} = Error -> Error
    end.

compile_entries(Kind, Entries) when is_map(Entries),
                                    map_size(Entries) =<
                                        ?MAX_ENTRIES_PER_KIND ->
    compile_entry_list(Kind, maps:to_list(Entries), #{});
compile_entries(Kind, Entries) when is_map(Entries) ->
    {error, {registry_capacity_exceeded, Kind}};
compile_entries(Kind, _Entries) ->
    {error, {invalid_registry_entries, Kind}}.

compile_entry_list(_Kind, [], Acc) ->
    {ok, Acc};
compile_entry_list(Kind, [{Id, Descriptor} | Rest], Acc) ->
    case {valid_id(Id), validate_descriptor(Kind, Descriptor)} of
        {false, _} -> {error, {invalid_registry_id, Kind}};
        {true, ok} ->
            compile_entry_list(Kind, Rest, Acc#{Id => Descriptor});
        {true, {error, Reason}} ->
            {error, {invalid_registry_descriptor, Kind, Id, Reason}}
    end.

validate_descriptor(provider, Descriptor) when is_atom(Descriptor);
                                                 is_binary(Descriptor) ->
    validate_provider_target(Descriptor);
validate_descriptor(provider, #{provider := Provider} = Descriptor) ->
    case exact_descriptor_keys(Descriptor, [provider, metadata]) andalso
         valid_metadata(maps:get(metadata, Descriptor, #{})) of
        true -> validate_provider_target(Provider);
        false -> {error, invalid_provider_descriptor}
    end;
validate_descriptor(mcp, Descriptor) ->
    validate_toolset_descriptor(Descriptor);
validate_descriptor(openapi, Descriptor) ->
    validate_toolset_descriptor(Descriptor);
validate_descriptor(tool_pack, Tools) when is_list(Tools) ->
    validate_tools(Tools);
validate_descriptor(tool_pack, #{tools := Tools} = Descriptor) ->
    case exact_descriptor_keys(Descriptor, [tools, metadata]) andalso
         valid_metadata(maps:get(metadata, Descriptor, #{})) of
        true -> validate_tools(Tools);
        false -> {error, invalid_tool_pack_descriptor}
    end;
validate_descriptor(credential, ProfileId) when is_binary(ProfileId) ->
    case valid_id(ProfileId) of
        true -> ok;
        false -> {error, invalid_credential_profile_descriptor}
    end;
validate_descriptor(credential, #{profile := ProfileId} = Descriptor) ->
    case exact_descriptor_keys(Descriptor, [profile, metadata]) andalso
         valid_id(ProfileId) andalso
         valid_metadata(maps:get(metadata, Descriptor, #{})) of
        true -> ok;
        false -> {error, invalid_credential_profile_descriptor}
    end;
validate_descriptor(runtime_policy, #{policy := Policy} = Descriptor) ->
    case exact_descriptor_keys(Descriptor, [policy, metadata]) andalso
         valid_metadata(maps:get(metadata, Descriptor, #{})) andalso
         valid_runtime_policy(Policy) of
        true -> ok;
        false -> {error, invalid_runtime_policy_descriptor}
    end;
validate_descriptor(workflow, #{workflow := Workflow} = Descriptor) ->
    case exact_descriptor_keys(Descriptor, [workflow, metadata]) andalso
         valid_metadata(maps:get(metadata, Descriptor, #{})) andalso
         adk_workflow:is_compiled(Workflow) of
        true -> ok;
        false -> {error, invalid_workflow_descriptor}
    end;
validate_descriptor(agent_template, Descriptor) when is_map(Descriptor) ->
    case exact_descriptor_keys(
           Descriptor, [template, sub_agents, metadata]) andalso
         maps:is_key(template, Descriptor) andalso
         valid_agent_template_data(maps:get(template, Descriptor)) andalso
         valid_template_dependencies(
           maps:get(sub_agents, Descriptor, [])) andalso
         valid_metadata(maps:get(metadata, Descriptor, #{})) of
        true -> ok;
        false -> {error, invalid_agent_template_descriptor}
    end;
validate_descriptor(Kind, _Descriptor) ->
    {error, {invalid_descriptor_shape, Kind}}.

valid_runtime_policy(Policy) ->
    try adk_runtime_policy:describe(Policy) of
        #{<<"status">> := <<"invalid">>} -> false;
        #{<<"schema_version">> := 1} -> true;
        _ -> false
    catch _:_ -> false
    end.

valid_agent_template_data(Template) when is_map(Template) ->
    case adk_json:normalize(Template) of
        {ok, Normalized} when is_map(Normalized) ->
            bounded_term(Normalized, ?MAX_TEMPLATE_BYTES);
        _ -> false
    end;
valid_agent_template_data(_Template) -> false.

valid_template_dependencies(Dependencies)
  when is_list(Dependencies),
       length(Dependencies) =< ?MAX_TEMPLATE_DEPENDENCIES ->
    case proper_unique_ids(Dependencies, #{}) of
        {ok, _} -> true;
        error -> false
    end;
valid_template_dependencies(_Dependencies) -> false.

proper_unique_ids([], Seen) -> {ok, Seen};
proper_unique_ids([Id | Rest], Seen) ->
    case valid_id(Id) andalso not maps:is_key(Id, Seen) of
        true -> proper_unique_ids(Rest, Seen#{Id => true});
        false -> error
    end.

validate_provider_target(Provider) when is_atom(Provider),
                                       Provider =/= undefined -> ok;
validate_provider_target(Provider) when is_binary(Provider) ->
    case valid_id(Provider) of
        true -> ok;
        false -> {error, invalid_provider_target}
    end;
validate_provider_target(_Provider) ->
    {error, invalid_provider_target}.

validate_toolset_descriptor(Descriptor)
  when is_tuple(Descriptor) ->
    case adk_toolset:is_descriptor(Descriptor) of
        true -> ok;
        false -> {error, invalid_toolset_descriptor}
    end;
validate_toolset_descriptor(#{toolset := Toolset} = Descriptor) ->
    case exact_descriptor_keys(Descriptor, [toolset, metadata]) andalso
         valid_metadata(maps:get(metadata, Descriptor, #{})) andalso
         adk_toolset:is_descriptor(Toolset) of
        true -> ok;
        false -> {error, invalid_toolset_descriptor}
    end;
validate_toolset_descriptor(_Descriptor) ->
    {error, invalid_toolset_descriptor}.

validate_tools(Tools) when is_list(Tools) ->
    case adk_toolset:expand_tools(Tools) of
        {ok, _Schemas} -> ok;
        {error, Reason} -> {error, {invalid_tool_pack, Reason}}
    end;
validate_tools(_Tools) ->
    {error, invalid_tool_pack}.

exact_descriptor_keys(Descriptor, Allowed) ->
    maps:keys(maps:without(Allowed, Descriptor)) =:= [].

valid_metadata(Value) -> is_map(Value).

valid_kind(provider) -> true;
valid_kind(mcp) -> true;
valid_kind(openapi) -> true;
valid_kind(tool_pack) -> true;
valid_kind(credential) -> true;
valid_kind(runtime_policy) -> true;
valid_kind(workflow) -> true;
valid_kind(agent_template) -> true;
valid_kind(_) -> false.

valid_id(Id) when is_binary(Id), byte_size(Id) > 0,
                              byte_size(Id) =< ?MAX_ID_BYTES ->
    case binary:bin_to_list(Id) of
        [First | Rest] -> valid_id_first(First) andalso
                          lists:all(fun valid_id_rest/1, Rest);
        [] -> false
    end;
valid_id(_Id) -> false.

valid_id_first(C) ->
    (C >= $a andalso C =< $z) orelse
    (C >= $A andalso C =< $Z) orelse
    (C >= $0 andalso C =< $9).

valid_id_rest(C) ->
    valid_id_first(C) orelse C =:= $. orelse C =:= $_ orelse C =:= $-.

valid_token(Token) when is_binary(Token), byte_size(Token) =:= 64 ->
    lists:all(
      fun(C) -> (C >= $0 andalso C =< $9) orelse
                (C >= $a andalso C =< $f)
      end, binary_to_list(Token));
valid_token(_Token) -> false.

valid_seal(Seal) -> is_binary(Seal) andalso byte_size(Seal) =:= 32.

seal_matches(Seal, Entries) ->
    try crypto:hash_equals(Seal, seal_entries(Entries))
    catch
        _:_ -> false
    end.

seal_entries(Entries) ->
    crypto:mac(hmac, sha256, snapshot_seal_key(),
               term_to_binary(Entries, [deterministic])).

snapshot_seal_key() ->
    case persistent_term:get(?SEAL_KEY, undefined) of
        Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
        undefined -> initialize_snapshot_seal_key()
    end.

initialize_snapshot_seal_key() ->
    Lock = {{?MODULE, snapshot_seal_key, node()}, self()},
    global:trans(
      Lock,
      fun() ->
          case persistent_term:get(?SEAL_KEY, undefined) of
              Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
              undefined ->
                  Key = crypto:strong_rand_bytes(32),
                  persistent_term:put(?SEAL_KEY, Key),
                  Key
          end
      end, [node()]).

valid_snapshot_entries(Entries) ->
    ExpectedKinds = lists:sort(kinds()),
    case lists:sort(maps:keys(Entries)) =:= ExpectedKinds andalso
         validate_registry_entries(Entries) =:= ok of
        true ->
            lists:all(
              fun(Kind) ->
                  Values = maps:get(Kind, Entries),
                  is_map(Values) andalso
                  map_size(Values) =< ?MAX_ENTRIES_PER_KIND andalso
                  lists:all(
                    fun({Id, Descriptor}) ->
                        valid_id(Id) andalso
                        validate_descriptor(Kind, Descriptor) =:= ok
                    end, maps:to_list(Values))
              end, kinds());
        false -> false
    end.

validate_registry_entries(Entries) ->
    case registry_size(Entries) of
        ok -> validate_agent_template_graph(
                maps:get(agent_template, Entries, #{}));
        {error, _} = Error -> Error
    end.

validate_agent_template_graph(Templates) when is_map(Templates) ->
    try validate_agent_template_roots(
          lists:sort(maps:keys(Templates)), Templates)
    catch _:_ -> {error, invalid_agent_template_registry}
    end;
validate_agent_template_graph(_Templates) ->
    {error, invalid_agent_template_registry}.

validate_agent_template_roots([], _Templates) -> ok;
validate_agent_template_roots([Id | Rest], Templates) ->
    case walk_agent_template(Id, Templates, 1, #{}, #{}) of
        {ok, _Visited} -> validate_agent_template_roots(Rest, Templates);
        {error, _} = Error -> Error
    end.

walk_agent_template(Id, _Templates, Depth, _Path, _Visited)
  when Depth > ?MAX_TEMPLATE_DEPTH ->
    {error, {agent_template_depth_limit_exceeded, Id,
             ?MAX_TEMPLATE_DEPTH}};
walk_agent_template(Id, Templates, Depth, Path, Visited) ->
    case {maps:is_key(Id, Path), maps:is_key(Id, Visited),
          map_size(Visited) >= ?MAX_TEMPLATE_NODES} of
        {true, _, _} -> {error, {agent_template_cycle, Id}};
        {false, true, _} -> {ok, Visited};
        {false, false, true} ->
            {error, {agent_template_count_limit_exceeded,
                     ?MAX_TEMPLATE_NODES}};
        {false, false, false} ->
            case maps:find(Id, Templates) of
                error -> {error, {unknown_agent_template_reference, Id}};
                {ok, Descriptor} when is_map(Descriptor) ->
                    Dependencies = maps:get(sub_agents, Descriptor, []),
                    walk_agent_template_dependencies(
                      Dependencies, Templates, Depth + 1,
                      Path#{Id => true}, Visited#{Id => true});
                {ok, _Invalid} ->
                    {error, invalid_agent_template_registry}
            end
    end.

walk_agent_template_dependencies([], _Templates, _Depth, _Path, Visited) ->
    {ok, Visited};
walk_agent_template_dependencies([Id | Rest], Templates, Depth,
                                 Path, Visited0) ->
    case walk_agent_template(Id, Templates, Depth, Path, Visited0) of
        {ok, Visited1} ->
            walk_agent_template_dependencies(
              Rest, Templates, Depth, Path, Visited1);
        {error, _} = Error -> Error
    end.

registry_instance_id(new_instance, Entries) ->
    case lists:all(fun(Values) -> map_size(Values) =:= 0 end,
                   maps:values(Entries)) of
        true ->
            binary:encode_hex(
              crypto:hash(sha256, ?EMPTY_INSTANCE_SEED), lowercase);
        false ->
            binary:encode_hex(crypto:strong_rand_bytes(32), lowercase)
    end;
registry_instance_id(InstanceId, _Entries)
  when is_binary(InstanceId), byte_size(InstanceId) =:= 64 ->
    InstanceId.

registry_snapshot_revision_id(1, new_instance, Entries) ->
    case lists:all(fun(Values) -> map_size(Values) =:= 0 end,
                   maps:values(Entries)) of
        true ->
            binary:encode_hex(
              crypto:hash(sha256, ?EMPTY_REVISION_SEED), lowercase);
        false -> random_id()
    end;
registry_snapshot_revision_id(_Generation, _InstanceId, _Entries) ->
    random_id().

random_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(32), lowercase).

registry_size(Entries) ->
    try erlang:external_size(Entries) of
        Bytes when Bytes =< ?MAX_REGISTRY_BYTES -> ok;
        _Bytes -> {error, config_registry_too_large}
    catch
        error:system_limit -> {error, config_registry_too_large};
        _:_ -> {error, invalid_config_registry_definitions}
    end.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.
