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
     fun test_parallel/0,
     fun test_parallel_worker_failure/0,
     fun test_not_approved_does_not_stop_loop/0,
     fun test_loop_returns_printable_binary/0
    ].

test_sequential() ->
    Pid1 = spawn(fun dummy_agent/0),
    Pid2 = spawn(fun dummy_agent/0),
    
    Result = erlang_adk_orchestrator:sequential([Pid1, Pid2], <<"Hi">>),
    ?assertEqual({ok, <<"Resp: Resp: Hi">>}, Result),
    Pid1 ! stop,
    Pid2 ! stop.

test_parallel_worker_failure() ->
    DeadPid = spawn(fun() -> ok end),
    timer:sleep(5),
    Started = erlang:monotonic_time(millisecond),
    [{DeadPid, {error, _}}] =
        erlang_adk_orchestrator:parallel([DeadPid], <<"Hi">>, 100),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000).

test_not_approved_does_not_stop_loop() ->
    Parent = self(),
    Worker = spawn(fun Loop() ->
        receive
            {'$gen_call', From, {prompt, _Msg}} ->
                Parent ! worker_called,
                gen_server:reply(From, {ok, <<"draft">>}),
                Loop();
            stop -> ok
        end
    end),
    Reviewer = spawn(fun Loop() ->
        receive
            {'$gen_call', From, {prompt, _Msg}} ->
                Parent ! reviewer_called,
                gen_server:reply(From, {ok, <<"Not approved: revise it">>}),
                Loop();
            stop -> ok
        end
    end),
    ?assertEqual({ok, <<"draft">>},
                 erlang_adk_orchestrator:loop(Worker, Reviewer, <<"write">>, 2)),
    ?assertEqual(2, count_messages(worker_called, 0)),
    ?assertEqual(2, count_messages(reviewer_called, 0)),
    Worker ! stop,
    Reviewer ! stop.

test_loop_returns_printable_binary() ->
    Parent = self(),
    FirstDraft = <<"First draft">>,
    FinalDraft = <<"Erlang ", 16#2615/utf8, "\nProcesses sing.">>,
    Worker = spawn(fun() ->
        binary_worker(Parent, 1, FirstDraft, FinalDraft)
    end),
    Reviewer = spawn(fun() -> binary_reviewer(Parent, 1) end),
    try
        ?assertEqual(
           {ok, FinalDraft},
           erlang_adk_orchestrator:loop(
             Worker, Reviewer, <<"Write a poem.">>, 2)),
        ?assertEqual(FinalDraft,
                     unicode:characters_to_binary(
                       io_lib:format("~ts", [FinalDraft]))),
        ?assertEqual({worker_prompt, 1, true}, receive_message()),
        ?assertEqual({reviewer_prompt, 1, true}, receive_message()),
        ?assertEqual({worker_prompt, 2, true}, receive_message()),
        ?assertEqual({reviewer_prompt, 2, true}, receive_message())
    after
        Worker ! stop,
        Reviewer ! stop
    end.

binary_worker(Parent, Iteration, FirstDraft, FinalDraft) ->
    receive
        {'$gen_call', From, {prompt, Prompt}} ->
            Parent ! {worker_prompt, Iteration, is_binary(Prompt)},
            Draft = case Iteration of
                1 -> FirstDraft;
                _ -> FinalDraft
            end,
            gen_server:reply(From, {ok, Draft}),
            binary_worker(Parent, Iteration + 1, FirstDraft, FinalDraft);
        stop -> ok
    end.

binary_reviewer(Parent, Iteration) ->
    receive
        {'$gen_call', From, {prompt, Prompt}} ->
            Parent ! {reviewer_prompt, Iteration, is_binary(Prompt)},
            Review = case Iteration of
                1 -> <<"Add a second line.">>;
                _ -> <<"APPROVED">>
            end,
            gen_server:reply(From, {ok, Review}),
            binary_reviewer(Parent, Iteration + 1);
        stop -> ok
    end.

receive_message() ->
    receive
        {worker_prompt, _Iteration, _IsBinary} = Message -> Message;
        {reviewer_prompt, _Iteration, _IsBinary} = Message -> Message
    after 1000 -> timeout
    end.

count_messages(Message, Count) ->
    receive
        Message -> count_messages(Message, Count + 1)
    after 0 ->
        Count
    end.

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
