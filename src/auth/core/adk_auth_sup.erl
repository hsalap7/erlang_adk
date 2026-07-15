%% @doc Supervision tree for credential storage and token refresh.
%%
%% This supervisor is intentionally standalone until it is integrated into the
%% application's top-level tree. A rest_for_one strategy ensures loss of the
%% private credential table also replaces all refresh and cache state.
-module(adk_auth_sup).

-behaviour(supervisor).

-export([start_link/0, start_link/1, child_spec/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, ?MODULE) of
        undefined -> supervisor:start_link(?MODULE, Opts);
        Name when is_atom(Name) ->
            supervisor:start_link({local, Name}, ?MODULE, Opts)
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

init(Opts) ->
    StoreModule = maps:get(credential_store_module, Opts,
                           adk_credential_store_ets),
    StoreName = required_name(credential_store_name, Opts,
                              adk_credential_store_ets),
    RefreshSupName = required_name(refresh_sup_name, Opts,
                                   adk_token_refresh_sup),
    TokenManagerName = required_name(token_manager_name, Opts,
                                     adk_token_manager),
    FlowExchangeSupName = required_name(
                            authorization_exchange_sup_name, Opts,
                            adk_authorization_flow_exchange_sup),
    FlowName = required_name(authorization_flow_name, Opts,
                             adk_authorization_flow),

    StoreOpts0 = maps:get(credential_store_opts, Opts, #{}),
    StoreOpts = StoreOpts0#{name => StoreName,
                            id => credential_store},
    RefreshOpts = #{name => RefreshSupName,
                    id => token_refresh_sup},
    ManagerOpts0 = maps:get(token_manager_opts, Opts, #{}),
    %% Provider profiles are immutable for the lifetime of this supervision
    %% tree. A standalone supervisor accepts them directly; the application
    %% tree falls back to an empty, network-free configuration unless the host
    %% sets `auth_provider_profiles` before startup.
    ProviderProfiles = maps:get(
                         provider_profiles, Opts,
                         maps:get(
                           provider_profiles, ManagerOpts0,
                           application:get_env(
                             erlang_adk, auth_provider_profiles, #{}))),
    ManagerOpts = ManagerOpts0#{name => TokenManagerName,
                                store_module => StoreModule,
                                store_handle => StoreName,
                                refresh_sup => RefreshSupName,
                                provider_profiles => ProviderProfiles,
                                id => token_manager},

    FlowExchangeOpts = #{name => FlowExchangeSupName,
                         id => authorization_flow_exchange_sup},
    FlowOpts0 = maps:get(authorization_flow_opts, Opts, #{}),
    %% Raw profiles can contain an OAuth client secret, so they are never
    %% copied into a child specification. Embedders that do not use the
    %% application environment provide a zero-arity module/function loader;
    %% the safe MFA is all a supervisor report can expose.
    ok = ensure_no_raw_flow_profiles(Opts, FlowOpts0),
    ProfileLoader = maps:get(
                      authorization_profile_loader, Opts,
                      application:get_env(
                        erlang_adk,
                        auth_authorization_profile_loader,
                        undefined)),
    FlowOptsBase = case ProfileLoader of
        undefined -> FlowOpts0;
        {Module, Function}
          when is_atom(Module), Module =/= undefined,
               is_atom(Function), Function =/= undefined ->
            FlowOpts0#{profile_loader => {Module, Function}};
        InvalidLoader ->
            erlang:error({invalid_authorization_profile_loader,
                          InvalidLoader})
    end,
    FlowOpts1 = FlowOptsBase#{name => FlowName,
                              store_module => StoreModule,
                              store_handle => StoreName,
                              exchange_sup => FlowExchangeSupName,
                              id => authorization_flow},
    %% For the normal application tree the flow reads immutable profiles from
    %% auth_authorization_profiles inside init/1. Keeping them out of this
    %% child spec prevents client secrets from appearing in supervisor reports.
    FlowOpts = FlowOpts1,

    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 10},
    Children = [StoreModule:child_spec(StoreOpts),
                adk_token_refresh_sup:child_spec(RefreshOpts),
                adk_token_manager:child_spec(ManagerOpts),
                adk_authorization_flow_exchange_sup:child_spec(
                  FlowExchangeOpts),
                adk_authorization_flow:child_spec(FlowOpts)],
    {ok, {SupFlags, Children}}.

required_name(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Name when is_atom(Name), Name =/= undefined -> Name;
        Invalid -> erlang:error({invalid_auth_component_name, Key, Invalid})
    end.

ensure_no_raw_flow_profiles(Opts, FlowOpts) ->
    case maps:is_key(authorization_profiles, Opts) orelse
         maps:is_key(provider_profiles, FlowOpts) of
        true -> erlang:error(raw_authorization_profiles_not_allowed);
        false -> ok
    end.
