%% @doc adk_callbacks - Behavior and registry for ADK execution callbacks.
%%
%% Callbacks allow hooking into the execution lifecycle (e.g., on_llm_start, 
%% on_tool_call, on_error) for logging, monitoring, or side-effects.
-module(adk_callbacks).

-export([execute/3, run/3]).

-define(APP, erlang_adk).
-define(DEFAULT_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_HEAP_WORDS, 262144).

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
    PublicArgs = adk_callback_view:callback_args(Hook, Args),
    lists:foreach(fun(Handler) ->
        _ = invoke(Handler, Hook, PublicArgs)
    end, Handlers),
    ok.

%% @doc Run handlers until one explicitly replaces or halts the operation.
%% Observation-only callbacks return `ok' or `continue'. A callback may return
%% `{replace, Value}' to replace an after-hook result, or `{halt, Value}' to
%% skip the operation wrapped by a before-hook.
-spec run([module()], atom(), [term()]) -> continue | {halt, term()} | {replace, term()}.
run([], _Hook, _Args) ->
    continue;
run(Handlers, Hook, Args) ->
    PublicArgs = adk_callback_view:callback_args(Hook, Args),
    run_public(Handlers, Hook, PublicArgs).

run_public([], _Hook, _Args) ->
    continue;
run_public([Handler | Rest], Hook, Args) ->
    case invoke(Handler, Hook, Args) of
        {halt, _} = Halt -> Halt;
        {replace, _} = Replace -> Replace;
        _ -> run_public(Rest, Hook, Args)
    end.

invoke(Handler, Hook, Args) ->
    case code:ensure_loaded(Handler) of
        {module, Handler} ->
            case erlang:function_exported(Handler, Hook, length(Args)) of
                true ->
                    invoke_isolated(Handler, Hook, Args);
                false -> continue
            end;
        {error, Reason} ->
            Failure = adk_failure:exception(
                        callback, load, error, Reason),
            logger:warning("Unable to load callback ~p: ~p",
                           [Handler, Failure]),
            continue
    end.

invoke_isolated(Handler, Hook, Args) ->
    TimeoutMs = positive_env(callback_timeout_ms, ?DEFAULT_TIMEOUT_MS),
    MaxHeapWords = positive_env(callback_max_heap_words,
                                ?DEFAULT_MAX_HEAP_WORDS),
    Parent = self(),
    ResultRef = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Worker = fun() ->
        Result = safe_apply(Handler, Hook, Args),
        Parent ! {adk_callback_result, ResultRef, self(), Result}
    end,
    Options =
        [monitor,
         {max_heap_size,
          #{size => MaxHeapWords, kill => true, error_logger => false}}],
    {Pid, MonitorRef} = erlang:spawn_opt(Worker, Options),
    await_result(Handler, Hook, Pid, MonitorRef, ResultRef, Deadline).

safe_apply(Handler, Hook, Args) ->
    try erlang:apply(Handler, Hook, Args) of
        Value -> Value
    catch
        Class:Reason:_Stack ->
            Failure = adk_failure:exception(
                        callback, Hook, Class, Reason),
            logger:error("Callback failed in ~p:~p: ~p",
                         [Handler, Hook, Failure]),
            continue
    end.

await_result(Handler, Hook, Pid, MonitorRef, ResultRef, Deadline) ->
    Remaining = remaining_ms(Deadline),
    receive
        {adk_callback_result, ResultRef, Pid, Value} ->
            await_worker_exit(Handler, Hook, Pid, MonitorRef, ResultRef,
                              Deadline, Value);
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            log_worker_failure(Handler, Hook, Reason),
            flush_result(ResultRef, Pid),
            continue
    after Remaining ->
        terminate_worker(Handler, Hook, Pid, MonitorRef, ResultRef, timeout)
    end.

await_worker_exit(Handler, Hook, Pid, MonitorRef, ResultRef, Deadline, Value) ->
    Remaining = remaining_ms(Deadline),
    receive
        {'DOWN', MonitorRef, process, Pid, normal} ->
            Value;
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            log_worker_failure(Handler, Hook, Reason),
            continue
    after Remaining ->
        terminate_worker(Handler, Hook, Pid, MonitorRef, ResultRef, timeout)
    end.

terminate_worker(Handler, Hook, Pid, MonitorRef, ResultRef, timeout) ->
    exit(Pid, kill),
    receive
        {'DOWN', MonitorRef, process, Pid, _Reason} -> ok
    end,
    flush_result(ResultRef, Pid),
    logger:error("Callback timed out in ~p:~p", [Handler, Hook]),
    continue.

flush_result(ResultRef, Pid) ->
    receive
        {adk_callback_result, ResultRef, Pid, _Value} -> ok
    after 0 ->
        ok
    end.

log_worker_failure(_Handler, _Hook, normal) ->
    ok;
log_worker_failure(Handler, Hook, Reason) ->
    Failure = adk_failure:external(callback, worker_down, Reason),
    logger:error("Callback worker failed in ~p:~p: ~p",
                 [Handler, Hook, Failure]).

remaining_ms(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

positive_env(Key, Default) ->
    case application:get_env(?APP, Key) of
        {ok, Value} when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.
