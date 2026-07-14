%% @doc Default-deny OIDC scope authorizer for production ADK gateways.
%%
%% The principal is re-derived from issuer and subject using the same binding
%% as `adk_jwt_policy'. This makes a malformed or accidentally hand-built
%% identity fail closed before it can select a user/session scope.
-module(adk_scope_authorizer).

-behaviour(adk_authorizer).

-export([new/1, authorize/4, owner_scope/2]).

-define(ACTIONS, [list_agents, start_run, observe_run,
                  control_run, resume_run]).

-spec new(map()) -> {ok, map()} | {error, invalid_policy}.
new(Config) when is_map(Config) ->
    case maps:keys(Config) -- [trusted_issuers, required_scopes] of
        [] -> normalize_policy(Config);
        _ -> {error, invalid_policy}
    end;
new(_Config) ->
    {error, invalid_policy}.

-spec authorize(map(), adk_authorizer:identity(),
                adk_authorizer:action(), adk_authorizer:resource()) ->
    {ok, adk_authorizer:decision()} |
    {error, unauthenticated | forbidden}.
authorize(Policy, Identity, Action, Resource)
  when is_map(Policy), is_map(Identity), is_atom(Action), is_map(Resource) ->
    Result = authorize_identity(Policy, Identity, Action),
    emit_decision(Action, Resource, Result),
    Result;
authorize(_Policy, _Identity, Action, Resource) ->
    Result = {error, unauthenticated},
    emit_decision(Action, Resource, Result),
    Result.

-spec owner_scope(binary(), binary()) -> binary().
owner_scope(Issuer, Subject) when is_binary(Issuer), is_binary(Subject) ->
    crypto:hash(sha256,
                <<(byte_size(Issuer)):32/unsigned-big, Issuer/binary,
                  Subject/binary>>).

normalize_policy(Config) ->
    Issuers = maps:get(trusted_issuers, Config, undefined),
    Required = maps:get(required_scopes, Config, undefined),
    case valid_issuers(Issuers) andalso valid_required_scopes(Required) of
        true ->
            {ok, #{trusted_issuers => lists:usort(Issuers),
                   required_scopes => Required}};
        false ->
            {error, invalid_policy}
    end.

authorize_identity(#{trusted_issuers := Issuers,
                     required_scopes := Required},
                   #{principal := Principal,
                     subject := Subject,
                     issuer := Issuer,
                     scopes := Scopes}, Action)
  when is_binary(Principal), is_binary(Subject), is_binary(Issuer),
       is_list(Scopes) ->
    case lists:member(Issuer, Issuers) andalso
         valid_identity_values(Principal, Subject, Scopes) andalso
         principal_matches(Principal, Issuer, Subject) of
        false ->
            {error, unauthenticated};
        true ->
            case maps:find(Action, Required) of
                {ok, Needed} ->
                    case contains_all_scopes(Scopes, Needed) of
                        true ->
                            {ok, #{principal => Principal,
                                   user_id => Principal,
                                   owner_scope => owner_scope(Issuer, Subject),
                                   action => Action}};
                        false ->
                            {error, forbidden}
                    end;
                error ->
                    {error, forbidden}
            end
    end;
authorize_identity(_Policy, _Identity, _Action) ->
    {error, unauthenticated}.

principal_matches(Principal, Issuer, Subject) ->
    Expected = principal_id(Issuer, Subject),
    adk_dev_auth:constant_time_equal(Principal, Expected).

principal_id(Issuer, Subject) ->
    Digest = owner_scope(Issuer, Subject),
    Encoded0 = base64:encode(Digest),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    Encoded = binary:replace(Encoded2, <<"=">>, <<>>, [global]),
    <<"oidc_", Encoded/binary>>.

valid_identity_values(Principal, Subject, Scopes) ->
    byte_size(Principal) > 0 andalso byte_size(Principal) =< 128 andalso
    byte_size(Subject) > 0 andalso byte_size(Subject) =< 1024 andalso
    valid_scopes(Scopes).

contains_all_scopes(Scopes, Needed) ->
    valid_scopes(Scopes) andalso
    lists:all(fun(Scope) -> lists:member(Scope, Scopes) end, Needed).

valid_required_scopes(Required) when is_map(Required) ->
    maps:keys(Required) -- ?ACTIONS =:= [] andalso
    lists:all(fun(Action) -> maps:is_key(Action, Required) end, ?ACTIONS)
    andalso
    lists:all(fun({_Action, Scopes}) -> valid_scopes(Scopes) end,
              maps:to_list(Required));
valid_required_scopes(_) -> false.

valid_scopes(Scopes) when is_list(Scopes), length(Scopes) =< 128 ->
    lists:all(fun(Scope) ->
                      is_binary(Scope) andalso byte_size(Scope) > 0 andalso
                      byte_size(Scope) =< 256
              end, Scopes) andalso
    length(Scopes) =:= length(lists:usort(Scopes));
valid_scopes(_) -> false.

valid_issuers(Issuers) when is_list(Issuers), Issuers =/= [],
                            length(Issuers) =< 32 ->
    lists:all(fun valid_issuer/1, Issuers) andalso
    length(Issuers) =:= length(lists:usort(Issuers));
valid_issuers(_) -> false.

valid_issuer(Issuer) when is_binary(Issuer), byte_size(Issuer) =< 2048 ->
    try uri_string:parse(Issuer) of
        #{scheme := <<"https">>, host := Host} = Uri
          when is_binary(Host), byte_size(Host) > 0 ->
            not maps:is_key(userinfo, Uri) andalso
            not maps:is_key(query, Uri) andalso
            not maps:is_key(fragment, Uri);
        _ -> false
    catch _:_ -> false
    end;
valid_issuer(_) -> false.

emit_decision(Action, Resource, Result) ->
    Outcome = case Result of
        {ok, _} -> allow;
        {error, Reason} -> Reason
    end,
    ResourceKind = case maps:keys(Resource) of
        [Key] when is_atom(Key) -> Key;
        _ -> resource
    end,
    _ = catch telemetry:execute(
                [erlang_adk, authorization, decision],
                #{count => 1},
                #{action => safe_action(Action), outcome => Outcome,
                  resource_kind => ResourceKind}),
    ok.

safe_action(Action) when is_atom(Action) -> Action;
safe_action(_) -> invalid.

