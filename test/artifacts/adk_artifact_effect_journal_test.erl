-module(adk_artifact_effect_journal_test).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, adk_artifact_effect_journal_test_table).

artifact_effect_journal_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun(Handle) -> ?_test(restart_isolation_and_reconciliation(Handle)) end,
      fun(Handle) -> ?_test(fault_redaction_and_terminal_prune(Handle)) end]}.

setup() ->
    {ok, Handle} = adk_artifact_effect_journal:init(config()),
    {atomic, ok} = mnesia:clear_table(?TABLE),
    Handle.

cleanup(_Handle) ->
    mnesia:clear_table(?TABLE),
    ok.

restart_isolation_and_reconciliation(Handle) ->
    Scope = {session, <<"artifact-app">>, <<"alice">>, <<"s1">>},
    Other = {session, <<"artifact-app">>, <<"bob">>, <<"s1">>},
    {ok, Intent} = adk_artifact_effect_journal:record_intent(
                     Handle, intent(Scope, <<"opaque/object/1">>, 5)),
    EffectId = maps:get(effect_id, Intent),
    {ok, Restarted} = adk_artifact_effect_journal:init(config()),
    {ok, #{phase := prepared}} = adk_artifact_effect_journal:status(
                                  Restarted, Scope, EffectId),
    {error, not_found} = adk_artifact_effect_journal:status(
                           Restarted, Other, EffectId),
    {ok, []} = adk_artifact_effect_journal:list_unresolved(
                 Restarted, Other, 10),
    {ok, [_]} = adk_artifact_effect_journal:list_unresolved(
                  Restarted, Scope, 10),
    {ok, #{phase := applied}} =
        adk_artifact_effect_journal:effect_applied(
          Restarted, Scope, EffectId,
          #{password => <<"receipt-secret">>, version => 1}),
    Now = erlang:system_time(millisecond) + 10,
    {ok, #{processed := 1, failed := 0}} =
        adk_artifact_orphan_reconciler:run(
          Restarted,
          {adk_artifact_reconcile_test_handler,
           #{mode => compensated, test_pid => self()}},
          #{max_items => 1, now_ms => Now,
            lease_ms => 500, call_timeout_ms => 50}),
    Work = receive
        {artifact_reconcile_seen, Seen} -> Seen
    after 1000 -> error(reconcile_not_called)
    end,
    ?assertEqual(Scope, maps:get(scope, Work)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Work), <<"receipt-secret">>)),
    {ok, #{phase := compensated}} =
        adk_artifact_effect_journal:status(Restarted, Scope, EffectId).

fault_redaction_and_terminal_prune(Handle) ->
    Scope = {user, <<"artifact-app">>, <<"fault-user">>},
    {ok, Intent} = adk_artifact_effect_journal:record_intent(
                     Handle, intent(Scope, <<"opaque/object/fault">>, 1)),
    EffectId = maps:get(effect_id, Intent),
    Now = erlang:system_time(millisecond) + 10,
    {ok, #{processed := 1, failed := 1}} =
        adk_artifact_orphan_reconciler:run(
          Handle,
          {adk_artifact_reconcile_test_handler, #{mode => error}},
          #{max_items => 1, now_ms => Now,
            lease_ms => 500, call_timeout_ms => 50}),
    {ok, Failed = #{phase := abandoned}} =
        adk_artifact_effect_journal:status(Handle, Scope, EffectId),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Failed),
                              <<"artifact-secret">>)),
    {ok, #{deleted := 1}} =
        adk_artifact_effect_journal:prune_terminal(
          Handle, Now + 100, 10),
    {error, not_found} = adk_artifact_effect_journal:status(
                           Handle, Scope, EffectId),

    {ok, Hanging} = adk_artifact_effect_journal:record_intent(
                      Handle,
                      intent(Scope, <<"opaque/object/hang">>, 1)),
    HangId = maps:get(effect_id, Hanging),
    {ok, #{processed := 1, failed := 1}} =
        adk_artifact_orphan_reconciler:run(
          Handle,
          {adk_artifact_reconcile_test_handler, #{mode => hang}},
          #{max_items => 1,
            now_ms => erlang:system_time(millisecond) + 10,
            lease_ms => 250, call_timeout_ms => 10}),
    {ok, #{phase := abandoned}} =
        adk_artifact_effect_journal:status(Handle, Scope, HangId).

intent(Scope, Resource, Attempts) ->
    #{scope => Scope, operation => put, resource_id => Resource,
      request_digest => <<"sha256:0123456789abcdef">>,
      idempotency_key => Resource,
      metadata => #{password => <<"metadata-secret">>, kind => <<"upload">>},
      max_attempts => Attempts}.

config() ->
    #{table => ?TABLE, orphan_grace_ms => 0,
      retry_base_ms => 1, max_retry_ms => 2,
      terminal_retention_ms => 0}.
