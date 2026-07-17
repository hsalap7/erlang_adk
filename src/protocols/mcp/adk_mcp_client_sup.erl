%% @doc Dynamic supervisor for independently-failing MCP client sessions.
-module(adk_mcp_client_sup).
-behaviour(supervisor).

-export([start_link/0, start_client/1, child_spec/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_client(term()) -> supervisor:startchild_ret().
start_client(Init) ->
    supervisor:start_child(?MODULE, [Init]).

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(_Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

init([]) ->
    Child = #{id => adk_mcp_client,
              start => {adk_mcp_client, start_link, []},
              restart => temporary,
              shutdown => 5000,
              type => worker,
              modules => [adk_mcp_client]},
    {ok, {#{strategy => simple_one_for_one,
            intensity => 10,
            period => 10}, [Child]}}.
