%% @doc Adapter behaviour for outbound OAuth token endpoint operations.
-module(adk_oauth_adapter).

-type provider() :: gen_server:server_ref().
-type token() :: #{
    access_token := binary(),
    expires_in_ms := pos_integer(),
    token_type => binary(),
    refresh_token => binary()
}.
-type opts() :: #{scope := [binary()]}.

-export_type([provider/0, token/0, opts/0]).

-callback client_credentials(Provider :: provider(), ClientId :: binary(),
                             ClientSecret :: binary(), Opts :: opts()) ->
    {ok, token()} | {error, term()}.

-callback refresh_token(Provider :: provider(), ClientId :: binary(),
                        ClientSecret :: binary(), RefreshToken :: binary(),
                        ExpectedSubject :: binary(), Opts :: opts()) ->
    {ok, token()} | {error, term()}.
