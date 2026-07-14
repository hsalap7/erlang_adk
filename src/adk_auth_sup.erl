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

    StoreOpts0 = maps:get(credential_store_opts, Opts, #{}),
    StoreOpts = StoreOpts0#{name => StoreName,
                            id => credential_store},
    RefreshOpts = #{name => RefreshSupName,
                    id => token_refresh_sup},
    ManagerOpts0 = maps:get(token_manager_opts, Opts, #{}),
    ManagerOpts = ManagerOpts0#{name => TokenManagerName,
                                store_module => StoreModule,
                                store_handle => StoreName,
                                refresh_sup => RefreshSupName,
                                id => token_manager},

    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 10},
    Children = [StoreModule:child_spec(StoreOpts),
                adk_token_refresh_sup:child_spec(RefreshOpts),
                adk_token_manager:child_spec(ManagerOpts)],
    {ok, {SupFlags, Children}}.

required_name(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Name when is_atom(Name), Name =/= undefined -> Name;
        Invalid -> erlang:error({invalid_auth_component_name, Key, Invalid})
    end.
