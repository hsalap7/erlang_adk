%% @doc Dynamic supervisor for stateful plugin instances.
%%
%% The application starts a registered instance for the convenience APIs.
%% start_link/0 remains available for isolated owners and tests that need a
%% private runtime.
-module(adk_plugin_runtime_sup).
-behaviour(supervisor).

-export([child_spec/0, start_link/0, start_link_registered/0,
         start_instance/1, start_instance/2,
         stop_instance/1, stop_instance/2]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE,
      start => {?MODULE, start_link_registered, []},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

-spec start_link() -> supervisor:startlink_ret().
start_link() -> supervisor:start_link(?MODULE, []).

-spec start_link_registered() -> supervisor:startlink_ret().
start_link_registered() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec start_instance(map()) -> {ok, pid()} | {error, term()}.
start_instance(Spec) -> start_instance(?SERVER, Spec).

-spec start_instance(supervisor:sup_ref(), map()) ->
    {ok, pid()} | {error, term()}.
start_instance(Supervisor, Spec) when is_map(Spec) ->
    %% An instance is addressed by its PID by both the stateful adapter and the
    %% caller. Restarting it behind that identity would silently reset policy
    %% state while leaving every retained PID stale. Instances are therefore
    %% explicitly temporary: failure makes the identity unavailable and the
    %% owner must start and distribute a new instance deliberately.
    ChildSpec = #{id => make_ref(),
                  start => {adk_plugin_instance, start_link, [Spec]},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [adk_plugin_instance]},
    case supervisor:start_child(Supervisor, ChildSpec) of
        {error, {Reason, Child}}
          when is_tuple(Child), tuple_size(Child) > 0,
               element(1, Child) =:= child ->
            %% OTP includes the complete child start term in this error. That
            %% term contains plugin config and must not escape this boundary.
            {error, Reason};
        Result -> Result
    end;
start_instance(_Supervisor, _Spec) -> {error, invalid_plugin_instance_spec}.

-spec stop_instance(pid()) -> ok | {error, term()}.
stop_instance(Pid) -> stop_instance(?SERVER, Pid).

-spec stop_instance(supervisor:sup_ref(), pid()) -> ok | {error, term()}.
stop_instance(Supervisor, Pid) when is_pid(Pid) ->
    case [Id || {Id, Child, _Type, _Modules} <-
                    supervisor:which_children(Supervisor),
                Child =:= Pid] of
        [Id] ->
            case supervisor:terminate_child(Supervisor, Id) of
                ok ->
                    %% Temporary child specs are deleted atomically by OTP
                    %% during termination.
                    case supervisor:delete_child(Supervisor, Id) of
                        ok -> ok;
                        {error, not_found} -> ok;
                        {error, _} = DeleteError -> DeleteError
                    end;
                {error, _} = Error -> Error
            end;
        [] -> {error, not_found}
    end;
stop_instance(_Supervisor, _Pid) -> {error, invalid_plugin_instance}.

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 5,
            period => 10}, []}}.
