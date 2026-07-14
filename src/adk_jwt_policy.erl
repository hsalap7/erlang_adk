%% @doc Explicit incoming JWT authentication policy.
%%
%% Oidcc performs signature and standard claim validation. This module then
%% independently enforces the configured issuer, audience allow-list, clock,
%% subject and scopes, and returns an issuer-bound opaque principal id.
-module(adk_jwt_policy).

-export([new/1, authenticate/2]).

-opaque policy() :: map().
-type identity() :: #{
    principal := binary(),
    subject := binary(),
    issuer := binary(),
    audiences := [binary(), ...],
    scopes := [binary()],
    claims := map()
}.
-type error_reason() :: invalid_policy |
                        adk_bearer_auth:error_reason() |
                        disallowed_signing_algorithm |
                        provider_unavailable |
                        invalid_token |
                        invalid_issuer |
                        invalid_audience |
                        token_expired |
                        token_not_yet_valid |
                        missing_subject |
                        insufficient_scope.

-export_type([policy/0, identity/0, error_reason/0]).

-define(MAX_CLOCK_SKEW_SECONDS, 300).
-define(MAX_JWT_BYTES, 16384).
-define(MAX_HEADER_BYTES, 4096).

-spec new(map()) -> {ok, policy()} | {error, invalid_policy}.
new(Config) when is_map(Config) ->
    case normalize_policy(Config) of
        {ok, Policy} -> {ok, Policy};
        error -> {error, invalid_policy}
    end;
new(_Config) ->
    {error, invalid_policy}.

-spec authenticate(policy(), map() | [{term(), term()}]) ->
    {ok, identity()} | {error, error_reason()}.
authenticate(Policy, Headers) when is_map(Policy) ->
    case adk_bearer_auth:extract(Headers) of
        {ok, Token} -> authenticate_token(Policy, Token);
        {error, _Reason} = Error -> Error
    end;
authenticate(_Policy, _Headers) ->
    {error, invalid_policy}.

normalize_policy(Config) ->
    AllowedKeys = [issuer, audience, trusted_audiences, signing_algs,
                   clock_skew_seconds, required_scopes, provider, verifier,
                   adapter_options, now_fun, claim_allowlist],
    case unknown_keys(Config, AllowedKeys) of
        [] -> normalize_known_policy(Config);
        _ -> error
    end.

normalize_known_policy(Config) ->
    Issuer = maps:get(issuer, Config, undefined),
    Audience = maps:get(audience, Config, undefined),
    Trusted0 = maps:get(trusted_audiences, Config, []),
    Algorithms0 = maps:get(signing_algs, Config, undefined),
    Skew = maps:get(clock_skew_seconds, Config, 0),
    RequiredScopes0 = maps:get(required_scopes, Config, []),
    Provider = maps:get(provider, Config, undefined),
    Verifier = maps:get(verifier, Config, adk_oidcc_jwt_verifier),
    AdapterOptions = maps:get(adapter_options, Config, #{}),
    NowFun = maps:get(now_fun, Config,
                      fun() -> erlang:system_time(second) end),
    ClaimAllowlist0 = maps:get(
                        claim_allowlist, Config,
                        [<<"sub">>, <<"iss">>, <<"aud">>, <<"scope">>,
                         <<"scp">>, <<"azp">>]),
    case valid_issuer(Issuer) andalso valid_binary(Audience) andalso
         valid_binary_list(Trusted0) andalso
         valid_algorithms(Algorithms0) andalso
         is_integer(Skew) andalso Skew >= 0 andalso
         Skew =< ?MAX_CLOCK_SKEW_SECONDS andalso
         valid_binary_list(RequiredScopes0) andalso
         valid_server_ref(Provider) andalso is_atom(Verifier) andalso
         Verifier =/= undefined andalso is_map(AdapterOptions) andalso
         is_function(NowFun, 0) andalso
         valid_claim_allowlist(ClaimAllowlist0) of
        true ->
            Trusted = lists:usort(Trusted0 -- [Audience]),
            Algorithms = lists:usort(Algorithms0),
            RequiredScopes = lists:usort(RequiredScopes0),
            ClaimAllowlist = lists:usort(ClaimAllowlist0),
            {ok, #{issuer => Issuer,
                   audience => Audience,
                   trusted_audiences => Trusted,
                   signing_algs => Algorithms,
                   clock_skew_seconds => Skew,
                   required_scopes => RequiredScopes,
                   provider => Provider,
                   verifier => Verifier,
                   adapter_options => AdapterOptions,
                   now_fun => NowFun,
                   claim_allowlist => ClaimAllowlist}};
        false ->
            error
    end.

authenticate_token(_Policy, Token) when byte_size(Token) > ?MAX_JWT_BYTES ->
    {error, invalid_token};
authenticate_token(Policy, Token) ->
    case signing_algorithm(Token) of
        {ok, Algorithm} ->
            case lists:member(Algorithm, maps:get(signing_algs, Policy)) of
                true -> verify_and_apply_policy(Policy, Token);
                false -> {error, disallowed_signing_algorithm}
            end;
        error ->
            {error, invalid_token}
    end.

verify_and_apply_policy(Policy, Token) ->
    Verifier = maps:get(verifier, Policy),
    VerifyConfig = #{provider => maps:get(provider, Policy),
                     client_id => maps:get(audience, Policy),
                     signing_algs => maps:get(signing_algs, Policy),
                     trusted_audiences =>
                         maps:get(trusted_audiences, Policy),
                     adapter_options => maps:get(adapter_options, Policy)},
    case safe_verify(Verifier, Token, VerifyConfig) of
        {ok, Claims} when is_map(Claims) ->
            apply_claim_policy(Policy, Claims);
        {error, provider_unavailable} ->
            {error, provider_unavailable};
        _ ->
            {error, invalid_token}
    end.

safe_verify(Verifier, Token, Config) ->
    try Verifier:verify(Token, Config) of
        Result -> Result
    catch
        _:_ -> {error, invalid_token}
    end.

apply_claim_policy(Policy, Claims) ->
    case validate_issuer(Policy, Claims) of
        ok ->
            case validate_audience(Policy, Claims) of
                {ok, Audiences} ->
                    case validate_time(Policy, Claims) of
                        ok -> validate_subject_and_scopes(
                                Policy, Claims, Audiences);
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

validate_issuer(#{issuer := Issuer}, #{<<"iss">> := Issuer}) -> ok;
validate_issuer(_Policy, _Claims) -> {error, invalid_issuer}.

validate_audience(Policy, Claims) ->
    case normalize_audiences(maps:get(<<"aud">>, Claims, undefined)) of
        {ok, Audiences} ->
            Primary = maps:get(audience, Policy),
            Allowed = [Primary | maps:get(trusted_audiences, Policy)],
            case lists:member(Primary, Audiences) andalso
                 lists:all(fun(Audience) ->
                     lists:member(Audience, Allowed)
                 end, Audiences) of
                true -> {ok, Audiences};
                false -> {error, invalid_audience}
            end;
        error ->
            {error, invalid_audience}
    end.

validate_time(#{clock_skew_seconds := Skew} = Policy, Claims) ->
    Now = policy_now(Policy),
    case maps:get(<<"exp">>, Claims, undefined) of
        Exp when is_integer(Exp) ->
            case Now > Exp + Skew of
                true -> {error, token_expired};
                false -> validate_not_before(Now, Skew, Claims)
            end;
        _ ->
            {error, invalid_token}
    end.

validate_not_before(Now, Skew, Claims) ->
    case maps:get(<<"nbf">>, Claims, undefined) of
        undefined -> validate_issued_at(Now, Skew, Claims);
        NotBefore when is_integer(NotBefore), Now >= NotBefore - Skew ->
            validate_issued_at(Now, Skew, Claims);
        NotBefore when is_integer(NotBefore) ->
            {error, token_not_yet_valid};
        _ ->
            {error, invalid_token}
    end.

validate_issued_at(Now, Skew, #{<<"iat">> := IssuedAt})
  when is_integer(IssuedAt), IssuedAt =< Now + Skew -> ok;
validate_issued_at(_Now, _Skew, #{<<"iat">> := IssuedAt})
  when is_integer(IssuedAt) -> {error, token_not_yet_valid};
validate_issued_at(_Now, _Skew, _Claims) -> {error, invalid_token}.

validate_subject_and_scopes(Policy, Claims, Audiences) ->
    case maps:get(<<"sub">>, Claims, undefined) of
        Subject when is_binary(Subject), byte_size(Subject) > 0 ->
            case normalize_scopes(Claims) of
                {ok, Scopes} ->
                    Required = maps:get(required_scopes, Policy),
                    case lists:all(fun(Scope) ->
                        lists:member(Scope, Scopes)
                    end, Required) of
                        true ->
                            {ok, identity(Policy, Claims, Subject,
                                          Audiences, Scopes)};
                        false ->
                            {error, insufficient_scope}
                    end;
                error ->
                    {error, invalid_token}
            end;
        _ ->
            {error, missing_subject}
    end.

identity(Policy, Claims, Subject, Audiences, Scopes) ->
    Issuer = maps:get(issuer, Policy),
    Allowlist = maps:get(claim_allowlist, Policy),
    SafeClaims = maps:with(Allowlist, Claims),
    #{principal => principal_id(Issuer, Subject),
      subject => Subject,
      issuer => Issuer,
      audiences => Audiences,
      scopes => Scopes,
      claims => SafeClaims}.

principal_id(Issuer, Subject) ->
    Material = <<(byte_size(Issuer)):32/unsigned-big, Issuer/binary,
                 Subject/binary>>,
    Digest = crypto:hash(sha256, Material),
    Encoded0 = base64:encode(Digest),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    Encoded = binary:replace(Encoded2, <<"=">>, <<>>, [global]),
    <<"oidc_", Encoded/binary>>.

signing_algorithm(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [HeaderSegment, PayloadSegment, Signature]
          when byte_size(HeaderSegment) > 0,
               byte_size(HeaderSegment) =< ?MAX_HEADER_BYTES,
               byte_size(PayloadSegment) > 0,
               byte_size(Signature) > 0 ->
            case decode_base64url(HeaderSegment) of
                {ok, HeaderJson} when byte_size(HeaderJson) =< ?MAX_HEADER_BYTES ->
                    decode_algorithm(HeaderJson);
                _ -> error
            end;
        _ -> error
    end.

decode_algorithm(HeaderJson) ->
    try jsx:decode(HeaderJson, [return_maps]) of
        #{<<"alg">> := Algorithm} when is_binary(Algorithm),
                                      byte_size(Algorithm) > 0 ->
            {ok, Algorithm};
        _ -> error
    catch
        _:_ -> error
    end.

decode_base64url(Segment) ->
    Standard0 = binary:replace(Segment, <<"-">>, <<"+">>, [global]),
    Standard = binary:replace(Standard0, <<"_">>, <<"/">>, [global]),
    PaddingLength = (4 - (byte_size(Standard) rem 4)) rem 4,
    Padding = case PaddingLength of
        0 -> <<>>;
        1 -> <<"=">>;
        2 -> <<"==">>;
        3 -> <<"===">>
    end,
    try base64:decode(<<Standard/binary, Padding/binary>>) of
        Decoded when is_binary(Decoded) -> {ok, Decoded}
    catch
        _:_ -> error
    end.

normalize_audiences(Audience) when is_binary(Audience),
                                   byte_size(Audience) > 0 ->
    {ok, [Audience]};
normalize_audiences(Audiences) when is_list(Audiences), Audiences =/= [] ->
    case valid_binary_list(Audiences) of
        true -> {ok, lists:usort(Audiences)};
        false -> error
    end;
normalize_audiences(_Audience) -> error.

normalize_scopes(Claims) ->
    case {scope_value(maps:get(<<"scope">>, Claims, undefined)),
          scope_value(maps:get(<<"scp">>, Claims, undefined))} of
        {{ok, Scope}, {ok, Scp}} -> {ok, lists:usort(Scope ++ Scp)};
        _ -> error
    end.

scope_value(undefined) -> {ok, []};
scope_value(Binary) when is_binary(Binary) ->
    Scopes = binary:split(Binary, <<" ">>, [global, trim_all]),
    case valid_binary_list(Scopes) of
        true -> {ok, Scopes};
        false -> error
    end;
scope_value(List) when is_list(List) ->
    case valid_binary_list(List) of
        true -> {ok, List};
        false -> error
    end;
scope_value(_) -> error.

policy_now(#{now_fun := NowFun}) ->
    try NowFun() of
        Now when is_integer(Now) -> Now;
        _ -> erlang:system_time(second)
    catch
        _:_ -> erlang:system_time(second)
    end.

valid_issuer(Issuer) when is_binary(Issuer), byte_size(Issuer) > 0 ->
    try uri_string:parse(Issuer) of
        #{scheme := <<"https">>, host := Host} = Uri
          when is_binary(Host), byte_size(Host) > 0 ->
            not maps:is_key(userinfo, Uri) andalso
            not maps:is_key(query, Uri) andalso
            not maps:is_key(fragment, Uri);
        _ -> false
    catch
        _:_ -> false
    end;
valid_issuer(_Issuer) -> false.

valid_algorithms(Algorithms) when is_list(Algorithms), Algorithms =/= [] ->
    Allowed = [<<"RS256">>, <<"RS384">>, <<"RS512">>,
               <<"PS256">>, <<"PS384">>, <<"PS512">>,
               <<"ES256">>, <<"ES384">>, <<"ES512">>, <<"EdDSA">>],
    valid_binary_list(Algorithms) andalso
    lists:all(fun(Algorithm) -> lists:member(Algorithm, Allowed) end,
              Algorithms);
valid_algorithms(_Algorithms) -> false.

valid_claim_allowlist(Claims) ->
    Denied = [<<"access_token">>, <<"refresh_token">>, <<"id_token">>,
              <<"token">>, <<"client_secret">>, <<"password">>],
    valid_binary_list(Claims) andalso
    lists:all(fun(Claim) -> not lists:member(Claim, Denied) end, Claims).

valid_binary(Binary) when is_binary(Binary) -> byte_size(Binary) > 0;
valid_binary(_Value) -> false.

valid_binary_list([]) -> true;
valid_binary_list([Value | Rest]) ->
    valid_binary(Value) andalso valid_binary_list(Rest);
valid_binary_list(_Values) -> false.

valid_server_ref(Ref) when is_pid(Ref) -> true;
valid_server_ref(Ref) when is_atom(Ref) -> Ref =/= undefined;
valid_server_ref(_Ref) -> false.

unknown_keys(Map, Allowed) ->
    [Key || Key <- maps:keys(Map), not lists:member(Key, Allowed)].
