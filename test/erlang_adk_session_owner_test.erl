-module(erlang_adk_session_owner_test).

-include_lib("eunit/include/eunit.hrl").

session_owner_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun table_is_owned_by_supervised_worker/0,
      fun concurrent_init_keeps_one_owner/0,
      fun stopping_initializing_agent_keeps_table/0]}.

setup() ->
    application:set_env(erlang_adk, a2a_enabled, false),
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ets:delete_all_objects(adk_sessions),
    ok.

cleanup(_) ->
    ets:delete_all_objects(adk_sessions),
    ok.

table_is_owned_by_supervised_worker() ->
    Owner = whereis(erlang_adk_session_owner),
    ?assert(is_pid(Owner)),
    ?assertEqual(Owner, ets:info(adk_sessions, owner)),
    Children = supervisor:which_children(erlang_adk_sup),
    ?assertMatch({erlang_adk_session_owner, Owner, worker, _},
                 lists:keyfind(erlang_adk_session_owner, 1, Children)).

concurrent_init_keeps_one_owner() ->
    Owner = whereis(erlang_adk_session_owner),
    Parent = self(),
    Count = 64,
    [spawn(fun() -> Parent ! {init_result, erlang_adk_session:init()} end)
     || _ <- lists:seq(1, Count)],
    Results = [receive {init_result, Result} -> Result after 5000 -> timeout end
               || _ <- lists:seq(1, Count)],
    ?assertEqual([], [Result || Result <- Results, Result =/= ok]),
    ?assertEqual(Owner, whereis(erlang_adk_session_owner)),
    ?assertEqual(Owner, ets:info(adk_sessions, owner)).

stopping_initializing_agent_keeps_table() ->
    SessionId = <<"session-owner-agent-stop">>,
    Name = <<"SessionOwnerAgent">>,
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       Name,
                       #{provider => adk_llm_dummy,
                         session_id => SessionId},
                       []),
    {ok, _} = erlang_adk:prompt(AgentPid, <<"remember this">>),
    Owner = whereis(erlang_adk_session_owner),
    ok = erlang_adk:stop_agent(AgentPid),
    ?assert(is_process_alive(Owner)),
    ?assertEqual(Owner, ets:info(adk_sessions, owner)),
    ?assertMatch([_ | _], erlang_adk_session:load(SessionId)),
    %% This was the operation that raised badarg in the live suite.
    ?assertEqual(ok, erlang_adk_session:delete(SessionId)),
    ?assertEqual([], erlang_adk_session:load(SessionId)).
