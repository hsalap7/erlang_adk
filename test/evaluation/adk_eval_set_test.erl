-module(adk_eval_set_test).
-include_lib("eunit/include/eunit.hrl").

set_and_result_roundtrip_multiturn_trajectory_test() ->
    {ok, Set} = stateful_set(),
    ?assertNot(maps:is_key(<<"access_token">>,
                           maps:get(<<"metadata">>, Set))),
    SetJson = jsx:encode(Set),
    ?assertEqual({ok, Set},
                 adk_eval_set:decode(jsx:decode(SetJson, [return_maps]))),
    Adapter = #{module => adk_eval_set_test_adapter,
                target => ignored, config => #{mode => stateful}},
    {ok, Result} = adk_eval_set:run(
                     Adapter, Set, passing_metrics(),
                     #{concurrency => 2,
                       result_metadata => #{build => <<"abc">>,
                                            client_secret => <<"hidden">>}}),
    ?assertEqual(true, maps:get(<<"passed">>, Result)),
    ?assertEqual(1.0, maps:get(<<"pass_rate">>, Result)),
    [Case] = maps:get(<<"cases">>, Result),
    ?assertEqual(<<"passed">>, maps:get(<<"status">>, Case)),
    [FirstTurn, SecondTurn] = maps:get(<<"turns">>, Case),
    ?assertEqual(<<"stored">>, maps:get(<<"actual">>, FirstTurn)),
    ?assertEqual(<<"Erlang">>, maps:get(<<"actual">>, SecondTurn)),
    ?assertEqual(2, length(maps:get(<<"events">>, FirstTurn))),
    ?assertEqual(4, length(maps:get(<<"trajectory">>, Case))),
    lists:foreach(fun(Item) ->
        ?assertNot(maps:is_key(<<"args">>, Item)),
        ?assertNot(maps:is_key(<<"result">>, Item))
    end, maps:get(<<"trajectory">>, Case)),
    AdapterMetadata = maps:get(<<"adapter_metadata">>, FirstTurn),
    ?assertNot(maps:is_key(<<"api_key">>, AdapterMetadata)),
    [Exact, Judge] = maps:get(<<"metrics">>, FirstTurn),
    ?assertEqual(true, maps:get(<<"passed">>, Exact)),
    ?assertEqual(<<"judge">>, maps:get(<<"kind">>, Judge)),
    ?assertNot(maps:is_key(<<"access_token">>,
                           maps:get(<<"metadata">>, Exact))),
    ?assertNot(maps:is_key(<<"client_secret">>,
                           maps:get(<<"metadata">>, Result))),
    ResultJson = jsx:encode(Result),
    DecodedResult = jsx:decode(ResultJson, [return_maps]),
    ?assertEqual({ok, Result}, adk_eval_set:decode_result(DecodedResult)).

threshold_and_metric_failure_test() ->
    {ok, Set} = adk_eval_set:new(
                  <<"threshold">>, <<"1">>,
                  [#{id => <<"case">>, input => <<"hello">>,
                     expected => <<"hello">>}]),
    Adapter = #{module => adk_eval_set_test_adapter, target => ignored,
                config => #{mode => echo_expected}},
    HighJudge = #{id => <<"judge">>, module => adk_eval_set_static_judge,
                  kind => judge, threshold => 0.9,
                  config => #{score => 0.8}},
    Broken = #{id => <<"broken">>, module => adk_eval_set_exact_metric,
               threshold => 0.1, config => #{action => crash}},
    {ok, Result} = adk_eval_set:run(Adapter, Set, [HighJudge, Broken], #{}),
    ?assertEqual(false, maps:get(<<"passed">>, Result)),
    [Case] = maps:get(<<"cases">>, Result),
    [Turn] = maps:get(<<"turns">>, Case),
    [JudgeResult, BrokenResult] = maps:get(<<"metrics">>, Turn),
    ?assertEqual(false, maps:get(<<"passed">>, JudgeResult)),
    ?assertEqual(<<"error">>, maps:get(<<"status">>, BrokenResult)),
    ?assertEqual(0.0, maps:get(<<"score">>, BrokenResult)).

adapter_failure_is_structured_test() ->
    {ok, Set} = adk_eval_set:new(
                  <<"failure">>, <<"1">>,
                  [#{id => <<"case">>, input => <<"x">>, expected => <<"y">>}]),
    Adapter = #{module => adk_eval_set_test_adapter, target => ignored,
                config => #{mode => fail}},
    {ok, Result} = adk_eval_set:run(Adapter, Set, passing_metrics(), #{}),
    [Case] = maps:get(<<"cases">>, Result),
    ?assertEqual(<<"error">>, maps:get(<<"status">>, Case)),
    ?assertEqual(<<"deliberately_failed">>, maps:get(<<"error">>, Case)),
    ?assertEqual([], maps:get(<<"turns">>, Case)).

case_deadline_is_enforced_test() ->
    {ok, Set} = adk_eval_set:new(
                  <<"timeout">>, <<"1">>,
                  [#{id => <<"slow">>, input => <<"x">>, expected => <<"x">>}]),
    Adapter = #{module => adk_eval_set_test_adapter, target => ignored,
                config => #{mode => echo_expected, delay_ms => 500}},
    Started = erlang:monotonic_time(millisecond),
    {ok, Result} = adk_eval_set:run(
                     Adapter, Set, passing_metrics(),
                     #{timeout_ms => 1000, case_timeout_ms => 20}),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    [Case] = maps:get(<<"cases">>, Result),
    ?assertEqual(<<"timeout">>, maps:get(<<"error">>, Case)),
    ?assertEqual(false, maps:get(<<"passed">>, Case)).

concurrency_is_bounded_test() ->
    Tracker = spawn(fun() -> tracker_loop(0, 0) end),
    Cases = [#{id => integer_to_binary(N), input => <<"x">>,
               expected => <<"x">>} || N <- lists:seq(1, 5)],
    {ok, Set} = adk_eval_set:new(<<"parallel">>, <<"1">>, Cases),
    Adapter = #{module => adk_eval_set_test_adapter, target => Tracker,
                config => #{mode => echo_expected, delay_ms => 30}},
    {ok, Result} = adk_eval_set:run(
                     Adapter, Set, passing_metrics(), #{concurrency => 2}),
    ?assertEqual(true, maps:get(<<"passed">>, Result)),
    Ref = make_ref(),
    Tracker ! {tracker_get, self(), Ref},
    receive
        {tracker_max, Ref, Max} -> ?assertEqual(2, Max)
    after 1000 -> erlang:error(tracker_query_timeout)
    end,
    Tracker ! stop.

untrusted_module_name_does_not_create_atom_test() ->
    {ok, Set} = adk_eval_set:new(<<"safe">>, <<"1">>, []),
    Before = erlang:system_info(atom_count),
    ?assertEqual(
       {error, invalid_eval_adapter},
       adk_eval_set:run(#{module => <<"untrusted.adapter">>, target => target},
                        Set, [], #{})),
    ?assertEqual(Before, erlang:system_info(atom_count)).

stateful_set() ->
    adk_eval_set:validate(
      #{id => <<"memory-dialogue">>, version => <<"2026-07-13">>,
        metadata => #{suite => <<"core">>, access_token => <<"hidden">>},
        cases => [
          #{id => <<"remember-and-recall">>,
            metadata => #{topic => <<"state">>},
            turns => [
              #{id => <<"store">>, input => <<"store:Erlang">>,
                expected => <<"stored">>},
              #{id => <<"recall">>, input => <<"recall">>,
                expected => <<"Erlang">>}
            ]}
        ]}).

passing_metrics() ->
    [#{id => <<"exact">>, module => adk_eval_set_exact_metric,
       kind => metric, threshold => 1.0, config => #{}},
     #{id => <<"judge">>, module => adk_eval_set_static_judge,
       kind => judge, threshold => 0.75, config => #{score => 0.8}}].

tracker_loop(Current, Maximum) ->
    receive
        {tracker_enter, Pid, Ref} ->
            Next = Current + 1,
            Pid ! {tracker_ack, Ref},
            tracker_loop(Next, erlang:max(Next, Maximum));
        {tracker_leave, Pid, Ref} ->
            Pid ! {tracker_ack, Ref},
            tracker_loop(Current - 1, Maximum);
        {tracker_get, Pid, Ref} ->
            Pid ! {tracker_max, Ref, Maximum},
            tracker_loop(Current, Maximum);
        stop -> ok
    end.
