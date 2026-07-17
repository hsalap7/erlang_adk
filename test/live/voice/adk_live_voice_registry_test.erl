-module(adk_live_voice_registry_test).

-include_lib("eunit/include/eunit.hrl").

public_claim_release_and_validation_test() ->
    RegistryOwnership = ensure_registry(),
    Session = spawn(fun process_loop/0),
    Remote = external_pid(),
    try
        ?assertEqual(
           {error, invalid_live_voice_lease},
           adk_live_voice_registry:claim(not_a_pid, self())),
        ?assertEqual(
           {error, invalid_live_voice_lease},
           adk_live_voice_registry:release(Session, not_a_pid)),
        ?assertEqual(
           {error, invalid_live_voice_lease},
           adk_live_voice_registry:release(Remote, self())),
        ?assertEqual(ok,
                     adk_live_voice_registry:claim(Session, self())),
        %% Reclaiming an owned lease is deliberately idempotent.
        ?assertEqual(ok,
                     adk_live_voice_registry:claim(Session, self())),
        ?assertEqual(ok,
                     adk_live_voice_registry:release(Session, self())),
        %% Releasing an absent lease is also idempotent.
        ?assertEqual(ok,
                     adk_live_voice_registry:release(Session, self()))
    after
        Session ! stop,
        stop_owned_registry(RegistryOwnership)
    end.

callback_defaults_status_and_termination_test() ->
    {ok, Empty} = adk_live_voice_registry:init([]),
    OtherBridge = spawn(fun process_loop/0),
    Session = spawn(fun process_loop/0),
    try
        ?assertEqual(
           {reply, {error, not_live_voice_lease_owner}, Empty},
           adk_live_voice_registry:handle_call(
             {claim, Session, OtherBridge},
             {self(), make_ref()}, Empty)),
        ?assertEqual(
           {reply, {error, invalid_live_voice_registry_call}, Empty},
           adk_live_voice_registry:handle_call(
             unsupported, {self(), make_ref()}, Empty)),
        ?assertEqual(
           {noreply, Empty},
           adk_live_voice_registry:handle_cast(ignored, Empty)),
        ?assertEqual(
           {noreply, Empty},
           adk_live_voice_registry:handle_info(ignored, Empty)),
        ?assertEqual(
           {noreply, Empty},
           adk_live_voice_registry:handle_info(
             {'DOWN', make_ref(), process, Session, normal}, Empty)),
        KnownRef = make_ref(),
        StaleRefOnly = Empty#{refs => #{KnownRef => Session}},
        ?assertEqual(
           {noreply, StaleRefOnly},
           adk_live_voice_registry:handle_info(
             {'DOWN', KnownRef, process, Session, normal},
             StaleRefOnly)),
        ?assertEqual(
           {ok, Empty},
           adk_live_voice_registry:code_change(old, Empty, extra)),

        Status = adk_live_voice_registry:format_status(
                   #{state => Empty,
                     message => <<"private">>,
                     reason => normal}),
        ?assertEqual(#{lease_count => 0}, maps:get(state, Status)),
        ?assertEqual(redacted, maps:get(message, Status)),
        ?assertEqual(normal, maps:get(reason, Status)),
        ?assertEqual(ok,
                     adk_live_voice_registry:terminate(normal, Empty))
    after
        OtherBridge ! stop,
        Session ! stop
    end.

dead_lease_is_replaced_and_monitors_are_cleaned_test() ->
    Session = spawn(fun process_loop/0),
    DeadBridge = spawn(fun() -> ok end),
    DeadRef = erlang:monitor(process, DeadBridge),
    receive
        {'DOWN', DeadRef, process, DeadBridge, normal} -> ok
    after 1000 ->
        erlang:error(dead_bridge_fixture_timeout)
    end,
    SessionRef = erlang:monitor(process, Session),
    Lease = #{bridge => DeadBridge,
              session_ref => SessionRef,
              bridge_ref => DeadRef},
    Stale = #{leases => #{Session => Lease},
              refs => #{SessionRef => Session, DeadRef => Session}},
    try
        {reply, ok, Replaced} =
            adk_live_voice_registry:handle_call(
              {claim, Session, self()},
              {self(), make_ref()}, Stale),
        #{Session := #{bridge := Bridge,
                       session_ref := NewSessionRef,
                       bridge_ref := NewBridgeRef}} =
            maps:get(leases, Replaced),
        ?assertEqual(self(), Bridge),
        ?assert(NewSessionRef =/= SessionRef),
        ?assert(NewBridgeRef =/= DeadRef),
        ?assertEqual(ok,
                     adk_live_voice_registry:terminate(
                       normal, Replaced))
    after
        erlang:demonitor(SessionRef, [flush]),
        Session ! stop
    end.

known_monitor_removes_exact_lease_test() ->
    Session = spawn(fun process_loop/0),
    {ok, Empty} = adk_live_voice_registry:init([]),
    try
        {reply, ok, Claimed} =
            adk_live_voice_registry:handle_call(
              {claim, Session, self()},
              {self(), make_ref()}, Empty),
        #{Session := #{session_ref := SessionRef}} =
            maps:get(leases, Claimed),
        {noreply, Removed} = adk_live_voice_registry:handle_info(
                               {'DOWN', SessionRef, process,
                                Session, shutdown}, Claimed),
        ?assertEqual(#{}, maps:get(leases, Removed)),
        ?assertEqual(#{}, maps:get(refs, Removed))
    after
        Session ! stop
    end.

process_loop() ->
    receive
        stop -> ok
    end.

ensure_registry() ->
    case whereis(adk_live_voice_registry) of
        undefined ->
            {ok, Registry} = adk_live_voice_registry:start_link(),
            {owned, Registry};
        Registry ->
            {shared, Registry}
    end.

stop_owned_registry({owned, Registry}) ->
    gen_server:stop(Registry);
stop_owned_registry({shared, _Registry}) ->
    ok.

external_pid() ->
    binary_to_term(
      <<131, 103, 100, 0, 23, "registry-test@elsewhere",
        0:32, 0:32, 0:8>>).
