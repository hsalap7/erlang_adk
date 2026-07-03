-module(adk_hitl_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"hitl_app">>).
-define(USER, <<"hitl_user">>).

hitl_pause_test_() ->
    {setup,
     fun() -> erlang_adk_session:init() end,
     fun(_) -> ok end,
     [
      fun test_runner_catches_pause/0
     ]}.

%% Dummy agent that calls the long_running tool
hitl_agent_loop() ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvId}} ->
            Calls = [{<<"request_human_approval">>, #{<<"action_summary">> => <<"Format Drive">>}, undefined}],
            AgentEvent = adk_event:new(<<"agent">>, {tool_calls, Calls}, #{invocation_id => InvId}),
            gen_server:reply(From, {tool_calls, AgentEvent, Calls}),
            hitl_agent_loop();
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [adk_long_running_tool], #{}}),
            hitl_agent_loop();
        stop ->
            ok;
        _ ->
            hitl_agent_loop()
    end.

wait_for_pause(StreamPid) ->
    receive
        {adk_error, StreamPid, {adk_pause, human_in_the_loop, <<"Format Drive">>}} ->
            ok;
        {adk_event, StreamPid, _Event} ->
            wait_for_pause(StreamPid);
        Other ->
            ?assertEqual({adk_error, StreamPid, {adk_pause, human_in_the_loop, <<"Format Drive">>}}, Other)
    after 5000 ->
        ?assert(false)
    end.

test_runner_catches_pause() ->
    AgentPid = spawn(fun hitl_agent_loop/0),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session),
    SessionId = <<"hitl_sess">>,
    
    %% The runner should run asynchronously and emit an error containing the pause instruction.
    {ok, StreamPid} = adk_runner:run_async(Runner, ?USER, SessionId, <<"Do dangerous thing">>),
    
    %% Wait for the adk_error message which contains the pause payload
    wait_for_pause(StreamPid),
    
    %% Gracefully terminate the mock agent so EUnit doesn't complain about killed processes
    AgentPid ! stop.
