%% @doc Dynamic supervisor for bounded, independently owned tasks.
-module(adk_task_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_task/3]).
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

-spec start_task(binary(), fun(() -> term()) | {module(), atom(), [term()]},
                 map()) -> supervisor:startchild_ret().
start_task(TaskRef, Work, Opts)
  when is_binary(TaskRef), is_map(Opts) ->
    %% Dynamic child MFAs are included in supervisor reports. Start an empty
    %% worker with only its random public reference, then synchronously perform
    %% a one-shot handoff. Work and options never enter supervisor state.
    ChildSpec = #{id => TaskRef,
                  start => {adk_task_worker, start_link, [TaskRef]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [adk_task_worker]},
    case supervisor:start_child(?SERVER, ChildSpec) of
        {ok, Pid} -> complete_handoff(Pid, TaskRef, Work, Opts, {ok, Pid});
        {ok, Pid, Info} ->
            complete_handoff(Pid, TaskRef, Work, Opts, {ok, Pid, Info});
        Error -> Error
    end.

complete_handoff(Pid, TaskRef, Work, Opts, Started) ->
    case adk_task_worker:handoff(Pid, TaskRef, Work, Opts) of
        ok -> Started;
        {error, Reason} ->
            _ = supervisor:terminate_child(?SERVER, TaskRef),
            _ = supervisor:delete_child(?SERVER, TaskRef),
            {error, Reason}
    end.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 20,
            period => 10}, []}}.
