-module(erlang_adk_slack_extra_toolset).

-export([schemas/1, resolved_call/4]).

schemas(Target) ->
    erlang_adk_slack_test_openapi:schemas(Target) ++
        [#{<<"name">> => <<"unreviewed_operation">>,
           <<"parameters">> => #{<<"type">> => <<"object">>}}].

resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, unknown_tool}.
