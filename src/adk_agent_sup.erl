-module(adk_agent_sup).
-behaviour(supervisor).

-export([start_link/0, start_agent/3]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Spawns a new ADK agent process dynamically under this supervisor.
start_agent(Name, LLMConfig, Tools) ->
    case adk_agent_config_store:put(Name, LLMConfig, Tools) of
        {ok, ConfigRef} ->
            case supervisor:start_child(?SERVER, [ConfigRef]) of
                {ok, _Pid} = Started -> Started;
                {ok, _Pid, _Info} = Started -> Started;
                {error, _Reason} = Error ->
                    ok = adk_agent_config_store:delete(ConfigRef),
                    Error
            end;
        {error, _Reason} = Error -> Error
    end.

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
