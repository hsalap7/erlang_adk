-module(adk_mcp_fixture_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"echo">>,
      <<"description">> => <<"Echo text through the MCP fixture">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"text">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"text">>]}}.

execute(#{<<"text">> := Text}, _Context) ->
    {ok, #{<<"echo">> => Text}};
execute(_, _Context) ->
    {error, invalid_arguments}.
