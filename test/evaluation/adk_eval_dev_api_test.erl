-module(adk_eval_dev_api_test).

-include_lib("eunit/include/eunit.hrl").

developer_eval_authoring_and_history_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     fun author_and_run/0}.

author_and_run() ->
    Name = <<"DeveloperEvalAgent",
             (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_eval_agent_test_provider,
                      mode => response}, []),
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = adk_eval_service:start_link(
                      #{store => {adk_eval_store_ets, Store},
                        max_concurrency => 1, max_queue => 4,
                        task_timeout_ms => 3000,
                        task_retention_ms => 100}),
    unlink(Service),
    Scope = {app, <<"developer-eval">>},
    Set = #{<<"schema_version">> => 2,
            <<"id">> => <<"ui-suite">>,
            <<"version">> => <<"1">>,
            <<"cases">> =>
                [#{<<"id">> => <<"case-1">>,
                   <<"turns">> =>
                       [#{<<"input">> => <<"evaluate">>,
                          <<"expected">> => <<"evaluated">>}]}],
            <<"metadata">> => #{}},
    Payload = #{<<"agent_name">> => Name,
                <<"set">> => Set,
                <<"metrics">> =>
                    [#{<<"id">> => <<"semantic">>,
                       <<"metric">> => <<"semantic_quality">>,
                       <<"threshold">> => 1.0,
                       <<"scope">> => <<"turn">>,
                       <<"config">> =>
                           #{<<"algorithm">> => <<"exact_normalized">>}}]},
    try
        {ok, Submitted} = adk_eval_dev_api:submit(Service, Scope, Payload),
        JobId = maps:get(job_id, Submitted),
        {ok, Completed} = await(Service, Scope, JobId, 3000),
        ?assertEqual(completed, maps:get(phase, Completed)),
        {ok, Result} = adk_eval_dev_api:result(Service, Scope, JobId),
        ?assertEqual(true, maps:get(<<"passed">>, Result)),
        {ok, History} = adk_eval_dev_api:list_jobs(
                          Service, Scope, #{limit => 10}),
        ?assertEqual(1, length(maps:get(items, History))),
        {ok, _Baseline} = adk_eval_dev_api:put_baseline(
                            Service, Scope, <<"main">>, JobId),
        ?assertMatch({ok, _}, adk_eval_dev_api:get_baseline(
                                Service, Scope, <<"main">>)),
        ?assertEqual(
           {error, unknown_eval_authoring_fields},
           adk_eval_dev_api:submit(
             Service, Scope,
             Payload#{<<"adapter_module">> => <<"unsafe">>}))
    after
        _ = catch adk_eval_service:stop(Service),
        _ = catch adk_eval_store_ets:stop(Store),
        _ = catch erlang_adk:stop_agent(Agent)
    end.

await(Service, Scope, JobId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_until(Service, Scope, JobId, Deadline).

await_until(Service, Scope, JobId, Deadline) ->
    case adk_eval_dev_api:status(Service, Scope, JobId) of
        {ok, #{phase := Phase} = Status}
          when Phase =:= completed; Phase =:= failed;
               Phase =:= timed_out; Phase =:= cancelled -> status_reply(Status);
        {ok, _} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    receive after 10 -> ok end,
                    await_until(Service, Scope, JobId, Deadline);
                false -> {error, timeout}
            end;
        Error -> Error
    end.

status_reply(Status) -> {ok, Status}.
