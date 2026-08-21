-module(adk_eval_store_failing).
-behaviour(adk_eval_store).

-export([ownership_identity/1, capabilities/1,
         put_set/3, get_set/4, list_sets/3,
         create_job/3, create_evaluation/4,
         transition_job/6, get_job/3, list_jobs/3,
         put_baseline/4, get_baseline/3, recover_active/2, prune/3]).

ownership_identity(Store) ->
    adk_eval_store_ets:ownership_identity(handle(Store)).
capabilities(Store) -> adk_eval_store_ets:capabilities(handle(Store)).
put_set(Store, Scope, Set) ->
    adk_eval_store_ets:put_set(handle(Store), Scope, Set).
get_set(Store, Scope, Id, Version) ->
    adk_eval_store_ets:get_set(handle(Store), Scope, Id, Version).
list_sets(Store, Scope, Options) ->
    adk_eval_store_ets:list_sets(handle(Store), Scope, Options).
create_job(Store, Scope, Job) ->
    adk_eval_store_ets:create_job(handle(Store), Scope, Job).
create_evaluation(Store, Scope, Set, Job) ->
    adk_eval_store_ets:create_evaluation(handle(Store), Scope, Set, Job).
transition_job({_Store, completed}, _Scope, _JobId, _Expected,
               completed, _Patch) ->
    {error, deliberate_persistence_failure};
transition_job({_Store, cancelled}, _Scope, _JobId, _Expected,
               cancelled, _Patch) ->
    {error, deliberate_persistence_failure};
transition_job({_Store, running_and_failed}, _Scope, _JobId, _Expected,
               Phase, _Patch)
  when Phase =:= running; Phase =:= failed ->
    {error, deliberate_persistence_failure};
transition_job(Store0, _Scope, _JobId, _Expected, completed, _Patch)
  when is_pid(Store0) ->
    {error, deliberate_persistence_failure};
transition_job(Store, Scope, JobId, Expected, Phase, Patch) ->
    adk_eval_store_ets:transition_job(
      handle(Store), Scope, JobId, Expected, Phase, Patch).
get_job(Store, Scope, JobId) ->
    adk_eval_store_ets:get_job(handle(Store), Scope, JobId).
list_jobs(Store, Scope, Options) ->
    adk_eval_store_ets:list_jobs(handle(Store), Scope, Options).
put_baseline(Store, Scope, Name, JobId) ->
    adk_eval_store_ets:put_baseline(handle(Store), Scope, Name, JobId).
get_baseline(Store, Scope, Name) ->
    adk_eval_store_ets:get_baseline(handle(Store), Scope, Name).
recover_active(Store, Reason) ->
    adk_eval_store_ets:recover_active(handle(Store), Reason).
prune(Store, Scope, Options) ->
    adk_eval_store_ets:prune(handle(Store), Scope, Options).

handle({Store, _Mode}) -> Store;
handle(Store) -> Store.
