%% @doc adk_callbacks - Behavior and registry for ADK execution callbacks.
%%
%% Callbacks allow hooking into the execution lifecycle (e.g., on_llm_start, 
%% on_tool_call, on_error) for logging, monitoring, or side-effects.
-module(adk_callbacks).

-export([execute/3, run/3]).

%% Callback behaviour definition.
-callback on_agent_start(AgentName :: binary(), Input :: term()) -> ok.
-callback on_agent_end(AgentName :: binary(), Output :: term()) -> ok.
-callback on_tool_start(ToolName :: binary(), Args :: map()) -> ok.
-callback on_tool_end(ToolName :: binary(), Result :: term()) -> ok.
-callback on_error(Error :: term()) -> ok.
-callback before_agent(AgentName :: term(), Input :: term()) -> callback_result().
-callback after_agent(AgentName :: term(), Output :: term()) -> callback_result().
-callback before_model(Config :: map(), Memory :: list(), Tools :: list()) -> callback_result().
-callback after_model(Config :: map(), Result :: term()) -> callback_result().
-callback before_tool(ToolName :: binary(), Args :: map(), Context :: map()) -> callback_result().
-callback after_tool(ToolName :: binary(), Args :: map(), Context :: map(), Result :: term()) -> callback_result().

-type callback_result() :: ok | continue | {halt, term()} | {replace, term()}.

-optional_callbacks([
    on_agent_start/2, on_agent_end/2, on_tool_start/2, on_tool_end/2, on_error/1,
    before_agent/2, after_agent/2, before_model/3, after_model/2,
    before_tool/3, after_tool/4
]).

%% @doc Execute a callback hook across all registered handlers.
-spec execute(Handlers :: [module()], Hook :: atom(), Args :: [term()]) -> ok.
execute(Handlers, Hook, Args) ->
    lists:foreach(fun(Handler) ->
        _ = invoke(Handler, Hook, Args)
    end, Handlers),
    ok.

%% @doc Run handlers until one explicitly replaces or halts the operation.
%% Observation-only callbacks return `ok` or `continue`. A callback may return
%% `{replace, Value}` to replace an after-hook result, or `{halt, Value}` to
%% skip the operation wrapped by a before-hook.
-spec run([module()], atom(), [term()]) -> continue | {halt, term()} | {replace, term()}.
run([], _Hook, _Args) ->
    continue;
run([Handler | Rest], Hook, Args) ->
    case invoke(Handler, Hook, Args) of
        {halt, _} = Halt -> Halt;
        {replace, _} = Replace -> Replace;
        _ -> run(Rest, Hook, Args)
    end.

invoke(Handler, Hook, Args) ->
    case code:ensure_loaded(Handler) of
        {module, Handler} ->
            case erlang:function_exported(Handler, Hook, length(Args)) of
                true ->
                    try erlang:apply(Handler, Hook, Args) of
                        Value -> Value
                    catch
                        E:R:S ->
                            logger:error("Callback error in ~p:~p - ~p:~p~n~p",
                                         [Handler, Hook, E, R, S]),
                            continue
                    end;
                false -> continue
            end;
        {error, Reason} ->
            logger:warning("Unable to load callback ~p: ~p", [Handler, Reason]),
            continue
    end.
