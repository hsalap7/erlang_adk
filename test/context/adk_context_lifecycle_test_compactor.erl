-module(adk_context_lifecycle_test_compactor).

-behaviour(adk_context_compactor).

-export([compact/2, reset/0, last_worker/0]).

-define(WORKER_KEY, {?MODULE, worker}).

reset() ->
    persistent_term:erase(?WORKER_KEY),
    ok.

last_worker() ->
    persistent_term:get(?WORKER_KEY, undefined).

compact(_Events, Request) ->
    Options = maps:get(<<"options">>, Request, #{}),
    persistent_term:put(?WORKER_KEY, self()),
    case maps:get(<<"mode">>, Options, <<"summary">>) of
        <<"summary">> -> {ok, <<"Bounded summary of older context.">>};
        <<"delay">> ->
            timer:sleep(maps:get(<<"delay_ms">>, Options, 1000)),
            {ok, <<"Delayed summary.">>};
        <<"crash">> -> erlang:error(compactor_fixture_crash);
        <<"error">> -> {error, fixture_failure};
        <<"oversized">> -> {ok, binary:copy(<<"x">>, 4096)}
    end.
