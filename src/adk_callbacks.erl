%% @doc adk_callbacks - Behavior and registry for ADK execution callbacks.
%%
%% Callbacks allow hooking into the execution lifecycle (e.g., on_llm_start, 
%% on_tool_call, on_error) for logging, monitoring, or side-effects.
-module(adk_callbacks).

-export([execute/3]).

%% Callback behaviour definition.
-callback on_agent_start(AgentName :: binary(), Input :: term()) -> ok.
-callback on_agent_end(AgentName :: binary(), Output :: term()) -> ok.
-callback on_tool_start(ToolName :: binary(), Args :: map()) -> ok.
-callback on_tool_end(ToolName :: binary(), Result :: term()) -> ok.
-callback on_error(Error :: term()) -> ok.

%% @doc Execute a callback hook across all registered handlers.
-spec execute(Handlers :: [module()], Hook :: atom(), Args :: [term()]) -> ok.
execute(Handlers, Hook, Args) ->
    lists:foreach(fun(Handler) ->
        case erlang:function_exported(Handler, Hook, length(Args)) of
            true ->
                try erlang:apply(Handler, Hook, Args)
                catch
                    E:R:S ->
                        logger:error("Callback error in ~p:~p - ~p:~p~n~p", [Handler, Hook, E, R, S])
                end;
            false -> ok
        end
    end, Handlers).
