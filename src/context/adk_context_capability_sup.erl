%% @doc Dynamic supervisor for invocation-owned context capabilities.
-module(adk_context_capability_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_capability/2]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec child_spec(term()) -> supervisor:child_spec().
child_spec(_Opts) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

-spec start_capability(pid(), map()) ->
    {ok, pid(), reference()} | {error, term()}.
start_capability(Owner, Spec) when is_pid(Owner), is_map(Spec) ->
    ChildRef = make_ref(),
    ChildSpec = #{id => ChildRef,
                  start => {adk_context_capability, start_link,
                            [Owner, Spec]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [adk_context_capability]},
    case supervisor:start_child(?SERVER, ChildSpec) of
        {ok, Pid} -> {ok, Pid, ChildRef};
        {ok, Pid, _Info} -> {ok, Pid, ChildRef};
        {error, _} = Error -> Error
    end;
start_capability(_Owner, _Spec) ->
    {error, invalid_context_capability_spec}.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 10,
            period => 10}, []}}.
