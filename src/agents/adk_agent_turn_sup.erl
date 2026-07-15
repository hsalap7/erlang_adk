%% @doc Dynamic supervisor for one coordinator per active direct agent turn.
-module(adk_agent_turn_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_turn/4]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec child_spec(term()) -> supervisor:child_spec().
child_spec(_Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

-spec start_turn(pid(), reference(), fun(() -> term()),
                 infinity | non_neg_integer()) -> supervisor:startchild_ret().
start_turn(Owner, TurnRef, Work, Timeout)
  when is_pid(Owner), is_reference(TurnRef), is_function(Work, 0),
       (Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)) ->
    ChildSpec = #{id => TurnRef,
                  start => {adk_agent_turn_worker, start_link,
                            [Owner, TurnRef, Timeout]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [adk_agent_turn_worker]},
    case supervisor:start_child(?MODULE, ChildSpec) of
        {ok, Pid} -> handoff_work(TurnRef, Pid, Work);
        {ok, Pid, Info} ->
            case handoff_work(TurnRef, Pid, Work) of
                {ok, Pid} -> {ok, Pid, Info};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 50,
            period => 10}, []}}.

handoff_work(TurnRef, Pid, Work) ->
    try adk_agent_turn_worker:assign_work(Pid, Work) of
        ok -> {ok, Pid};
        {error, _Reason} ->
            _ = supervisor:terminate_child(?MODULE, TurnRef),
            {error, agent_turn_work_handoff_failed}
    catch
        _Class:_Reason ->
            _ = supervisor:terminate_child(?MODULE, TurnRef),
            {error, agent_turn_work_handoff_failed}
    end.
