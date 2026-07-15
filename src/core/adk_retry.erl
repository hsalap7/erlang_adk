%% @doc Bounded retry execution with isolated monitored attempts.
%%
%% Backoff consumes the same absolute deadline as callback execution. Each
%% attempt runs in a fresh lightweight process, so a callback crash, timeout,
%% or excessive heap cannot take down or indefinitely block its caller.
-module(adk_retry).

-export([execute/2, execute/4]).

-define(DEFAULT_MAX_ATTEMPTS, 3).
-define(DEFAULT_INITIAL_DELAY, 1000).
-define(DEFAULT_MAX_DELAY, 10000).
-define(DEFAULT_BACKOFF_FACTOR, 2.0).
-define(DEFAULT_ATTEMPT_TIMEOUT, 30000).
-define(DEFAULT_TOTAL_TIMEOUT, 60000).
-define(DEFAULT_MAX_HEAP_WORDS, 1000000).
-define(MAX_ATTEMPTS, 1000).
-define(MAX_DELAY, 86400000).

-type retry_opts() :: #{
    max_attempts => pos_integer(),
    initial_delay => non_neg_integer(),
    max_delay => non_neg_integer(),
    backoff_factor => number(),
    attempt_timeout => pos_integer() | infinity,
    timeout => non_neg_integer() | infinity,
    deadline => integer() | infinity,
    max_heap_words => pos_integer() | infinity,
    jitter => none | full
}.
-export_type([retry_opts/0]).

-spec execute(fun(() -> {ok, term()} | {error, term()}), retry_opts()) ->
    {ok, term()} | {error, term()}.
execute(Fun, Opts0) when is_function(Fun, 0), is_map(Opts0) ->
    case normalize_options(Opts0) of
        {ok, Opts} ->
            loop(Fun, 1, maps:get(initial_delay, Opts), Opts);
        {error, _} = Error ->
            Error
    end;
execute(_Fun, _Opts) ->
    {error, invalid_retry_options}.

%% @doc Compatibility entry point retained for callers of the original API.
-spec execute(fun(() -> {ok, term()} | {error, term()}), pos_integer(),
              non_neg_integer(), retry_opts()) ->
    {ok, term()} | {error, term()}.
execute(Fun, Attempts, Delay, Opts)
  when is_function(Fun, 0), is_integer(Attempts), Attempts > 0,
       is_integer(Delay), Delay >= 0, is_map(Opts) ->
    execute(Fun, Opts#{max_attempts => Attempts, initial_delay => Delay});
execute(_Fun, _Attempts, _Delay, _Opts) ->
    {error, invalid_retry_options}.

normalize_options(Opts0) ->
    Known = [max_attempts, initial_delay, max_delay, backoff_factor,
             attempt_timeout, timeout, deadline, max_heap_words, jitter],
    Unknown = maps:without(Known, Opts0),
    MaxAttempts = maps:get(max_attempts, Opts0, ?DEFAULT_MAX_ATTEMPTS),
    InitialDelay = maps:get(initial_delay, Opts0, ?DEFAULT_INITIAL_DELAY),
    MaxDelay = maps:get(max_delay, Opts0, ?DEFAULT_MAX_DELAY),
    Factor = maps:get(backoff_factor, Opts0, ?DEFAULT_BACKOFF_FACTOR),
    AttemptTimeout = maps:get(attempt_timeout, Opts0,
                              ?DEFAULT_ATTEMPT_TIMEOUT),
    Timeout = maps:get(timeout, Opts0, ?DEFAULT_TOTAL_TIMEOUT),
    MaxHeap = maps:get(max_heap_words, Opts0, ?DEFAULT_MAX_HEAP_WORDS),
    Jitter = maps:get(jitter, Opts0, none),
    Deadline = maps:get(deadline, Opts0, deadline_after(Timeout)),
    case map_size(Unknown) =:= 0 andalso
         valid_positive_bounded(MaxAttempts, ?MAX_ATTEMPTS) andalso
         valid_nonnegative_bounded(InitialDelay, ?MAX_DELAY) andalso
         valid_nonnegative_bounded(MaxDelay, ?MAX_DELAY) andalso
         InitialDelay =< MaxDelay andalso
         is_number(Factor) andalso Factor >= 1.0 andalso Factor =< 100.0 andalso
         valid_timeout(AttemptTimeout) andalso valid_timeout(Timeout) andalso
         valid_deadline(Deadline) andalso valid_heap(MaxHeap) andalso
         (Jitter =:= none orelse Jitter =:= full) of
        true ->
            {ok, #{max_attempts => MaxAttempts,
                   initial_delay => InitialDelay,
                   max_delay => MaxDelay,
                   backoff_factor => Factor,
                   attempt_timeout => AttemptTimeout,
                   deadline => Deadline,
                   max_heap_words => MaxHeap,
                   jitter => Jitter}};
        false ->
            {error, invalid_retry_options}
    end.

loop(Fun, Attempt, Delay, Opts) ->
    case remaining(maps:get(deadline, Opts)) of
        expired ->
            {error, retry_deadline_exceeded};
        Remaining ->
            AttemptTimeout = bounded_attempt_timeout(
                               maps:get(attempt_timeout, Opts), Remaining),
            case run_attempt(Fun, AttemptTimeout,
                             maps:get(max_heap_words, Opts)) of
                {ok, _} = Success ->
                    Success;
                {invalid, Other} ->
                    {error, {invalid_retry_result, Other}};
                {error, Reason} ->
                    case Attempt >= maps:get(max_attempts, Opts) of
                        true -> {error, Reason};
                        false -> retry_after(Fun, Attempt, Delay, Opts)
                    end
            end
    end.

retry_after(Fun, Attempt, Delay, Opts) ->
    Wait = jittered_delay(Delay, maps:get(jitter, Opts)),
    case wait_with_deadline(Wait, maps:get(deadline, Opts)) of
        ok ->
            NextDelay = next_delay(Delay, maps:get(max_delay, Opts),
                                   maps:get(backoff_factor, Opts)),
            loop(Fun, Attempt + 1, NextDelay, Opts);
        expired ->
            {error, retry_deadline_exceeded}
    end.

run_attempt(Fun, AttemptTimeout, MaxHeap) ->
    Parent = self(),
    CallRef = make_ref(),
    SpawnOptions = [monitor | heap_option(MaxHeap)],
    {Pid, Monitor} = spawn_opt(
                       fun() ->
                           Result = try Fun() of
                               Value -> {returned, Value}
                           catch
                               Class:Reason -> {exception, Class, Reason}
                           end,
                           Parent ! {CallRef, self(), Result}
                       end, SpawnOptions),
    await_attempt(CallRef, Pid, Monitor, AttemptTimeout).

await_attempt(CallRef, Pid, Monitor, infinity) ->
    receive_attempt(CallRef, Pid, Monitor);
await_attempt(CallRef, Pid, Monitor, Timeout)
  when is_integer(Timeout), Timeout >= 0 ->
    receive
        {CallRef, Pid, Result} ->
            erlang:demonitor(Monitor, [flush]),
            normalize_attempt(Result);
        {'DOWN', Monitor, process, Pid, Reason} ->
            flush_attempt(CallRef, Pid),
            {error, {attempt_process_down, Reason}}
    after Timeout ->
        exit(Pid, kill),
        receive
            {'DOWN', Monitor, process, Pid, _} -> ok
        after 100 ->
            erlang:demonitor(Monitor, [flush])
        end,
        flush_attempt(CallRef, Pid),
        {error, attempt_timeout}
    end.

receive_attempt(CallRef, Pid, Monitor) ->
    receive
        {CallRef, Pid, Result} ->
            erlang:demonitor(Monitor, [flush]),
            normalize_attempt(Result);
        {'DOWN', Monitor, process, Pid, Reason} ->
            flush_attempt(CallRef, Pid),
            {error, {attempt_process_down, Reason}}
    end.

normalize_attempt({returned, {ok, _} = Success}) -> Success;
normalize_attempt({returned, {error, Reason}}) -> {error, Reason};
normalize_attempt({returned, Other}) -> {invalid, Other};
normalize_attempt({exception, Class, Reason}) ->
    {error, {attempt_exception, Class, Reason}}.

flush_attempt(CallRef, Pid) ->
    receive {CallRef, Pid, _} -> ok after 0 -> ok end.

heap_option(infinity) -> [];
heap_option(MaxHeap) ->
    [{max_heap_size, #{size => MaxHeap,
                       kill => true,
                       error_logger => false}}].

bounded_attempt_timeout(infinity, infinity) -> infinity;
bounded_attempt_timeout(infinity, Remaining) -> Remaining;
bounded_attempt_timeout(AttemptTimeout, infinity) -> AttemptTimeout;
bounded_attempt_timeout(AttemptTimeout, Remaining) ->
    erlang:min(AttemptTimeout, Remaining).

wait_with_deadline(Delay, infinity) ->
    receive after Delay -> ok end;
wait_with_deadline(Delay, Deadline) ->
    case remaining(Deadline) of
        expired -> expired;
        Remaining when Delay >= Remaining ->
            receive after Remaining -> expired end;
        _Remaining ->
            receive after Delay -> ok end
    end.

remaining(infinity) -> infinity;
remaining(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Value when Value =< 0 -> expired;
        Value -> Value
    end.

deadline_after(infinity) -> infinity;
deadline_after(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout;
deadline_after(_Invalid) -> invalid.

next_delay(Delay, MaxDelay, Factor) ->
    erlang:min(MaxDelay, erlang:round(Delay * Factor)).

jittered_delay(0, _Jitter) -> 0;
jittered_delay(Delay, none) -> Delay;
jittered_delay(Delay, full) -> rand:uniform(Delay + 1) - 1.

valid_positive_bounded(Value, Max) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Max.

valid_nonnegative_bounded(Value, Max) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< Max.

valid_timeout(infinity) -> true;
valid_timeout(Value) -> valid_nonnegative_bounded(Value, ?MAX_DELAY).

valid_deadline(infinity) -> true;
valid_deadline(Value) -> is_integer(Value).

valid_heap(infinity) -> true;
valid_heap(Value) -> is_integer(Value) andalso Value >= 1000.
