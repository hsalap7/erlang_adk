-module(adk_a2a_v1_test_auth).
-behaviour(adk_a2a_v1_auth).

-export([authorize/3]).

authorize(_Operation, Headers, _Summary) ->
    case maps:get(<<"authorization">>, Headers, undefined) of
        <<"Bearer alice-secret">> ->
            {ok, #{subject => <<"alice">>, token => <<"alice-secret">>},
             <<"alice">>};
        <<"Bearer bob-secret">> ->
            {ok, #{subject => <<"bob">>, token => <<"bob-secret">>},
             <<"bob">>};
        _ -> {error, unauthenticated}
    end.
