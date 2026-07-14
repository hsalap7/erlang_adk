%% @doc Injectable transport boundary for the OTLP/HTTP JSON exporter.
%%
%% The production implementation is `adk_openapi_gun_transport', whose
%% request contract already enforces exact host/scheme allowlists, bounded
%% response streaming, verified HTTPS, deadlines, and no redirect following.
-module(adk_otlp_http_transport).

-type handle() :: term().
-type request() :: #{method := binary(),
                     url := binary(),
                     headers := [{binary(), binary()}],
                     body := binary(),
                     timeout_ms := pos_integer(),
                     max_response_bytes := pos_integer(),
                     follow_redirects := false,
                     allowed_schemes := [binary()],
                     allowed_hosts := [binary()],
                     allow_private_hosts := boolean()}.
-type response() :: #{status := pos_integer(),
                      headers := [{binary(), binary()}],
                      body := binary()}.

-export_type([handle/0, request/0, response/0]).

-callback request(Handle :: handle(), Request :: request()) ->
    {ok, response()} | {error, term()}.

