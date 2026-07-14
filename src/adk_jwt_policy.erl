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
                        invalid_authorized_party |
                        invalid_token_type |
                        token_expired |
                        token_lifetime_exceeded |
                        token_not_yet_valid |
                        missing_subject |
                        insufficient_scope.

-export_type([policy/0, identity/0, error_reason/0]).

-define(MAX_CLOCK_SKEW_SECONDS, 300).
-define(MAX_JWT_BYTES, 16384).
-define(MAX_HEADER_BYTES, 4096).
-define(DEFAULT_VERIFIER_TIMEOUT_MS, 5000).
-define(MAX_VERIFIER_TIMEOUT_MS, 30000).
-define(DEFAULT_VERIFIER_MAX_HEAP_WORDS, 262144).
-define(MAX_VERIFIER_MAX_HEAP_WORDS, 4000000).
-define(MAX_ADAPTER_OPTIONS_BYTES, 65536).
-define(MAX_VERIFIER_RESULT_BYTES, 131072).

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
                   allowed_token_types, max_token_lifetime_seconds,
                   clock_skew_seconds, required_scopes, provider, verifier,
                   adapter_options, now_fun, claim_allowlist, token_use,
                   verifier_timeout_ms, verifier_max_heap_words],
    case unknown_keys(Config, AllowedKeys) of
        [] -> normalize_known_policy(Config);
        _ -> error
    end.

normalize_known_policy(Config) ->
    Issuer = maps:get(issuer, Config, undefined),
    Audience = maps:get(audience, Config, undefined),
    Trusted0 = maps:get(trusted_audiences, Config, []),
    Algorithms0 = maps:get(signing_algs, Config, undefined),
    TokenTypes0 = maps:get(allowed_token_types, Config,
                           [undefined, <<"JWT">>, <<"at+jwt">>]),
    TokenUse = maps:get(token_use, Config, access_token),
    MaxLifetime = maps:get(max_token_lifetime_seconds, Config, 3600),
    Skew = maps:get(clock_skew_seconds, Config, 0),
    RequiredScopes0 = maps:get(required_scopes, Config, []),
    Provider = maps:get(provider, Config, undefined),
    Verifier = maps:get(verifier, Config, adk_oidcc_jwt_verifier),
    AdapterOptions = maps:get(adapter_options, Config, #{}),
    VerifierTimeout = maps:get(verifier_timeout_ms, Config,
                               ?DEFAULT_VERIFIER_TIMEOUT_MS),
    VerifierMaxHeap = maps:get(verifier_max_heap_words, Config,
                               ?DEFAULT_VERIFIER_MAX_HEAP_WORDS),
    NowFun = maps:get(now_fun, Config,
                      fun() -> erlang:system_time(second) end),
    ClaimAllowlist0 = maps:get(
                        claim_allowlist, Config,
                        [<<"sub">>, <<"iss">>, <<"aud">>, <<"scope">>,
                         <<"scp">>, <<"azp">>]),
    case valid_issuer(Issuer) andalso valid_binary(Audience) andalso
         valid_binary_list(Trusted0) andalso
         valid_algorithms(Algorithms0) andalso
         valid_token_types(TokenTypes0) andalso
         valid_token_use(TokenUse) andalso
         is_integer(MaxLifetime) andalso MaxLifetime > 0 andalso
         MaxLifetime =< 86400 andalso
         is_integer(Skew) andalso Skew >= 0 andalso
         Skew =< ?MAX_CLOCK_SKEW_SECONDS andalso
         valid_binary_list(RequiredScopes0) andalso
         valid_server_ref(Provider) andalso is_atom(Verifier) andalso
         Verifier =/= undefined andalso is_map(AdapterOptions) andalso
         bounded_term(AdapterOptions, ?MAX_ADAPTER_OPTIONS_BYTES) andalso
         is_integer(VerifierTimeout) andalso VerifierTimeout > 0 andalso
         VerifierTimeout =< ?MAX_VERIFIER_TIMEOUT_MS andalso
         is_integer(VerifierMaxHeap) andalso VerifierMaxHeap >= 16384 andalso
         VerifierMaxHeap =< ?MAX_VERIFIER_MAX_HEAP_WORDS andalso
         is_function(NowFun, 0) andalso
         valid_claim_allowlist(ClaimAllowlist0) of
        true ->
            Trusted = lists:usort(Trusted0 -- [Audience]),
            Algorithms = lists:usort(Algorithms0),
            TokenTypes = lists:usort(TokenTypes0),
            RequiredScopes = lists:usort(RequiredScopes0),
            ClaimAllowlist = lists:usort(ClaimAllowlist0),
            {ok, #{issuer => Issuer,
                   audience => Audience,
                   trusted_audiences => Trusted,
                   signing_algs => Algorithms,
                   allowed_token_types => TokenTypes,
                   token_use => TokenUse,
                   max_token_lifetime_seconds => MaxLifetime,
                   clock_skew_seconds => Skew,
                   required_scopes => RequiredScopes,
                   provider => Provider,
                   verifier => Verifier,
                   adapter_options => AdapterOptions,
                   verifier_timeout_ms => VerifierTimeout,
                   verifier_max_heap_words => VerifierMaxHeap,
                   now_fun => NowFun,
                   claim_allowlist => ClaimAllowlist}};
        false ->
            error
    end.

authenticate_token(_Policy, Token) when byte_size(Token) > ?MAX_JWT_BYTES ->
    {error, invalid_token};
authenticate_token(Policy, Token) ->
    case signing_header(Token) of
        {ok, Algorithm, TokenType} ->
            case lists:member(Algorithm, maps:get(signing_algs, Policy)) of
                true ->
                    case lists:member(
                           TokenType,
                           maps:get(allowed_token_types, Policy)) of
                        true -> verify_and_apply_policy(Policy, Token);
                        false -> {error, invalid_token_type}
                    end;
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
    case safe_verify(Verifier, Token, VerifyConfig,
                     maps:get(verifier_timeout_ms, Policy),
                     maps:get(verifier_max_heap_words, Policy)) of
        {ok, Claims} when is_map(Claims) ->
            apply_claim_policy(Policy, Claims);
        {error, provider_unavailable} ->
            {error, provider_unavailable};
        _ ->
            {error, invalid_token}
    end.

safe_verify(Verifier, Token, Config, Timeout, MaxHeapWords) ->
    Callback = fun() -> Verifier:verify(Token, Config) end,
    case adk_auth_callback_guard:run(
           Callback, fun normalize_verifier_result/1,
           Timeout, MaxHeapWords, ?MAX_VERIFIER_RESULT_BYTES) of
        {ok, Result} -> Result;
        timeout -> {error, provider_unavailable};
        failed -> {error, invalid_token}
    end.

normalize_verifier_result({ok, Claims}) when is_map(Claims) ->
    case bounded_term(Claims, ?MAX_VERIFIER_RESULT_BYTES - 64) of
        true -> {ok, Claims};
        false -> {error, invalid_token}
    end;
normalize_verifier_result({error, provider_unavailable}) ->
    {error, provider_unavailable};
normalize_verifier_result(_Invalid) ->
    {error, invalid_token}.

apply_claim_policy(Policy, Claims) ->
    case validate_issuer(Policy, Claims) of
        ok ->
            case validate_audience(Policy, Claims) of
                {ok, Audiences} ->
                    case validate_token_use_claims(
                           Policy, Claims, Audiences) of
                        ok ->
                            case validate_time(Policy, Claims) of
                                ok -> validate_subject_and_scopes(
                                        Policy, Claims, Audiences);
                                {error, _Reason} = Error -> Error
                            end;
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

%% `azp` identifies an OpenID Connect client, not an OAuth resource server.
%% Applying the ID-token rule to an API access token incorrectly compares a
%% client identifier with the resource audience. Access-token authorization is
%% therefore based on `aud` and scopes; a present `azp` is only shape-checked.
%% ID-token consumers opt in explicitly and retain the OIDC multi-audience
%% authorized-party rule.
validate_token_use_claims(#{token_use := access_token}, Claims, _Audiences) ->
    case maps:get(<<"azp">>, Claims, undefined) of
        undefined -> ok;
        Azp when is_binary(Azp), byte_size(Azp) > 0,
                                byte_size(Azp) =< 1024 -> ok;
        _ -> {error, invalid_authorized_party}
    end;
validate_token_use_claims(#{token_use := id_token, audience := Audience},
                          Claims, Audiences) ->
    case {maps:get(<<"azp">>, Claims, undefined), length(Audiences)} of
        {undefined, 1} -> ok;
        {Audience, _} -> ok;
        _ -> {error, invalid_authorized_party}
    end.

validate_time(#{clock_skew_seconds := Skew} = Policy, Claims) ->
    Now = policy_now(Policy),
    case maps:get(<<"exp">>, Claims, undefined) of
        Exp when is_integer(Exp) ->
            case Now > Exp + Skew of
                true -> {error, token_expired};
                false -> validate_lifetime(Policy, Exp, Claims, Now, Skew)
            end;
        _ ->
            {error, invalid_token}
    end.

validate_lifetime(#{max_token_lifetime_seconds := Maximum}, Exp,
                  #{<<"iat">> := IssuedAt} = Claims, Now, Skew)
  when is_integer(IssuedAt), Exp >= IssuedAt,
       Exp - IssuedAt =< Maximum ->
    validate_not_before(Now, Skew, Claims);
validate_lifetime(_Policy, _Exp, #{<<"iat">> := IssuedAt}, _Now, _Skew)
  when is_integer(IssuedAt) ->
    {error, token_lifetime_exceeded};
validate_lifetime(_Policy, _Exp, _Claims, _Now, _Skew) ->
    {error, invalid_token}.

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
        Subject when is_binary(Subject), byte_size(Subject) > 0,
                     byte_size(Subject) =< 1024 ->
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

signing_header(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [HeaderSegment, PayloadSegment, Signature]
          when byte_size(HeaderSegment) > 0,
               byte_size(HeaderSegment) =< ?MAX_HEADER_BYTES,
               byte_size(PayloadSegment) > 0,
               byte_size(Signature) > 0 ->
            case decode_base64url(HeaderSegment) of
                {ok, HeaderJson} when byte_size(HeaderJson) =< ?MAX_HEADER_BYTES ->
                    decode_header(HeaderJson);
                _ -> error
            end;
        _ -> error
    end.

decode_header(HeaderJson) ->
    try jsx:decode(HeaderJson, [return_maps]) of
        #{<<"alg">> := Algorithm} = Header
          when is_binary(Algorithm), byte_size(Algorithm) > 0 ->
            case maps:get(<<"typ">>, Header, undefined) of
                undefined -> {ok, Algorithm, undefined};
                Type when is_binary(Type), byte_size(Type) > 0,
                                              byte_size(Type) =< 64 ->
                    {ok, Algorithm, Type};
                _ -> error
            end;
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

valid_token_types(Types) when is_list(Types), Types =/= [],
                              length(Types) =< 8 ->
    length(Types) =:= length(lists:usort(Types)) andalso
    lists:all(
      fun(undefined) -> true;
         (Type) when is_binary(Type), byte_size(Type) > 0,
                                      byte_size(Type) =< 64 -> true;
         (_) -> false
      end, Types);
valid_token_types(_Types) -> false.

valid_token_use(access_token) -> true;
valid_token_use(id_token) -> true;
valid_token_use(_TokenUse) -> false.

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

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch
        _:_ -> false
    end.
