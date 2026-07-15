%% @doc Dynamic supervisor for short-lived authorization-code exchanges.
-module(adk_authorization_flow_exchange_sup).

-behaviour(supervisor).

-export([start_link/0, start_link/1, child_spec/1,
         start_exchange/3, start_exchange/5, cancel_exchange/2]).
-export([init/1]).

-type server() :: supervisor:sup_ref().

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, ?MODULE) of
        undefined -> supervisor:start_link(?MODULE, Opts);
        Name when is_atom(Name), Name =/= undefined ->
            supervisor:start_link({local, Name}, ?MODULE, Opts)
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

%% The child spec deliberately contains only an opaque generation and the
%% manager pid. Provider secrets and PKCE material arrive later in a redacted
%% cast and can never appear in supervisor reports.
-spec start_exchange(server(), pid(), reference()) ->
    supervisor:startchild_ret().
start_exchange(Supervisor, Manager, Generation)
  when is_pid(Manager), is_reference(Generation) ->
    start_exchange(Supervisor, Manager, Generation,
                   erlang:monotonic_time(millisecond) + 30000, 262144).

-spec start_exchange(server(), pid(), reference(), integer(), pos_integer()) ->
    supervisor:startchild_ret().
start_exchange(Supervisor, Manager, Generation, Deadline, MaxHeapWords)
  when is_pid(Manager), is_reference(Generation), is_integer(Deadline),
       is_integer(MaxHeapWords), MaxHeapWords >= 16384,
       MaxHeapWords =< 4000000 ->
    ChildSpec = #{id => Generation,
                  start => {adk_authorization_flow_worker, start_link,
                            [Manager, Generation, Deadline, MaxHeapWords]},
                  restart => temporary,
                  shutdown => brutal_kill,
                  type => worker,
                  modules => [adk_authorization_flow_worker]},
    supervisor:start_child(Supervisor, ChildSpec).

-spec cancel_exchange(server(), reference()) -> ok.
cancel_exchange(Supervisor, Generation) when is_reference(Generation) ->
    _ = catch supervisor:terminate_child(Supervisor, Generation),
    _ = catch supervisor:delete_child(Supervisor, Generation),
    ok.

init(_Opts) ->
    {ok, {#{strategy => one_for_one,
            intensity => 10,
            period => 10}, []}}.
