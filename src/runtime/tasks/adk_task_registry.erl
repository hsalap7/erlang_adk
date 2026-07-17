%% @doc Monitor-backed registry for supervised tasks.
-module(adk_task_registry).
-behaviour(gen_server).

-export([start_link/0, child_spec/1, register/2, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    tasks = #{} :: map(),
    refs = #{} :: map()
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec child_spec(term()) -> supervisor:child_spec().
child_spec(_Opts) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec register(binary(), pid()) -> ok | {error, already_exists}.
register(TaskRef, Pid) when is_binary(TaskRef), is_pid(Pid) ->
    gen_server:call(?SERVER, {register, TaskRef, Pid}).

-spec lookup(binary()) -> {ok, pid()} | {error, not_found}.
lookup(TaskRef) when is_binary(TaskRef) ->
    gen_server:call(?SERVER, {lookup, TaskRef}).

init([]) ->
    {ok, #state{}}.

handle_call({register, TaskRef, Pid}, _From,
            State = #state{tasks = Tasks, refs = Refs}) ->
    case maps:is_key(TaskRef, Tasks) of
        true ->
            {reply, {error, already_exists}, State};
        false ->
            Ref = erlang:monitor(process, Pid),
            {reply, ok,
             State#state{tasks = Tasks#{TaskRef => {Pid, Ref}},
                         refs = Refs#{Ref => TaskRef}}}
    end;
handle_call({lookup, TaskRef}, _From, State = #state{tasks = Tasks}) ->
    Reply = case maps:find(TaskRef, Tasks) of
        {ok, {Pid, _Ref}} -> {ok, Pid};
        error -> {error, not_found}
    end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason},
            State = #state{tasks = Tasks0, refs = Refs0}) ->
    case maps:take(Ref, Refs0) of
        {TaskRef, Refs1} ->
            {noreply,
             State#state{tasks = maps:remove(TaskRef, Tasks0),
                         refs = Refs1}};
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
