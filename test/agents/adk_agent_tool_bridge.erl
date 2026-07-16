-module(adk_agent_tool_bridge).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"delegate_via_agent_tool">>,
      <<"description">> => <<"Delegate through the AgentTool API">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"prompt">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"prompt">>],
            <<"additionalProperties">> => false}}.

execute(Args, Context) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) ->
            adk_agent_tool:execute(Pid, Args, Context);
        _ ->
            {error, agent_tool_bridge_target_unavailable}
    end.
