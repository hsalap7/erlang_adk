-module(dummy_tool).
-export([schema/0, execute/1]).

schema() ->
    #{<<"name">> => <<"dummy_tool">>,
      <<"description">> => <<"A dummy tool">>,
      <<"parameters">> => #{<<"type">> => <<"OBJECT">>}
    }.

execute(#{<<"arg">> := Val}) ->
    {ok, #{<<"status">> => <<"success">>, <<"val">> => Val}}.
