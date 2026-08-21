-module(adk_eval_worker_rpc_test).

-include_lib("eunit/include/eunit.hrl").

rpc_worker_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun direct_worker_completes_and_cancels/0,
      fun service_uses_configured_worker/0,
      fun unavailable_node_fails_closed/0]}.

direct_worker_completes_and_cancels() ->
    Request = request(0),
    {ok, Ref, _Handle} = adk_eval_worker_rpc:start(
                           Request, self(), #{nodes => [node()],
                                              timeout_ms => 3000}),
    receive
        {adk_eval_worker_terminal, adk_eval_worker_rpc, Ref,
         {completed, {ok, Result}}} ->
            ?assertEqual(true, maps:get(<<"passed">>, Result))
    after 4000 -> erlang:error(distributed_eval_did_not_complete)
    end,

    {ok, CancelRef, Handle} = adk_eval_worker_rpc:start(
                                request(5000), self(),
                                #{nodes => [node()], timeout_ms => 10000}),
    ok = adk_eval_worker_rpc:cancel(Handle, user_cancelled),
    receive
        {adk_eval_worker_terminal, adk_eval_worker_rpc, CancelRef,
         {cancelled, _}} -> ok
    after 2000 -> erlang:error(distributed_eval_did_not_cancel)
    end.

service_uses_configured_worker() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = adk_eval_service:start_link(
      #{store => {adk_eval_store_ets, Store},
        max_concurrency => 1, max_queue => 1,
        task_timeout_ms => 3000, task_retention_ms => 0,
        worker => #{module => adk_eval_worker_rpc,
                    config => #{nodes => [node()]}}}),
    unlink(Service),
    Scope = {app, <<"eval-rpc-worker">>},
    try
        {ok, Submitted} = adk_eval_service:submit(Service, Scope, request(0)),
        JobId = maps:get(job_id, Submitted),
        {ok, Completed} = await(Service, Scope, JobId, 4000),
        ?assertEqual(completed, maps:get(phase, Completed)),
        {ok, Capabilities} = adk_eval_service:capabilities(Service),
        ?assertEqual(rpc,
                     maps:get(transport, maps:get(worker, Capabilities)))
    after
        ok = adk_eval_service:stop(Service),
        ok = adk_eval_store_ets:stop(Store)
    end.

unavailable_node_fails_closed() ->
    ?assertEqual(
       {error, eval_worker_node_unavailable},
       adk_eval_worker_rpc:start(
         request(0), self(), #{nodes => ['not-connected@example']})).

request(Delay) ->
    {ok, Set} = adk_eval_set:new(
                  <<"rpc-worker">>, <<"1">>,
                  [#{id => <<"case">>, input => <<"expected">>,
                     expected => <<"expected">>}]),
    #{set => Set,
      adapter => #{module => adk_eval_set_test_adapter,
                   target => ignored,
                   config => #{mode => echo_expected, delay_ms => Delay}},
      metrics => [#{id => <<"exact">>,
                    module => adk_eval_set_exact_metric,
                    kind => metric, threshold => 1.0, config => #{}}],
      options => #{concurrency => 1}, metadata => #{}}.

await(Service, Scope, JobId, Remaining) when Remaining > 0 ->
    case adk_eval_service:status(Service, Scope, JobId) of
        {ok, #{phase := completed} = Job} -> {ok, Job};
        {ok, #{phase := Phase}} when Phase =:= failed;
                                      Phase =:= timed_out;
                                      Phase =:= cancelled ->
            {error, {unexpected_terminal, Phase}};
        _ -> timer:sleep(20), await(Service, Scope, JobId, Remaining - 20)
    end;
await(_Service, _Scope, _JobId, _Remaining) -> {error, timeout}.
