-module(adk_plugin_pipeline_test).
-include_lib("eunit/include/eunit.hrl").

ordered_amendment_continues_test() ->
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"observer-1">>, observe, open,
                   #{label => first, test_pid => self(), action => observe}),
        descriptor(<<"intervention">>, intervene, closed,
                   #{label => second, test_pid => self(), action => amend,
                     amendment => <<"rewritten">>}),
        descriptor(<<"observer-2">>, observe, open,
                   #{label => third, test_pid => self(), action => observe})
    ]),
    Context = #{run_id => <<"run-1">>, access_token => <<"secret">>,
                nested => #{client_secret => <<"also-secret">>, safe => 7}},
    {amend, <<"rewritten">>, Trace} =
        adk_plugin_pipeline:run(Pipeline, before_run, Context, <<"original">>),
    {plugin_called, first, FirstContext, <<"original">>} =
        receive_plugin(first),
    {plugin_called, second, SecondContext, <<"original">>} =
        receive_plugin(second),
    {plugin_called, third, ThirdContext, <<"rewritten">>} =
        receive_plugin(third),
    lists:foreach(fun(SafeContext) ->
        ?assertNot(maps:is_key(<<"access_token">>, SafeContext)),
        Nested = maps:get(<<"nested">>, SafeContext),
        ?assertNot(maps:is_key(<<"client_secret">>, Nested)),
        ?assertEqual(7, maps:get(<<"safe">>, Nested))
    end, [FirstContext, SecondContext, ThirdContext]),
    ?assertEqual([<<"observer-1">>, <<"intervention">>, <<"observer-2">>],
                 [maps:get(<<"plugin_id">>, Entry) || Entry <- Trace]),
    ?assertEqual([<<"observed">>, <<"amended">>, <<"observed">>],
                 [maps:get(<<"outcome">>, Entry) || Entry <- Trace]).

return_stops_remaining_plugins_test() ->
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"returner">>, intervene, closed,
                   #{label => returner, test_pid => self(),
                     action => return, returned => <<"cached">>}),
        descriptor(<<"must-not-run">>, observe, closed,
                   #{label => must_not_run, test_pid => self(),
                     action => observe})
    ]),
    {return, <<"cached">>, [Trace]} =
        adk_plugin_pipeline:run(Pipeline, before_model, #{}, request),
    ?assertEqual(<<"returned">>, maps:get(<<"outcome">>, Trace)),
    {plugin_called, returner, _, #{}} = receive_plugin(returner),
    receive
        {plugin_called, must_not_run, _, _} -> ?assert(false)
    after 30 -> ok
    end.

legacy_replace_is_early_return_test() ->
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"legacy">>, intervene, closed,
                   #{action => replace, replacement => legacy_value})
    ]),
    ?assertMatch(
       {return, legacy_value, [#{<<"outcome">> := <<"returned">>}]},
       adk_plugin_pipeline:run(Pipeline, before_agent, #{}, original)).

fail_open_and_fail_closed_test() ->
    Open = descriptor(<<"open-crash">>, intervene, open,
                      #{label => open_crash, test_pid => self(),
                        action => crash}),
    Later = descriptor(<<"later">>, intervene, closed,
                       #{label => later, test_pid => self(), action => replace,
                         replacement => <<"survived">>}),
    {ok, OpenPipeline} = adk_plugin_pipeline:compile([Open, Later]),
    {return, <<"survived">>, OpenTrace} =
        adk_plugin_pipeline:run(OpenPipeline, on_error, #{}, failed),
    ?assertEqual(<<"exception">>,
                 maps:get(<<"outcome">>, hd(OpenTrace))),
    SafeFailure =
        {adk_failure,
         #{component => plugin, operation => on_error,
           class => external, reason => failed}},
    {plugin_called, open_crash, _, SafeFailure} = receive_plugin(open_crash),
    {plugin_called, later, _, SafeFailure} = receive_plugin(later),

    Closed = descriptor(<<"closed-crash">>, intervene, closed,
                        #{label => closed_crash, test_pid => self(),
                          action => crash}),
    {ok, ClosedPipeline} = adk_plugin_pipeline:compile([Closed, Later]),
    {error, {plugin_failed, <<"closed-crash">>, on_error, exception},
     [ClosedTrace]} =
        adk_plugin_pipeline:run(ClosedPipeline, on_error, #{}, failed),
    ?assertEqual(<<"exception">>, maps:get(<<"outcome">>, ClosedTrace)),
    {plugin_called, closed_crash, _, SafeFailure} =
        receive_plugin(closed_crash),
    receive
        {plugin_called, later, _, _} -> ?assert(false)
    after 20 -> ok
    end.

timeout_and_heap_limit_test() ->
    Timeout = (descriptor(<<"timeout">>, intervene, closed,
                          #{action => timeout, delay_ms => 500}))#{
        timeout_ms => 20
    },
    {ok, TimeoutPipeline} = adk_plugin_pipeline:compile([Timeout]),
    Started = erlang:monotonic_time(millisecond),
    {error, {plugin_failed, <<"timeout">>, before_model, timeout}, _} =
        adk_plugin_pipeline:run(TimeoutPipeline, before_model, #{}, input),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),

    HeapBomb = (descriptor(<<"heap">>, intervene, closed,
                           #{action => heap_bomb}))#{
        max_heap_words => 2000, timeout_ms => 1000
    },
    {ok, HeapPipeline} = adk_plugin_pipeline:compile([HeapBomb]),
    {error, {plugin_failed, <<"heap">>, before_tool, worker_down}, _} =
        adk_plugin_pipeline:run(HeapPipeline, before_tool, #{}, input).

observer_cannot_intervene_test() ->
    Observer = descriptor(<<"observer">>, observe, closed,
                          #{action => replace, replacement => unexpected}),
    {ok, Pipeline} = adk_plugin_pipeline:compile([Observer]),
    {error, {plugin_failed, <<"observer">>, after_model,
             observer_cannot_return}, _} =
        adk_plugin_pipeline:run(Pipeline, after_model, #{}, original).

notifications_are_best_effort_and_immutable_test() ->
    Crash = descriptor(<<"closed-crash">>, intervene, closed,
                       #{label => notification_crash,
                         test_pid => self(), action => crash}),
    Return = descriptor(<<"ignored-return">>, intervene, closed,
                        #{label => notification_return,
                          test_pid => self(), action => return,
                          returned => masked}),
    {ok, Pipeline} = adk_plugin_pipeline:compile([Crash, Return]),
    SafeFailure =
        {adk_failure,
         #{component => plugin, operation => on_run_error,
           class => external, reason => original_failure}},
    {continue, SafeFailure, Trace} =
        adk_plugin_pipeline:run(
          Pipeline, on_run_error, #{}, original_failure),
    ?assertEqual([<<"exception">>, <<"notification_result_ignored">>],
                 [maps:get(<<"outcome">>, Entry) || Entry <- Trace]),
    _ = receive_plugin(notification_crash),
    _ = receive_plugin(notification_return).

result_size_and_type_are_bounded_test() ->
    Large = (descriptor(<<"large">>, intervene, closed,
                        #{action => large_result,
                          result_bytes => 2048}))#{
                max_result_bytes => 128},
    {ok, LargePipeline} = adk_plugin_pipeline:compile([Large]),
    ?assertMatch(
       {error, {plugin_failed, <<"large">>, before_model,
                result_too_large}, _},
       adk_plugin_pipeline:run(
         LargePipeline, before_model, #{}, request)),
    Unsafe = descriptor(<<"unsafe">>, intervene, closed,
                        #{action => unsafe_result}),
    {ok, UnsafePipeline} = adk_plugin_pipeline:compile([Unsafe]),
    ?assertMatch(
       {error, {plugin_failed, <<"unsafe">>, before_tool,
                invalid_result_type}, _},
       adk_plugin_pipeline:run(
         UnsafePipeline, before_tool, #{}, request)).

owner_death_cancels_callback_worker_test() ->
    Blocking = (descriptor(
                  <<"owner-cancel">>, intervene, closed,
                  #{action => timeout, delay_ms => 5000,
                    test_pid => self(), label => owner_cancel,
                    report_worker => true}))#{timeout_ms => 10000},
    {ok, Pipeline} = adk_plugin_pipeline:compile([Blocking]),
    Owner = spawn(fun() ->
        _ = adk_plugin_pipeline:run(
              Pipeline, before_run, #{}, value)
    end),
    Worker = receive
        {plugin_worker, Pid} -> Pid
    after 1000 -> erlang:error(plugin_worker_not_started)
    end,
    WorkerMonitor = erlang:monitor(process, Worker),
    exit(Owner, kill),
    receive
        {'DOWN', WorkerMonitor, process, Worker, _} -> ok
    after 1000 -> erlang:error(plugin_worker_not_cancelled)
    end,
    receive
        {plugin_called, owner_cancel, _, _} -> ok
    after 0 -> ok
    end.

invalid_module_does_not_create_atom_test() ->
    Before = erlang:system_info(atom_count),
    ?assertMatch(
       {error, {invalid_plugin_descriptor, 0, invalid_module}},
       adk_plugin_pipeline:compile([
           #{id => <<"bad">>, module => <<"untrusted.module.name">>}
       ])),
    ?assertEqual(Before, erlang:system_info(atom_count)).

plugin_collection_identity_and_resource_bounds_test() ->
    Plugins = [descriptor(
                 <<"bounded-", (integer_to_binary(I))/binary>>,
                 observe, open, #{}) || I <- lists:seq(1, 129)],
    ?assertEqual({error, {plugin_limit, 128}},
                 adk_plugin_pipeline:compile(Plugins)),
    ?assertMatch(
       {error, {invalid_plugin_descriptor, 0, invalid_id}},
       adk_plugin_pipeline:compile([
         descriptor(binary:copy(<<"i">>, 257), observe, open, #{})
       ])),
    Base = descriptor(<<"bounded">>, observe, open, #{}),
    ?assertMatch(
       {error, {invalid_plugin_descriptor, 0,
                {invalid_timeout_ms, 120001}}},
       adk_plugin_pipeline:compile([Base#{timeout_ms => 120001}])),
    ?assertMatch(
       {error, {invalid_plugin_descriptor, 0,
                {invalid_max_heap_words, 10000001}}},
       adk_plugin_pipeline:compile(
         [Base#{max_heap_words => 10000001}])),
    ?assertMatch(
       {error, {invalid_plugin_descriptor, 0,
                {invalid_max_result_bytes, 1048577}}},
       adk_plugin_pipeline:compile(
         [Base#{max_result_bytes => 1048577}])),
    ?assertMatch(
       {error, {invalid_plugin_descriptor, 0,
                invalid_plugin_config}},
       adk_plugin_pipeline:compile(
         [Base#{config =>
                    #{blob => binary:copy(<<0>>, 1048577)}}])).

descriptor(Id, Mode, FailurePolicy, Config) ->
    #{id => Id, module => adk_plugin_test_plugin, mode => Mode,
      failure_policy => FailurePolicy, config => Config,
      timeout_ms => 1000, max_heap_words => 100000}.

receive_plugin(Label) ->
    receive
        {plugin_called, Label, _, _} = Message -> Message
    after 1000 -> erlang:error({plugin_message_timeout, Label})
    end.
