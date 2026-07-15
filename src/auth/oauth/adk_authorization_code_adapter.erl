%% @doc Internal adapter contract for an OAuth/OIDC authorization-code flow.
%%
%% Implementations receive only operator-owned context and manager-generated
%% flow bindings.  Browser callers can never select an adapter or inject
%% transport options.
-module(adk_authorization_code_adapter).

-type context() :: map().
-type authorization_opts() :: #{
    state := binary(),
    nonce := binary(),
    pkce_verifier := binary(),
    redirect_uri := binary(),
    scopes := [binary()],
    resource := undefined | binary()
}.
-type exchange_opts() :: #{
    state := binary(),
    nonce := binary(),
    pkce_verifier := binary(),
    redirect_uri := binary(),
    scopes := [binary()],
    resource := undefined | binary()
}.

-export_type([context/0, authorization_opts/0, exchange_opts/0]).

-callback validate_context(context()) -> ok | {error, term()}.
-callback authorization_uri(context(), authorization_opts()) ->
    {ok, iodata()} | {error, term()}.
-callback exchange_code(context(), binary(), exchange_opts()) ->
    {ok, adk_credential_store:credential()} | {error, term()}.
