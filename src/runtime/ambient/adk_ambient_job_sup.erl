%% @doc Dynamic supervisor for isolated ambient event jobs.
-module(adk_ambient_job_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_job/2]).
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

-spec start_job(binary(), map()) -> supervisor:startchild_ret().
start_job(EventRef, Spec) when is_binary(EventRef), is_map(Spec) ->
    Child = #{id => EventRef,
              start => {adk_ambient_job, start_link, [EventRef, Spec]},
              restart => temporary,
              shutdown => 5000,
              type => worker,
              modules => [adk_ambient_job]},
    supervisor:start_child(?SERVER, Child).

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 20,
            period => 10}, []}}.

