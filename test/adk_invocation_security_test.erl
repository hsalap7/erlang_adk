-module(adk_invocation_security_test).

-include_lib("eunit/include/eunit.hrl").

-define(APP, <<"invocation-security-app">>).

invocation_security_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun supervisor_child_and_status_hide_invocation_payload_case/0,
      fun handoff_validates_identity_payload_and_one_shot_case/0,
      fun rejected_handoff_and_registration_race_clean_children_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    flush_messages(),
    ok.

cleanup(_) ->
    flush_messages(),
    ok.

supervisor_child_and_status_hide_invocation_payload_case() ->
    Seed = seed(),
    TestPid = self(),
    Tag = make_ref(),
    Agent = spawn(fun() -> blocking_agent_loop(TestPid, Tag) end),
    Runner = secret_runner(Agent, Seed),
    RunId = unique_binary(<<"run-", Seed/binary>>),
    UserId = <<"user-", Seed/binary>>,
    SessionId = unique_binary(<<"session-", Seed/binary>>),
    Request = #{runner => Runner,
                user_id => UserId,
                session_id => SessionId,
                message => <<"prompt-", Seed/binary>>,
                authorization => Seed},
    Opts = #{retention_ms => 200,
             max_buffered_events => 4,
             cancel_grace_ms => 25,
             private_option => Seed},
    try
        {ok, Invocation} = adk_invocation_sup:start_invocation(
                             RunId, Request, Opts),
        await_blocked(Tag),
        ok = await_event_count(RunId, 1, 100),

        [{ChildId, Invocation, worker, [adk_invocation]}] =
            [Child || Child = {_Id, Pid, worker, [adk_invocation]} <-
                          supervisor:which_children(adk_invocation_sup),
                      Pid =:= Invocation],
        ?assert(is_reference(ChildId)),
        ?assertNotEqual(RunId, ChildId),
        {ok, ChildSpec} = supervisor:get_childspec(
                            adk_invocation_sup, ChildId),
        #{start := {adk_invocation, start_link, StartArgs}} = ChildSpec,
        ?assert(StartArgs =:= [ChildId] orelse StartArgs =:= undefined),

        assert_absent(Seed, ChildSpec),
        assert_absent(RunId, ChildSpec),
        assert_absent(Seed, supervisor:which_children(adk_invocation_sup)),
        assert_absent(Seed, sys:get_status(adk_invocation_sup)),
        assert_absent(Seed, sys:get_status(Invocation)),
        assert_absent(
          Seed,
          process_info(Invocation,
                       [initial_call, current_function, dictionary,
                        links, monitors, monitored_by])),

        ok = adk_run:cancel(RunId, security_test_cleanup),
        Outcome = adk_run:await(RunId, 1000),
        ?assertMatch({cancelled, {adk_failure, _}}, Outcome),
        assert_absent(Seed, Outcome)
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(
              ?APP, UserId, SessionId)
    end.

handoff_validates_identity_payload_and_one_shot_case() ->
    Seed = seed(),
    TestPid = self(),
    Tag = make_ref(),
    Agent = spawn(fun() -> blocking_agent_loop(TestPid, Tag) end),
    Runner = secret_runner(Agent, Seed),
    InvocationRef = make_ref(),
    WrongRef = make_ref(),
    RunId = unique_binary(<<"direct-run">>),
    UserId = <<"direct-user">>,
    SessionId = unique_binary(<<"direct-session">>),
    Request = #{runner => Runner,
                user_id => UserId,
                session_id => SessionId,
                message => <<"direct-prompt">>},
    {ok, Invocation} = adk_invocation:start_link(InvocationRef),
    unlink(Invocation),
    Monitor = erlang:monitor(process, Invocation),
    try
        WrongIdentity = adk_invocation:handoff(
                          Invocation, WrongRef, RunId, Request, #{}),
        ?assertEqual({error, invalid_invocation_handoff}, WrongIdentity),

        InvalidRequest = adk_invocation:handoff(
                           Invocation, InvocationRef, RunId,
                           #{private_body => Seed}, #{}),
        ?assertEqual({error, invalid_invocation_request}, InvalidRequest),
        assert_absent(Seed, InvalidRequest),

        InvalidOptions = adk_invocation:handoff(
                           Invocation, InvocationRef, RunId, Request,
                           #{retention_ms => Seed}),
        ?assertEqual({error, invalid_invocation_options}, InvalidOptions),
        assert_absent(Seed, InvalidOptions),

        ok = adk_invocation:handoff(
               Invocation, InvocationRef, RunId, Request,
               #{retention_ms => 200, cancel_grace_ms => 25}),
        await_blocked(Tag),
        ?assertEqual(
           {error, handoff_already_completed},
           adk_invocation:handoff(
             Invocation, InvocationRef, RunId, Request, #{})),
        ok = adk_run:cancel(RunId, direct_cleanup),
        ?assertMatch({cancelled, {adk_failure, _}},
                     adk_run:await(RunId, 1000)),
        await_down(Monitor, Invocation)
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(
              ?APP, UserId, SessionId),
        case is_process_alive(Invocation) of
            true -> exit(Invocation, kill);
            false -> ok
        end
    end.

rejected_handoff_and_registration_race_clean_children_case() ->
    Seed = seed(),
    Baseline = active_invocations(),

    InvalidRunId = unique_binary(<<"invalid-", Seed/binary>>),
    InvalidResult = adk_invocation_sup:start_invocation(
                      InvalidRunId,
                      #{message => Seed, private_body => Seed},
                      #{retention_ms => Seed, private_option => Seed}),
    ?assertEqual({error, invalid_invocation_request}, InvalidResult),
    assert_absent(Seed, InvalidResult),
    ok = await_active_invocations(Baseline, 100),
    ?assertEqual({error, not_found},
                 adk_run_registry:lookup(InvalidRunId)),

    TestPid = self(),
    Tag = make_ref(),
    WinnerAgent = spawn(fun() -> blocking_agent_loop(TestPid, Tag) end),
    LoserAgent = spawn(fun() -> blocking_agent_loop(TestPid, make_ref()) end),
    WinnerRunner = secret_runner(WinnerAgent, <<"winner-handle">>),
    LoserRunner = secret_runner(LoserAgent, Seed),
    RunId = unique_binary(<<"registration-race">>),
    UserId = <<"race-user">>,
    SessionId = unique_binary(<<"race-session">>),
    WinnerRequest = #{runner => WinnerRunner,
                      user_id => UserId,
                      session_id => SessionId,
                      message => <<"winner">>},
    LoserRequest = WinnerRequest#{runner => LoserRunner,
                                  message => Seed,
                                  private_body => Seed},
    try
        {ok, Winner} = adk_invocation_sup:start_invocation(
                         RunId, WinnerRequest,
                         #{retention_ms => 200, cancel_grace_ms => 25}),
        await_blocked(Tag),
        LoserResult = adk_invocation_sup:start_invocation(
                        RunId, LoserRequest,
                        #{retention_ms => 200, private_option => Seed}),
        ?assertMatch(
           {error,
            {adk_failure,
             #{component := invocation,
               operation := registry_registration,
               reason := already_exists}}},
           LoserResult),
        assert_absent(Seed, LoserResult),
        ok = await_active_invocations(Baseline + 1, 100),
        ?assertEqual({ok, Winner}, adk_run_registry:lookup(RunId)),

        ok = adk_run:cancel(RunId, race_cleanup),
        ?assertMatch({cancelled, {adk_failure, _}},
                     adk_run:await(RunId, 1000)),
        ok = await_active_invocations(Baseline, 100)
    after
        WinnerAgent ! stop,
        LoserAgent ! stop,
        _ = erlang_adk_session:delete_session(
              ?APP, UserId, SessionId)
    end.

secret_runner(Agent, CredentialHandle) ->
    adk_runner:new(
      Agent, ?APP, erlang_adk_session,
      #{run_timeout => 5000,
        credential_store => {adk_credential_store_ets, CredentialHandle}}).

blocking_agent_loop(TestPid, Tag) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"invocation-security-agent">>, #{}, [], #{}}),
            blocking_agent_loop(TestPid, Tag);
        {'$gen_call', _From,
         {run_with_events, _History, _InvocationId}} ->
            TestPid ! {invocation_security_blocked, Tag},
            blocking_agent_loop(TestPid, Tag);
        stop ->
            ok;
        _Other ->
            blocking_agent_loop(TestPid, Tag)
    end.

await_blocked(Tag) ->
    receive
        {invocation_security_blocked, Tag} -> ok
    after 2000 ->
        error({invocation_did_not_block, Tag})
    end.

await_event_count(_RunId, _Minimum, 0) ->
    {error, event_count_timeout};
await_event_count(RunId, Minimum, Attempts) ->
    case adk_run:status(RunId) of
        {ok, #{event_count := Count}} when Count >= Minimum -> ok;
        _ ->
            receive after 10 -> ok end,
            await_event_count(RunId, Minimum, Attempts - 1)
    end.

active_invocations() ->
    proplists:get_value(
      active, supervisor:count_children(adk_invocation_sup), 0).

await_active_invocations(_Expected, 0) ->
    {error, invocation_child_cleanup_timeout};
await_active_invocations(Expected, Attempts) ->
    case active_invocations() of
        Expected -> ok;
        _ ->
            receive after 10 -> ok end,
            await_active_invocations(Expected, Attempts - 1)
    end.

await_down(Monitor, Pid) ->
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 2000 ->
        error({invocation_process_did_not_stop, Pid})
    end.

unique_binary(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.

seed() ->
    <<"ERLANG_ADK_INVOCATION_SECRET_7dd10b4d">>.

assert_absent(Needle, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Needle)).

flush_messages() ->
    receive _ -> flush_messages()
    after 0 -> ok
    end.
