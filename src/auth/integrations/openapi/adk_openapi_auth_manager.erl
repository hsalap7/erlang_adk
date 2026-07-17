%% @doc Opaque credential resolver used by compiled OpenAPI tools.
%%
%% `Request' contains only scheme metadata, requested OAuth scopes, and the
%% operation id. It never contains tool arguments or agent context. Returned
%% credentials live only inside the bounded execution worker and are applied
%% immediately to the outgoing request.
-module(adk_openapi_auth_manager).

-type handle() :: pid() | atom() | reference().
-type request() :: #{
    operation_id := binary(),
    scheme_name := binary(),
    scheme_type := api_key | bearer | oauth2,
    location => header | query,
    parameter_name => binary(),
    scopes := [binary()]
}.
-type credential() :: {api_key, binary()} | {bearer, binary()}.

-export_type([handle/0, request/0, credential/0]).

-callback resolve(Handle :: handle(), Request :: request()) ->
    {ok, credential()} | {error, term()}.
