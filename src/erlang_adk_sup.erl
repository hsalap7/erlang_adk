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
    AgentSup = #{id => adk_agent_sup,
                 start => {adk_agent_sup, start_link, []},
                 restart => permanent,
                 shutdown => infinity,
                 type => supervisor,
                 modules => [adk_agent_sup]},
    ChildSpecs = [SessionOwner, Registry, AgentSup],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
