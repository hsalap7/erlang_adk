%% @doc Strict compiler for the built-in local runtime-service profiles.
%%
%% Profiles deliberately select adapters rather than accepting module names
%% from configuration.  This makes the durability promise of a named profile
%% stable and keeps untrusted configuration from widening the code-loading
%% boundary.
-module(adk_runtime_service_profile).

-export([profiles/0, compile/2]).

-type profile() :: ephemeral_local | durable_local.
-type plan() :: map().
-export_type([profile/0, plan/0]).

-define(ARTIFACT_ETS_KEYS,
        [max_artifact_bytes, max_total_bytes, max_scope_bytes,
         max_total_artifacts, max_scope_artifacts, max_page_limit,
         legacy_list_limit]).
-define(ARTIFACT_FS_KEYS,
        [max_artifact_bytes, max_page_limit, legacy_list_limit,
         max_scan_entries, recovery_grace_ms]).
-define(MEMORY_KEYS,
        [max_content_bytes, max_metadata_bytes, max_metadata_depth,
         max_metadata_nodes, max_query_bytes, max_results,
         max_result_bytes, max_entries, max_total_bytes,
         max_events_per_request, call_timeout]).
-define(COMPONENT_KEYS,
        [adapter_config, max_active_scopes, max_router_queue,
         idle_scope_timeout_ms]).
-define(DURABLE_MEMORY_ADAPTER_ID,
        <<"durable-local-memory-v1">>).

-spec profiles() -> [profile()].
profiles() -> [ephemeral_local, durable_local].

-spec compile(profile(), map()) -> {ok, plan()} | {error, term()}.
compile(ephemeral_local, Config) when is_map(Config) ->
    compile_ephemeral(Config);
compile(durable_local, Config) when is_map(Config) ->
    compile_durable(Config);
compile(Profile, Config) when not is_map(Config) ->
    {error, {invalid_runtime_service_profile_config,
             Profile, expected_map}};
compile(Profile, _Config) ->
    {error, {unknown_runtime_service_profile, Profile}}.

compile_ephemeral(Config) ->
    case reject_unknown(Config, [artifact, memory], ephemeral_local) of
        ok ->
            compile_components(
              ephemeral_local, ephemeral,
              erlang_adk_session,
              adk_artifact_ets, ?ARTIFACT_ETS_KEYS,
              adk_memory_ets, Config, undefined);
        {error, _} = Error -> Error
    end.

compile_durable(Config) ->
    case reject_unknown(
           Config,
           [artifact_root, artifact, memory, artifact_journal,
            memory_outbox],
           durable_local) of
        ok ->
            case normalize_absolute_root(
                   maps:get(artifact_root, Config, undefined)) of
                {ok, Root} ->
                    compile_durable_components(Config, Root);
                {error, Reason} ->
                    {error, {invalid_runtime_service_profile_config,
                             durable_local, {artifact_root, Reason}}}
            end;
        {error, _} = Error -> Error
    end.

compile_durable_components(Config, Root) ->
    JournalConfig = maps:get(artifact_journal, Config, #{}),
    OutboxOptions = maps:get(memory_outbox, Config, #{}),
    case {adk_artifact_effect_journal:validate_config(JournalConfig),
          compile_memory_outbox(OutboxOptions)} of
        {ok, {ok, MemoryOutbox}} ->
            case compile_components(
                   durable_local, durable,
                   erlang_adk_session_mnesia,
                   adk_artifact_fs, ?ARTIFACT_FS_KEYS,
                   adk_memory_mnesia, Config, Root) of
                {ok, Plan} ->
                    {ok, Plan#{artifact_effect_journal =>
                                   #{config => JournalConfig},
                               memory_outbox => MemoryOutbox}};
                {error, _} = Error -> Error
            end;
        {{error, Reason}, _} ->
            {error, {invalid_runtime_service_profile_config,
                     durable_local, {artifact_journal, Reason}}};
        {_, {error, Reason}} ->
            {error, {invalid_runtime_service_profile_config,
                     durable_local, {memory_outbox, Reason}}}
    end.

compile_memory_outbox(Options) when is_map(Options) ->
    case adk_memory_outbox_sup:validate_options(Options) of
        ok ->
            OutboxConfig = maps:get(outbox, Options, #{}),
            case adk_memory_outbox:compile_config(OutboxConfig) of
                {ok, Store} ->
                    Limits = maps:get(limits, Store),
                    MaxAttempts = maps:get(default_max_attempts, Limits),
                    case MaxAttempts =< 10 of
                        true ->
                            {ok, #{options => Options,
                                   store => Store,
                                   ingestion =>
                                       #{mode => durable,
                                         adapter_id =>
                                             ?DURABLE_MEMORY_ADAPTER_ID,
                                         max_attempts => MaxAttempts}}};
                        false ->
                            {error,
                             {memory_outbox_runner_max_attempts_exceeded,
                              MaxAttempts}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
compile_memory_outbox(_) ->
    {error, invalid_memory_outbox_supervisor_options}.

compile_components(Profile, Durability, SessionService,
                   ArtifactAdapter, ArtifactKeys,
                   MemoryAdapter, Config, Root) ->
    Artifact0 = maps:get(artifact, Config, #{}),
    Memory0 = maps:get(memory, Config, #{}),
    case {compile_component(artifact, Artifact0, ArtifactKeys),
          compile_component(memory, Memory0, ?MEMORY_KEYS)} of
        {{ok, ArtifactConfig0}, {ok, MemoryConfig}} ->
            case validate_adapter_configs(
                   ArtifactAdapter, ArtifactConfig0,
                   MemoryConfig) of
                ok ->
                    ArtifactConfig = put_artifact_root(
                                       ArtifactConfig0, Root),
                    ScopeStrategy = case Durability of
                        ephemeral -> shared;
                        durable -> exact_scope
                    end,
                    {ok,
                     #{profile => Profile,
                       durability => Durability,
                       session_service => SessionService,
                       artifact =>
                           #{module => adk_artifact_sharded,
                             adapter => ArtifactAdapter,
                             config => ArtifactConfig#{
                                         adapter => ArtifactAdapter,
                                         scope_strategy => ScopeStrategy}},
                       memory =>
                           #{module => adk_memory_sharded,
                             adapter => MemoryAdapter,
                             config => MemoryConfig#{
                                       adapter => MemoryAdapter,
                                       scope_strategy => ScopeStrategy}}}};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

compile_component(Kind, Config, AdapterKeys) when is_map(Config) ->
    Unknown = lists:sort(
                maps:keys(maps:without(?COMPONENT_KEYS, Config))),
    AdapterConfig = maps:get(adapter_config, Config, #{}),
    MaxScopes = maps:get(max_active_scopes, Config, 1024),
    MaxQueue = maps:get(max_router_queue, Config, 256),
    IdleTimeout = maps:get(idle_scope_timeout_ms, Config, 60000),
    case {Unknown, is_map(AdapterConfig),
          positive_integer(MaxScopes), positive_integer(MaxQueue),
          positive_integer(IdleTimeout) andalso
              IdleTimeout =< 86400000} of
        {[_ | _], _, _, _, _} ->
            component_error(Kind, {unknown_keys, Unknown});
        {[], false, _, _, _} ->
            component_error(Kind, adapter_config);
        {[], true, false, _, _} ->
            component_error(Kind, max_active_scopes);
        {[], true, true, false, _} ->
            component_error(Kind, max_router_queue);
        {[], true, true, true, false} ->
            component_error(Kind, idle_scope_timeout_ms);
        {[], true, true, true, true} ->
            case reject_adapter_unknown(Kind, AdapterConfig, AdapterKeys) of
                ok ->
                    {ok,
                     #{adapter_config => AdapterConfig,
                       max_active_scopes => MaxScopes,
                       max_router_queue => MaxQueue,
                       idle_scope_timeout_ms => IdleTimeout}};
                {error, _} = Error -> Error
            end
    end;
compile_component(Kind, _Config, _AdapterKeys) ->
    component_error(Kind, expected_map).

reject_adapter_unknown(Kind, Config, Allowed) ->
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Config))),
    case Unknown of
        [] -> ok;
        _ -> component_error(Kind, {adapter_unknown_keys, Unknown})
    end.

reject_unknown(Config, Allowed, Profile) ->
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Config))),
    case Unknown of
        [] -> ok;
        _ ->
            {error, {invalid_runtime_service_profile_config,
                     Profile, {unknown_keys, Unknown}}}
    end.

component_error(Kind, Reason) ->
    {error, {invalid_runtime_service_component_config, Kind, Reason}}.

validate_adapter_configs(ArtifactAdapter, ArtifactConfig, MemoryConfig) ->
    ArtifactOptions = maps:get(adapter_config, ArtifactConfig),
    MemoryOptions = maps:get(adapter_config, MemoryConfig),
    case validate_artifact_adapter_config(
           ArtifactAdapter, ArtifactOptions) of
        ok ->
            case adk_memory_contract:compile_config(MemoryOptions) of
                {ok, _Limits} -> ok;
                {error, Reason} ->
                    component_error(memory, {adapter_config, Reason})
            end;
        {error, Reason} ->
            component_error(artifact, {adapter_config, Reason})
    end.

validate_artifact_adapter_config(adk_artifact_ets, Config) ->
    Defaults =
        #{max_artifact_bytes => 64 * 1024 * 1024,
          max_total_bytes => 512 * 1024 * 1024,
          max_scope_bytes => 256 * 1024 * 1024,
          max_total_artifacts => 100000,
          max_scope_artifacts => 25000,
          max_page_limit => 1000,
          legacy_list_limit => 1000},
    Limits = maps:merge(Defaults, Config),
    case {all_positive(Limits),
          maps:get(max_artifact_bytes, Limits) =<
              maps:get(max_scope_bytes, Limits),
          maps:get(max_scope_bytes, Limits) =<
              maps:get(max_total_bytes, Limits),
          maps:get(max_scope_artifacts, Limits) =<
              maps:get(max_total_artifacts, Limits)} of
        {true, true, true, true} -> ok;
        {false, _, _, _} -> {error, invalid_config_limit};
        {_, false, _, _} -> {error, invalid_max_artifact_bytes};
        {_, _, false, _} -> {error, invalid_max_scope_bytes};
        {_, _, _, false} -> {error, invalid_max_scope_artifacts}
    end;
validate_artifact_adapter_config(adk_artifact_fs, Config) ->
    Defaults =
        #{max_artifact_bytes => 64 * 1024 * 1024,
          max_page_limit => 1000,
          legacy_list_limit => 1000,
          max_scan_entries => 10000,
          recovery_grace_ms => 300000},
    Limits = maps:merge(Defaults, Config),
    Positive = maps:with(
                 [max_artifact_bytes, max_page_limit,
                  legacy_list_limit, max_scan_entries], Limits),
    Grace = maps:get(recovery_grace_ms, Limits),
    case {all_positive(Positive),
          is_integer(Grace) andalso Grace >= 0,
          maps:get(max_scan_entries, Limits) >= 3,
          maps:get(max_page_limit, Limits) =<
              maps:get(max_scan_entries, Limits),
          maps:get(legacy_list_limit, Limits) =<
              maps:get(max_scan_entries, Limits)} of
        {true, true, true, true, true} -> ok;
        {false, _, _, _, _} -> {error, invalid_config_limit};
        {_, false, _, _, _} -> {error, invalid_recovery_grace_ms};
        {_, _, false, _, _} -> {error, invalid_max_scan_entries};
        {_, _, _, false, _} -> {error, invalid_max_page_limit};
        {_, _, _, _, false} -> {error, invalid_legacy_list_limit}
    end.

all_positive(Map) ->
    lists:all(
      fun({_Key, Value}) -> is_integer(Value) andalso Value > 0 end,
      maps:to_list(Map)).

put_artifact_root(Config, undefined) -> Config;
put_artifact_root(Config, Root) ->
    AdapterConfig = maps:get(adapter_config, Config),
    Config#{adapter_config => AdapterConfig#{root => Root}}.

normalize_absolute_root(undefined) -> {error, required};
normalize_absolute_root(Root) when is_binary(Root), byte_size(Root) > 0 ->
    case valid_utf8(Root) andalso binary:match(Root, <<0>>) =:= nomatch of
        true ->
            Path = binary_to_list(Root),
            case filename:pathtype(Path) of
                absolute -> {ok, filename:absname(Path)};
                _ -> {error, must_be_absolute}
            end;
        false -> {error, invalid}
    end;
normalize_absolute_root(Root) when is_list(Root), Root =/= [] ->
    try unicode:characters_to_binary(Root) of
        Binary when is_binary(Binary) -> normalize_absolute_root(Binary);
        _ -> {error, invalid}
    catch
        _:_ -> {error, invalid}
    end;
normalize_absolute_root(_Root) -> {error, invalid}.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

positive_integer(Value) -> is_integer(Value) andalso Value > 0.
