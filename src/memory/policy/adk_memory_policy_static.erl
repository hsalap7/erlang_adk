%% @doc Bounded static consent, TTL, retention and legal-hold policy.
-module(adk_memory_policy_static).
-behaviour(adk_memory_policy).

-export([compile/1, evaluate/5]).

-define(MAX_SCOPES, 10000).
-define(MAX_DURATION_MS, 315360000000).

compile(Config) when is_map(Config) ->
    Allowed = [default_consent, consented_scopes, ttl_ms,
               retention_ms, legal_hold_scopes],
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Config))),
    Consent = maps:get(default_consent, Config, deny),
    Consented = maps:get(consented_scopes, Config, []),
    Holds = maps:get(legal_hold_scopes, Config, []),
    Ttl = maps:get(ttl_ms, Config, undefined),
    Retention = maps:get(retention_ms, Config, undefined),
    case {Unknown, lists:member(Consent, [allow, deny]),
          scopes(Consented), scopes(Holds), duration(Ttl),
          duration(Retention)} of
        {[], true, {ok, ConsentScopes}, {ok, HoldScopes}, true, true} ->
            {ok, #{default_consent => Consent,
                   consented_scopes => maps:from_keys(ConsentScopes, true),
                   legal_hold_scopes => maps:from_keys(HoldScopes, true),
                   ttl_ms => Ttl, retention_ms => Retention}};
        {[_ | _], _, _, _, _, _} ->
            {error, {invalid_memory_policy_config,
                     {unknown_keys, Unknown}}};
        _ -> {error, invalid_memory_policy_config}
    end;
compile(_) -> {error, invalid_memory_policy_config}.

evaluate(Policy, Action, Scope, _Resource, Context) when is_map(Policy) ->
    Consent = maps:is_key(Scope, maps:get(consented_scopes, Policy)) orelse
              maps:get(default_consent, Policy) =:= allow,
    Hold = maps:is_key(Scope, maps:get(legal_hold_scopes, Policy)),
    case decision(Action, Consent, Hold) of
        allow ->
            Now = maps:get(<<"now_ms">>, Context,
                           erlang:system_time(millisecond)),
            {allow, obligations(Policy, Now, Hold)};
        {deny, _} = Denied -> Denied
    end.

decision(Action, false, _Hold) when Action =:= ingest; Action =:= search ->
    {deny, consent_required};
decision(Action, _Consent, true)
  when Action =:= delete; Action =:= erase; Action =:= prune ->
    {deny, legal_hold};
decision(_, _, _) -> allow.

obligations(Policy, Now, Hold) ->
    Base = #{legal_hold => Hold},
    WithTtl = maybe_time(expires_at, maps:get(ttl_ms, Policy), Now, Base),
    maybe_time(retain_until, maps:get(retention_ms, Policy), Now, WithTtl).

maybe_time(_Key, undefined, _Now, Map) -> Map;
maybe_time(Key, Duration, Now, Map) -> Map#{Key => Now + Duration}.

scopes(List) when is_list(List) -> scopes(List, 0, []);
scopes(_) -> error.
scopes([], _Count, Acc) -> {ok, lists:usort(Acc)};
scopes([Scope | Rest], Count, Acc) when Count < ?MAX_SCOPES ->
    case adk_memory_contract:validate_scope(Scope) of
        {ok, Canonical} -> scopes(Rest, Count + 1, [Canonical | Acc]);
        {error, _} -> error
    end;
scopes(_, _, _) -> error.

duration(undefined) -> true;
duration(Value) -> is_integer(Value) andalso Value >= 0 andalso
                   Value =< ?MAX_DURATION_MS.
