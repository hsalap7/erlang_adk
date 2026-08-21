-module(adk_artifact_effect_journal_context_test).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, adk_artifact_effect_journal_context_test_table).
-define(APP, <<"journal-context-app">>).
-define(USER, <<"journal-context-user">>).
-define(SESSION, <<"journal-context-session">>).

artifact_effect_journal_context_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun(State) -> ?_test(success_commits_staged_rows(State)) end,
      fun(State) -> ?_test(abort_leaves_applied_orphan(State)) end,
      fun(State) -> ?_test(journal_failure_prevents_mutation(State)) end,
      fun(State) -> ?_test(runner_accepts_only_journal_handles(State)) end]}.

setup() ->
    {ok, Journal} = adk_artifact_effect_journal:init(
                      #{table => ?TABLE, orphan_grace_ms => 0,
                        retry_base_ms => 1, max_retry_ms => 2,
                        terminal_retention_ms => 0}),
    {atomic, ok} = mnesia:clear_table(?TABLE),
    #{journal => Journal}.

cleanup(_State) ->
    _ = mnesia:clear_table(?TABLE),
    ok.

success_commits_staged_rows(#{journal := Journal}) ->
    with_context(Journal, fun(Root, Context, _ArtifactPid) ->
        {ok, _} = adk_context:save_artifact(
                    Context, <<"committed.txt">>, <<"durable bytes">>,
                    #{mime_type => <<"text/plain">>}),
        %% Distinct mutations inside one tool call receive stable ordinals;
        %% identical puts must not collapse into one journal intent.
        {ok, _} = adk_context:save_artifact(
                    Context, <<"committed.txt">>, <<"durable bytes">>,
                    #{mime_type => <<"text/plain">>}),
        ok = adk_context:delete_artifact(
               Context, <<"committed.txt">>, latest),
        {ok, Receipt, Effects} = adk_context_capability:prepare_effects(
                                   Root, effect_call),
        ?assertEqual(3, length(Effects)),
        JournalIds = [maps:get(artifact_journal_id, Effect)
                      || Effect <- Effects],
        ?assert(lists:all(
                  fun(Effect) ->
                      not maps:is_key(artifact_journal_receipt, Effect)
                  end, Effects)),
        lists:foreach(fun(Id) ->
            {ok, #{phase := applied}} =
                adk_artifact_effect_journal:status(
                  Journal, scope(), Id)
        end, JournalIds),
        ok = adk_context_capability:commit_effects(Root, Receipt),
        lists:foreach(fun(Id) ->
            {ok, #{phase := committed}} =
                adk_artifact_effect_journal:status(
                  Journal, scope(), Id)
        end, JournalIds),
        {ok, none, []} = adk_context_capability:prepare_effects(
                           Root, effect_call)
    end).

abort_leaves_applied_orphan(#{journal := Journal}) ->
    with_context(Journal, fun(Root, Context, _ArtifactPid) ->
        {ok, _} = adk_context:save_artifact(
                    Context, <<"orphan.txt">>, <<"orphan bytes">>, #{}),
        {ok, Receipt1, [Effect]} =
            adk_context_capability:prepare_effects(Root, effect_call),
        Id = maps:get(artifact_journal_id, Effect),
        ok = adk_context_capability:abort_effects(Root, Receipt1),
        {ok, #{phase := applied}} =
            adk_artifact_effect_journal:status(Journal, scope(), Id),

        Now = erlang:system_time(millisecond) + 10,
        {ok, #{processed := 1, failed := 0}} =
            adk_artifact_orphan_reconciler:run(
              Journal,
              {adk_artifact_reconcile_test_handler,
               #{mode => committed, test_pid => self()}},
              #{max_items => 1, now_ms => Now,
                lease_ms => 500, call_timeout_ms => 50}),
        receive
            {artifact_reconcile_seen, #{effect_id := Id}} -> ok
        after 1000 -> error(orphan_not_reconciled)
        end,
        {ok, #{phase := committed}} =
            adk_artifact_effect_journal:status(Journal, scope(), Id),

        %% A later event retry sees the already-reconciled journal commit as
        %% success and can safely drain the original staged effect.
        {ok, Receipt2, [Effect]} =
            adk_context_capability:prepare_effects(Root, effect_call),
        ok = adk_context_capability:commit_effects(Root, Receipt2)
    end).

journal_failure_prevents_mutation(#{journal := Journal}) ->
    Missing = Journal#{table => adk_artifact_effect_missing_table},
    ?assert(adk_artifact_effect_journal:is_handle(Missing)),
    with_context(Missing, fun(_Root, Context, ArtifactPid) ->
        ?assertEqual(
           {error, artifact_effect_journal_unavailable},
           adk_context:save_artifact(
             Context, <<"must-not-exist.txt">>, <<"secret">>, #{})),
        ?assertEqual(
           {error, not_found},
           adk_artifact_ets:get(
             ArtifactPid, scope(), <<"must-not-exist.txt">>, latest))
    end).

runner_accepts_only_journal_handles(#{journal := Journal}) ->
    Runner = adk_runner:new(
               ?MODULE, ?APP, adk_session_ets,
               #{artifact_effect_journal => Journal}),
    ?assert(adk_runner:is_runner(Runner)),
    ?assertError(
       invalid_runner_artifact_effect_journal,
       adk_runner:new(
         ?MODULE, ?APP, adk_session_ets,
         #{artifact_effect_journal => #{table => forged}})).

with_context(Journal, Test) ->
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    Spec = #{identity => identity(),
             artifact_service => {adk_artifact_ets, ArtifactPid},
             artifact_scope => scope(),
             artifact_effect_journal => Journal,
             timeout => 1000},
    {ok, CapabilityPid} = adk_context_capability:start(self(), Spec),
    try
        {ok, Root} = adk_context_capability:root(CapabilityPid),
        {ok, Child} = adk_context_capability:delegate(
                        Root, [artifact_put, artifact_delete],
                        effect_call, 1000),
        Context = #{context_capability => Child},
        Test(Root, Context, ArtifactPid)
    after
        adk_context_capability:stop(CapabilityPid),
        adk_artifact_ets:stop(ArtifactPid)
    end.

identity() ->
    #{app_name => ?APP, user_id => ?USER, session_id => ?SESSION,
      invocation_id => <<"journal-context-invocation">>}.

scope() -> {session, ?APP, ?USER, ?SESSION}.
