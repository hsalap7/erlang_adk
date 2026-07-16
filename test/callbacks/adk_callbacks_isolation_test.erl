-module(adk_callbacks_isolation_test).

-include_lib("eunit/include/eunit.hrl").

-export([
    ordered/3,
    replace_second/3,
    halt_first/3,
    crash_then_replace/3,
    timeout_then_replace/3,
    exhaust_heap_then_replace/3
]).

-define(APP, erlang_adk).

callbacks_isolation_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun ordered_handlers_and_control_results_are_preserved/0,
      fun callback_crash_is_fail_open_and_workers_are_reaped/0,
      fun callback_timeout_is_fail_open_and_workers_are_reaped/0,
      fun callback_heap_exhaustion_is_fail_open_and_workers_are_reaped/0]}.

setup() ->
    Previous =
        [{Key, application:get_env(?APP, Key)}
         || Key <- [callback_timeout_ms, callback_max_heap_words]],
    ok = application:set_env(?APP, callback_timeout_ms, 100),
    ok = application:set_env(?APP, callback_max_heap_words, 32768),
    Previous.

cleanup(Previous) ->
    lists:foreach(fun restore_env/1, Previous),
    flush_probe_messages().

ordered_handlers_and_control_results_are_preserved() ->
    Counter = atomics:new(1, []),
    Tag = make_ref(),
    ok = adk_callbacks:execute(
           [?MODULE, ?MODULE, ?MODULE], ordered,
           [self(), Tag, Counter]),
    Workers = receive_workers(Tag, 3, []),
    ?assertEqual([1, 2, 3], [N || {N, _Pid} <- Workers]),
    assert_workers_reaped(Workers),

    atomics:put(Counter, 1, 0),
    ReplaceTag = make_ref(),
    ?assertEqual(
       {replace, <<"replacement">>},
       adk_callbacks:run(
         [?MODULE, ?MODULE, ?MODULE], replace_second,
         [self(), ReplaceTag, Counter])),
    ReplaceWorkers = receive_workers(ReplaceTag, 2, []),
    ?assertEqual([1, 2], [N || {N, _Pid} <- ReplaceWorkers]),
    assert_workers_reaped(ReplaceWorkers),
    assert_no_probe(ReplaceTag),

    atomics:put(Counter, 1, 0),
    HaltTag = make_ref(),
    ?assertEqual(
       {halt, <<"halted">>},
       adk_callbacks:run(
         [?MODULE, ?MODULE], halt_first,
         [self(), HaltTag, Counter])),
    HaltWorkers = receive_workers(HaltTag, 1, []),
    assert_workers_reaped(HaltWorkers),
    assert_no_probe(HaltTag).

callback_crash_is_fail_open_and_workers_are_reaped() ->
    assert_first_worker_failure_isolated(crash_then_replace,
                                         <<"after-crash">>).

callback_timeout_is_fail_open_and_workers_are_reaped() ->
    assert_first_worker_failure_isolated(timeout_then_replace,
                                         <<"after-timeout">>).

callback_heap_exhaustion_is_fail_open_and_workers_are_reaped() ->
    assert_first_worker_failure_isolated(exhaust_heap_then_replace,
                                         <<"after-heap-exhaustion">>).

assert_first_worker_failure_isolated(Hook, Replacement) ->
    Counter = atomics:new(1, []),
    Tag = make_ref(),
    ?assertEqual(
       {replace, Replacement},
       adk_callbacks:run(
         [?MODULE, ?MODULE], Hook, [self(), Tag, Counter])),
    Workers = receive_workers(Tag, 2, []),
    ?assertEqual([1, 2], [N || {N, _Pid} <- Workers]),
    assert_workers_reaped(Workers),
    assert_no_monitor_messages().

ordered(Parent, Tag, Counter) ->
    _ = notify_order(Parent, Tag, Counter),
    ok.

replace_second(Parent, Tag, Counter) ->
    case notify_order(Parent, Tag, Counter) of
        2 -> {replace, <<"replacement">>};
        _ -> continue
    end.

halt_first(Parent, Tag, Counter) ->
    _ = notify_order(Parent, Tag, Counter),
    {halt, <<"halted">>}.

crash_then_replace(Parent, Tag, Counter) ->
    case notify_order(Parent, Tag, Counter) of
        1 -> erlang:error(callback_fixture_crash);
        _ -> {replace, <<"after-crash">>}
    end.

timeout_then_replace(Parent, Tag, Counter) ->
    case notify_order(Parent, Tag, Counter) of
        1 -> receive stop -> continue end;
        _ -> {replace, <<"after-timeout">>}
    end.

exhaust_heap_then_replace(Parent, Tag, Counter) ->
    case notify_order(Parent, Tag, Counter) of
        1 -> exhaust_heap([]);
        _ -> {replace, <<"after-heap-exhaustion">>}
    end.

notify_order(Parent, Tag, Counter) ->
    N = atomics:add_get(Counter, 1, 1),
    Parent ! {callback_probe, Tag, N, self()},
    N.

exhaust_heap(Acc) ->
    exhaust_heap([make_ref(), make_ref(), make_ref(), make_ref() | Acc]).

receive_workers(_Tag, 0, Acc) ->
    lists:reverse(Acc);
receive_workers(Tag, Remaining, Acc) ->
    receive
        {callback_probe, Tag, N, Pid} ->
            receive_workers(Tag, Remaining - 1, [{N, Pid} | Acc])
    after 1000 ->
        error({missing_callback_probe, Tag, Remaining})
    end.

assert_workers_reaped(Workers) ->
    Pids = [Pid || {_N, Pid} <- Workers],
    ?assertEqual(length(Pids), length(lists:usort(Pids))),
    lists:foreach(
      fun(Pid) -> ?assertNot(erlang:is_process_alive(Pid)) end,
      Pids).

assert_no_probe(Tag) ->
    receive
        {callback_probe, Tag, N, Pid} ->
            error({unexpected_callback_probe, N, Pid})
    after 20 ->
        ok
    end.

assert_no_monitor_messages() ->
    receive
        {'DOWN', Ref, process, Pid, Reason} ->
            error({leaked_callback_monitor, Ref, Pid, Reason})
    after 0 ->
        ok
    end.

restore_env({Key, {ok, Value}}) ->
    application:set_env(?APP, Key, Value);
restore_env({Key, undefined}) ->
    application:unset_env(?APP, Key).

flush_probe_messages() ->
    receive
        {callback_probe, _Tag, _N, _Pid} -> flush_probe_messages()
    after 0 ->
        ok
    end.
