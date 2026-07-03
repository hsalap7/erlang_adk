-module(erlang_adk_orchestrator_test).
-include_lib("eunit/include/eunit.hrl").

%% Dummy agent for testing orchestrator graph delegation
dummy_agent() ->
    receive
        {'$gen_call', From, {prompt, Msg}} ->
            gen_server:reply(From, {ok, <<"Resp: ", Msg/binary>>}),
            dummy_agent();
        stop ->
            ok;
        _ ->
            dummy_agent()
    end.

orchestrator_test_() ->
    [
     fun test_sequential/0,
     fun test_parallel/0
    ].

test_sequential() ->
    Pid1 = spawn(fun dummy_agent/0),
    Pid2 = spawn(fun dummy_agent/0),
    
    Result = erlang_adk_orchestrator:sequential([Pid1, Pid2], <<"Hi">>),
    ?assertEqual({ok, <<"Resp: Resp: Hi">>}, Result),
    Pid1 ! stop,
    Pid2 ! stop.

test_parallel() ->
    Pid1 = spawn(fun dummy_agent/0),
    Pid2 = spawn(fun dummy_agent/0),
    
    ResultList = erlang_adk_orchestrator:parallel([Pid1, Pid2], <<"Hi">>),
    ?assertEqual(2, length(ResultList)),
    
    %% Output order may not be guaranteed, so we check presence
    HasPid1 = lists:keymember(Pid1, 1, ResultList),
    HasPid2 = lists:keymember(Pid2, 1, ResultList),
    ?assert(HasPid1),
    ?assert(HasPid2),
    Pid1 ! stop,
    Pid2 ! stop.
