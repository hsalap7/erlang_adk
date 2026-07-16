-module(adk_credential_request_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2, pause_capable/0]).

schema() ->
    #{<<"name">> => <<"request_user_credential">>,
      <<"description">> => <<"Requests a preconfigured OAuth/OIDC login.">>,
      <<"pause_capable">> => true,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"request">> => #{<<"type">> => <<"object">>}},
            <<"required">> => [<<"request">>]}}.

pause_capable() -> true.

execute(#{<<"request">> := Request}, Context) ->
    adk_suspension:request_credential(Request, Context).
