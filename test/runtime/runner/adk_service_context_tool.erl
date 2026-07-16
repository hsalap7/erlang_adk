-module(adk_service_context_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"inspect_service_context">>,
      <<"description">> => <<"Capture the ToolContext for a test.">>,
      <<"parameters">> => #{<<"type">> => <<"OBJECT">>}}.

execute(_Args, Context) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! {service_tool_context, Context};
        _ -> ok
    end,
    {ok, <<"context captured">>}.
