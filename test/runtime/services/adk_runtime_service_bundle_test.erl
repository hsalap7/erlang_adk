-module(adk_runtime_service_bundle_test).
-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-export([init/1]).

-define(OUTBOX_JOBS, adk_runtime_service_bundle_test_outbox_job).
-define(OUTBOX_USAGE, adk_runtime_service_bundle_test_outbox_usage).
-define(OUTBOX_SCHEDULE, adk_runtime_service_bundle_test_outbox_schedule).

runtime_service_bundle_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun profile_compilation_is_strict/0,
      fun invalid_adapter_config_fails_startup/0,
      fun durable_profile_rejects_nonnumeric_memory_contract/0,
      fun named_child_is_discoverable/0,
      fun ephemeral_profile_returns_runner_ready_services/0,
      fun explicit_stop_releases_owned_services/0,
      fun durable_profile_survives_bundle_restart/0,
      fun durable_profile_runner_spec_owns_ingestion/0,
      fun durable_outbox_failure_stops_atomic_generation/0,
      fun durable_profile_fails_closed_when_mnesia_stops/0,
      fun child_failure_restarts_one_atomic_generation/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_State) -> ok.

profile_compilation_is_strict() ->
    ?assertEqual(
       [ephemeral_local, durable_local],
       adk_runtime_service_bundle:profiles()),
    {ok, Ephemeral} = adk_runtime_service_profile:compile(
                        ephemeral_local, #{}),
    ?assertEqual(erlang_adk_session,
                 maps:get(session_service, Ephemeral)),
    ?assertEqual(
       adk_artifact_ets,
       maps:get(adapter, maps:get(artifact, Ephemeral))),
    ?assertEqual(
       adk_memory_ets,
       maps:get(adapter, maps:get(memory, Ephemeral))),
    ?assertEqual(
       shared,
       maps:get(scope_strategy,
                maps:get(config, maps:get(artifact, Ephemeral)))),
    ?assertEqual(
       shared,
       maps:get(scope_strategy,
                maps:get(config, maps:get(memory, Ephemeral)))),
    Root = temp_root(),
    {ok, Durable} = adk_runtime_service_profile:compile(
                      durable_local, #{artifact_root => Root}),
    ?assertEqual(
       exact_scope,
       maps:get(scope_strategy,
                maps:get(config, maps:get(artifact, Durable)))),
    MemoryOutbox = maps:get(memory_outbox, Durable),
    ?assertEqual(
       #{mode => durable,
         adapter_id => <<"durable-local-memory-v1">>,
         max_attempts => 5},
       maps:get(ingestion, MemoryOutbox)),
    ?assertEqual(
       [adk_memory_outbox_job, adk_memory_outbox_usage,
        adk_memory_outbox_schedule, adk_memory_erasure_epoch],
       adk_memory_outbox:table_names(
         maps:get(store, MemoryOutbox))),
    ?assertEqual(
       {error, {unknown_runtime_service_profile, remote}},
       adk_runtime_service_profile:compile(remote, #{})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_profile_config,
         ephemeral_local, {unknown_keys, [unexpected]}}},
       adk_runtime_service_profile:compile(
         ephemeral_local, #{unexpected => true})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_component_config,
         artifact, {unknown_keys, [adapter]}}},
       adk_runtime_service_profile:compile(
         ephemeral_local, #{artifact => #{adapter => arbitrary_module}})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_component_config,
         memory, {adapter_unknown_keys, [unknown_limit]}}},
       adk_runtime_service_profile:compile(
         ephemeral_local,
         #{memory =>
               #{adapter_config => #{unknown_limit => 1}}})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_profile_config,
         durable_local, {artifact_root, required}}},
       adk_runtime_service_profile:compile(durable_local, #{})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_profile_config,
         durable_local, {artifact_root, must_be_absolute}}},
       adk_runtime_service_profile:compile(
         durable_local, #{artifact_root => <<"relative/path">>})),
    ?assertMatch(
       {error,
        {invalid_runtime_service_profile_config,
         durable_local,
         {memory_outbox,
          {invalid_memory_outbox_config,
           {unknown_keys, [unknown_store_option]}}}}},
       adk_runtime_service_profile:compile(
         durable_local,
         #{artifact_root => Root,
           memory_outbox =>
               #{outbox => #{unknown_store_option => true}}})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_profile_config,
         durable_local,
         {memory_outbox,
          {memory_outbox_runner_max_attempts_exceeded, 11}}}},
       adk_runtime_service_profile:compile(
         durable_local,
         #{artifact_root => Root,
           memory_outbox =>
               #{outbox => #{max_attempts => 11,
                              default_max_attempts => 11}}})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_profile_config,
         durable_local,
         {memory_outbox,
          {invalid_memory_outbox_registry_options,
           {unknown_keys, [unknown_registry_option]}}}}},
       adk_runtime_service_profile:compile(
         durable_local,
         #{artifact_root => Root,
           memory_outbox =>
               #{registry => #{unknown_registry_option => true}}})),
    ?assertEqual(
       {error,
        {invalid_runtime_service_profile_config,
         durable_local,
         {memory_outbox, invalid_memory_outbox_poll_interval}}},
       adk_runtime_service_profile:compile(
         durable_local,
         #{artifact_root => Root,
           memory_outbox =>
               #{processor => #{poll_interval_ms => 0}}})),
    ?assertError(
       {invalid_runtime_service_child_spec,
        {invalid_runtime_service_profile_config,
         durable_local, {artifact_root, required}}},
       adk_runtime_service_bundle:child_spec(
         #{profile => durable_local})).

invalid_adapter_config_fails_startup() ->
    Config =
        #{memory =>
              #{adapter_config => #{max_content_bytes => 0}}},
    Expected =
       {error,
        {invalid_runtime_service_component_config,
         memory,
         {adapter_config,
          {invalid_memory_config,
           {max_content_bytes, 0, {allowed_range, 1, 1048576}}}}}},
    ?assertEqual(
       Expected,
       adk_runtime_service_profile:compile(ephemeral_local, Config)),
    ?assertEqual(
       Expected,
       adk_runtime_service_bundle:start_link(ephemeral_local, Config)).

durable_profile_rejects_nonnumeric_memory_contract() ->
    delete_outbox_tables(),
    Root = temp_root(),
    {ok, Plan0} = adk_runtime_service_profile:compile(
                    durable_local, durable_config(Root)),
    Memory0 = maps:get(memory, Plan0),
    MemoryConfig0 = maps:get(config, Memory0),
    InvalidMemory = Memory0#{
      adapter => adk_memory_outbox_test_adapter,
      config => MemoryConfig0#{
        adapter => adk_memory_outbox_test_adapter,
        adapter_config => #{contract_version => <<"v2">>}}},
    try
        ?assertEqual(
           {stop,
            {runtime_service_bundle_start_failed,
             memory_outbox,
             memory_outbox_requires_fenced_idempotent_v2_adapter}},
           adk_runtime_service_bundle:init(
             Plan0#{memory => InvalidMemory}))
    after
        delete_outbox_tables()
    end.

named_child_is_discoverable() ->
    Name = adk_runtime_service_bundle_test_named,
    ChildSpec = adk_runtime_service_bundle:child_spec(
                  #{id => Name, name => Name,
                    profile => ephemeral_local, config => #{}}),
    {ok, Supervisor} = supervisor:start_link(
                         ?MODULE, {test_supervisor, ChildSpec}),
    try
        Bundle = whereis(Name),
        ?assert(is_pid(Bundle)),
        ?assertEqual(Bundle, whereis(Name)),
        {ok, #{status := running}} =
            adk_runtime_service_bundle:status(Name)
    after
        stop_supervisor(Supervisor)
    end,
    ?assertEqual(undefined, whereis(Name)).

ephemeral_profile_returns_runner_ready_services() ->
    Config =
        #{artifact => #{max_active_scopes => 4,
                        max_router_queue => 2},
          memory => #{max_active_scopes => 4,
                      max_router_queue => 2}},
    {ok, Bundle} = adk_runtime_service_bundle:start_link(
                     ephemeral_local, Config),
    App = unique(<<"ephemeral-app">>),
    User = unique(<<"ephemeral-user">>),
    Session = unique(<<"ephemeral-session">>),
    ArtifactScope = {session, App, User, Session},
    MemoryScope = {user, App, User},
    try
        {ok, Services} = adk_runtime_service_bundle:services(Bundle),
        ?assertEqual(ephemeral_local, maps:get(profile, Services)),
        ?assertEqual(erlang_adk_session,
                     maps:get(session_service, Services)),
        ArtifactRef = maps:get(artifact_service, Services),
        MemoryRef = maps:get(memory_service, Services),
        ?assertMatch({ok, ArtifactRef},
                     adk_service_ref:validate(artifact, ArtifactRef)),
        ?assertMatch({ok, MemoryRef},
                     adk_service_ref:validate(memory, MemoryRef)),
        {ok, RunnerSpec} = adk_runtime_service_bundle:runner_spec(Bundle),
        ?assertEqual(erlang_adk_session,
                     maps:get(session_service, RunnerSpec)),
        RunnerOptions = maps:get(runner_options, RunnerSpec),
        ?assertEqual(ArtifactRef,
                     maps:get(artifact_svc, RunnerOptions)),
        ?assertEqual(MemoryRef,
                     maps:get(memory_svc, RunnerOptions)),
        ?assertEqual(false,
                     maps:is_key(memory_ingestion, RunnerOptions)),
        ?assert(adk_runner:is_runner(
                  adk_runner:new(self(), App, erlang_adk_session,
                                 RunnerOptions))),

        {ok, _} = erlang_adk_session:create_session(
                    App, User, #{session_id => Session}),
        {ok, #{version := 1}} = artifact_put(
                                   ArtifactRef, ArtifactScope,
                                   <<"result.txt">>, <<"ready">>),
        {ok, #{data := <<"ready">>}} = artifact_get(
                                            ArtifactRef, ArtifactScope,
                                            <<"result.txt">>),
        {ok, _Entry} = memory_add(
                         MemoryRef, MemoryScope,
                         <<"OTP supervisors restart children">>),
        {ok, [_]} = memory_search(
                      MemoryRef, MemoryScope, <<"supervisors restart">>),

        {ok, Status} = adk_runtime_service_bundle:status(Bundle),
        ?assertEqual(running, maps:get(status, Status)),
        ?assertEqual(ephemeral, maps:get(durability, Status)),
        ?assertEqual(disabled, maps:get(memory_outbox, Status)),
        ArtifactStatus = maps:get(artifact, Status),
        MemoryStatus = maps:get(memory, Status),
        ?assertEqual(adk_artifact_ets,
                     maps:get(adapter, ArtifactStatus)),
        ?assertEqual(volatile,
                     maps:get(
                       persistence,
                       maps:get(capabilities, ArtifactStatus))),
        ?assertEqual(adk_memory_ets,
                     maps:get(adapter, MemoryStatus)),
        ?assertEqual(false,
                     maps:get(durable,
                              maps:get(capabilities, MemoryStatus))),
        ?assertEqual(1, maps:get(active_scopes, ArtifactStatus)),
        ?assertEqual(1, maps:get(active_scopes, MemoryStatus))
    after
        _ = erlang_adk_session:delete_session(App, User, Session),
        ok = stop_bundle(Bundle)
    end,
    ?assertEqual(
       {error, runtime_service_bundle_unavailable},
       adk_runtime_service_bundle:services(Bundle)).

explicit_stop_releases_owned_services() ->
    {ok, Bundle} = adk_runtime_service_bundle:start(
                     ephemeral_local, #{}),
    {ok, Services} = adk_runtime_service_bundle:services(Bundle),
    {adk_artifact_sharded, ArtifactHandle} =
        maps:get(artifact_service, Services),
    {adk_memory_sharded, MemoryHandle} =
        maps:get(memory_service, Services),
    ArtifactRouter = router_pid(ArtifactHandle),
    MemoryRouter = router_pid(MemoryHandle),
    ArtifactMonitor = erlang:monitor(process, ArtifactRouter),
    MemoryMonitor = erlang:monitor(process, MemoryRouter),
    ok = adk_runtime_service_bundle:stop(Bundle),
    receive
        {'DOWN', ArtifactMonitor, process, ArtifactRouter, normal} -> ok
    after 3000 ->
        erlang:error(artifact_router_was_not_stopped)
    end,
    receive
        {'DOWN', MemoryMonitor, process, MemoryRouter, normal} -> ok
    after 3000 ->
        erlang:error(memory_router_was_not_stopped)
    end.

durable_profile_survives_bundle_restart() ->
    delete_outbox_tables(),
    Root = temp_root(),
    App = unique(<<"durable-app">>),
    User = unique(<<"durable-user">>),
    Session = unique(<<"durable-session">>),
    ArtifactScope = {session, App, User, Session},
    MemoryScope = {user, App, User},
    Config = durable_config(Root),
    try
        {ok, First} = adk_runtime_service_bundle:start_link(
                        durable_local, Config),
        {ok, FirstServices} =
            adk_runtime_service_bundle:services(First),
        FirstArtifact = maps:get(artifact_service, FirstServices),
        FirstMemory = maps:get(memory_service, FirstServices),
        FirstOutbox = maps:get(memory_outbox, FirstServices),
        OutboxSupervisor = maps:get(supervisor, FirstOutbox),
        PendingRequest =
            #{scope => MemoryScope,
              session_id => Session,
              adapter =>
                  {adk_memory_sharded, <<"unresolved-restart-adapter">>},
              events => [adk_event:new(
                           <<"user">>, <<"outbox survives restart">>)],
              max_attempts => 10},
        {ok, Submitted} = adk_memory_outbox_sup:submit(
                            OutboxSupervisor, PendingRequest),
        OutboxJobId = maps:get(job_id, Submitted),
        try
            ?assertEqual(erlang_adk_session_mnesia,
                         maps:get(session_service, FirstServices)),
            {ok, _} = erlang_adk_session_mnesia:create_session(
                        App, User,
                        #{session_id => Session,
                          state => #{<<"checkpoint">> => 7}}),
            {ok, #{version := 1}} = artifact_put(
                                       FirstArtifact, ArtifactScope,
                                       <<"durable.txt">>, <<"persisted">>),
            {ok, _} = memory_add(
                        FirstMemory, MemoryScope,
                        <<"durable memory survives restart">>),
            {ok, BeforeRestart} = adk_memory_outbox_sup:status(
                                    OutboxSupervisor, OutboxJobId),
            ?assertEqual(Session, maps:get(session_id, BeforeRestart)),
            {ok, Status} = adk_runtime_service_bundle:status(First),
            ?assertEqual(durable, maps:get(durability, Status)),
            ?assertEqual(
               filesystem,
               maps:get(persistence,
                        maps:get(capabilities,
                                 maps:get(artifact, Status)))),
            ?assertEqual(
               true,
               maps:get(durable,
                        maps:get(capabilities,
                                 maps:get(memory, Status)))),
            ?assertMatch(#{status := ready, persistence := mnesia},
                         maps:get(memory_outbox, Status))
        after
            ok = stop_bundle(First)
        end,

        {ok, Second} = adk_runtime_service_bundle:start_link(
                         durable_local, Config),
        try
            {ok, SecondServices} =
                adk_runtime_service_bundle:services(Second),
            SecondArtifact = maps:get(artifact_service, SecondServices),
            SecondMemory = maps:get(memory_service, SecondServices),
            SecondOutbox = maps:get(memory_outbox, SecondServices),
            SecondOutboxSupervisor = maps:get(supervisor, SecondOutbox),
            {ok, AfterRestart} = adk_memory_outbox_sup:status(
                                   SecondOutboxSupervisor, OutboxJobId),
            ?assertEqual(Session, maps:get(session_id, AfterRestart)),
            ?assertEqual(
               {adk_memory_sharded, <<"unresolved-restart-adapter">>},
               maps:get(adapter, AfterRestart)),
            {ok, #{data := <<"persisted">>}} = artifact_get(
                                                   SecondArtifact,
                                                   ArtifactScope,
                                                   <<"durable.txt">>),
            {ok, [_]} = memory_search(
                          SecondMemory, MemoryScope,
                          <<"memory survives">>),
            {ok, SessionValue} =
                erlang_adk_session_mnesia:get_session(
                  App, User, Session),
            ?assertEqual(7,
                         maps:get(<<"checkpoint">>,
                                  maps:get(state, SessionValue))),
            ok = artifact_delete(
                   SecondArtifact, ArtifactScope, <<"durable.txt">>),
            ok = memory_delete_user(SecondMemory, MemoryScope),
            ok = erlang_adk_session_mnesia:delete_session(
                   App, User, Session)
        after
            ok = stop_bundle(Second)
        end
    after
        _ = file:del_dir_r(Root),
        delete_outbox_tables()
    end.

durable_profile_runner_spec_owns_ingestion() ->
    delete_outbox_tables(),
    Root = temp_root(),
    Config = durable_config(Root),
    Saved = save_runtime_profile_environment(),
    App = unique(<<"durable-runner-app">>),
    User = unique(<<"durable-runner-user">>),
    Session = unique(<<"durable-runner-session">>),
    Agent = spawn(fun durable_agent_loop/0),
    application:set_env(erlang_adk, runtime_service_profile, durable_local),
    application:set_env(erlang_adk, runtime_service_profile_config, Config),
    try
        {ok, Bundle} = adk_runtime_service_bundle:start_link(
                         adk_runtime_service_bundle,
                         durable_local, Config),
        try
            {ok, #{profile := durable_local,
                   session_service := erlang_adk_session_mnesia,
                   runner_options := RunnerOptions}} =
                erlang_adk:runtime_runner_spec(),
            #{mode := durable,
              adapter_id := <<"durable-local-memory-v1">>,
              max_attempts := 5,
              outbox := OutboxSupervisor} =
                maps:get(memory_ingestion, RunnerOptions),
            ?assert(is_pid(OutboxSupervisor)),
            ?assertEqual(undefined, whereis(adk_memory_outbox_sup)),
            ?assertMatch(
               {ok, #{status := ready, persistence := mnesia}},
               adk_memory_outbox_sup:health(OutboxSupervisor)),
            %% Legacy module-named convenience calls must resolve the one
            %% bundle-owned processor even though no duplicate global
            %% supervisor is registered.
            {ok, Services} =
                adk_runtime_service_bundle:services(Bundle),
            #{adapter := CompatibilityIdentity} =
                maps:get(memory_outbox, Services),
            ok = adk_memory_outbox_sup:register_adapter(
                   CompatibilityIdentity,
                   maps:get(memory_service, Services)),
            {ok, CompatibilityJob} = adk_memory_outbox_sup:submit(
                #{scope => {user, App, User},
                  session_id => <<Session/binary, "-compat">>,
                  adapter => CompatibilityIdentity,
                  events => [adk_event:new(
                               <<"user">>,
                               <<"legacy named outbox compatibility">>)],
                  max_attempts => 5}),
            CompatibilityJobId = maps:get(job_id, CompatibilityJob),
            ?assertMatch({ok, #{active_jobs := _}},
                         adk_memory_outbox_sup:stats()),
            ?assertMatch(
               #{phase := completed, attempt := 1},
               wait_for_named_outbox_phase(
                 CompatibilityJobId, completed, 3000)),
            Runner = adk_runner:new(
                       Agent, App, erlang_adk_session_mnesia,
                       RunnerOptions#{run_timeout => 5000,
                                      service_timeout => 1000}),
            ?assertEqual(
               {ok, <<"the owned outbox remembered the banana">>},
               adk_runner:run(
                 Runner, User, Session,
                 <<"remember the owned durable banana">>)),
            Memory = maps:get(memory_svc, RunnerOptions),
            Hits = wait_for_memory_hits(
                     Memory, {user, App, User}, <<"banana">>, 2, 3000),
            ?assertEqual(2, length(Hits)),
            {ok, Status} = adk_runtime_service_bundle:status(Bundle),
            ?assertMatch(#{status := ready, persistence := mnesia},
                         maps:get(memory_outbox, Status)),
            ok = memory_delete_user(Memory, {user, App, User}),
            ok = erlang_adk_session_mnesia:delete_session(
                   App, User, Session)
        after
            ok = stop_bundle(Bundle)
        end
    after
        Agent ! stop,
        restore_runtime_profile_environment(Saved),
        _ = file:del_dir_r(Root),
        delete_outbox_tables()
    end.

durable_outbox_failure_stops_atomic_generation() ->
    delete_outbox_tables(),
    Root = temp_root(),
    try
        {ok, Bundle} = adk_runtime_service_bundle:start(
                         durable_local, durable_config(Root)),
        {ok, Services} = adk_runtime_service_bundle:services(Bundle),
        {ok, RunnerSpec} = adk_runtime_service_bundle:runner_spec(Bundle),
        RunnerOptions = maps:get(runner_options, RunnerSpec),
        Outbox = maps:get(memory_outbox, Services),
        OutboxSupervisor = maps:get(supervisor, Outbox),
        BundleMonitor = erlang:monitor(process, Bundle),
        exit(OutboxSupervisor, kill),
        receive
            {'DOWN', BundleMonitor, process, Bundle,
             {runtime_service_child_down, memory_outbox, killed}} -> ok
        after 3000 ->
            erlang:error(durable_bundle_survived_owned_outbox_loss)
        end,
        ?assertMatch(
           {error, _}, adk_runtime_service_bundle:services(Bundle)),
        ?assertError(
           {memory_outbox_runtime_required, _},
           adk_runner:new(
             self(), <<"failed-owned-outbox">>,
             maps:get(session_service, RunnerSpec), RunnerOptions))
    after
        _ = file:del_dir_r(Root),
        delete_outbox_tables()
    end.

durable_profile_fails_closed_when_mnesia_stops() ->
    delete_outbox_tables(),
    Root = temp_root(),
    {ok, Bundle} = adk_runtime_service_bundle:start(
                     durable_local, durable_config(Root)),
    Monitor = erlang:monitor(process, Bundle),
    try
        {ok, #{status := running}} =
            adk_runtime_service_bundle:status(Bundle),
        ok = application:stop(mnesia),
        receive
            {'DOWN', Monitor, process, Bundle,
             {runtime_service_dependency_down, mnesia, _Reason}} -> ok;
            {'DOWN', Monitor, process, Bundle,
             {runtime_service_dependency_unavailable,
              mnesia, _Reason}} -> ok
        after 3000 ->
            erlang:error(durable_bundle_did_not_fail_closed)
        end,
        ?assertMatch(
           {error, _}, adk_runtime_service_bundle:services(Bundle))
    after
        erlang:demonitor(Monitor, [flush]),
        _ = catch adk_runtime_service_bundle:stop(Bundle),
        {ok, _} = application:ensure_all_started(mnesia),
        _ = file:del_dir_r(Root),
        delete_outbox_tables()
    end.

child_failure_restarts_one_atomic_generation() ->
    ChildSpec = adk_runtime_service_bundle:child_spec(
                  #{id => runtime_services_under_test,
                    profile => ephemeral_local,
                    config => #{}}),
    {ok, Supervisor} = supervisor:start_link(
                         ?MODULE, {test_supervisor, ChildSpec}),
    try
        First = bundle_child(Supervisor),
        {ok, FirstServices} =
            adk_runtime_service_bundle:services(First),
        {adk_artifact_sharded, ArtifactHandle} =
            maps:get(artifact_service, FirstServices),
        {adk_memory_sharded, MemoryHandle} =
            maps:get(memory_service, FirstServices),
        ArtifactRouter = router_pid(ArtifactHandle),
        MemoryRouter = router_pid(MemoryHandle),
        FirstMonitor = erlang:monitor(process, First),
        MemoryMonitor = erlang:monitor(process, MemoryRouter),
        exit(ArtifactRouter, kill),
        receive
            {'DOWN', FirstMonitor, process, First,
             {runtime_service_child_down, artifact, killed}} -> ok
        after 3000 ->
            erlang:error(bundle_did_not_fail_stop)
        end,
        receive
            {'DOWN', MemoryMonitor, process, MemoryRouter, _} -> ok
        after 3000 ->
            erlang:error(sibling_service_was_not_stopped)
        end,
        Second = await_restarted_bundle(Supervisor, First, 3000),
        ?assert(is_pid(Second)),
        ?assert(Second =/= First),
        {ok, #{status := running,
               restart_semantics := atomic_generation_fail_stop}} =
            adk_runtime_service_bundle:status(Second)
    after
        stop_supervisor(Supervisor)
    end.

init({test_supervisor, ChildSpec}) ->
    {ok, {#{strategy => one_for_one,
            intensity => 5,
            period => 10}, [ChildSpec]}}.

artifact_put({Module, Handle}, Scope, Name, Data) ->
    Module:put(Handle, Scope, Name, Data,
               #{mime_type => <<"text/plain">>}).

artifact_get({Module, Handle}, Scope, Name) ->
    Module:get(Handle, Scope, Name, latest).

artifact_delete({Module, Handle}, Scope, Name) ->
    Module:delete(Handle, Scope, Name, all).

memory_add({Module, Handle}, Scope, Content) ->
    Module:add_entry(
      Handle, Scope, #{content => Content, metadata => #{}}, #{}).

memory_search({Module, Handle}, Scope, Query) ->
    Module:search(Handle, Scope, Query, #{limit => 5}).

memory_delete_user({Module, Handle}, Scope) ->
    Module:delete_user(Handle, Scope).

durable_config(Root) ->
    #{artifact_root => Root,
      artifact => #{max_active_scopes => 4},
      memory => #{max_active_scopes => 4},
      memory_outbox =>
          #{outbox =>
                #{jobs_table => ?OUTBOX_JOBS,
                  usage_table => ?OUTBOX_USAGE,
                  schedule_table => ?OUTBOX_SCHEDULE}}}.

delete_outbox_tables() ->
    lists:foreach(
      fun(Table) -> _ = catch mnesia:delete_table(Table) end,
      [?OUTBOX_JOBS, ?OUTBOX_USAGE, ?OUTBOX_SCHEDULE]),
    ok.

save_runtime_profile_environment() ->
    [{Key, application:get_env(erlang_adk, Key)}
     || Key <- [runtime_service_profile,
                runtime_service_profile_config]].

restore_runtime_profile_environment(Saved) ->
    lists:foreach(
      fun({Key, undefined}) -> application:unset_env(erlang_adk, Key);
         ({Key, {ok, Value}}) ->
              application:set_env(erlang_adk, Key, Value)
      end, Saved),
    ok.

wait_for_memory_hits(Service, Scope, Query, Count, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_memory_hits_until(Service, Scope, Query, Count, Deadline).

wait_for_named_outbox_phase(JobId, Phase, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_named_outbox_phase_until(JobId, Phase, Deadline).

wait_for_named_outbox_phase_until(JobId, Phase, Deadline) ->
    case adk_memory_outbox_sup:status(JobId) of
        {ok, #{phase := Phase} = Status} -> Status;
        {ok, #{phase := failed} = Status} ->
            erlang:error({named_outbox_job_failed, Status});
        Other ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error({named_outbox_phase_timeout, Other});
                false ->
                    receive after 10 -> ok end,
                    wait_for_named_outbox_phase_until(
                      JobId, Phase, Deadline)
            end
    end.

wait_for_memory_hits_until(Service, Scope, Query, Count, Deadline) ->
    case memory_search(Service, Scope, Query) of
        {ok, Hits} when length(Hits) =:= Count -> Hits;
        Other ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error({memory_ingestion_timeout, Other});
                false ->
                    receive after 10 -> ok end,
                    wait_for_memory_hits_until(
                      Service, Scope, Query, Count, Deadline)
            end
    end.

durable_agent_loop() ->
    receive
        {'$gen_call', From,
         {run_with_events, _HistoryEvents, InvocationId}} ->
            Event = adk_event:new(
                      <<"DurableProfileAgent">>,
                      <<"the owned outbox remembered the banana">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            durable_agent_loop();
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"DurableProfileAgent">>, #{}, [], #{}}),
            durable_agent_loop();
        stop -> ok
    end.

router_pid({adk_scope_shard, Pid, _Table, _Admission, _MaxQueue}) -> Pid.

bundle_child(Supervisor) ->
    case supervisor:which_children(Supervisor) of
        [{runtime_services_under_test, Pid, worker,
          [adk_runtime_service_bundle]}] when is_pid(Pid) -> Pid;
        Other -> erlang:error({unexpected_bundle_children, Other})
    end.

await_restarted_bundle(_Supervisor, _Previous, Remaining)
  when Remaining =< 0 ->
    erlang:error(bundle_was_not_restarted);
await_restarted_bundle(Supervisor, Previous, Remaining) ->
    case catch bundle_child(Supervisor) of
        Pid when is_pid(Pid), Pid =/= Previous -> Pid;
        _ ->
            receive after 10 -> ok end,
            await_restarted_bundle(
              Supervisor, Previous, Remaining - 10)
    end.

stop_bundle(Bundle) ->
    case adk_runtime_service_bundle:stop(Bundle) of
        ok -> ok;
        {error, runtime_service_bundle_unavailable} -> ok
    end.

stop_supervisor(Supervisor) ->
    Monitor = erlang:monitor(process, Supervisor),
    unlink(Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _} -> ok
    after 3000 ->
        erlang:demonitor(Monitor, [flush]),
        erlang:error(test_supervisor_did_not_stop)
    end.

temp_root() ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end,
    filename:join(
      Base,
      "erlang-adk-runtime-services-" ++
          integer_to_list(
            erlang:unique_integer([positive, monotonic]))).

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
