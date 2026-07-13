-module(readme_weather_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"get_weather">>,
      <<"description">> => <<"Get the weather for a city">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"city">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"city">>]}}.

execute(#{<<"city">> := City}, Context) ->
    %% Context contains session_id, user_id, and state_ref when available.
    _ = Context,
    {ok, #{<<"city">> => City, <<"forecast">> => <<"sunny">>}}.
