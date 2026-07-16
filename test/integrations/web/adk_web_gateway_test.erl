-module(adk_web_gateway_test).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"adk_web_gateway_test">>).
-define(ISSUER, <<"https://identity.example.test">>).

web_gateway_test_() ->
    {setup,
     fun setup/0,
     fun(_Setup) -> ok end,
     [fun policy_is_default_deny_and_rejects_forged_identity/0,
      fun agent_catalog_is_resolved_only_after_authorization/0,
      fun run_scope_is_derived_and_cross_principal_access_is_hidden/0,
      fun resumed_run_inherits_owner_scope/0,
      fun authorizer_failures_are_isolated_and_bounded/0,
      fun independent_authorizations_overlap_with_bounded_admission/0,
      fun queued_post_deadline_authorization_fails_closed/0,
      fun gateway_death_reaps_authorizer_worker/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

policy_is_default_deny_and_rejects_forged_identity() ->
    {ok, Policy} = adk_scope_authorizer:new(policy_config()),
    Alice = identity(<<"alice">>, all_scopes()),
    {ok, Decision} = adk_scope_authorizer:authorize(
                       Policy, Alice, start_run,
                       #{agent => <<"assistant">>}),
    ?assertEqual(maps:get(principal, Alice), maps:get(user_id, Decision)),
    ?assertEqual(32, byte_size(maps:get(owner_scope, Decision))),

    Missing = identity(<<"alice">>, [<<"adk.agents.read">>]),
    ?assertEqual(
       {error, forbidden},
       adk_scope_authorizer:authorize(
         Policy, Missing, start_run, #{agent => <<"assistant">>})),
    Forged = Alice#{principal => <<"oidc_forged">>},
    ?assertEqual(
       {error, unauthenticated},
       adk_scope_authorizer:authorize(
         Policy, Forged, observe_run, #{run => <<"run-hidden">>})),
    ?assertEqual(
       {error, forbidden},
       adk_scope_authorizer:authorize(
         Policy, Alice, unknown_action, #{})).

agent_catalog_is_resolved_only_after_authorization() ->
    Agent = spawn(fun() -> completing_agent_loop() end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, Gateway} = gateway(Runner),
    MissingStartScope = identity(
                          <<"catalog-reader">>,
                          [<<"adk.agents.read">>]),
    Authorized = identity(<<"catalog-runner">>, all_scopes()),
    SessionId = unique(<<"catalog">>),
    try
        ?assertEqual(
           {error, forbidden},
           adk_web_gateway:start_run(
             Gateway, MissingStartScope, <<"assistant">>, SessionId,
             <<"hello">>)),
        ?assertEqual(
           {error, forbidden},
           adk_web_gateway:start_run(
             Gateway, MissingStartScope, <<"private-or-unknown">>,
             SessionId, <<"hello">>)),
        ?assertEqual(
           {error, not_found},
           adk_web_gateway:start_run(
             Gateway, Authorized, <<"private-or-unknown">>, SessionId,
             <<"hello">>))
    after
        Agent ! stop,
        gen_server:stop(Gateway)
    end.

run_scope_is_derived_and_cross_principal_access_is_hidden() ->
    Agent = spawn(fun() -> completing_agent_loop() end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, Gateway} = gateway(Runner),
    Alice = identity(<<"alice">>, all_scopes()),
    Bob = identity(<<"bob">>, all_scopes()),
    SessionId = unique(<<"owned">>),
    try
        {ok, [#{id := <<"assistant">>}]} =
            adk_web_gateway:list_agents(Gateway, Alice),
        {ok, RunId} = adk_web_gateway:start_run(
                        Gateway, Alice, <<"assistant">>, SessionId,
                        <<"hello">>),
        ?assertMatch({ok, #{state := _}},
                     adk_web_gateway:status(Gateway, Alice, RunId)),
        ?assertEqual({error, not_found},
                     adk_web_gateway:status(Gateway, Bob, RunId)),
        ?assertEqual({error, not_found},
                     adk_web_gateway:cancel(Gateway, Bob, RunId)),

        {ok, _Info} = adk_web_gateway:subscribe_credit(
                        Gateway, Alice, RunId, self(), 0),
        Sequence = receive
            {adk_run_event, RunId, Seq, #adk_event{}} -> Seq
        after 1000 ->
            error(missing_owned_run_event)
        end,
        ok = adk_web_gateway:ack(
               Gateway, Alice, RunId, self(), Sequence),
        ?assertEqual({completed, <<"Gateway response">>},
                     adk_run:await(RunId, 1000)),
        ok = adk_web_gateway:unsubscribe(
               Gateway, Alice, RunId, self()),

        Principal = maps:get(principal, Alice),
        ?assertMatch({ok, _}, erlang_adk_session:get_session(
                                ?APP, Principal, SessionId)),
        ?assertEqual({error, not_found},
                     erlang_adk_session:get_session(
                       ?APP, <<"alice">>, SessionId))
    after
        Agent ! stop,
        gen_server:stop(Gateway),
        _ = erlang_adk_session:delete_session(
              ?APP, maps:get(principal, Alice), SessionId)
    end.

resumed_run_inherits_owner_scope() ->
    Agent = spawn(fun() -> resumable_agent_loop(initial) end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, Gateway} = gateway(Runner),
    Alice = identity(<<"resume-alice">>, all_scopes()),
    Bob = identity(<<"resume-bob">>, all_scopes()),
    SessionId = unique(<<"resume">>),
    try
        {ok, PausedRunId} = adk_web_gateway:start_run(
                              Gateway, Alice, <<"assistant">>, SessionId,
                              <<"publish">>),
        {paused, _Pause} = adk_run:await(PausedRunId, 1000),
        {ok, ResumedRunId} = adk_web_gateway:resume(
                               Gateway, Alice, PausedRunId,
                               #{<<"decision">> => <<"approved">>}),
        ?assertEqual({completed, <<"Release published">>},
                     adk_run:await(ResumedRunId, 1000)),
        ?assertMatch({ok, #{parent_run_id := PausedRunId}},
                     adk_web_gateway:status(
                       Gateway, Alice, ResumedRunId)),
        ?assertEqual({error, not_found},
                     adk_web_gateway:status(
                       Gateway, Bob, ResumedRunId)),

        {ok, Policy} = adk_scope_authorizer:new(policy_config()),
        {ok, AliceDecision} = adk_scope_authorizer:authorize(
                                Policy, Alice, observe_run,
                                #{run => ResumedRunId}),
        {ok, _} = adk_run_registry:lookup_authorized(
                    ResumedRunId, maps:get(owner_scope, AliceDecision))
    after
        Agent ! stop,
        gen_server:stop(Gateway),
        _ = erlang_adk_session:delete_session(
              ?APP, maps:get(principal, Alice), SessionId)
    end.

authorizer_failures_are_isolated_and_bounded() ->
    lists:foreach(
      fun({Mode, HeapWords}) ->
          Agent = spawn(fun() -> completing_agent_loop() end),
          Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                                  #{run_timeout => 2000}),
          {ok, Gateway} = gateway(
                            Runner,
                            #{authorizer =>
                                  adk_web_gateway_test_authorizer,
                              policy =>
                                  #{mode => Mode,
                                    policy => policy_config()},
                              authorizer_timeout_ms => 30,
                              authorizer_max_heap_words => HeapWords}),
          try
              ?assertEqual(
                 {error, forbidden},
                 adk_web_gateway:list_agents(
                   Gateway, identity(<<"bounded">>, all_scopes()))),
              ?assert(is_process_alive(Gateway))
          after
              Agent ! stop,
              gen_server:stop(Gateway)
          end
      end,
      [{sleep, 100000}, {crash, 100000}, {heap, 10000}]).

independent_authorizations_overlap_with_bounded_admission() ->
    Agent = spawn(fun() -> completing_agent_loop() end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, Gateway} = gateway(
                      Runner,
                      #{authorizer => adk_web_gateway_test_authorizer,
                        policy =>
                            #{mode => concurrent, observer => self(),
                              policy => policy_config()},
                        authorizer_timeout_ms => 1000,
                        max_authorizations => 2}),
    Identity = identity(<<"parallel">>, all_scopes()),
    Parent = self(),
    Caller = fun() ->
        Parent ! {gateway_result, self(),
                  adk_web_gateway:list_agents(Gateway, Identity)}
    end,
    try
        _Caller1 = spawn(Caller),
        _Caller2 = spawn(Caller),
        Worker1 = receive
            {authorizer_entered, Pid1} -> Pid1
        after 1000 -> error(first_authorizer_not_started)
        end,
        Worker2 = receive
            {authorizer_entered, Pid2} -> Pid2
        after 1000 -> error(second_authorizer_not_started)
        end,
        ?assert(Worker1 =/= Worker2),
        ?assertEqual({error, gateway_busy},
                     adk_web_gateway:list_agents(Gateway, Identity)),
        Worker1 ! {release_authorizer, self()},
        Worker2 ! {release_authorizer, self()},
        Results = [receive
                       {gateway_result, _Caller, Result} -> Result
                   after 1000 -> error(missing_gateway_result)
                   end || _ <- lists:seq(1, 2)],
        ?assert(lists:all(
                  fun({ok, [#{id := <<"assistant">>}]}) -> true;
                     (_) -> false
                  end, Results)),
        ?assert(is_process_alive(Gateway))
    after
        Agent ! stop,
        gen_server:stop(Gateway)
    end.

queued_post_deadline_authorization_fails_closed() ->
    Agent = spawn(fun() -> completing_agent_loop() end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, Gateway} = gateway(
                      Runner,
                      #{authorizer => adk_web_gateway_test_authorizer,
                        policy =>
                            #{mode => concurrent, observer => self(),
                              policy => policy_config()},
                        authorizer_timeout_ms => 30}),
    Parent = self(),
    try
        _Caller = spawn(fun() ->
            Parent ! {late_gateway_result,
                      adk_web_gateway:list_agents(
                        Gateway, identity(<<"late">>, all_scopes()))}
        end),
        Worker = receive
            {authorizer_entered, Pid} -> Pid
        after 1000 -> error(authorizer_not_started)
        end,
        ok = sys:suspend(Gateway),
        timer:sleep(40),
        Worker ! {release_authorizer, self()},
        timer:sleep(10),
        ok = sys:resume(Gateway),
        ?assertEqual(
           {error, forbidden},
           receive
               {late_gateway_result, Result} -> Result
           after 1000 -> error(missing_late_gateway_result)
           end)
    after
        _ = catch sys:resume(Gateway),
        Agent ! stop,
        _ = catch gen_server:stop(Gateway)
    end.

gateway_death_reaps_authorizer_worker() ->
    Agent = spawn(fun() -> completing_agent_loop() end),
    Runner = adk_runner:new(Agent, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    {ok, Gateway} = gateway(
                      Runner,
                      #{authorizer => adk_web_gateway_test_authorizer,
                        policy =>
                            #{mode => concurrent, observer => self(),
                              policy => policy_config()},
                        authorizer_timeout_ms => 1000}),
    Parent = self(),
    _Caller = spawn(fun() ->
        Parent ! {dead_gateway_result,
                  adk_web_gateway:list_agents(
                    Gateway, identity(<<"owner-death">>, all_scopes()))}
    end),
    Worker = receive
        {authorizer_entered, Pid} -> Pid
    after 1000 -> error(authorizer_not_started)
    end,
    unlink(Gateway),
    exit(Gateway, kill),
    wait_until_dead(Worker, 100),
    ?assertEqual(
       {error, gateway_unavailable},
       receive
           {dead_gateway_result, Result} -> Result
       after 1000 -> error(missing_dead_gateway_result)
       end),
    Agent ! stop.

gateway(Runner) ->
    gateway(Runner, #{}).

gateway(Runner, Overrides) ->
    Base = #{agents =>
            #{<<"assistant">> =>
                  #{runner => Runner,
                    label => <<"Assistant">>,
                    description => <<"Deterministic gateway fixture">>,
                    run_options => #{retention_ms => 2000}}},
             policy => policy_config()},
    adk_web_gateway:start_link(maps:merge(Base, Overrides)).

policy_config() ->
    #{trusted_issuers => [?ISSUER],
      required_scopes =>
          #{list_agents => [<<"adk.agents.read">>],
            start_run => [<<"adk.run.start">>],
            observe_run => [<<"adk.run.read">>],
            control_run => [<<"adk.run.control">>],
            resume_run => [<<"adk.run.control">>]}}.

all_scopes() ->
    [<<"adk.agents.read">>, <<"adk.run.start">>,
     <<"adk.run.read">>, <<"adk.run.control">>].

identity(Subject, Scopes) ->
    OwnerScope = adk_scope_authorizer:owner_scope(?ISSUER, Subject),
    Encoded0 = base64:encode(OwnerScope),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    Encoded = binary:replace(Encoded2, <<"=">>, <<>>, [global]),
    #{principal => <<"oidc_", Encoded/binary>>,
      subject => Subject,
      issuer => ?ISSUER,
      audiences => [<<"erlang-adk-ui">>],
      scopes => Scopes,
      claims => #{<<"sub">> => Subject}}.

completing_agent_loop() ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From,
                             {ok, <<"gateway-agent">>, #{}, [], #{}}),
            completing_agent_loop();
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      <<"gateway-agent">>, <<"Gateway response">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            completing_agent_loop();
        stop -> ok;
        _ -> completing_agent_loop()
    end.

resumable_agent_loop(initial) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"gateway-resumable">>, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(initial);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Calls = [{<<"request_human_approval">>,
                      #{<<"action_summary">> => <<"Publish release">>},
                      undefined, <<"approval-call">>}],
            Event = adk_event:new(
                      <<"gateway-resumable">>, {tool_calls, Calls},
                      #{invocation_id => InvocationId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            resumable_agent_loop(paused);
        stop -> ok;
        _ -> resumable_agent_loop(initial)
    end;
resumable_agent_loop(paused) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"gateway-resumable">>, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(paused);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      <<"gateway-resumable">>, <<"Release published">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            resumable_agent_loop(done);
        stop -> ok;
        _ -> resumable_agent_loop(paused)
    end;
resumable_agent_loop(done) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"gateway-resumable">>, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(done);
        stop -> ok;
        _ -> resumable_agent_loop(done)
    end.

unique(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(
         erlang:unique_integer([positive, monotonic])))/binary>>.

wait_until_dead(Pid, 0) ->
    ?assertNot(is_process_alive(Pid));
wait_until_dead(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(2),
            wait_until_dead(Pid, Attempts - 1)
    end.
