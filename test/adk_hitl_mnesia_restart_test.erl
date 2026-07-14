-module(adk_hitl_mnesia_restart_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"hitl_mnesia_restart">>).
-define(USER, <<"restart-user">>).
-define(SESSION, <<"restart-session">>).
-define(CALL_ID, <<"restart-approval-call">>).

paused_continuation_survives_mnesia_restart_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session_mnesia:init(),
    _ = erlang_adk_session_mnesia:delete_session(
          ?APP, ?USER, ?SESSION),
    Parent = self(),
    InitialAgent = spawn(fun() -> agent_loop(Parent, initial) end),
    Runner1 = runner(InitialAgent),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner1, ?USER, ?SESSION,
                         <<"Perform the restart-safe action">>),
        PauseEvent = await_pause(Stream),
        InvocationId = PauseEvent#adk_event.invocation_id,
        ?assertMatch(<<"inv-", _/binary>>, InvocationId),

        %% The continuation is data in the disc_copies session transaction,
        %% not a mailbox owned by the original Runner worker.
        ok = application:stop(erlang_adk),
        ok = application:stop(mnesia),
        ok = erlang_adk_session_mnesia:init(),
        {ok, _} = application:ensure_all_started(erlang_adk),
        {ok, Persisted} = erlang_adk_session_mnesia:get_session(
                            ?APP, ?USER, ?SESSION),
        ?assert(maps:is_key(
                  <<"__adk_runner_continuation:", InvocationId/binary>>,
                  maps:get(state, Persisted))),

        ReplacementAgent = spawn(
                             fun() -> agent_loop(Parent, resumed) end),
        Runner2 = runner(ReplacementAgent),
        try
            {ok, ResumeStream} = adk_runner:resume(
                                   Runner2, ?USER, ?SESSION,
                                   InvocationId,
                                   #{<<"approved">> => true}),
            Events = await_done(ResumeStream, []),
            ?assert(lists:any(
                      fun(#adk_event{is_final = true,
                                     invocation_id = Id}) ->
                              Id =:= InvocationId;
                         (_) -> false
                      end, Events)),
            receive
                {resumed_after_restart, InvocationId, History} ->
                    ?assert(has_correlated_tool_response(
                              History, InvocationId))
            after 1000 ->
                ?assert(false)
            end,
            ?assertEqual(
               {error, no_paused_invocation},
               adk_runner:resume(
                 Runner2, ?USER, ?SESSION, InvocationId,
                 #{<<"approved">> => true}))
        after
            ReplacementAgent ! stop
        end
    after
        InitialAgent ! stop,
        _ = application:ensure_all_started(mnesia),
        _ = application:ensure_all_started(erlang_adk),
        _ = erlang_adk_session_mnesia:delete_session(
              ?APP, ?USER, ?SESSION)
    end.

runner(Agent) ->
    adk_runner:new(
      Agent, ?APP, erlang_adk_session_mnesia,
      #{run_timeout => 3000}).

agent_loop(Parent, initial) ->
    receive
        {'$gen_call', From,
         {run_with_events, _History, InvocationId}} ->
            Calls = [{<<"request_human_approval">>,
                      #{<<"action_summary">> =>
                            <<"Approve restart-safe action">>},
                      undefined, ?CALL_ID}],
            Event = adk_event:new(
                      <<"restart-agent">>, {tool_calls, Calls},
                      #{invocation_id => InvocationId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            agent_loop(Parent, initial);
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [adk_long_running_tool], #{}}),
            agent_loop(Parent, initial);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From,
              {ok, <<"restart-agent">>, #{},
               [adk_long_running_tool], #{}}),
            agent_loop(Parent, initial);
        stop -> ok;
        _ -> agent_loop(Parent, initial)
    end;
agent_loop(Parent, resumed) ->
    receive
        {'$gen_call', From,
         {run_with_events, History, InvocationId}} ->
            Parent ! {resumed_after_restart, InvocationId, History},
            Event = adk_event:new(
                      <<"restart-agent">>, <<"Approved after restart">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            agent_loop(Parent, resumed);
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [adk_long_running_tool], #{}}),
            agent_loop(Parent, resumed);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From,
              {ok, <<"restart-agent">>, #{},
               [adk_long_running_tool], #{}}),
            agent_loop(Parent, resumed);
        stop -> ok;
        _ -> agent_loop(Parent, resumed)
    end.

await_pause(Stream) ->
    receive
        {adk_event, Stream, _Event} -> await_pause(Stream);
        {adk_paused, Stream, PauseEvent} -> PauseEvent;
        {adk_error, Stream, Reason} -> erlang:error({unexpected_error, Reason})
    after 3000 ->
        erlang:error(pause_timeout)
    end.

await_done(Stream, Acc) ->
    receive
        {adk_event, Stream, Event} -> await_done(Stream, [Event | Acc]);
        {adk_done, Stream} -> lists:reverse(Acc);
        {adk_error, Stream, Reason} -> erlang:error({unexpected_error, Reason})
    after 3000 ->
        erlang:error(resume_timeout)
    end.

has_correlated_tool_response(History, InvocationId) ->
    lists:any(
      fun(#adk_event{author = <<"tool">>, invocation_id = Id,
                     content = {tool_response,
                                <<"request_human_approval">>,
                                _Result, _Signature, ?CALL_ID}}) ->
              Id =:= InvocationId;
         (_) -> false
      end, History).
