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
compress(Events, #{options := #{mode := duplicate_current}}) ->
    Current = lists:last(Events),
    {ok, [Current, Current]};
compress(Events, #{options := #{mode := reverse}}) ->
    {ok, lists:reverse(Events)};
compress(_Events, #{options := #{mode := drop_current}}) ->
    {ok, []};
compress(Events, #{options := #{mode := mutate_current}}) ->
    Current = lists:last(Events),
    Content = maps:get(<<"content">>, Current),
    Mutated = Current#{<<"content">> =>
                           Content#{<<"text">> => <<"mutated">>}},
    {ok, [Mutated]};
compress(Events, #{options := #{mode := partial_exchange}}) ->
    [_Call, Response, Current] = Events,
    {ok, [Response, Current]};
compress(_Events, _Request) ->
    {error, unsupported_test_mode}.

cache_identity() ->
    <<"adk-context-test-compressor-v1">>.
