%% @doc adk_agent_tool - Wraps an agent as a tool.
%%
%% This module allows exposing one agent as a tool to another agent, enabling
%% agent-to-agent delegation in multi-agent systems.
-module(adk_agent_tool).

-export([schema/1, execute/3]).

%% @doc Define the schema for the agent tool.
-spec schema(AgentConfig :: map()) -> map().
schema(AgentConfig) ->
    Name = maps:get(name, AgentConfig, <<"AgentTool">>),
    Desc = maps:get(description, AgentConfig, <<"Delegates a task to another agent.">>),
    #{
        <<"name">> => Name,
        <<"description">> => Desc,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"prompt">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"The task instruction for the agent.">>
                }
            },
            <<"required">> => [<<"prompt">>]
        }
    }.

%% @doc Execute the agent as a tool.
-spec execute(AgentRef :: pid() | atom(), Args :: map(), Opts :: map()) -> {ok, term()} | {error, term()}.
execute(AgentRef, Args, _Opts) ->
    case maps:get(<<"prompt">>, Args, undefined) of
        undefined ->
            {error, <<"Missing required parameter 'prompt'">>};
        Prompt when is_binary(Prompt) ->
            %% Call the agent synchronously
            case erlang_adk:prompt(AgentRef, Prompt) of
                {ok, Response} -> {ok, Response};
                {error, Reason} -> {error, Reason}
            end;
        Prompt ->
            {error, list_to_binary(io_lib:format("Invalid prompt type: ~p", [Prompt]))}
    end.
