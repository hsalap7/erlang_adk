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
    Registry = #{id => adk_agent_registry,
                 start => {adk_agent_registry, start_link, []},
                 restart => permanent,
                 shutdown => 5000,
                 type => worker,
                 modules => [adk_agent_registry]},
    AgentConfigStore = adk_agent_config_store:child_spec(#{}),
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
    ChildSpecs = [SessionOwner, Registry, AgentConfigStore, AgentSup,
                  AgentTurnSup,
                  TaskRegistry, TaskSup,
                  RunRegistry, InvocationSup, ContextCapabilitySup,
                  MemoryIngestSup,
                  AdmissionControl, AmbientSup,
                  AuthSup, OidcProviderSup, McpClientSup,
                  WorkflowSup] ++ MemoryOutboxSpecs ++
                 a2a_v1_child_specs() ++ http_child_specs(),
    {ok, {SupFlags, ChildSpecs}}.

memory_outbox_child_specs() ->
    case application:get_env(erlang_adk, memory_outbox_enabled, false) of
        false -> [];
        true ->
            Options = application:get_env(
                        erlang_adk, memory_outbox_options, #{}),
            case is_map(Options) of
                true -> [adk_memory_outbox_sup:child_spec(Options)];
                false ->
                    erlang:error({invalid_application_env,
                                  memory_outbox_options, Options})
            end;
        Invalid ->
            erlang:error({invalid_application_env,
                          memory_outbox_enabled, Invalid})
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
    DevEnabled = application:get_env(erlang_adk, dev_enabled, false),
    case {A2AEnabled, A2AV1Enabled, DevEnabled} of
        {false, false, false} -> [];
        {A2A, A2AV1, Dev}
          when is_boolean(A2A), is_boolean(A2AV1), is_boolean(Dev) ->
            [#{id => erlang_adk_http,
               start => {erlang_adk_http, start_link, []},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [erlang_adk_http]}];
        {Invalid, _, _} when not is_boolean(Invalid) ->
            erlang:error({invalid_application_env, a2a_enabled, Invalid});
        {_, Invalid, _} when not is_boolean(Invalid) ->
            erlang:error({invalid_application_env, a2a_v1_enabled, Invalid});
        {_, _, Invalid} ->
            erlang:error({invalid_application_env, dev_enabled, Invalid})
    end.
