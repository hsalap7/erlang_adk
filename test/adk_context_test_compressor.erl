-module(adk_context_test_compressor).
-behaviour(adk_context_compressor).

-export([compress/2, cache_identity/0]).

compress(Events, #{options := #{mode := last}}) ->
    {ok, [lists:last(Events)]};
compress(_Events, #{options := #{mode := timeout, notify := Notify}}) ->
    Notify ! {compressor_started, self()},
    receive stop -> {ok, []} after 5000 -> {ok, []} end;
compress(_Events, #{options := #{mode := crash}}) ->
    erlang:error(intentional_compressor_crash);
compress(Events, #{options := #{mode := identity}}) ->
    {ok, Events};
compress(_Events, _Request) ->
    {error, unsupported_test_mode}.

cache_identity() ->
    <<"adk-context-test-compressor-v1">>.
