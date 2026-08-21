-module(adk_memory_policy_test_hook).
-behaviour(adk_memory_policy).
-export([evaluate/5]).

evaluate(hang, _Action, _Scope, _Resource, _Context) ->
    receive stop -> allow after 5000 -> allow end;
evaluate(crash, _Action, _Scope, _Resource, _Context) ->
    erlang:error(<<"password=do-not-leak">>).
