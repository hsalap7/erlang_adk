%% @doc Internal isolation boundary for authentication provider callbacks.
%%
%% The callback and its result normalizer run in a bounded process.  A process
%% alias prevents late replies from remaining in the caller mailbox, while a
%% tiny watchdog kills the callback if its owner dies before the deadline.
-module(adk_auth_callback_guard).

-export([run/5]).

-type outcome(Value) :: {ok, Value} | timeout | failed.

-spec run(fun(() -> term()), fun((term()) -> Value), pos_integer(),
          pos_integer(), pos_integer()) -> outcome(Value).
run(Callback, Normalizer, TimeoutMs, MaxHeapWords, MaxResultBytes)
  when is_function(Callback, 0), is_function(Normalizer, 1),
       is_integer(TimeoutMs), TimeoutMs > 0,
       is_integer(MaxHeapWords), MaxHeapWords > 0,
       is_integer(MaxResultBytes), MaxResultBytes > 0 ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Ref = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    WorkerFun = fun() ->
        start_owner_watchdog(Owner, self()),
        Outcome = callback_outcome(Callback, Normalizer, MaxResultBytes),
        CompletedAt = erlang:monotonic_time(millisecond),
        _ = erlang:send(
              ReplyAlias,
              {adk_auth_callback_result, Ref, self(), CompletedAt, Outcome},
              [noconnect, nosuspend]),
        ok
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => MaxHeapWords, kill => true, error_logger => false,
            include_shared_binaries => true}}],
    try erlang:spawn_opt(WorkerFun, SpawnOptions) of
        {Worker, Monitor} ->
            await_result(Worker, Monitor, ReplyAlias, Ref, Deadline)
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            failed
    end;
run(_Callback, _Normalizer, _TimeoutMs, _MaxHeapWords, _MaxResultBytes) ->
    failed.

callback_outcome(Callback, Normalizer, MaxResultBytes) ->
    try Normalizer(Callback()) of
        SafeValue ->
            case bounded_term(SafeValue, MaxResultBytes) of
                true -> {ok, SafeValue};
                false -> failed
            end
    catch
        _:_ -> failed
    end.

await_result(Worker, Monitor, ReplyAlias, Ref, Deadline) ->
    Remaining = erlang:max(
                  0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {adk_auth_callback_result, Ref, Worker, CompletedAt,
         {ok, SafeValue}} when CompletedAt =< Deadline ->
            _ = erlang:unalias(ReplyAlias),
            _ = erlang:demonitor(Monitor, [flush]),
            {ok, SafeValue};
        {adk_auth_callback_result, Ref, Worker, CompletedAt, failed}
          when CompletedAt =< Deadline ->
            _ = erlang:unalias(ReplyAlias),
            _ = erlang:demonitor(Monitor, [flush]),
            failed;
        {adk_auth_callback_result, Ref, Worker, _CompletedAt, _LateOutcome} ->
            _ = erlang:unalias(ReplyAlias),
            exit(Worker, kill),
            await_worker_down(Worker, Monitor),
            timeout;
        {'DOWN', Monitor, process, Worker, _OpaqueReason} ->
            _ = erlang:unalias(ReplyAlias),
            failed
    after Remaining ->
        _ = erlang:unalias(ReplyAlias),
        exit(Worker, kill),
        await_worker_down(Worker, Monitor),
        timeout
    end.

await_worker_down(Worker, Monitor) ->
    receive
        {'DOWN', Monitor, process, Worker, _OpaqueReason} -> ok
    after 100 ->
        _ = erlang:demonitor(Monitor, [flush]),
        ok
    end.

start_owner_watchdog(Owner, Callback) ->
    Watchdog = fun() -> owner_watchdog(Owner, Callback) end,
    _ = spawn_opt(
          Watchdog,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]),
    ok.

owner_watchdog(Owner, Callback) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    CallbackMonitor = erlang:monitor(process, Callback),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(Callback, kill),
            _ = erlang:demonitor(CallbackMonitor, [flush]),
            ok;
        {'DOWN', CallbackMonitor, process, Callback, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch
        _:_ -> false
    end.
