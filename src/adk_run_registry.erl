%% @doc Process registry and bounded terminal-run retention for adk_run.
%%
%% Active invocations are retained for as long as they execute. Completed
%% invocations are retained for replay, subject to both their own retention
%% timer and this registry's global count limit. The registry monitors every
%% invocation so stale process identifiers are never returned deliberately.
-module(adk_run_registry).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1]).
-export([register/2, lookup/1, terminal/2, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_RETAINED_TERMINAL, 100).

-record(state, {
    runs = #{} :: map(),
    refs = #{} :: map(),
    terminal_queue = {[], []} :: term(),
    terminal_count = 0 :: non_neg_integer(),
    max_retained_terminal = ?DEFAULT_MAX_RETAINED_TERMINAL
        :: non_neg_integer()
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec register(binary(), pid()) -> ok | {error, already_exists}.
register(RunId, Pid) when is_binary(RunId), is_pid(Pid) ->
    gen_server:call(?SERVER, {register, RunId, Pid}).

-spec lookup(binary()) -> {ok, pid()} | {error, not_found}.
lookup(RunId) when is_binary(RunId) ->
    gen_server:call(?SERVER, {lookup, RunId}).

-spec terminal(binary(), pid()) -> ok.
terminal(RunId, Pid) when is_binary(RunId), is_pid(Pid) ->
    gen_server:cast(?SERVER, {terminal, RunId, Pid}).

-spec stats() -> map().
stats() ->
    gen_server:call(?SERVER, stats).

init(Opts) ->
    Max = maps:get(
            max_retained_terminal, Opts,
            application:get_env(
              erlang_adk, run_max_retained_terminal,
              ?DEFAULT_MAX_RETAINED_TERMINAL)),
    case is_integer(Max) andalso Max >= 0 of
        true -> {ok, #state{max_retained_terminal = Max}};
        false -> {stop, {invalid_max_retained_terminal, Max}}
    end.

handle_call({register, RunId, Pid}, _From,
            State = #state{runs = Runs, refs = Refs}) ->
    case maps:is_key(RunId, Runs) of
        true ->
            {reply, {error, already_exists}, State};
        false ->
            Ref = erlang:monitor(process, Pid),
            Entry = {Pid, Ref, active},
            {reply, ok,
             State#state{runs = Runs#{RunId => Entry},
                         refs = Refs#{Ref => RunId}}}
    end;
handle_call({lookup, RunId}, _From, State = #state{runs = Runs}) ->
    Reply = case maps:find(RunId, Runs) of
        {ok, {Pid, _Ref, _Phase}} -> {ok, Pid};
        error -> {error, not_found}
    end,
    {reply, Reply, State};
handle_call(stats, _From,
            State = #state{runs = Runs,
                           terminal_count = TerminalCount,
                           max_retained_terminal = Max}) ->
    {reply, #{run_count => map_size(Runs),
              terminal_count => TerminalCount,
              max_retained_terminal => Max}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast({terminal, RunId, Pid},
            State0 = #state{runs = Runs0,
                            terminal_queue = Queue0,
                            terminal_count = Count0}) ->
    case maps:find(RunId, Runs0) of
        {ok, {Pid, Ref, active}} ->
            Runs1 = Runs0#{RunId => {Pid, Ref, terminal}},
            Queue1 = queue:in({RunId, Pid}, Queue0),
            State1 = State0#state{runs = Runs1,
                                  terminal_queue = Queue1,
                                  terminal_count = Count0 + 1},
            {noreply, enforce_terminal_limit(State1)};
        _ ->
            %% Duplicate terminal notifications and messages from stale
            %% processes are intentionally idempotent.
            {noreply, State0}
    end;
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason},
            State = #state{refs = Refs0, runs = Runs0,
                           terminal_count = Count0}) ->
    case maps:take(Ref, Refs0) of
        {RunId, Refs1} ->
            case maps:take(RunId, Runs0) of
                {{_RegisteredPid, Ref, terminal}, Runs1} ->
                    {noreply,
                     State#state{refs = Refs1, runs = Runs1,
                                 terminal_count = Count0 - 1}};
                {{_RegisteredPid, Ref, active}, Runs1} ->
                    {noreply, State#state{refs = Refs1, runs = Runs1}};
                error ->
                    {noreply, State#state{refs = Refs1}}
            end;
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

enforce_terminal_limit(
  State = #state{terminal_count = Count,
                 max_retained_terminal = Max}) when Count =< Max ->
    State;
enforce_terminal_limit(
  State0 = #state{terminal_queue = Queue0,
                  runs = Runs0, refs = Refs0,
                  terminal_count = Count0}) ->
    case queue:out(Queue0) of
        {{value, {RunId, Pid}}, Queue1} ->
            case maps:find(RunId, Runs0) of
                {ok, {Pid, Ref, terminal}} ->
                    erlang:demonitor(Ref, [flush]),
                    Pid ! adk_expire,
                    State1 = State0#state{
                               terminal_queue = Queue1,
                               runs = maps:remove(RunId, Runs0),
                               refs = maps:remove(Ref, Refs0),
                               terminal_count = Count0 - 1},
                    enforce_terminal_limit(State1);
                _StaleQueueEntry ->
                    enforce_terminal_limit(
                      State0#state{terminal_queue = Queue1})
            end;
        {empty, Queue1} ->
            %% Defensive recovery: every counted terminal normally has a queue
            %% entry, but never loop forever if state was upgraded incorrectly.
            State0#state{terminal_queue = Queue1,
                         terminal_count = 0}
    end.
