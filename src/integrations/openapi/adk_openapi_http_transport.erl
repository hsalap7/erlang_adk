%% @doc Injected HTTP transport contract for OpenAPI tools.
%%
%% The request can contain authorization headers resolved inside the bounded
%% OpenAPI worker. Implementations must not log or retain it. A production
%% transport must stream-limit the response to `max_response_bytes', enforce
%% the supplied host/scheme policy after DNS resolution, and must not follow
%% redirects when `follow_redirects' is false.
-module(adk_openapi_http_transport).

-type handle() :: pid() | atom() | reference().
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

-export_type([handle/0, request/0, response/0]).

-callback request(Handle :: handle(), Request :: request()) ->
    {ok, response()} | {error, term()}.
