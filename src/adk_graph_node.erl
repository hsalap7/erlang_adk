%% @doc adk_graph_node - Helper functions for creating common graph nodes.
%%
%% ADK 2.0 graphs can contain various node types. This module provides builders
%% for common node types to simplify graph construction.
-module(adk_graph_node).

-export([agent_node/3, function_node/1, tool_node/1]).

%% @doc Create a node that executes an agent.
%% The agent will generate a response based on the current state (memory/events).
-spec agent_node(Name :: binary(), Config :: map(), Tools :: [module()]) -> fun((map()) -> map()).
agent_node(Name, Config, Tools) ->
    fun(State) ->
        %% Extract history from state or use empty
        History = maps:get(<<"events">>, State, []),
        
        %% Invoke LLM
        case adk_llm:generate(Config, History, Tools) of
            {ok, Text} ->
                ResponseText = unicode:characters_to_list(Text),
                FinalEvent = adk_event:new(Name, ResponseText, #{is_final => true}),
                %% Append new event to events list
                NewHistory = [FinalEvent | History],
                #{<<"events">> => NewHistory, <<"last_agent">> => Name};
            {tool_calls, Calls} ->
                AgentEvent = adk_event:new(Name, {tool_calls, Calls}, #{}),
                NewHistory = [AgentEvent | History],
                #{<<"events">> => NewHistory, <<"pending_tools">> => Calls, <<"last_agent">> => Name};
            {error, Reason} ->
                ErrorEvent = adk_event:new(Name, list_to_binary(io_lib:format("Error: ~p", [Reason])), #{}),
                NewHistory = [ErrorEvent | History],
                #{<<"events">> => NewHistory, <<"error">> => Reason}
        end
    end.

%% @doc Create a node that executes a pure Erlang function on the state.
%% Function should take a map (State) and return a map (StateDelta).
-spec function_node(Fun :: fun((map()) -> map())) -> fun((map()) -> map()).
function_node(Fun) when is_function(Fun, 1) ->
    fun(State) ->
        Fun(State)
    end.

%% @doc Create a node that executes pending tool calls.
-spec tool_node(ToolsList :: [module()]) -> fun((map()) -> map()).
tool_node(ToolsList) ->
    fun(State) ->
        case maps:get(<<"pending_tools">>, State, []) of
            [] -> #{}; %% No tools to execute
            Calls ->
                History = maps:get(<<"events">>, State, []),
                NewEvents = execute_tools(Calls, ToolsList, []),
                NewHistory = lists:reverse(NewEvents) ++ History,
                #{<<"events">> => NewHistory, <<"pending_tools">> => []}
        end
    end.

%% Internal Tool Execution
execute_tools([], _ToolsList, Acc) ->
    Acc;
execute_tools([{NameBin, ArgsMap} | Rest], ToolsList, Acc) ->
    execute_tools_inner(NameBin, ArgsMap, undefined, Rest, ToolsList, Acc);
execute_tools([{NameBin, ArgsMap, Sig} | Rest], ToolsList, Acc) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, Rest, ToolsList, Acc).

execute_tools_inner(NameBin, ArgsMap, Sig, Rest, ToolsList, Acc) ->
    FoundTool = lists:search(
        fun(Mod) ->
            Schema = Mod:schema(),
            maps:get(<<"name">>, Schema, atom_to_binary(Mod, utf8)) == NameBin
        end, ToolsList),
    
    Result = case FoundTool of
        {value, Mod} ->
            case Mod:execute(ArgsMap, #{}) of
                {ok, Res} -> #{<<"success">> => true, <<"result">> => format_result(Res)};
                {error, Reason} -> #{<<"success">> => false, <<"error">> => format_result(Reason)}
            end;
        false ->
            #{<<"success">> => false, <<"error">> => <<"Tool not found">>}
    end,
    ToolEvent = adk_event:new(<<"tool">>, {tool_response, NameBin, Result, Sig}),
    execute_tools(Rest, ToolsList, [ToolEvent | Acc]).

format_result(Res) when is_map(Res) -> Res;
format_result(Res) when is_binary(Res) -> #{<<"result">> => Res};
format_result(Res) -> #{<<"result">> => list_to_binary(io_lib:format("~p", [Res]))}.
