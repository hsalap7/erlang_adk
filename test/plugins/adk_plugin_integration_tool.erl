-module(adk_plugin_integration_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"integration_tool">>,
      <<"description">> => <<"Integration lifecycle probe">>,
      <<"parameters">> => #{<<"type">> => <<"OBJECT">>}}.

execute(Args, _Context) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! {integration_tool_executed, Args};
        _ -> ok
    end,
    {ok, #{<<"executed">> => true}}.
