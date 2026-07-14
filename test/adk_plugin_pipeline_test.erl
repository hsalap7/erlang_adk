-module(adk_plugin_pipeline_test).
-include_lib("eunit/include/eunit.hrl").

ordered_replace_and_redaction_test() ->
    {ok, Pipeline} = adk_plugin_pipeline:compile([
        descriptor(<<"observer-1">>, observe, open,
                   #{label => first, test_pid => self(), action => observe}),
        descriptor(<<"intervention">>, intervene, closed,
                   #{label => second, test_pid => self(), action => replace,
                     replacement => <<"rewritten">>}),
        descriptor(<<"observer-2">>, observe, open,
                   #{label => third, test_pid => self(), action => observe})
    ]),
    Context = #{run_id => <<"run-1">>, access_token => <<"secret">>,
                nested => #{client_secret => <<"also-secret">>, safe => 7}},
    {ok, <<"rewritten">>, Trace} =
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
    ?assertEqual([<<"observed">>, <<"replaced">>, <<"observed">>],
                 [maps:get(<<"outcome">>, Entry) || Entry <- Trace]).

fail_open_and_fail_closed_test() ->
    Open = descriptor(<<"open-crash">>, intervene, open,
                      #{label => open_crash, test_pid => self(),
                        action => crash}),
    Later = descriptor(<<"later">>, intervene, closed,
                       #{label => later, test_pid => self(), action => replace,
                         replacement => <<"survived">>}),
    {ok, OpenPipeline} = adk_plugin_pipeline:compile([Open, Later]),
    {ok, <<"survived">>, OpenTrace} =
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
    {error, {plugin_failed, <<"observer">>, after_run,
             observer_cannot_replace}, _} =
        adk_plugin_pipeline:run(Pipeline, after_run, #{}, original).

invalid_module_does_not_create_atom_test() ->
    Before = erlang:system_info(atom_count),
    ?assertMatch(
       {error, {invalid_plugin_descriptor, 0, invalid_module}},
       adk_plugin_pipeline:compile([
           #{id => <<"bad">>, module => <<"untrusted.module.name">>}
       ])),
    ?assertEqual(Before, erlang:system_info(atom_count)).

descriptor(Id, Mode, FailurePolicy, Config) ->
    #{id => Id, module => adk_plugin_test_plugin, mode => Mode,
      failure_policy => FailurePolicy, config => Config,
      timeout_ms => 1000, max_heap_words => 100000}.

receive_plugin(Label) ->
    receive
        {plugin_called, Label, _, _} = Message -> Message
    after 1000 -> erlang:error({plugin_message_timeout, Label})
    end.
