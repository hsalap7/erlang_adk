-module(adk_retry_test).
-include_lib("eunit/include/eunit.hrl").

retry_test_() ->
    [
        {"Success first try", ?_test(test_success())},
        {"Retry then success", ?_test(test_retry_success())},
        {"Exhaust retries", ?_test(test_exhaust_retries())},
        {"Reject invalid options", ?_test(test_invalid_options())}
    ].

test_success() ->
    Fun = fun() -> {ok, <<"success">>} end,
    {ok, Res} = adk_retry:execute(Fun, #{}),
    ?assertEqual(<<"success">>, Res).

test_retry_success() ->
    %% Use process dictionary to keep state across closures
    put(retry_count, 0),
    Fun = fun() ->
        C = get(retry_count),
        put(retry_count, C + 1),
        if C < 2 -> {error, fail};
           true -> {ok, <<"success">>}
        end
    end,
    
    Opts = #{max_attempts => 3, initial_delay => 1, backoff_factor => 1.0},
    {ok, Res} = adk_retry:execute(Fun, Opts),
    ?assertEqual(<<"success">>, Res),
    ?assertEqual(3, get(retry_count)).

test_exhaust_retries() ->
    put(retry_count2, 0),
    Fun = fun() ->
        put(retry_count2, get(retry_count2) + 1),
        {error, fail}
    end,
    
    Opts = #{max_attempts => 3, initial_delay => 1, backoff_factor => 1.0},
    {error, fail} = adk_retry:execute(Fun, Opts),
    ?assertEqual(3, get(retry_count2)).

test_invalid_options() ->
    ?assertEqual({error, invalid_retry_options},
                 adk_retry:execute(fun() -> {ok, never} end,
                                   #{max_attempts => 0})).
