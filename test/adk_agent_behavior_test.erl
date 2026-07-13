-module(adk_agent_behavior_test).
-include_lib("eunit/include/eunit.hrl").

agent_behavior_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_) -> ok end,
     [fun provider_error_is_not_success/0,
      fun callback_module_is_loaded_and_can_halt/0,
      fun correlated_delegation/0,
      fun callback_result_is_persisted_in_history/0,
      fun callback_short_circuit_is_persisted_in_history/0,
      fun agent_call_timeout_is_configurable/0,
      fun stopped_agent_name_can_be_reused/0,
      fun restored_session_keeps_instructions/0,
      fun registry_and_agents_have_coupled_restart_strategy/0]}.

provider_error_is_not_success() ->
    {ok, Pid} = erlang_adk:spawn_agent("ErrorContractAgent", #{
        provider => adk_llm_probe,
        mode => error,
        reason => unavailable
    }, []),
    ?assertEqual({error, unavailable}, erlang_adk:prompt(Pid, "hello")),
    ?assert(is_process_alive(Pid)),
    ok = erlang_adk:stop_agent(Pid).

callback_module_is_loaded_and_can_halt() ->
    _ = code:purge(adk_unloaded_callback),
    _ = code:delete(adk_unloaded_callback),
    ?assertEqual(false, code:is_loaded(adk_unloaded_callback)),
    {ok, Pid} = erlang_adk:spawn_agent("CallbackContractAgent", #{
        provider => adk_llm_probe,
        test_pid => self(),
        callback_pid => self(),
        callback_action => halt,
        callbacks => [adk_unloaded_callback]
    }, []),
    ?assertEqual({ok, <<"blocked by callback">>},
                 erlang_adk:prompt(Pid, "hello")),
    receive before_model -> ok after 1000 -> ?assert(false) end,
    receive after_model -> ok after 1000 -> ?assert(false) end,
    %% The provider must have been skipped by the before-model callback.
    receive {probe_generate, _, _} -> ?assert(false) after 20 -> ok end,
    ok = erlang_adk:stop_agent(Pid).

correlated_delegation() ->
    {ok, Pid} = erlang_adk:spawn_agent("CorrelatedAgent", #{
        provider => adk_llm_probe,
        response => <<"done">>
    }, []),
    Ref = make_ref(),
    ok = erlang_adk:delegate(Pid, "work", self(), Ref),
    receive
        {agent_response, Ref, Pid, {ok, <<"done">>}} -> ok
    after 1000 ->
        ?assert(false)
    end,
    ok = erlang_adk:stop_agent(Pid).

callback_result_is_persisted_in_history() ->
    {ok, Pid} = erlang_adk:spawn_agent("CallbackHistoryReplaceAgent", #{
        provider => adk_llm_probe,
        response => <<"original response">>,
        test_pid => self(),
        callbacks => [adk_agent_history_callback]
    }, []),
    try
        ?assertEqual({ok, <<"replacement response">>},
                     erlang_adk:prompt(Pid, <<"first turn">>)),
        receive {probe_generate, _FirstHistory, _} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertEqual({ok, <<"replacement response">>},
                     erlang_adk:prompt(Pid, <<"second turn">>)),
        receive
            {probe_generate, SecondHistory, _} ->
                ?assert(lists:any(
                          fun(#{role := agent,
                                content := <<"replacement response">>}) -> true;
                             (_) -> false
                          end, SecondHistory)),
                ?assertNot(lists:any(
                             fun(#{role := agent,
                                   content := "original response"}) -> true;
                                (_) -> false
                             end, SecondHistory))
        after 1000 ->
            ?assert(false)
        end
    after
        _ = catch erlang_adk:stop_agent(Pid)
    end.

callback_short_circuit_is_persisted_in_history() ->
    {ok, Pid} = erlang_adk:spawn_agent("CallbackHistoryHaltAgent", #{
        provider => adk_llm_probe,
        response => <<"provider response">>,
        test_pid => self(),
        callbacks => [adk_agent_history_callback]
    }, []),
    try
        ?assertEqual({ok, <<"short-circuited response">>},
                     erlang_adk:prompt(Pid, <<"skip model">>)),
        receive {probe_generate, _, _} -> ?assert(false)
        after 20 -> ok
        end,
        ?assertEqual({ok, <<"provider response">>},
                     erlang_adk:prompt(Pid, <<"continue">>)),
        receive
            {probe_generate, History, _} ->
                ?assert(lists:any(
                          fun(#{role := agent,
                                content := <<"short-circuited response">>}) -> true;
                             (_) -> false
                          end, History))
        after 1000 ->
            ?assert(false)
        end
    after
        _ = catch erlang_adk:stop_agent(Pid)
    end.

agent_call_timeout_is_configurable() ->
    OldTimeout = application:get_env(erlang_adk, agent_call_timeout),
    {ok, Pid} = erlang_adk:spawn_agent("ConfigurableTimeoutAgent", #{
        provider => adk_llm_probe,
        mode => delay,
        delay_ms => 50,
        response => <<"finished">>
    }, []),
    try
        application:set_env(erlang_adk, agent_call_timeout, 10),
        ?assertExit({timeout, _}, erlang_adk:prompt(Pid, <<"first">>)),
        %% The timed-out call continues in the agent process and then leaves it
        %% available for subsequent work, as gen_server call timeouts normally do.
        timer:sleep(60),
        application:set_env(erlang_adk, agent_call_timeout, 200),
        ?assertEqual({ok, <<"finished">>},
                     erlang_adk:prompt(Pid, <<"second">>)),
        application:set_env(erlang_adk, agent_call_timeout, invalid),
        ?assertError({invalid_agent_call_timeout, invalid},
                     erlang_adk:prompt(Pid, <<"third">>))
    after
        restore_agent_call_timeout(OldTimeout),
        _ = catch erlang_adk:stop_agent(Pid)
    end.

stopped_agent_name_can_be_reused() ->
    Config = #{provider => adk_llm_probe},
    {ok, Pid1} = erlang_adk:spawn_agent("ReusableAgent", Config, []),
    ?assertEqual({ok, Pid1}, adk_agent_registry:lookup(<<"ReusableAgent">>)),
    ok = erlang_adk:stop_agent(Pid1),
    {ok, Pid2} = erlang_adk:spawn_agent("ReusableAgent", Config, []),
    ?assert(Pid1 =/= Pid2),
    ok = erlang_adk:stop_agent(Pid2).

restored_session_keeps_instructions() ->
    SessionId = restored_instruction_session,
    ok = erlang_adk_session:save(
           SessionId,
           [#{role => user, content => <<"old turn">>, timestamp => 1}]),
    {ok, Pid} = erlang_adk:spawn_agent("RestoredInstructionAgent", #{
        provider => adk_llm_probe,
        instructions => <<"MUST FOLLOW">>,
        session_id => SessionId,
        test_pid => self()
    }, []),
    {ok, _} = erlang_adk:prompt(Pid, <<"new turn">>),
    receive
        {probe_generate, History, _Tools} ->
            ?assert(lists:any(
                      fun(#{role := system, content := <<"MUST FOLLOW">>}) -> true;
                         (_) -> false
                      end, History))
    after 1000 ->
        ?assert(false)
    end,
    ok = erlang_adk:stop_agent(Pid),
    ok = erlang_adk_session:delete(SessionId).

registry_and_agents_have_coupled_restart_strategy() ->
    {ok, {Flags, [SessionOwner, Registry, AgentSup]}} = erlang_adk_sup:init([]),
    ?assertEqual(rest_for_one, maps:get(strategy, Flags)),
    ?assertEqual(erlang_adk_session_owner, maps:get(id, SessionOwner)),
    ?assertEqual(adk_agent_registry, maps:get(id, Registry)),
    ?assertEqual(adk_agent_sup, maps:get(id, AgentSup)).

restore_agent_call_timeout(undefined) ->
    application:unset_env(erlang_adk, agent_call_timeout);
restore_agent_call_timeout({ok, Timeout}) ->
    application:set_env(erlang_adk, agent_call_timeout, Timeout).
