%% @doc Behaviour implemented by authentication token providers.
%%
%% Provider implementations receive credentials only inside a short-lived,
%% supervised refresh worker. Implementations must not log credentials, token
%% responses, or provider errors before redaction.
-module(adk_auth_provider).

-type credential() :: map().
-type context() :: map().
-type token() :: #{
    access_token := binary(),
    expires_in_ms := pos_integer(),
    token_type => binary()
}.
-type error_reason() :: term().

-export_type([credential/0, context/0, token/0, error_reason/0]).

-callback refresh(Credential :: credential(), Context :: context()) ->
    {ok, token()} | {error, error_reason()}.
