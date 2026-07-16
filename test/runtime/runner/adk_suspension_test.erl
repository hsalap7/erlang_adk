-module(adk_suspension_test).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"suspension-app">>).
-define(USER, <<"suspension-user">>).
-define(PROVIDER, <<"calendar-oauth">>).

suspension_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun long_running_progress_and_terminal_resume_case/0,
      fun stable_run_rejects_invalid_completion_before_linking_case/0,
      fun interactive_auth_pkce_and_opaque_resume_case/0,
      fun expired_or_malformed_pkce_flow_fails_closed_case/0,
      fun malformed_auth_request_rejected_before_pause_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_State) -> ok.

long_running_progress_and_terminal_resume_case() ->
    Session = unique(<<"long-running">>),
    Operation = <<"operation-42">>,
    Args = #{<<"operation_id">> => Operation,
             <<"summary">> => <<"Export is running">>},
    Agent = spawn(fun() -> agent_loop(
                             <<"long-running-agent">>,
                             <<"start_external_operation">>, Args,
                             [adk_long_running_operation_tool], initial)
                  end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, Session, <<"Export my data">>),
        Pause = await_pause(Stream),
        Invocation = Pause#adk_event.invocation_id,
        PublicPause = maps:get(<<"pause">>, Pause#adk_event.actions),
        Details = maps:get(<<"details">>, PublicPause),
        ?assertEqual(<<"long_running">>, maps:get(<<"type">>, Details)),
        ?assertEqual(Operation, maps:get(<<"operation_id">>, Details)),

        Progress1 = #{<<"operation_id">> => Operation,
                      <<"status">> => <<"running">>,
                      <<"progress">> => 25,
                      <<"message">> => <<"Quarter complete">>},
        {ok, ProgressEvent1} = adk_runner:update_long_running(
                                 Runner, ?USER, Session, Invocation,
                                 Operation, Progress1),
        ?assertEqual(Invocation, ProgressEvent1#adk_event.invocation_id),
        ?assertEqual(
           false,
           maps:get(
             <<"terminal">>,
             maps:get(<<"long_running_update">>,
                      ProgressEvent1#adk_event.actions))),
        Progress2 = #{<<"operation_id">> => Operation,
                      <<"status">> => <<"running">>,
                      <<"progress">> => 75},
        {ok, _} = adk_runner:update_long_running(
                    Runner, ?USER, Session, Invocation,
                    Operation, Progress2),
        ?assertEqual(
           {error, long_running_operation_mismatch},
           adk_runner:update_long_running(
             Runner, ?USER, Session, Invocation,
             <<"wrong-operation">>, Progress2)),

        WrongCompletion = #{<<"operation_id">> => <<"wrong-operation">>,
                            <<"status">> => <<"completed">>,
                            <<"result">> => <<"ignored">>},
        ?assertEqual(
           {error, invalid_long_running_completion},
           adk_runner:resume(
             Runner, ?USER, Session, Invocation, WrongCompletion)),

        Completion = #{<<"operation_id">> => Operation,
                       <<"status">> => <<"completed">>,
                       <<"result">> => #{<<"artifact">> => <<"export.zip">>}},
        {ok, ResumeStream} = adk_runner:resume(
                               Runner, ?USER, Session, Invocation,
                               Completion),
        Events = await_done(ResumeStream, []),
        ?assert(lists:any(
                  fun(#adk_event{is_final = true}) -> true;
                     (_) -> false
                  end, Events)),
        ?assertEqual(
           {error, no_paused_invocation},
           adk_runner:update_long_running(
             Runner, ?USER, Session, Invocation, Operation, Progress2)),
        {ok, Stored} = erlang_adk_session:get_session(
                         ?APP, ?USER, Session),
        StoredEvents = maps:get(events, Stored),
        Updates = [Event || Event <- StoredEvents,
                            maps:is_key(<<"long_running_update">>,
                                        Event#adk_event.actions)],
        ?assertEqual(2, length(Updates))
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, Session)
    end.

stable_run_rejects_invalid_completion_before_linking_case() ->
    Session = unique(<<"stable-long-running">>),
    Operation = <<"stable-operation">>,
    Args = #{<<"operation_id">> => Operation,
             <<"summary">> => <<"Stable operation is running">>},
    Agent = spawn(fun() -> agent_loop(
                             <<"stable-long-running-agent">>,
                             <<"start_external_operation">>, Args,
                             [adk_long_running_operation_tool], initial)
                  end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        {ok, RunId} = adk_run:start(
                        Runner, ?USER, Session, <<"Start work">>,
                        #{retention_ms => 5000}),
        {paused, _} = adk_run:await(RunId, 2000),
        Invalid = #{<<"operation_id">> => <<"other">>,
                    <<"status">> => <<"completed">>},
        ?assertEqual(
           {error, invalid_long_running_completion},
           adk_run:resume(RunId, Invalid)),
        {ok, StatusAfterInvalid} = adk_run:status(RunId),
        ?assertEqual(undefined, maps:get(resumed_to, StatusAfterInvalid)),
        Valid = #{<<"operation_id">> => Operation,
                  <<"status">> => <<"completed">>,
                  <<"result">> => <<"done">>},
        {ok, ResumedRunId} = adk_run:resume(RunId, Valid),
        {completed, <<"External work completed">>} =
            adk_run:await(ResumedRunId, 2000)
    after
        Agent ! stop,
        _ = erlang_adk_session:delete_session(?APP, ?USER, Session)
    end.

interactive_auth_pkce_and_opaque_resume_case() ->
    Session = unique(<<"credential">>),
    Correlation = <<"oauth-correlation-1">>,
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    {ok, Pkce} = adk_suspension:prepare_pkce(
                   adk_credential_store_ets, Store, ?USER,
                   ?PROVIDER, Correlation),
    FlowRef = maps:get(<<"credential_flow_ref">>, Pkce),
    {ok, Pending} = adk_credential_store_ets:fetch(
                      Store, ?USER, ?PROVIDER, FlowRef),
    Verifier = maps:get(code_verifier, Pending),
    Request = maps:merge(
                #{<<"provider">> => ?PROVIDER,
                  <<"scheme">> => <<"oauth2">>,
                  <<"authorization_uri">> =>
                      <<"https://accounts.example.test/authorize?client_id=public-client">>,
                  <<"scopes">> => [<<"calendar.read">>],
                  <<"correlation_id">> => Correlation,
                  <<"prompt">> => <<"Sign in to Calendar">>},
                Pkce),
    Args = #{<<"request">> => Request},
    Agent = spawn(fun() -> agent_loop(
                             <<"credential-agent">>,
                             <<"request_user_credential">>, Args,
                             [adk_credential_request_tool], initial)
                  end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 2000,
                 credential_store => {adk_credential_store_ets, Store}}),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, Session, <<"Read my calendar">>),
        Pause = await_pause(Stream),
        Invocation = Pause#adk_event.invocation_id,
        EncodedPause = jsx:encode(element(2, adk_event:encode(Pause))),
        ?assertEqual(nomatch, binary:match(EncodedPause, Verifier)),
        PublicPause = maps:get(<<"pause">>, Pause#adk_event.actions),
        Details = maps:get(<<"details">>, PublicPause),
        ?assertEqual(<<"credential_request">>,
                     maps:get(<<"type">>, Details)),
        ?assertEqual(Correlation,
                     maps:get(<<"correlation_id">>, Details)),

        {ok, PendingOther} = adk_suspension:prepare_pkce(
                               adk_credential_store_ets, Store,
                               <<"other-user">>, ?PROVIDER,
                               Correlation),
        OtherRef = maps:get(<<"credential_flow_ref">>, PendingOther),
        ?assertEqual(
           {error, credential_flow_mismatch},
           adk_runner:resume(
             Runner, ?USER, Session, Invocation,
             #{<<"credential_ref">> => OtherRef,
               <<"correlation_id">> => Correlation})),
        ?assertEqual(
           {error, credential_authorization_incomplete},
           adk_runner:resume(
             Runner, ?USER, Session, Invocation,
             #{<<"credential_ref">> => FlowRef,
               <<"correlation_id">> => Correlation})),

        %% A completed credential for the same principal, provider, and
        %% correlation still cannot satisfy a different paused PKCE flow.
        {ok, SameScopePkce} = adk_suspension:prepare_pkce(
                                adk_credential_store_ets, Store, ?USER,
                                ?PROVIDER, Correlation),
        SameScopeRef = maps:get(<<"credential_flow_ref">>, SameScopePkce),
        {ok, SameScopeRef} = adk_suspension:complete_pkce(
                               adk_credential_store_ets, Store, ?USER,
                               ?PROVIDER, SameScopeRef, Correlation,
                               #{kind => oauth_refresh_token,
                                 refresh_token => <<"different-flow">>}),
        ?assertEqual(
           {error, credential_flow_mismatch},
           adk_runner:resume(
             Runner, ?USER, Session, Invocation,
             #{<<"credential_ref">> => SameScopeRef,
               <<"correlation_id">> => Correlation})),

        RefreshToken = <<"private-refresh-token-never-in-events">>,
        ?assertEqual(
           {error, credential_correlation_mismatch},
           adk_suspension:complete_pkce(
             adk_credential_store_ets, Store, ?USER, ?PROVIDER, FlowRef,
             <<"wrong-correlation">>,
             #{kind => oauth_refresh_token,
               client_id => <<"public-client">>,
               refresh_token => RefreshToken})),
        {ok, FinalRef} = adk_suspension:complete_pkce(
                           adk_credential_store_ets, Store, ?USER,
                           ?PROVIDER, FlowRef, Correlation,
                           #{kind => oauth_refresh_token,
                             client_id => <<"public-client">>,
                             refresh_token => RefreshToken}),
        ?assertEqual(FlowRef, FinalRef),
        {ok, CompletedCredential} = adk_credential_store_ets:fetch(
                                      Store, ?USER, ?PROVIDER, FinalRef),
        ?assertEqual(false,
                     maps:is_key(code_verifier, CompletedCredential)),
        ?assertEqual(
           {error, credential_flow_already_completed},
           adk_suspension:complete_pkce(
             adk_credential_store_ets, Store, ?USER, ?PROVIDER, FlowRef,
             Correlation,
             #{kind => oauth_refresh_token,
               refresh_token => <<"replayed-token">>})),
        ?assertEqual(
           {error, invalid_credential_completion},
           adk_runner:resume(
             Runner, ?USER, Session, Invocation,
             #{<<"credential_ref">> => FinalRef,
               <<"correlation_id">> => <<"wrong-correlation">>})),
        Completion = #{<<"credential_ref">> => FinalRef,
                       <<"correlation_id">> => Correlation},
        {ok, ResumeStream} = adk_runner:resume(
                               Runner, ?USER, Session, Invocation,
                               Completion),
        _ = await_done(ResumeStream, []),
        {ok, Stored} = erlang_adk_session:get_session(
                         ?APP, ?USER, Session),
        EncodedSession = term_to_binary(
                           [adk_event:to_map(Event)
                            || Event <- maps:get(events, Stored)]),
        ?assertEqual(nomatch,
                     binary:match(EncodedSession, RefreshToken)),
        ?assertNotEqual(nomatch,
                        binary:match(EncodedSession, FinalRef))
    after
        Agent ! stop,
        ok = gen_server:stop(Store),
        _ = erlang_adk_session:delete_session(?APP, ?USER, Session)
    end.

expired_or_malformed_pkce_flow_fails_closed_case() ->
    {ok, Store} = adk_credential_store_ets:start_link(#{name => undefined}),
    Correlation = <<"expired-correlation">>,
    Now = erlang:system_time(millisecond),
    try
        {ok, ExpiredRef} = adk_credential_store_ets:put(
                             Store, ?USER, ?PROVIDER,
                             #{kind => oauth_authorization_pending,
                               code_verifier => binary:copy(<<"v">>, 43),
                               correlation_id => Correlation,
                               created_at => Now - 700000}),
        ?assertEqual(
           {error, credential_flow_expired},
           adk_suspension:complete_pkce(
             adk_credential_store_ets, Store, ?USER, ?PROVIDER,
             ExpiredRef, Correlation,
             #{kind => oauth_refresh_token,
               refresh_token => <<"must-not-be-stored">>})),
        {ok, StillPending} = adk_credential_store_ets:fetch(
                               Store, ?USER, ?PROVIDER, ExpiredRef),
        ?assertEqual(oauth_authorization_pending,
                     maps:get(kind, StillPending)),

        {ok, MalformedRef} = adk_credential_store_ets:put(
                               Store, ?USER, ?PROVIDER,
                               #{kind => oauth_authorization_pending,
                                 code_verifier => binary:copy(<<"v">>, 43),
                                 correlation_id => Correlation}),
        ?assertEqual(
           {error, invalid_stored_credential},
           adk_suspension:complete_pkce(
             adk_credential_store_ets, Store, ?USER, ?PROVIDER,
             MalformedRef, Correlation,
             #{kind => oauth_refresh_token,
               refresh_token => <<"must-not-be-stored">>}))
    after
        ok = gen_server:stop(Store)
    end.

malformed_auth_request_rejected_before_pause_case() ->
    Context = #{user_id => ?USER, invocation_id => <<"inv-test">>},
    Request = #{<<"provider">> => ?PROVIDER,
                <<"scheme">> => <<"oauth2">>,
                <<"authorization_uri">> =>
                    <<"https://accounts.example.test/authorize?access_token=secret">>,
                <<"scopes">> => [<<"calendar.read">>],
                <<"correlation_id">> => <<"corr">>,
                <<"credential_flow_ref">> => adk_credential_store:new_ref(),
                <<"pkce_challenge">> => binary:copy(<<"a">>, 43),
                <<"pkce_method">> => <<"S256">>},
    ?assertError(invalid_credential_suspension,
                 adk_suspension:request_credential(Request, Context)).

agent_loop(Name, ToolName, Args, Tools, initial) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Calls = [{ToolName, Args, <<"signature">>, <<"call-id">>}],
            Event = adk_event:new(
                      Name, {tool_calls, Calls},
                      #{invocation_id => InvocationId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            agent_loop(Name, ToolName, Args, Tools, resumed);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, #{}, Tools, #{}}),
            agent_loop(Name, ToolName, Args, Tools, initial);
        stop -> ok
    end;
agent_loop(Name, ToolName, Args, Tools, resumed) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      Name, <<"External work completed">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            agent_loop(Name, ToolName, Args, Tools, complete);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, #{}, Tools, #{}}),
            agent_loop(Name, ToolName, Args, Tools, resumed);
        stop -> ok
    end;
agent_loop(Name, ToolName, Args, Tools, complete) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, #{}, Tools, #{}}),
            agent_loop(Name, ToolName, Args, Tools, complete);
        stop -> ok
    end.

await_pause(Stream) ->
    receive
        {adk_event, Stream, _Event} -> await_pause(Stream);
        {adk_paused, Stream, Pause} -> Pause;
        {adk_error, Stream, Reason} -> error({unexpected_error, Reason})
    after 2000 ->
        error(pause_timeout)
    end.

await_done(Stream, Acc) ->
    receive
        {adk_event, Stream, Event} -> await_done(Stream, [Event | Acc]);
        {adk_done, Stream} -> lists:reverse(Acc);
        {adk_error, Stream, Reason} -> error({unexpected_error, Reason});
        {adk_paused, Stream, _Pause} -> error(unexpected_second_pause)
    after 2000 ->
        error(done_timeout)
    end.

unique(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(
         erlang:unique_integer([positive, monotonic])))/binary>>.
