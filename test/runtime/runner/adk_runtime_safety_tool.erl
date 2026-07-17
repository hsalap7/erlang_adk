-module(adk_runtime_safety_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"secret_output">>,
      <<"description">> => <<"Runtime policy output-budget fixture">>,
      <<"parameters">> => #{<<"type">> => <<"object">>}}.

execute(_Args, _Context) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! runtime_safety_tool_executed;
        _ -> ok
    end,
    Secret = binary:copy(<<"private-tool-output-">>, 16),
    {ok, #{<<"secret">> => Secret}}.
