-module(adk_tool_call_test).

-include_lib("eunit/include/eunit.hrl").

tool_call_validation_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun validates_supported_call_shapes/0,
      fun rejects_malformed_batches_structurally/0,
      fun direct_agent_rejects_malformed_provider_call_without_crashing/0,
      fun runner_rejects_malformed_provider_call_without_crashing/0]}.

validates_supported_call_shapes() ->
    ?assertEqual(ok, adk_tool_call:validate_list(
                       [{<<"tool">>, #{}},
                        {<<"tool">>, #{}, undefined},
                        {<<"tool">>, #{}, <<"sig">>, <<"call">>}])).

rejects_malformed_batches_structurally() ->
    ?assertEqual(
       {error, {invalid_tool_call, 1, invalid_arguments}},
       adk_tool_call:validate_list(
         [{<<"valid">>, #{}}, {<<"invalid">>, not_a_map}])).

direct_agent_rejects_malformed_provider_call_without_crashing() ->
    Name = unique_name("MalformedDirect"),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_llm_probe,
                      mode => malformed_tool_call,
                      malformed_call =>
                          {<<"dummy_tool">>, not_a_map}},
                    [dummy_tool]),
    try
        ?assertMatch({error, {adk_failure, _}},
                     erlang_adk:prompt(Agent, <<"run">>)),
        ?assert(is_process_alive(Agent))
    after
        ok = erlang_adk:stop_agent(Agent)
    end.

runner_rejects_malformed_provider_call_without_crashing() ->
    ok = erlang_adk_session:init(),
    Name = unique_name("MalformedRunner"),
    SessionId = unique_binary("malformed-runner"),
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_llm_probe,
                      mode => malformed_tool_call,
                      malformed_call =>
                          {<<"dummy_tool">>, not_a_map}},
                    [dummy_tool]),
    Runner = adk_runner:new(
               Agent, <<"tool_call_app">>, erlang_adk_session,
               #{run_timeout => 2000}),
    try
        ?assertMatch(
           {error, {adk_failure, _}},
           adk_runner:run(
             Runner, <<"user">>, SessionId, <<"run">>)),
        ?assert(is_process_alive(Agent))
    after
        ok = erlang_adk:stop_agent(Agent),
        _ = erlang_adk_session:delete_session(
              <<"tool_call_app">>, <<"user">>, SessionId)
    end.

unique_name(Prefix) ->
    Prefix ++ integer_to_list(erlang:unique_integer([positive])).

unique_binary(Prefix) ->
    iolist_to_binary(
      [Prefix, "-", integer_to_list(
                       erlang:unique_integer([positive]))]).
