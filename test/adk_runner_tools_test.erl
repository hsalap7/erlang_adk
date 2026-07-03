-module(adk_runner_tools_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"runner_tool_app">>).
-define(USER, <<"runner_user">>).

runner_tool_execution_test_() ->
    {setup,
     fun() -> erlang_adk_session:init() end,
     fun(_) -> ok end,
     [
      fun test_runner_executes_tools_recursively/0
     ]}.

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
