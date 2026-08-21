-module(adk_artifact_effect_journal_bundle_test).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, adk_artifact_effect_journal_bundle_test_table).

durable_bundle_owns_journal_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Root = temp_root(),
    JournalConfig = #{table => ?TABLE, orphan_grace_ms => 0},
    Config = #{artifact_root => Root,
               artifact_journal => JournalConfig},
    Scope = {session, <<"bundle-journal-app">>,
             <<"bundle-journal-user">>, <<"bundle-journal-session">>},
    try
        {ok, Plan} = adk_runtime_service_profile:compile(
                       durable_local, Config),
        ?assertMatch(#{artifact_effect_journal := #{config := _}}, Plan),
        ?assertMatch(
           {error,
            {invalid_runtime_service_profile_config, durable_local,
             {artifact_journal,
              {invalid_artifact_journal_config,
               {unknown_keys, [unexpected]}}}}},
           adk_runtime_service_profile:compile(
             durable_local,
             #{artifact_root => Root,
               artifact_journal => #{unexpected => true}})),

        {ok, First} = adk_runtime_service_bundle:start_link(
                        durable_local, Config),
        {EffectId, FirstJournal} = try
            {ok, Services} = adk_runtime_service_bundle:services(First),
            Journal = maps:get(artifact_effect_journal, Services),
            ?assert(adk_artifact_effect_journal:is_handle(Journal)),
            {ok, RunnerSpec} =
                adk_runtime_service_bundle:runner_spec(First),
            RunnerOptions = maps:get(runner_options, RunnerSpec),
            ?assertEqual(Journal,
                         maps:get(artifact_effect_journal,
                                  RunnerOptions)),
            ?assert(adk_runner:is_runner(
                      adk_runner:new(
                        self(), <<"bundle-journal-app">>,
                        maps:get(session_service, RunnerSpec),
                        RunnerOptions))),
            {ok, #{artifact_effect_journal :=
                       #{status := ready, persistence := mnesia}}} =
                adk_runtime_service_bundle:status(First),
            {ok, Intent} = adk_artifact_effect_journal:record_intent(
                             Journal, intent(Scope)),
            {maps:get(effect_id, Intent), Journal}
        after
            ok = adk_runtime_service_bundle:stop(First)
        end,

        {ok, Second} = adk_runtime_service_bundle:start_link(
                         durable_local, Config),
        try
            {ok, Services2} =
                adk_runtime_service_bundle:services(Second),
            RestartedJournal = maps:get(
                                 artifact_effect_journal, Services2),
            ?assertEqual(FirstJournal, RestartedJournal),
            {ok, #{phase := prepared}} =
                adk_artifact_effect_journal:status(
                  RestartedJournal, Scope, EffectId)
        after
            ok = adk_runtime_service_bundle:stop(Second)
        end
    after
        _ = mnesia:clear_table(?TABLE),
        _ = file:del_dir_r(Root)
    end.

intent(Scope) ->
    #{scope => Scope, operation => put,
      resource_id => <<"bundle/journal.txt">>,
      request_digest => <<"bundle-request-digest">>,
      idempotency_key => <<"bundle-idempotency-key">>,
      metadata => #{source => <<"bundle-test">>}}.

temp_root() ->
    Name = "erlang-adk-journal-bundle-" ++
           integer_to_list(erlang:unique_integer([positive, monotonic])),
    Root = filename:join("/tmp", Name),
    ok = file:make_dir(Root),
    Root.
