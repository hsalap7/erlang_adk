%% @doc Dynamic supervisor for bounded, idempotent memory ingestion jobs.
-module(adk_memory_ingest_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1, start_ingestion/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

child_spec(_Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

start_ingestion(Spec) when is_map(Spec) ->
    Ref = make_ref(),
    Child = #{id => Ref,
              start => {adk_memory_ingest_worker, start_link, [Spec]},
              restart => temporary,
              shutdown => 5000,
              type => worker,
              modules => [adk_memory_ingest_worker]},
    case supervisor:start_child(?SERVER, Child) of
        {ok, Pid} -> {ok, Pid, Ref};
        {ok, Pid, _Info} -> {ok, Pid, Ref};
        {error, _} = Error -> Error
    end;
start_ingestion(_) ->
    {error, invalid_memory_ingestion_spec}.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 10,
            period => 10}, []}}.
