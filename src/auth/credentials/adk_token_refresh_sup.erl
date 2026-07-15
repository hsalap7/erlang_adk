%% @doc Dynamic supervisor for short-lived authentication refresh workers.
-module(adk_token_refresh_sup).

-behaviour(supervisor).

-export([start_link/0, start_link/1, child_spec/1,
         start_refresh/3, cancel_refresh/2]).
-export([init/1]).

-type server() :: supervisor:sup_ref().

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, ?MODULE) of
        undefined -> supervisor:start_link(?MODULE, Opts);
        Name when is_atom(Name) ->
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

%% Only the manager pid and an opaque generation are present in the child
%% specification. Credentials and provider context can therefore never appear
%% in supervisor reports.
-spec start_refresh(server(), pid(), reference()) ->
    supervisor:startchild_ret().
start_refresh(Supervisor, Manager, Generation)
  when is_pid(Manager), is_reference(Generation) ->
    ChildSpec = #{id => Generation,
                  start => {adk_token_refresh_worker, start_link,
                            [Manager, Generation]},
                  restart => temporary,
                  shutdown => brutal_kill,
                  type => worker,
                  modules => [adk_token_refresh_worker]},
    supervisor:start_child(Supervisor, ChildSpec).

%% @doc Stop a refresh and remove its dynamic child specification.
-spec cancel_refresh(server(), reference()) -> ok.
cancel_refresh(Supervisor, Generation) when is_reference(Generation) ->
    _ = catch supervisor:terminate_child(Supervisor, Generation),
    _ = catch supervisor:delete_child(Supervisor, Generation),
    ok.

init(_Opts) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 10},
    {ok, {SupFlags, []}}.
