%% @doc Bounded FIFO connection pool for MCP clients.
%%
%% Connections are leased to one borrower at a time.  Borrower death and
%% explicit cancellation always discard the connection because an in-flight
%% request may have reached the peer.  The pool reconnects for future leases;
%% `request/4' never replays a callback, and reports mutating disconnects as an
%% uncertain delivery instead of risking duplicate effects.
-module(adk_mcp_pool).
-behaviour(gen_server).

-export([start/1, start_link/1, child_spec/1,
         stop/1, checkout/2, checkin/3, cancel/2,
         request/4, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_SIZE, 4).
-define(DEFAULT_MAX_WAITERS, 256).
-define(DEFAULT_CONNECT_TIMEOUT, 10000).
-define(MAX_TIMEOUT, 120000).
-define(CALL_GRACE, 1000).

-spec start(map()) -> gen_server:start_ret().
start(Config) when is_map(Config) ->
    gen_server:start(?MODULE, Config, []);
start(_Config) -> {error, invalid_mcp_pool_config}.

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) when is_map(Config) ->
    gen_server:start_link(?MODULE, Config, []);
start_link(_Config) -> {error, invalid_mcp_pool_config}.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Config) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Config]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec stop(pid()) -> ok.
stop(Pool) -> gen_server:stop(Pool).

-spec checkout(pid(), pos_integer()) ->
    {ok, reference(), term()} | {error, term()}.
checkout(Pool, Timeout) when is_integer(Timeout), Timeout > 0,
                             Timeout =< ?MAX_TIMEOUT ->
    safe_call(Pool, {checkout, Timeout}, Timeout + ?CALL_GRACE);
checkout(_Pool, _Timeout) -> {error, invalid_mcp_pool_timeout}.

-spec checkin(pid(), reference(), healthy | disconnected | failed) ->
    ok | {error, term()}.
checkin(Pool, Lease, Outcome) ->
    safe_call(Pool, {checkin, Lease, Outcome}, 5000).

-spec cancel(pid(), reference()) -> ok | {error, term()}.
cancel(Pool, Lease) -> safe_call(Pool, {cancel, Lease}, 5000).

-spec request(pid(), read_only | mutation, fun((term()) -> term()),
              pos_integer()) -> term().
request(Pool, Class, Fun, Timeout)
  when (Class =:= read_only orelse Class =:= mutation), is_function(Fun, 1) ->
    case checkout(Pool, Timeout) of
        {ok, Lease, Connection} ->
            execute_once(Pool, Lease, Connection, Class, Fun);
        {error, _} = Error -> Error
    end;
request(_Pool, _Class, _Fun, _Timeout) ->
    {error, invalid_mcp_pool_request}.

-spec status(pid()) -> {ok, map()} | {error, term()}.
status(Pool) -> safe_call(Pool, status, 5000).

init(Config0) ->
    process_flag(trap_exit, true),
    case normalize_config(Config0) of
        {ok, Config} ->
            {ok, #{config => Config, available => queue:new(),
                   waiters => queue:new(), waiter_index => #{},
                   leases => #{}, connecting => #{}}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({checkout, Timeout}, From, State0) ->
    case take_available(State0) of
        {ok, Connection, State1} ->
            {Lease, State} = make_lease(Connection, From, State1),
            {reply, {ok, Lease, Connection}, State};
        empty ->
            Config = maps:get(config, State0),
            case queue:len(maps:get(waiters, State0)) >=
                 maps:get(max_waiters, Config) of
                true -> {reply, {error, mcp_pool_busy}, State0};
                false ->
                    State1 = enqueue_waiter(From, Timeout, State0),
                    {noreply, ensure_connecting(State1)}
            end
    end;
handle_call({checkin, Lease, Outcome}, From, State) ->
    handle_return(Lease, Outcome, From, State);
handle_call({cancel, Lease}, From, State) ->
    handle_return(Lease, cancelled, From, State);
handle_call(status, _From, State) ->
    {reply, {ok, public_status(State)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_mcp_pool_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({mcp_pool_connect_result, Ref, Worker, CompletedAt, Result},
            State0) ->
    case maps:take(Ref, maps:get(connecting, State0)) of
        {#{pid := Worker, monitor := Monitor, timer := Timer,
           deadline := Deadline}, Connecting} ->
            erlang:cancel_timer(Timer),
            erlang:demonitor(Monitor, [flush]),
            State1 = State0#{connecting => Connecting},
            case {CompletedAt =< Deadline, normalize_connection(Result)} of
                {true, {ok, Connection}} ->
                    {noreply, ensure_connecting(assign_connection(
                                                   Connection, State1))};
                _ ->
                    {noreply, ensure_connecting(fail_next_waiter(
                                                   mcp_pool_connect_failed,
                                                   State1))}
            end;
        error ->
            maybe_close_late(Result, State0),
            {noreply, State0}
    end;
handle_info({mcp_pool_connect_timeout, Ref}, State0) ->
    case maps:take(Ref, maps:get(connecting, State0)) of
        {ConnectingEntry, Connecting} ->
            exit(maps:get(pid, ConnectingEntry), kill),
            erlang:demonitor(maps:get(monitor, ConnectingEntry), [flush]),
            State1 = State0#{connecting => Connecting},
            {noreply, ensure_connecting(fail_next_waiter(
                                           mcp_pool_connect_timeout,
                                           State1))};
        error -> {noreply, State0}
    end;
handle_info({mcp_pool_wait_timeout, Ref}, State0) ->
    case maps:take(Ref, maps:get(waiter_index, State0)) of
        {Waiter, Index} ->
            erlang:demonitor(maps:get(monitor, Waiter), [flush]),
            gen_server:reply(maps:get(from, Waiter),
                             {error, mcp_pool_checkout_timeout}),
            Queue = remove_waiter_ref(Ref, maps:get(waiters, State0)),
            {noreply, State0#{waiter_index => Index, waiters => Queue}};
        error -> {noreply, State0}
    end;
handle_info({'DOWN', Monitor, process, Borrower, _Reason}, State0) ->
    case waiter_by_monitor(Monitor, Borrower, State0) of
        {ok, Ref, Waiter} ->
            erlang:cancel_timer(maps:get(timer, Waiter)),
            Index = maps:remove(Ref, maps:get(waiter_index, State0)),
            Queue = remove_waiter_ref(Ref, maps:get(waiters, State0)),
            {noreply, State0#{waiter_index => Index, waiters => Queue}};
        error ->
            case lease_by_monitor(Monitor, Borrower, State0) of
                {ok, Lease, #{connection := Connection}} ->
                    Leases = maps:remove(Lease, maps:get(leases, State0)),
                    close_async(Connection, State0),
                    {noreply, ensure_connecting(State0#{leases => Leases})};
                error ->
                    handle_connect_worker_down(Monitor, State0)
            end
    end;
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    lists:foreach(fun(Connection) -> close_async(Connection, State) end,
                  queue:to_list(maps:get(available, State, queue:new()))),
    maps:foreach(fun(_Lease, #{connection := Connection}) ->
                         close_async(Connection, State)
                 end, maps:get(leases, State, #{})),
    maps:foreach(fun(_Ref, Entry) -> exit(maps:get(pid, Entry), kill) end,
                 maps:get(connecting, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, State) when is_map(State) -> public_status(State);
         (message, _Message) -> redacted;
         (log, _Log) -> [];
         (reason, _Reason) -> redacted;
         (_Key, Value) -> Value
      end, Status);
format_status(Status) -> Status.

execute_once(Pool, Lease, Connection, Class, Fun) ->
    try Fun(Connection) of
        {error, disconnected} = Error ->
            _ = checkin(Pool, Lease, disconnected),
            disconnected_result(Class, Error);
        {error, {http_transport, _}} = Error ->
            _ = checkin(Pool, Lease, disconnected),
            disconnected_result(Class, Error);
        {error, {request_failed, _}} = Error ->
            _ = checkin(Pool, Lease, disconnected),
            disconnected_result(Class, Error);
        Result ->
            _ = checkin(Pool, Lease, healthy),
            Result
    catch
        _:_ ->
            _ = checkin(Pool, Lease, disconnected),
            case Class of
                mutation -> {error, {delivery_uncertain, not_replayed}};
                read_only -> {error, mcp_pool_request_failed}
            end
    end.

disconnected_result(mutation, _Error) ->
    {error, {delivery_uncertain, not_replayed}};
disconnected_result(read_only, Error) -> Error.

handle_return(Lease, Outcome, From, State) ->
    case maps:find(Lease, maps:get(leases, State)) of
        {ok, #{borrower := Borrower, monitor := Monitor,
               connection := Connection}} ->
            case caller_pid(From) =:= Borrower andalso
                 valid_outcome(Outcome) of
                false -> {reply, {error, invalid_mcp_pool_lease}, State};
                true ->
                    erlang:demonitor(Monitor, [flush]),
                    Leases = maps:remove(Lease, maps:get(leases, State)),
                    State1 = State#{leases => Leases},
                    case Outcome of
                        healthy ->
                            {reply, ok, ensure_connecting(
                                          assign_connection(Connection,
                                                            State1))};
                        _ ->
                            close_async(Connection, State1),
                            {reply, ok, ensure_connecting(State1)}
                    end
            end;
        error -> {reply, {error, invalid_mcp_pool_lease}, State}
    end.

enqueue_waiter(From, Timeout, State) ->
    Ref = make_ref(),
    Borrower = caller_pid(From),
    Monitor = erlang:monitor(process, Borrower),
    Timer = erlang:send_after(Timeout, self(),
                              {mcp_pool_wait_timeout, Ref}),
    Waiter = #{ref => Ref, from => From, borrower => Borrower,
               monitor => Monitor, timer => Timer},
    Queue = queue:in(Ref, maps:get(waiters, State)),
    Index = maps:get(waiter_index, State),
    State#{waiters => Queue, waiter_index => Index#{Ref => Waiter}}.

take_available(State) ->
    case queue:out(maps:get(available, State)) of
        {{value, Connection}, Queue} ->
            {ok, Connection, State#{available => Queue}};
        {empty, _Queue} -> empty
    end.

assign_connection(Connection, State0) ->
    case take_waiter(State0) of
        {ok, Waiter, State1} ->
            erlang:cancel_timer(maps:get(timer, Waiter)),
            erlang:demonitor(maps:get(monitor, Waiter), [flush]),
            {Lease, State} = make_lease(Connection,
                                        maps:get(from, Waiter), State1),
            gen_server:reply(maps:get(from, Waiter),
                             {ok, Lease, Connection}),
            State;
        empty ->
            State0#{available => queue:in(Connection,
                                           maps:get(available, State0))}
    end.

make_lease(Connection, From, State) ->
    Lease = make_ref(),
    Borrower = caller_pid(From),
    Monitor = erlang:monitor(process, Borrower),
    Entry = #{connection => Connection, borrower => Borrower,
              monitor => Monitor},
    {Lease, State#{leases => (maps:get(leases, State))#{Lease => Entry}}}.

take_waiter(State0) ->
    case queue:out(maps:get(waiters, State0)) of
        {{value, Ref}, Queue} ->
            State1 = State0#{waiters => Queue},
            case maps:take(Ref, maps:get(waiter_index, State1)) of
                {Waiter, Index} ->
                    {ok, Waiter, State1#{waiter_index => Index}};
                error -> take_waiter(State1)
            end;
        {empty, _} -> empty
    end.

fail_next_waiter(Reason, State0) ->
    case take_waiter(State0) of
        {ok, Waiter, State} ->
            erlang:cancel_timer(maps:get(timer, Waiter)),
            erlang:demonitor(maps:get(monitor, Waiter), [flush]),
            gen_server:reply(maps:get(from, Waiter), {error, Reason}),
            State;
        empty -> State0
    end.

ensure_connecting(State0) ->
    Waiting = map_size(maps:get(waiter_index, State0)),
    Capacity = maps:get(max_size, maps:get(config, State0)) - total(State0),
    Needed = erlang:min(Waiting, erlang:max(0, Capacity)),
    start_connections(Needed, State0).

start_connections(0, State) -> State;
start_connections(Count, State0) ->
    case start_connection(State0) of
        {ok, State} -> start_connections(Count - 1, State);
        {error, State} -> fail_next_waiter(mcp_pool_connect_failed, State)
    end.

start_connection(State) ->
    Config = maps:get(config, State),
    Connect = maps:get(connect_fun, Config),
    Timeout = maps:get(connect_timeout, Config),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Owner = self(),
    Ref = make_ref(),
    Work = fun() ->
        Result = catch Connect(),
        Owner ! {mcp_pool_connect_result, Ref, self(),
                 erlang:monotonic_time(millisecond), Result}
    end,
    try spawn_opt(Work, [monitor, {message_queue_data, off_heap}]) of
        {Pid, Monitor} ->
            Timer = erlang:send_after(Timeout, self(),
                                      {mcp_pool_connect_timeout, Ref}),
            Entry = #{pid => Pid, monitor => Monitor, timer => Timer,
                      deadline => Deadline},
            Connecting = maps:get(connecting, State),
            {ok, State#{connecting => Connecting#{Ref => Entry}}}
    catch _:_ -> {error, State}
    end.

handle_connect_worker_down(Monitor, State0) ->
    case connecting_by_monitor(Monitor, maps:get(connecting, State0)) of
        {ok, Ref, Entry} ->
            erlang:cancel_timer(maps:get(timer, Entry)),
            Connecting = maps:remove(Ref, maps:get(connecting, State0)),
            {noreply, ensure_connecting(fail_next_waiter(
                                           mcp_pool_connect_failed,
                                           State0#{connecting => Connecting}))};
        error -> {noreply, State0}
    end.

waiter_by_monitor(Monitor, Borrower, State) ->
    first_match(
      fun(_Ref, Waiter) -> maps:get(monitor, Waiter) =:= Monitor andalso
                              maps:get(borrower, Waiter) =:= Borrower end,
      maps:get(waiter_index, State)).

lease_by_monitor(Monitor, Borrower, State) ->
    first_match(
      fun(_Lease, Entry) -> maps:get(monitor, Entry) =:= Monitor andalso
                               maps:get(borrower, Entry) =:= Borrower end,
      maps:get(leases, State)).

connecting_by_monitor(Monitor, Connecting) ->
    first_match(fun(_Ref, Entry) ->
                        maps:get(monitor, Entry) =:= Monitor
                end, Connecting).

first_match(Predicate, Map) ->
    case [{Key, Value} || {Key, Value} <- maps:to_list(Map),
                           Predicate(Key, Value)] of
        [{Key, Value}] -> {ok, Key, Value};
        _ -> error
    end.

close_async(Connection, State) ->
    Close = maps:get(close_fun, maps:get(config, State)),
    _ = spawn(fun() -> _ = catch Close(Connection), ok end),
    ok.

maybe_close_late({ok, Connection}, State) -> close_async(Connection, State);
maybe_close_late(_, _State) -> ok.

normalize_connection({ok, Connection}) -> {ok, Connection};
normalize_connection(_) -> error.

total(State) ->
    queue:len(maps:get(available, State)) +
    map_size(maps:get(leases, State)) +
    map_size(maps:get(connecting, State)).

public_status(State) ->
    #{available => queue:len(maps:get(available, State)),
      leased => map_size(maps:get(leases, State)),
      connecting => map_size(maps:get(connecting, State)),
      waiting => map_size(maps:get(waiter_index, State)),
      max_size => maps:get(max_size, maps:get(config, State))}.

normalize_config(Config) ->
    Allowed = [connect_fun, close_fun, max_size, max_waiters,
               connect_timeout],
    Connect = maps:get(connect_fun, Config, undefined),
    Close = maps:get(close_fun, Config, fun(_Connection) -> ok end),
    MaxSize = maps:get(max_size, Config, ?DEFAULT_MAX_SIZE),
    MaxWaiters = maps:get(max_waiters, Config, ?DEFAULT_MAX_WAITERS),
    Timeout = maps:get(connect_timeout, Config, ?DEFAULT_CONNECT_TIMEOUT),
    case maps:keys(maps:without(Allowed, Config)) =:= [] andalso
         is_function(Connect, 0) andalso is_function(Close, 1) andalso
         valid_positive(MaxSize, 64) andalso
         valid_positive(MaxWaiters, 4096) andalso
         valid_positive(Timeout, ?MAX_TIMEOUT) of
        true -> {ok, #{connect_fun => Connect, close_fun => Close,
                       max_size => MaxSize, max_waiters => MaxWaiters,
                       connect_timeout => Timeout}};
        false -> {error, invalid_mcp_pool_config}
    end.

valid_outcome(healthy) -> true;
valid_outcome(disconnected) -> true;
valid_outcome(failed) -> true;
valid_outcome(cancelled) -> true;
valid_outcome(_) -> false.

caller_pid({Pid, _Tag}) -> Pid.

remove_waiter_ref(Ref, Queue) ->
    queue:from_list([Other || Other <- queue:to_list(Queue), Other =/= Ref]).

valid_positive(Value, Ceiling) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Ceiling.

safe_call(Pool, Request, Timeout) ->
    try gen_server:call(Pool, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, mcp_pool_timeout};
        exit:{noproc, _} -> {error, mcp_pool_unavailable};
        exit:_ -> {error, mcp_pool_unavailable}
    end.
