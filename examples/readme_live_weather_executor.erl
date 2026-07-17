-module(readme_live_weather_executor).
-behaviour(adk_live_tool_executor).

-export([execute/2]).

execute(#{id := _CallId,
          name := <<"get_weather">>,
          args := Arguments}, _Options) ->
    readme_weather_tool:execute(Arguments, #{});
execute(_Call, _Options) ->
    {error, unsupported_live_tool}.
