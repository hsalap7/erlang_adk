-module(my_weather_tool).
-behaviour(adk_tool).
-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"get_weather">>,
      <<"description">> => <<"Get current weather for a city">>,
      <<"parameters">> => #{
          <<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"city">> => #{<<"type">> => <<"string">>}
          },
          <<"required">> => [<<"city">>]
      }}.

execute(#{<<"city">> := City}, _Context) ->
    {ok, <<"Sunny in ", City/binary>>}.
