-module(adk_runner_tools_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"runner_tool_app">>).
-define(USER, <<"runner_user">>).

runner_tool_execution_test_() ->
    {setup,
     fun setup/0,
     fun(_) -> ok end,
     [
      fun test_runner_executes_tools_recursively/0,
      fun test_runner_callback_lifecycle/0,
      fun test_runner_sub_agent_callback_lifecycle/0
     ]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    erlang_adk_session:init().

%% Dummy agent that first returns tool_calls, then on second call returns final text.
dummy_tool_agent_loop(CallCount) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvId}} ->
            case CallCount of
                0 ->
                    %% First call: request a tool execution
                    Calls = [{<<"dummy_tool">>, #{<<"arg">> => <<"val">>}, undefined}],
                    AgentEvent = adk_event:new(<<"agent">>, {tool_calls, Calls}, #{invocation_id => InvId}),
                    gen_server:reply(From, {tool_calls, AgentEvent, Calls}),
                    dummy_tool_agent_loop(1);
                _ ->
                    %% Second call: return final response
                    FinalEvent = adk_event:new(<<"agent">>, <<"Tool executed successfully">>, #{invocation_id => InvId, is_final => true}),
                    gen_server:reply(From, {ok, FinalEvent}),
                    dummy_tool_agent_loop(CallCount + 1)
            end;
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [dummy_tool], #{}}),
            dummy_tool_agent_loop(CallCount);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"agent">>, #{}, [dummy_tool], #{}}),
            dummy_tool_agent_loop(CallCount);
        stop ->
            ok;
        _ ->
            dummy_tool_agent_loop(CallCount)
    end.

test_runner_executes_tools_recursively() ->
    AgentPid = spawn(fun() -> dummy_tool_agent_loop(0) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session),
    SessionId = <<"runner_tool_sess">>,
    
    %% This should:
    %% 1. Agent returns tool_calls
    %% 2. Runner executes dummy_tool
    %% 3. Runner loops back, agent returns final text
    Result = adk_runner:run(Runner, ?USER, SessionId, <<"Execute tool">>),
    ?assertEqual({ok, <<"Tool executed successfully">>}, Result),
    
    %% Verify events were recorded (user + agent_tool_call + tool_response + agent_final = 4)
    {ok, Session} = erlang_adk_session:get_session(?APP, ?USER, SessionId),
    Events = maps:get(events, Session),
    ?assert(length(Events) >= 4),
    
    %% Gracefully terminate the mock agent
    AgentPid ! stop.

test_runner_callback_lifecycle() ->
    persistent_term:put({adk_callback_lifecycle_test, target}, self()),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       <<"RunnerCallbackAgent">>,
                       #{provider => adk_llm_dummy,
                         callbacks => [adk_callback_lifecycle_test]},
                       [dummy_tool]),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        ?assertEqual(
           {ok, <<"Tool executed">>},
           adk_runner:run(Runner, ?USER, <<"runner_callback_sess">>,
                          <<"Trigger tool">>)),
        Events = receive_callback_events(10, []),
        ?assertEqual(1, count_callback(on_agent_start, Events)),
        ?assertEqual(1, count_callback(on_agent_end, Events)),
        ?assertEqual(2, count_callback(before_model, Events)),
        ?assertEqual(2, count_callback(after_model, Events)),
        ?assertEqual(1, count_callback(on_tool_start, Events)),
        ?assertEqual(1, count_callback(before_tool, Events)),
        ?assertEqual(1, count_callback(after_tool, Events)),
        ?assertEqual(1, count_callback(on_tool_end, Events))
    after
        _ = catch erlang_adk:stop_agent(AgentPid),
        persistent_term:erase({adk_callback_lifecycle_test, target}),
        _ = erlang_adk_session:delete_session(
              ?APP, ?USER, <<"runner_callback_sess">>)
    end.

test_runner_sub_agent_callback_lifecycle() ->
    persistent_term:put({adk_callback_lifecycle_test, target}, self()),
    {ok, SubPid} = erlang_adk:spawn_agent(
                     <<"RunnerCallbackSubWorker">>,
                     #{provider => adk_llm_probe,
                       response => <<"specialist response">>}, []),
    {ok, MasterPid} = erlang_adk:spawn_agent(
                        <<"RunnerCallbackSubMaster">>,
                        #{provider => adk_llm_probe,
                          mode => sub_agent_call,
                          call_name => <<"RunnerCallbackSubWorker">>,
                          callbacks => [adk_callback_lifecycle_test],
                          sub_agents => #{<<"RunnerCallbackSubWorker">> => SubPid}},
                        []),
    SessionId = <<"runner_sub_callback_sess">>,
    Runner = adk_runner:new(MasterPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        ?assertEqual({ok, <<"delegation complete">>},
                     adk_runner:run(
                       Runner, ?USER, SessionId, <<"delegate">>)),
        Events = receive_callback_events(10, []),
        ?assertEqual(1, count_callback(on_tool_start, Events)),
        ?assertEqual(1, count_callback(before_tool, Events)),
        ?assertEqual(1, count_callback(after_tool, Events)),
        ?assertEqual(1, count_callback(on_tool_end, Events))
    after
        _ = catch erlang_adk:stop_agent(MasterPid),
        _ = catch erlang_adk:stop_agent(SubPid),
        persistent_term:erase({adk_callback_lifecycle_test, target}),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

receive_callback_events(0, Acc) -> Acc;
receive_callback_events(Remaining, Acc) ->
    receive
        {callback, Event} ->
            receive_callback_events(Remaining - 1, [Event | Acc])
    after 1000 ->
        Acc
    end.

count_callback(Event, Events) ->
    length([ok || Seen <- Events, Seen =:= Event]).
