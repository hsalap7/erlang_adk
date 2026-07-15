%% @doc Adapter behaviour for cryptographic JWT verification.
%%
%% Implementations must validate the signature before returning claims and
%% must never return a token or unredacted provider response in an error.
-module(adk_jwt_verifier).

-type config() :: #{
    provider := gen_server:server_ref(),
    client_id := binary(),
    signing_algs := [binary(), ...],
    trusted_audiences := [binary()],
    adapter_options => map()
}.
-type claims() :: #{binary() => term()}.
-type error_reason() :: provider_unavailable | invalid_token.

-export_type([config/0, claims/0, error_reason/0]).

-callback verify(Token :: binary(), Config :: config()) ->
    {ok, claims()} | {error, error_reason()}.
