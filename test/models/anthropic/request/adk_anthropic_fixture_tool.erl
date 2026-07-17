-module(adk_anthropic_fixture_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"weather">>,
      <<"description">> => <<"Look up weather">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"city">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"city">>]}}.

execute(Args, _Context) ->
    {ok, Args}.
