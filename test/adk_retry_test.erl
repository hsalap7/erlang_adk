-module(adk_retry_test).
-include_lib("eunit/include/eunit.hrl").

retry_test_() ->
    [
        {"success first try", ?_test(success())},
        {"retry then success", ?_test(retry_success())},
        {"exhaust retries", ?_test(exhaust_retries())},
        {"callback crash is isolated and retryable", ?_test(crash_isolated())},
        {"attempt timeout is isolated and retryable", ?_test(timeout_isolated())},
        {"absolute deadline bounds backoff", ?_test(deadline_bounds_backoff())},
        {"invalid callback result is not retried", ?_test(invalid_result())},
        {"reject invalid options", ?_test(invalid_options())}
    ].

success() ->
    ?assertEqual({ok, <<"success">>},
                 adk_retry:execute(fun() -> {ok, <<"success">>} end, #{})).

retry_success() ->
    Counter = atomics:new(1, []),
    Fun = fun() ->
        case atomics:add_get(Counter, 1, 1) of
            Attempt when Attempt < 3 -> {error, fail};
            _ -> {ok, <<"success">>}
        end
    end,
    Opts = #{max_attempts => 3, initial_delay => 1,
             backoff_factor => 1.0},
    ?assertEqual({ok, <<"success">>}, adk_retry:execute(Fun, Opts)),
    ?assertEqual(3, atomics:get(Counter, 1)).

exhaust_retries() ->
    Counter = atomics:new(1, []),
    Fun = fun() ->
        _ = atomics:add_get(Counter, 1, 1),
        {error, fail}
    end,
    Opts = #{max_attempts => 3, initial_delay => 1,
             backoff_factor => 1.0},
    ?assertEqual({error, fail}, adk_retry:execute(Fun, Opts)),
    ?assertEqual(3, atomics:get(Counter, 1)).

crash_isolated() ->
    Counter = atomics:new(1, []),
    Fun = fun() ->
        case atomics:add_get(Counter, 1, 1) of
            1 -> erlang:error(transient_crash);
            _ -> {ok, recovered}
        end
    end,
    ?assertEqual(
       {ok, recovered},
       adk_retry:execute(
         Fun, #{max_attempts => 2, initial_delay => 0, timeout => 1000})).

timeout_isolated() ->
    Counter = atomics:new(1, []),
    Fun = fun() ->
        case atomics:add_get(Counter, 1, 1) of
            1 -> receive stop -> {error, impossible} end;
            _ -> {ok, recovered}
        end
    end,
    ?assertEqual(
       {ok, recovered},
       adk_retry:execute(
         Fun, #{max_attempts => 2, initial_delay => 0,
                attempt_timeout => 5, timeout => 1000})),
    ?assertEqual(2, atomics:get(Counter, 1)).

deadline_bounds_backoff() ->
    Started = erlang:monotonic_time(millisecond),
    Result = adk_retry:execute(
               fun() -> {error, temporary} end,
               #{max_attempts => 10, initial_delay => 100,
                 max_delay => 100, timeout => 10}),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertEqual({error, retry_deadline_exceeded}, Result),
    ?assert(Elapsed < 100).

invalid_result() ->
    Counter = atomics:new(1, []),
    Result = adk_retry:execute(
               fun() ->
                   _ = atomics:add_get(Counter, 1, 1),
                   unexpected
               end,
               #{max_attempts => 5}),
    ?assertEqual({error, {invalid_retry_result, unexpected}}, Result),
    ?assertEqual(1, atomics:get(Counter, 1)).

invalid_options() ->
    Fun = fun() -> {ok, never} end,
    ?assertEqual({error, invalid_retry_options},
                 adk_retry:execute(Fun, #{max_attempts => 0})),
    ?assertEqual({error, invalid_retry_options},
                 adk_retry:execute(Fun, #{unknown => true})),
    ?assertEqual({error, invalid_retry_options},
                 adk_retry:execute(Fun, #{initial_delay => 2,
                                          max_delay => 1})).
