%% @doc Injected bounded HTTP transport contract for model providers.
%%
%% Provider adapters pass credentials only in the private request value. A
%% transport must neither log nor retain them, must enforce the supplied
%% scheme/host policy after DNS resolution, must not follow redirects, and
%% must stop reading once `max_response_bytes' is reached.
-module(adk_model_http_transport).

-type handle() :: term().
-type request() :: #{
    method := binary(),
    url := binary(),
    headers := [{binary(), binary()}],
    body := binary(),
    timeout_ms := pos_integer(),
    max_response_bytes := pos_integer(),
    follow_redirects := false,
    allowed_schemes := [binary()],
    allowed_hosts := [binary()],
    allow_private_hosts := boolean()
}.
-type response() :: #{
    status := 100..599,
    headers => [{binary(), binary()}] | map(),
    body := binary()
}.
-type chunk_callback() :: fun((binary()) -> ok | {error, term()}).

-export_type([handle/0, request/0, response/0, chunk_callback/0]).

-callback request(Handle :: handle(), Request :: request()) ->
    {ok, response()} | {error, term()}.

%% Successful response bytes are delivered synchronously to Callback with
%% transport-level flow control. For non-success responses, Callback is not
%% invoked and a bounded body is returned for provider error classification.
-callback stream(Handle :: handle(), Request :: request(),
                 Callback :: chunk_callback()) ->
    {ok, response()} | {error, term()}.
