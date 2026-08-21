%%%-------------------------------------------------------------------
%% @doc erlang_adk top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(erlang_adk_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    %% Session-table, registry, and agent lifetimes are coupled. If the ETS owner
    %% or registry dies, rest_for_one also replaces the downstream services and
    %% agents so none continue against lost storage or stale registrations.
    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 10},
    SessionOwner = #{id => erlang_adk_session_owner,
                     start => {erlang_adk_session_owner, start_link, []},
                     restart => permanent,
                     shutdown => 5000,
                     type => worker,
                     modules => [erlang_adk_session_owner]},
    RuntimeServiceSpecs = runtime_service_child_specs(),
    Registry = #{id => adk_agent_registry,
                 start => {adk_agent_registry, start_link, []},
                 restart => permanent,
                 shutdown => 5000,
                 type => worker,
                 modules => [adk_agent_registry]},
    AgentConfigStore = adk_agent_config_store:child_spec(#{}),
    %% Stateful plugin instances are serialized and isolated below their own
    %% dynamic supervisor. Keep it ahead of agents so a runtime replacement
    %% also replaces downstream consumers under rest_for_one.
    PluginRuntimeSup = adk_plugin_runtime_sup:child_spec(),
    AgentSup = #{id => adk_agent_sup,
                 start => {adk_agent_sup, start_link, []},
                 restart => permanent,
                 shutdown => infinity,
                 type => supervisor,
                 modules => [adk_agent_sup]},
    AgentTurnSup = adk_agent_turn_sup:child_spec(#{}),
    %% Blocking model/tool work is independently supervised. Keep every
    %% registry immediately ahead of its dynamic supervisor. Tasks sit before
    %% runs because invocations may own tasks; rest_for_one can therefore never
    %% leave a run attached to a stale task registry.
    TaskRegistry = adk_task_registry:child_spec(#{}),
    TaskSup = adk_task_sup:child_spec(#{}),
    EvaluationServiceSpecs = evaluation_service_child_specs(),
    RunRegistry = adk_run_registry:child_spec(#{}),
    InvocationSup = adk_invocation_sup:child_spec(#{}),
    ContextCapabilitySup = adk_context_capability_sup:child_spec(#{}),
    MemoryIngestSup = adk_memory_ingest_sup:child_spec(#{}),
    MemoryOutboxSpecs = memory_outbox_child_specs(),
    AdmissionControl = adk_admission_control:child_spec(
                         application:get_env(
                           erlang_adk, admission_control, #{})),
    AmbientSup = adk_ambient_sup:child_spec(#{}),
    AuthSup = adk_auth_sup:child_spec(#{}),
    OidcProviderSup = adk_oidc_provider_sup:child_spec(
                        #{providers => application:get_env(
                                         erlang_adk, oidc_providers, [])}),
    McpClientSup = adk_mcp_client_sup:child_spec(#{}),
    WorkflowSup = adk_workflow_sup:child_spec(#{}),
    %% Registry failure restarts the downstream Live supervisor under
    %% rest_for_one, so no session can outlive lost exclusive voice leases.
    LiveVoiceRegistry = adk_live_voice_registry:child_spec(#{}),
    LiveSessionSup = adk_live_session_sup:child_spec(#{}),
    ChildSpecs = [SessionOwner] ++ RuntimeServiceSpecs ++
                 MemoryOutboxSpecs ++
                 trace_store_child_specs() ++
                 developer_payload_child_specs() ++
                 [Registry, AgentConfigStore,
                  PluginRuntimeSup, AgentSup,
                  AgentTurnSup,
                  TaskRegistry, TaskSup] ++
                 EvaluationServiceSpecs ++
                 [RunRegistry, InvocationSup, ContextCapabilitySup,
                  MemoryIngestSup,
                  AdmissionControl, AmbientSup,
                  AuthSup, OidcProviderSup, McpClientSup,
                  WorkflowSup, LiveVoiceRegistry, LiveSessionSup] ++
                 a2a_v1_child_specs() ++ http_child_specs() ++
                 observability_child_specs(),
    {ok, {SupFlags, ChildSpecs}}.

runtime_service_child_specs() ->
    case application:get_env(
           erlang_adk, runtime_service_profile, disabled) of
        disabled -> [];
        Profile when Profile =:= ephemeral_local;
                     Profile =:= durable_local ->
            Config0 = application:get_env(
                        erlang_adk, runtime_service_profile_config, #{}),
            case is_map(Config0) of
                true ->
                    Config = runtime_service_profile_config(Profile, Config0),
                    [adk_runtime_service_bundle:child_spec(
                       #{id => adk_runtime_service_bundle,
                         name => adk_runtime_service_bundle,
                         profile => Profile, config => Config})];
                false ->
                    erlang:error(
                      {invalid_application_env,
                       runtime_service_profile_config, Config0})
            end;
        Invalid ->
            erlang:error(
              {invalid_application_env, runtime_service_profile, Invalid})
    end.

evaluation_service_child_specs() ->
    case application:get_env(
           erlang_adk, evaluation_service_enabled, false) of
        false -> [];
        true -> [evaluation_service_child_spec()];
        Invalid ->
            erlang:error(
              {invalid_application_env, evaluation_service_enabled, Invalid})
    end.

evaluation_service_child_spec() ->
    StoreKind = application:get_env(
                  erlang_adk, evaluation_store, ets),
    StoreOptions = application:get_env(
                     erlang_adk, evaluation_store_options, #{}),
    ServiceOptions = application:get_env(
                       erlang_adk, evaluation_service_options, #{}),
    Store = case StoreKind of
        ets -> {owned, adk_eval_store_ets, StoreOptions};
        mnesia -> {owned, adk_eval_store_mnesia, StoreOptions};
        _ -> invalid
    end,
    Name = case is_map(ServiceOptions) of
        true -> maps:get(name, ServiceOptions, adk_eval_service);
        false -> invalid
    end,
    case {Store, is_map(StoreOptions), is_map(ServiceOptions),
          is_atom(Name) andalso Name =/= undefined,
          is_map(ServiceOptions) andalso
              not maps:is_key(store, ServiceOptions)} of
        {invalid, _, _, _, _} ->
            erlang:error(
              {invalid_application_env, evaluation_store, StoreKind});
        {_, false, _, _, _} ->
            erlang:error(
              {invalid_application_env,
               evaluation_store_options, StoreOptions});
        {_, _, false, _, _} ->
            erlang:error(
              {invalid_application_env,
               evaluation_service_options, ServiceOptions});
        {_, _, _, false, _} ->
            erlang:error(
              {invalid_application_env, evaluation_service_name, Name});
        {_, _, _, _, false} ->
            erlang:error(
              {invalid_application_env,
               evaluation_service_options, store_is_managed});
        {OwnedStore, true, true, true, true} ->
            adk_eval_service:child_spec(
              ServiceOptions#{name => Name, store => OwnedStore})
    end.

trace_store_child_specs() ->
    case application:get_env(erlang_adk, trace_store_enabled, false) of
        false -> [];
        true ->
            Options = application:get_env(
                        erlang_adk, trace_store_options, #{}),
            Name = case is_map(Options) of
                true -> maps:get(name, Options, adk_trace_store);
                false -> invalid
            end,
            case is_map(Options) andalso is_atom(Name) andalso
                 Name =/= undefined of
                true -> [adk_trace_store:child_spec(
                           Options#{name => Name})];
                false ->
                    erlang:error(
                      {invalid_application_env, trace_store_options, Options})
            end;
        Invalid ->
            erlang:error(
              {invalid_application_env, trace_store_enabled, Invalid})
    end.

developer_payload_child_specs() ->
    case application:get_env(
           erlang_adk, dev_provider_payload_inspection, false) of
        false -> [];
        #{enabled := true} = Config0 ->
            case application:get_env(erlang_adk, dev_enabled, false) of
                true ->
                    Config = maps:remove(enabled, Config0),
                    case adk_dev_payload_store:validate_options(Config) of
                        {ok, #{name := Name} = SafeConfig}
                          when is_atom(Name), Name =/= undefined ->
                            [adk_dev_payload_store:child_spec(SafeConfig)];
                        {ok, _} ->
                            erlang:error(
                              {invalid_application_env,
                               dev_provider_payload_inspection,
                               named_store_required});
                        {error, Reason} ->
                            erlang:error(
                              {invalid_application_env,
                               dev_provider_payload_inspection, Reason})
                    end;
                _ ->
                    erlang:error(
                      {invalid_application_env,
                       dev_provider_payload_inspection,
                       requires_developer_ui})
            end;
        Invalid ->
            erlang:error(
              {invalid_application_env,
               dev_provider_payload_inspection, Invalid})
    end.

memory_outbox_child_specs() ->
    Profile = application:get_env(
                erlang_adk, runtime_service_profile, disabled),
    case {Profile,
          application:get_env(erlang_adk, memory_outbox_enabled, false)} of
        {durable_local, false} -> [];
        {durable_local, true} ->
            _ = independent_memory_outbox_options(),
            [];
        {_OtherProfile, false} -> [];
        {_OtherProfile, true} ->
            Options = independent_memory_outbox_options(),
            [adk_memory_outbox_sup:child_spec(Options)];
        {_Profile, Invalid} ->
            erlang:error({invalid_application_env,
                          memory_outbox_enabled, Invalid})
    end.

runtime_service_profile_config(durable_local, Config) ->
    case application:get_env(erlang_adk, memory_outbox_enabled, false) of
        false -> Config;
        true ->
            Compatibility = independent_memory_outbox_options(),
            Configured = maps:get(memory_outbox, Config, #{}),
            case is_map(Configured) of
                true ->
                    Config#{memory_outbox =>
                                merge_memory_outbox_options(
                                  Compatibility, Configured)};
                false ->
                    erlang:error(
                      {invalid_application_env,
                       runtime_service_profile_config, Config})
            end;
        Invalid ->
            erlang:error({invalid_application_env,
                          memory_outbox_enabled, Invalid})
    end;
runtime_service_profile_config(_Profile, Config) -> Config.

merge_memory_outbox_options(Compatibility, Configured) ->
    Merged = maps:merge(Compatibility, Configured),
    lists:foldl(
      fun(Key, Options) ->
              case {maps:find(Key, Compatibility),
                    maps:find(Key, Configured)} of
                  {{ok, Legacy}, {ok, Override}}
                    when is_map(Legacy), is_map(Override) ->
                      Options#{Key => maps:merge(Legacy, Override)};
                  _ ->
                      Options
              end
      end,
      Merged,
      [outbox, registry, processor]).

independent_memory_outbox_options() ->
    Options = application:get_env(
                erlang_adk, memory_outbox_options, #{}),
    case is_map(Options) of
        true -> Options;
        false ->
            erlang:error({invalid_application_env,
                          memory_outbox_options, Options})
    end.

%% internal functions

a2a_v1_child_specs() ->
    case application:get_env(erlang_adk, a2a_v1_enabled, false) of
        true ->
            Options = application:get_env(
                        erlang_adk, a2a_v1_server_options, #{}),
            [adk_a2a_v1_server:child_spec(Options)];
        false -> [];
        Invalid ->
            erlang:error({invalid_application_env, a2a_v1_enabled, Invalid})
    end.

http_child_specs() ->
    A2AEnabled = application:get_env(erlang_adk, a2a_enabled, false),
    A2AV1Enabled = application:get_env(erlang_adk, a2a_v1_enabled, false),
    HealthEnabled = application:get_env(
                      erlang_adk, http_health_enabled, false),
    DevEnabled = application:get_env(erlang_adk, dev_enabled, false),
    case {A2AEnabled, A2AV1Enabled, HealthEnabled, DevEnabled} of
        {false, false, false, false} -> [];
        {A2A, A2AV1, Health, Dev}
          when is_boolean(A2A), is_boolean(A2AV1),
               is_boolean(Health), is_boolean(Dev) ->
            [#{id => erlang_adk_http,
               start => {erlang_adk_http, start_link, []},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [erlang_adk_http]}];
        {Invalid, _, _, _} when not is_boolean(Invalid) ->
            erlang:error({invalid_application_env, a2a_enabled, Invalid});
        {_, Invalid, _, _} when not is_boolean(Invalid) ->
            erlang:error({invalid_application_env, a2a_v1_enabled, Invalid});
        {_, _, Invalid, _} when not is_boolean(Invalid) ->
            erlang:error(
              {invalid_application_env, http_health_enabled, Invalid});
        {_, _, _, Invalid} ->
            erlang:error({invalid_application_env, dev_enabled, Invalid})
    end.

observability_child_specs() ->
    MetricsOptions = application:get_env(
                       erlang_adk, observability_metrics_options, #{}),
    BusEnabled = application:get_env(
                   erlang_adk, observability_bus_enabled, false),
    BusOptions = application:get_env(
                   erlang_adk, observability_bus_options, #{}),
    EffectiveBus = adk_trace_runtime:bus_enabled(BusEnabled),
    EffectiveOptions = adk_trace_runtime:configure_bus_options(BusOptions),
    case {is_map(MetricsOptions), EffectiveBus, EffectiveOptions} of
        {true, {ok, false}, {ok, _SafeBusOptions}} ->
            [adk_observability_metrics:child_spec(MetricsOptions)];
        {true, {ok, true}, {ok, SafeBusOptions}} ->
            [adk_observability_metrics:child_spec(MetricsOptions),
             adk_observability_bus:child_spec(SafeBusOptions)];
        {false, _, _} ->
            erlang:error({invalid_application_env,
                          observability_metrics_options, MetricsOptions});
        {_, {error, Reason}, _} -> erlang:error(Reason);
        {_, _, {error, Reason}} -> erlang:error(Reason)
    end.
