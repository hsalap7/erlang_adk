%% @doc Dynamic supervisor for independently owned workflow coordinators.
-module(adk_workflow_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_workflow/3]).
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

-spec start_workflow(map(), map(), map()) -> supervisor:startchild_ret().
start_workflow(Compiled, InitialState, Opts)
  when is_map(Compiled), is_map(InitialState), is_map(Opts) ->
    %% Dynamic child MFAs are retained in supervisor state and may be copied
    %% into crash reports.  Start an empty coordinator with only an opaque
    %% launch reference, then perform a validated one-shot handoff.  Compiled
    %% closures, application state, options, and ledger handles never enter
    %% supervisor metadata.
    LaunchRef = make_ref(),
    ChildSpec = #{id => LaunchRef,
                  start => {adk_workflow_run, start_link, [LaunchRef]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [adk_workflow_run]},
    case supervisor:start_child(?SERVER, ChildSpec) of
        {ok, Pid} ->
            complete_handoff(Pid, LaunchRef, Compiled, InitialState, Opts,
                             {ok, Pid});
        {ok, Pid, Info} ->
            complete_handoff(Pid, LaunchRef, Compiled, InitialState, Opts,
                             {ok, Pid, Info});
        Error -> Error
    end.

complete_handoff(Pid, LaunchRef, Compiled, InitialState, Opts, Started) ->
    case adk_workflow_run:handoff(
           Pid, LaunchRef, Compiled, InitialState, Opts) of
        ok -> Started;
        {error, Reason} ->
            %% The child is temporary, but explicit termination also closes the
            %% race in which a failed handoff leaves an idle child alive.
            _ = supervisor:terminate_child(?SERVER, LaunchRef),
            _ = supervisor:delete_child(?SERVER, LaunchRef),
            {error, Reason}
    end.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 20,
            period => 10}, []}}.
