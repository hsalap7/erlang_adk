-module(adk_agent_sup).
-behaviour(supervisor).

-export([start_link/0, start_agent/3]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Spawns a new ADK agent process dynamically under this supervisor.
start_agent(Name, LLMConfig, Tools) ->
    supervisor:start_child(?SERVER, [Name, LLMConfig, Tools]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 5,
                 period => 10},
    ChildSpecs = [
        #{id => adk_agent,
          start => {adk_agent, start_link, []},
          restart => transient,
          shutdown => 5000,
          type => worker,
          modules => [adk_agent]}
    ],
    {ok, {SupFlags, ChildSpecs}}.
