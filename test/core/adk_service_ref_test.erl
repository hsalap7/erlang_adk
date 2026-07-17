-module(adk_service_ref_test).
-include_lib("eunit/include/eunit.hrl").

validation_and_bounded_call_test() ->
    Handle = #{test_pid => self(), delay_ms => 100,
               search_reply => {ok, []}},
    Service = {adk_memory_probe_service, Handle},
    ?assertEqual({ok, Service}, adk_service_ref:validate(memory, Service)),
    ?assertMatch(
       {error, {missing_service_callbacks, adk_llm_probe, _}},
       adk_service_ref:validate(memory, {adk_llm_probe, self()})),
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(
       {error, service_timeout},
       adk_service_ref:call(Service, search, [<<"q">>, #{}, 1], 10)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 250).

service_worker_dies_when_caller_dies_test() ->
    Parent = self(),
    Handle = #{test_pid => Parent, delay_ms => 5000,
               report_worker => true, search_reply => {ok, []}},
    Service = {adk_memory_probe_service, Handle},
    Caller = spawn(
               fun() ->
                   Result = adk_service_ref:call(
                              Service, search, [<<"q">>, #{}, 1], 5000),
                   Parent ! {unexpected_service_result, Result}
               end),
    Worker = receive
        {memory_service_worker, WorkerPid} -> WorkerPid
    after 1000 ->
        ?assert(false)
    end,
    WorkerMonitor = erlang:monitor(process, Worker),
    exit(Caller, kill),
    receive
        {'DOWN', WorkerMonitor, process, Worker, killed} -> ok
    after 500 ->
        ?assert(false)
    end,
    receive {unexpected_service_result, _} -> ?assert(false)
    after 0 -> ok
    end.
