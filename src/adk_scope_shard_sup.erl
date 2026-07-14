%% @doc Per-service dynamic supervisor for independently executing scope shards.
-module(adk_scope_shard_sup).
-behaviour(supervisor).

-export([start_link/0, start_adapter/3, stop_adapter/2]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link(?MODULE, []).

-spec start_adapter(pid(), module(), map()) ->
    {ok, pid(), reference()} | {error, term()}.
start_adapter(Supervisor, Adapter, Config)
  when is_pid(Supervisor), is_atom(Adapter), is_map(Config) ->
    ChildId = make_ref(),
    ChildSpec = #{id => ChildId,
                  start => {Adapter, start_link, [Config]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [Adapter]},
    case supervisor:start_child(Supervisor, ChildSpec) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid, ChildId};
        {ok, Pid, _Info} when is_pid(Pid) -> {ok, Pid, ChildId};
        {error, _} = Error -> Error
    end;
start_adapter(_Supervisor, _Adapter, _Config) ->
    {error, invalid_scope_shard_child}.

-spec stop_adapter(pid(), reference()) -> ok.
stop_adapter(Supervisor, ChildId)
  when is_pid(Supervisor), is_reference(ChildId) ->
    _ = supervisor:terminate_child(Supervisor, ChildId),
    _ = supervisor:delete_child(Supervisor, ChildId),
    ok.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 20,
            period => 10}, []}}.
