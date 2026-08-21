-module(adk_artifact_reconcile_test_handler).
-behaviour(adk_artifact_reconcile_handler).
-export([reconcile/3]).

reconcile(#{mode := Outcome, test_pid := TestPid}, Work, _Timeout)
  when Outcome =:= committed; Outcome =:= compensated;
       Outcome =:= not_applied ->
    TestPid ! {artifact_reconcile_seen, Work},
    {ok, Outcome};
reconcile(#{mode := error}, _Work, _Timeout) ->
    {error, {authorization, <<"Bearer artifact-secret">>}};
reconcile(#{mode := hang}, _Work, _Timeout) ->
    receive stop -> ok after 5000 -> ok end,
    {error, late}.
