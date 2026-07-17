%% @doc Dynamic supervisor for independently owned ADK invocations.
-module(adk_invocation_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_invocation/3]).
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

-spec start_invocation(binary(), map(), map()) ->
    supervisor:startchild_ret().
start_invocation(RunId, Request, Opts)
  when is_binary(RunId), is_map(Request), is_map(Opts) ->
    %% Dynamic child specifications are visible in OTP diagnostics. Start an
    %% empty child under a fresh opaque identity, then hand over sensitive
    %% invocation data exactly once outside supervisor state.
    InvocationRef = make_ref(),
    ChildSpec = #{id => InvocationRef,
                  start => {adk_invocation, start_link, [InvocationRef]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [adk_invocation]},
    case supervisor:start_child(?SERVER, ChildSpec) of
        {ok, Pid} ->
            complete_handoff(
              Pid, InvocationRef, RunId, Request, Opts, {ok, Pid});
        {ok, Pid, Info} ->
            complete_handoff(
              Pid, InvocationRef, RunId, Request, Opts,
              {ok, Pid, Info});
        Error ->
            Error
    end.

complete_handoff(Pid, InvocationRef, RunId, Request, Opts, Started) ->
    case adk_invocation:handoff(
           Pid, InvocationRef, RunId, Request, Opts) of
        ok ->
            Started;
        {error, Reason} ->
            %% The process may already be gone after losing a registration
            %% race. Both cleanup operations are intentionally idempotent.
            _ = supervisor:terminate_child(?SERVER, InvocationRef),
            _ = supervisor:delete_child(?SERVER, InvocationRef),
            {error, Reason}
    end.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 10,
            period => 10}, []}}.
