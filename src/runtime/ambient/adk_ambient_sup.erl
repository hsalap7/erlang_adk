%% @doc Supervisor for the bounded ambient/background invocation runtime.
-module(adk_ambient_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec child_spec(term()) -> supervisor:child_spec().
child_spec(_Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

init([]) ->
    %% If the registry dies, every job/source is replaced too. This prevents a
    %% restarted registry from losing ownership of still-running invocations.
    Flags = #{strategy => one_for_all,
              intensity => 5,
              period => 10},
    RuntimeOptions = application:get_env(erlang_adk, ambient_runtime, #{}),
    Children = [adk_ambient_job_sup:child_spec(#{}),
                adk_trigger_sup:child_spec(#{}),
                adk_ambient:child_spec(RuntimeOptions)],
    {ok, {Flags, Children}}.
