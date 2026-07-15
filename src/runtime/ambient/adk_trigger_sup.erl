%% @doc Dynamic supervisor for external and periodic trigger sources.
-module(adk_trigger_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/1,
         start_source/2, stop_source/1, sources/0]).
-export([init/1]).

-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_SOURCES, 64).

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

-spec start_source(module(), map()) -> supervisor:startchild_ret().
start_source(Module, Options) when is_atom(Module), is_map(Options) ->
    Max = application:get_env(erlang_adk, ambient_max_sources,
                              ?DEFAULT_MAX_SOURCES),
    Counts = supervisor:count_children(?SERVER),
    case is_integer(Max) andalso Max > 0 andalso
         proplists:get_value(active, Counts, 0) < Max of
        false ->
            {error, trigger_source_limit_reached};
        true ->
            try Module:child_spec(Options) of
                Spec0 when is_map(Spec0) ->
                    Id = {Module, make_ref()},
                    Spec = Spec0#{id => Id, restart => transient},
                    supervisor:start_child(?SERVER, Spec);
                _ ->
                    {error, invalid_trigger_source_child_spec}
            catch
                Class:Reason ->
                    {error, {trigger_source_start_failed, Class, Reason}}
            end
    end;
start_source(_Module, _Options) ->
    {error, invalid_trigger_source_options}.

-spec stop_source(pid()) -> ok | {error, term()}.
stop_source(Pid) when is_pid(Pid) ->
    case lists:keyfind(Pid, 2, supervisor:which_children(?SERVER)) of
        {Id, Pid, _Type, _Modules} ->
            case supervisor:terminate_child(?SERVER, Id) of
                ok -> supervisor:delete_child(?SERVER, Id);
                {error, not_found} -> {error, not_found};
                {error, _} = Error -> Error
            end;
        false ->
            {error, not_found}
    end;
stop_source(_Pid) ->
    {error, invalid_trigger_source}.

-spec sources() -> [pid()].
sources() ->
    [Pid || {_Id, Pid, _Type, _Modules} <-
                supervisor:which_children(?SERVER),
            is_pid(Pid)].

init([]) ->
    {ok, {#{strategy => one_for_one,
            intensity => 10,
            period => 10}, []}}.

