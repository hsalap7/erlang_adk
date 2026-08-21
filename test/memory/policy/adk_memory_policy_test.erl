-module(adk_memory_policy_test).
-include_lib("eunit/include/eunit.hrl").

governance_policy_test_() ->
    [?_test(consent_ttl_retention_and_hold()),
     ?_test(policy_failures_are_closed())].

consent_ttl_retention_and_hold() ->
    Scope = {user, <<"policy-app">>, <<"alice">>},
    Other = {user, <<"policy-app">>, <<"bob">>},
    {ok, Policy} = adk_memory_policy_static:compile(
                     #{consented_scopes => [Scope], ttl_ms => 100,
                       retention_ms => 1000,
                       legal_hold_scopes => [Scope]}),
    {ok, Obligations} = adk_memory_policy:check(
                          {adk_memory_policy_static, Policy}, ingest,
                          Scope, #{}, #{now_ms => 5000}, 100),
    ?assertEqual(5100, maps:get(expires_at, Obligations)),
    ?assertEqual(6000, maps:get(retain_until, Obligations)),
    ?assertEqual(true, maps:get(legal_hold, Obligations)),
    {error, {memory_policy_denied, legal_hold}} =
        adk_memory_policy:check(
          {adk_memory_policy_static, Policy}, erase,
          Scope, #{}, #{now_ms => 5000}, 100),
    {error, {memory_policy_denied, consent_required}} =
        adk_memory_policy:check(
          {adk_memory_policy_static, Policy}, search,
          Other, #{}, #{now_ms => 5000}, 100).

policy_failures_are_closed() ->
    Scope = {user, <<"policy-app">>, <<"failures">>},
    {error, memory_policy_timeout} = adk_memory_policy:check(
        {adk_memory_policy_test_hook, hang}, ingest,
        Scope, #{}, #{}, 10),
    {error, invalid_memory_policy_decision} = adk_memory_policy:check(
        {adk_memory_policy_test_hook, crash}, ingest,
        Scope, #{}, #{}, 100).
