-module(adk_a2a_v1_auth_test).

-include_lib("eunit/include/eunit.hrl").

isolated_authentication_test_() ->
    [fun successful_hook_is_normalized/0,
     fun crashing_hook_fails_closed/0,
     fun slow_hook_is_killed/0,
     fun heap_exhaustion_fails_closed/0,
     fun oversized_result_fails_closed/0,
     fun hook_dies_with_request_owner/0,
     fun late_reply_does_not_pollute_owner_mailbox/0,
     fun invalid_worker_options_fail_closed/0].

successful_hook_is_normalized() ->
    Hook = fun(_Operation, _Headers, _Summary) ->
        {ok, #{subject => <<"alice">>}, <<"alice">>}
    end,
    {ok, Auth} = adk_a2a_v1_auth:authorize(
                   Hook, <<"GetTask">>, #{}, #{}, worker_options()),
    ?assertEqual(adk_a2a_v1_auth:scope(<<"alice">>),
                 maps:get(scope, Auth)).

crashing_hook_fails_closed() ->
    Hook = fun(_Operation, _Headers, _Summary) -> error(secret_failure) end,
    ?assertEqual(
       {error, unauthenticated},
       adk_a2a_v1_auth:authorize(
         Hook, <<"GetTask">>, #{}, #{}, worker_options())).

slow_hook_is_killed() ->
    Owner = self(),
    Hook = fun(_Operation, _Headers, _Summary) ->
        Owner ! {auth_worker, self()},
        timer:sleep(5000),
        {ok, #{}, <<"too-late">>}
    end,
    ?assertEqual(
       {error, unauthenticated},
       adk_a2a_v1_auth:authorize(
         Hook, <<"GetTask">>, #{}, #{},
         #{timeout_ms => 10, max_heap_words => 10000})),
    Worker = receive {auth_worker, Pid} -> Pid after 1000 -> error(no_worker) end,
    ?assertNot(is_process_alive(Worker)).

heap_exhaustion_fails_closed() ->
    Hook = fun(_Operation, _Headers, _Summary) ->
        _ = lists:seq(1, 1000000),
        {ok, #{}, <<"too-large">>}
    end,
    ?assertEqual(
       {error, unauthenticated},
       adk_a2a_v1_auth:authorize(
         Hook, <<"GetTask">>, #{}, #{},
         #{timeout_ms => 1000, max_heap_words => 1000})).

oversized_result_fails_closed() ->
    Hook = fun(_Operation, _Headers, _Summary) ->
        {ok, #{profile => binary:copy(<<"x">>, 1048577)}, <<"alice">>}
    end,
    ?assertEqual(
       {error, unauthenticated},
       adk_a2a_v1_auth:authorize(
         Hook, <<"GetTask">>, #{}, #{},
         #{timeout_ms => 1000, max_heap_words => 300000})).

hook_dies_with_request_owner() ->
    TestProcess = self(),
    RequestOwner = spawn(fun() ->
        Hook = fun(_Operation, _Headers, _Summary) ->
            TestProcess ! {owned_server_auth_started, self()},
            receive release -> {ok, #{}, <<"late">>} end
        end,
        Result = adk_a2a_v1_auth:authorize(
                   Hook, <<"GetTask">>, #{}, #{},
                   #{timeout_ms => 10000, max_heap_words => 10000}),
        TestProcess ! {unexpected_server_auth_result, Result}
    end),
    OwnerMonitor = erlang:monitor(process, RequestOwner),
    AuthWorker = receive
        {owned_server_auth_started, Pid} -> Pid
    after 500 -> error(owned_server_auth_worker_not_started)
    end,
    WorkerMonitor = erlang:monitor(process, AuthWorker),
    exit(RequestOwner, kill),
    receive
        {'DOWN', OwnerMonitor, process, RequestOwner, killed} -> ok
    after 500 -> error(server_auth_owner_not_killed)
    end,
    receive
        {'DOWN', WorkerMonitor, process, AuthWorker, killed} -> ok
    after 500 -> error(orphaned_server_auth_worker)
    end,
    receive
        {unexpected_server_auth_result, Result} ->
            error({unexpected_server_auth_result, Result})
    after 0 -> ok
    end.

late_reply_does_not_pollute_owner_mailbox() ->
    TestProcess = self(),
    RequestOwner = spawn(fun() ->
        Hook = fun(_Operation, _Headers, _Summary) ->
            TestProcess ! {late_server_auth_started, self()},
            receive release -> {ok, #{}, <<"late">>} end
        end,
        Result = adk_a2a_v1_auth:authorize(
                   Hook, <<"GetTask">>, #{}, #{},
                   #{timeout_ms => 20, max_heap_words => 10000}),
        timer:sleep(30),
        {message_queue_len, QueueLength} =
            erlang:process_info(self(), message_queue_len),
        TestProcess ! {late_server_auth_result, Result, QueueLength}
    end),
    OwnerMonitor = erlang:monitor(process, RequestOwner),
    AuthWorker = receive
        {late_server_auth_started, Pid} -> Pid
    after 500 -> error(late_server_auth_worker_not_started)
    end,
    timer:sleep(30),
    AuthWorker ! release,
    receive
        {late_server_auth_result, {error, unauthenticated}, 0} -> ok;
        {late_server_auth_result, Result, QueueLength} ->
            error({unexpected_late_server_auth_result,
                   Result, QueueLength})
    after 1000 -> error(late_server_auth_owner_stuck)
    end,
    receive
        {'DOWN', OwnerMonitor, process, RequestOwner, normal} -> ok
    after 1000 -> error(late_server_auth_owner_not_stopped)
    end,
    ?assertNot(is_process_alive(AuthWorker)).

invalid_worker_options_fail_closed() ->
    Hook = fun(_Operation, _Headers, _Summary) ->
        {ok, #{}, <<"alice">>}
    end,
    ?assertEqual(
       {error, unauthenticated},
       adk_a2a_v1_auth:authorize(
         Hook, <<"GetTask">>, #{}, #{},
         #{timeout_ms => 30001, max_heap_words => 300000})).

worker_options() ->
    #{timeout_ms => 1000, max_heap_words => 10000}.
