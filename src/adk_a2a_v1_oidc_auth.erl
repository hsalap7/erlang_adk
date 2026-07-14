%% @doc A2A 1.0 authorization hook backed by `adk_jwt_policy`.
%%
%% Configure the already validated policy as `a2a_v1_jwt_policy`. The bearer
%% token is read only from request headers by the policy and is never returned
%% in the principal or retained by the A2A task store.
-module(adk_a2a_v1_oidc_auth).
-behaviour(adk_a2a_v1_auth).

-export([authorize/3]).

authorize(_Operation, Headers, _Summary) ->
    case application:get_env(erlang_adk, a2a_v1_jwt_policy) of
        {ok, Policy} ->
            case adk_jwt_policy:authenticate(Policy, Headers) of
                {ok, Identity = #{principal := PrincipalId}} ->
                    {ok, Identity, PrincipalId};
                {error, insufficient_scope} -> {error, forbidden};
                {error, _} -> {error, unauthenticated}
            end;
        undefined -> {error, unauthenticated}
    end.
