%% @doc adk_graph_node - Helper functions for creating common graph nodes.
%%
%% Erlang ADK graphs can contain various node types. This module provides builders
%% for common node types to simplify graph construction.
-module(adk_graph_node).

-export([agent_node/3, function_node/1, tool_node/1]).

%% @doc Create a node that executes an agent.
%% The agent will generate a response based on the current state (memory/events).
-spec agent_node(Name :: binary(), Config :: map(), Tools :: [module()]) -> fun((map()) -> map()).
agent_node(Name, Config, Tools) ->
    fun(State) ->
        %% Extract history from state or use empty
        HistoryEvents = maps:get(<<"events">>, State, []),
        Memory0 = adk_memory:from_events(HistoryEvents),
        Memory = ensure_instructions(Memory0, Config),
        History = adk_memory:get_history(Memory),

        %% Invoke LLM
        case generate_with_callbacks(Config, Memory, History, Tools) of
            {ok, Text} ->
                ResponseText = unicode:characters_to_binary(Text),
                FinalEvent = adk_event:new(Name, ResponseText, #{is_final => true}),
                %% Append new event to events list
                NewHistory = HistoryEvents ++ [FinalEvent],
                #{<<"events">> => NewHistory, <<"last_agent">> => Name};
            {tool_calls, Calls} ->
                AgentEvent = adk_event:new(Name, {tool_calls, Calls}, #{}),
                NewHistory = HistoryEvents ++ [AgentEvent],
                #{<<"events">> => NewHistory, <<"pending_tools">> => Calls, <<"last_agent">> => Name};
            {error, Reason} ->
                Failure = adk_failure:sanitize(
                            graph_node, model_generate, Reason),
                ErrorEvent = adk_event:new(
                               Name, <<"Model execution failed">>, #{}),
                NewHistory = HistoryEvents ++ [ErrorEvent],
                #{<<"events">> => NewHistory, <<"error">> => Failure}
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
                NewHistory = History ++ lists:reverse(NewEvents),
                #{<<"events">> => NewHistory, <<"pending_tools">> => []}
        end
    end.

%% Internal Tool Execution
execute_tools([], _ToolsList, Acc) ->
    Acc;
execute_tools([{NameBin, ArgsMap} | Rest], ToolsList, Acc) ->
    execute_tools_inner(NameBin, ArgsMap, undefined, undefined, Rest,
                        ToolsList, Acc);
execute_tools([{NameBin, ArgsMap, Sig} | Rest], ToolsList, Acc) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, undefined, Rest,
                        ToolsList, Acc);
execute_tools([{NameBin, ArgsMap, Sig, CallId} | Rest], ToolsList, Acc) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, CallId, Rest, ToolsList, Acc).

execute_tools_inner(NameBin, ArgsMap, Sig, CallId, Rest, ToolsList, Acc) ->
    FoundTool = lists:search(
        fun(Mod) ->
            Schema = Mod:schema(),
            maps:get(<<"name">>, Schema, atom_to_binary(Mod, utf8)) == NameBin
        end, ToolsList),

    Result = case FoundTool of
        {value, Mod} ->
            try Mod:execute(ArgsMap, #{}) of
                {ok, Res} -> #{<<"success">> => true, <<"result">> => format_result(Res)};
                {error, Reason} ->
                    #{<<"success">> => false,
                      <<"error">> => adk_failure:model_response(
                                        graph_tool, execute, Reason)};
                Other -> #{<<"success">> => false,
                           <<"error">> => adk_failure:model_response(
                                             graph_tool, invalid_result,
                                             Other)}
            catch
                Class:Failure ->
                    #{<<"success">> => false,
                      <<"error">> =>
                          adk_failure:model_response(
                            graph_tool, execute,
                            adk_failure:exception(
                              graph_tool, execute, Class, Failure))}
            end;
        false ->
            #{<<"success">> => false, <<"error">> => <<"Tool not found">>}
    end,
    ToolResponse = case CallId of
        undefined -> {tool_response, NameBin, Result, Sig};
        _ -> {tool_response, NameBin, Result, Sig, CallId}
    end,
    ToolEvent = adk_event:new(<<"tool">>, ToolResponse),
    execute_tools(Rest, ToolsList, [ToolEvent | Acc]).

format_result(Res) when is_map(Res) -> Res;
format_result(Res) when is_binary(Res) -> #{<<"result">> => Res};
format_result(Res) ->
    #{<<"result">> => unicode:characters_to_binary(io_lib:format("~p", [Res]))}.

ensure_instructions(Memory, Config) ->
    case lists:any(fun(#{role := system}) -> true; (_) -> false end, Memory) of
        true -> Memory;
        false ->
            Instructions = maps:get(instructions, Config,
                                    <<"You are a helpful assistant.">>),
            Memory ++ [#{role => system, content => Instructions,
                         timestamp => erlang:system_time(millisecond)}]
    end.

generate_with_callbacks(Config, Memory, History, Tools) ->
    Handlers = maps:get(callbacks, Config, []),
    RawResult = case adk_callbacks:run(Handlers, before_model,
                                       [Config, Memory, Tools]) of
        {halt, Replacement} -> Replacement;
        {replace, Replacement} -> Replacement;
        _ ->
            try adk_llm:generate(Config, History, Tools) of
                {error, Reason} ->
                    {error, adk_failure:sanitize(
                              graph_node, model_generate, Reason)};
                Result -> Result
            catch
                Class:Reason ->
                    {error, adk_failure:exception(
                              graph_node, model_generate, Class, Reason)}
            end
    end,
    case adk_callbacks:run(Handlers, after_model, [Config, RawResult]) of
        {halt, ReplacementResult} -> ReplacementResult;
        {replace, ReplacementResult} -> ReplacementResult;
        _ -> RawResult
    end.
