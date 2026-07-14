%% @doc Bounded execution for already-resolved tool calls.
%%
%% A resolved call is a map containing name, args, and either module or an
%% internal zero-arity execute function. Optional
%% thought_signature and call_id values are copied unchanged to the result.
%% Serial execution is the default. In parallel mode, only calls explicitly
%% marked parallel_safe (or whose module opts in through parallel_safe/0 or
%% schema metadata) overlap; an unsafe call is a barrier.
-module(adk_tool_executor).

-export([start/1, start/2, start/3,
         execute/1, execute/2, execute/3,
         await/1, await/2,
         cancel/1, cancel/2,
         is_parallel_safe/1, is_pause_capable/1]).

-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_TOOL_TIMEOUT, 30000).
-define(DEFAULT_MAX_CONCURRENCY, 4).

-type resolved_call() :: #{
    index => pos_integer(),
    name := binary(),
    args := map(),
    module => module(),
    execute => fun(() -> term()),
    thought_signature => term(),
    call_id => term(),
    context => map(),
    parallel_safe => boolean(),
    pause_capable => boolean(),
    timeout => non_neg_integer() | infinity,
    deadline => integer() | infinity
}.
-type call_result() :: #{
    index := pos_integer(),
    name := binary(),
    thought_signature := term(),
    call_id := term(),
    outcome := {ok, term()}
             | {error, term()}
             | {paused, term(), term()}
}.
-export_type([resolved_call/0, call_result/0]).

-spec start([resolved_call()]) ->
    {ok, adk_task:task_ref()} | {error, term()}.
start(Calls) ->
    start(Calls, #{}).

-spec start([resolved_call()], map()) ->
    {ok, adk_task:task_ref()} | {error, term()}.
start(Calls, Opts) when is_map(Opts) ->
    Context = maps:get(context, Opts, #{}),
    start(Calls, Context, maps:remove(context, Opts)).

-spec start([resolved_call()], map(), map()) ->
    {ok, adk_task:task_ref()} | {error, term()}.
start(Calls, Context, Opts)
  when is_list(Calls), is_map(Context), is_map(Opts) ->
    case normalize_calls(Calls) of
        {ok, Normalized} ->
            case normalize_options(Opts) of
                {ok, Config} ->
                    Work = fun() ->
                        schedule(Normalized, Context, Config)
                    end,
                    adk_task:start(Work, outer_task_options(Opts, Config));
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
start(Calls, Context, Opts) ->
    {error, {invalid_tool_execution_arguments,
             Calls, Context, Opts}}.

-spec execute([resolved_call()]) ->
    {ok, [call_result()]} | {error, term()}.
execute(Calls) ->
    execute(Calls, #{}).

-spec execute([resolved_call()], map()) ->
    {ok, [call_result()]} | {error, term()}.
execute(Calls, Opts) when is_map(Opts) ->
    Context = maps:get(context, Opts, #{}),
    execute(Calls, Context, maps:remove(context, Opts)).

-spec execute([resolved_call()], map(), map()) ->
    {ok, [call_result()]} | {error, term()}.
execute(Calls, Context, Opts) ->
    case start(Calls, Context, Opts) of
        {ok, TaskRef} -> await(TaskRef);
        {error, _} = Error -> Error
    end.

-spec await(adk_task:task_ref()) ->
    {ok, [call_result()]} | {error, term()}.
await(TaskRef) ->
    await(TaskRef, infinity).

-spec await(adk_task:task_ref(), timeout()) ->
    {ok, [call_result()]} | {error, term()}.
await(TaskRef, Timeout) ->
    case adk_task:await(TaskRef, Timeout) of
        {completed, Results} when is_list(Results) -> {ok, Results};
        {failed, Reason} ->
            {error, adk_failure:sanitize(
                      tool_executor, batch_execute, Reason)};
        {timed_out, deadline_exceeded} -> {error, timeout};
        {cancelled, Reason} ->
            {error, adk_failure:sanitize(tool_executor, cancel, Reason)};
        {error, _} = Error -> Error;
        Other ->
            {error, adk_failure:external(
                      tool_executor, invalid_outcome, Other)}
    end.

-spec cancel(adk_task:task_ref()) -> ok | {error, term()}.
cancel(TaskRef) ->
    cancel(TaskRef, user_cancelled).

-spec cancel(adk_task:task_ref(), term()) -> ok | {error, term()}.
cancel(TaskRef, Reason) ->
    adk_task:cancel(TaskRef, Reason).

normalize_calls(Calls) ->
    normalize_calls(Calls, 1, []).

normalize_calls([], _Index, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_calls([Call | Rest], Index, Acc) when is_map(Call) ->
    case normalize_call(Call, Index) of
        {ok, Normalized} ->
            normalize_calls(Rest, Index + 1, [Normalized | Acc]);
        {error, _} = Error ->
            Error
    end;
normalize_calls([Call | _Rest], Index, _Acc) ->
    {error, {invalid_resolved_tool_call, Index, Call}}.

normalize_call(Call, Index) ->
    case {maps:find(name, Call), maps:find(args, Call),
          valid_executor(Call)} of
        {{ok, Name}, {ok, Args}, true}
          when is_binary(Name), is_map(Args) ->
            Context = maps:get(context, Call, #{}),
            case is_map(Context) of
                true ->
                    {ok, Call#{index => Index,
                               context => Context,
                               thought_signature =>
                                   maps:get(thought_signature, Call,
                                            undefined),
                               call_id => maps:get(call_id, Call,
                                                   undefined)}};
                false ->
                    {error, {invalid_tool_call_context, Index, Context}}
            end;
        _ ->
            {error, {invalid_resolved_tool_call, Index, Call}}
    end.

normalize_options(Opts) ->
    Mode = maps:get(mode, Opts, serial),
    Max = maps:get(max_concurrency, Opts,
                   ?DEFAULT_MAX_CONCURRENCY),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Deadline = maps:get(deadline, Opts,
                        deadline_from_timeout(Timeout)),
    ToolTimeout = maps:get(tool_timeout, Opts,
                           ?DEFAULT_TOOL_TIMEOUT),
    case valid_mode(Mode)
         andalso is_integer(Max) andalso Max > 0
         andalso valid_deadline(Deadline)
         andalso valid_timeout(ToolTimeout) of
        true ->
            {ok, #{mode => Mode,
                   max_concurrency => Max,
                   deadline => Deadline,
                   tool_timeout => ToolTimeout}};
        false ->
            {error, {invalid_tool_executor_options,
                     #{mode => Mode,
                       max_concurrency => Max,
                       deadline => Deadline,
                       tool_timeout => ToolTimeout}}}
    end.

valid_mode(serial) -> true;
valid_mode(parallel) -> true;
valid_mode(_) -> false.

valid_deadline(infinity) -> true;
valid_deadline(Value) -> is_integer(Value).

valid_timeout(infinity) -> true;
valid_timeout(Value) -> is_integer(Value) andalso Value >= 0.

deadline_from_timeout(infinity) ->
    infinity;
deadline_from_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    adk_task:deadline_after(Timeout);
deadline_from_timeout(Invalid) ->
    {invalid_timeout, Invalid}.

outer_task_options(Opts, Config) ->
    Keys = [retention_ms, notify, owner, cancel_on_owner_down],
    Selected = maps:with(Keys, Opts),
    Selected#{deadline => maps:get(deadline, Config)}.

schedule(Calls, Context, #{mode := serial} = Config) ->
    Results = serial_schedule(Calls, Context, Config, #{}),
    ordered_results(Results, length(Calls));
schedule(Calls, Context, #{mode := parallel} = Config) ->
    Results = parallel_schedule(Calls, Context, Config, #{}, #{}),
    ordered_results(Results, length(Calls)).

serial_schedule([], _Context, _Config, Results) ->
    Results;
serial_schedule([Call | Rest], Context, Config, Results0) ->
    {TaskRef, StartedResult} = start_call(Call, Context, Config),
    Result = case StartedResult of
        started ->
            await_call(TaskRef, Call);
        {start_error, Reason} ->
            result_map(Call,
                       {error, adk_failure:sanitize(
                                 tool_executor, task_start, Reason)})
    end,
    Index = maps:get(index, Call),
    serial_schedule(Rest, Context, Config,
                    Results0#{Index => Result}).

parallel_schedule([], _Context, _Config, Active, Results) ->
    drain_active(Active, Results);
parallel_schedule([Call | Rest] = Pending, Context,
                  Config = #{max_concurrency := Max}, Active, Results0) ->
    case is_parallel_safe(Call) of
        false ->
            Results1 = drain_active(Active, Results0),
            Results2 = serial_schedule([Call], Context, Config, Results1),
            parallel_schedule(Rest, Context, Config, #{}, Results2);
        true when map_size(Active) < Max ->
            Index = maps:get(index, Call),
            {TaskRef, StartedResult} = start_call(Call, Context, Config),
            case StartedResult of
                started ->
                    Active1 = Active#{TaskRef => Call},
                    parallel_schedule(Rest, Context, Config,
                                      Active1, Results0);
                {start_error, Reason} ->
                    Result = result_map(
                               Call,
                               {error, adk_failure:sanitize(
                                         tool_executor, task_start,
                                         Reason)}),
                    parallel_schedule(
                      Rest, Context, Config, Active,
                      Results0#{Index => Result})
            end;
        true ->
            {Active1, Results1} = await_one_active(Active, Results0),
            parallel_schedule(Pending, Context, Config,
                              Active1, Results1)
    end.

start_call(Call, CommonContext, Config) ->
    Args = maps:get(args, Call),
    CallContext = maps:get(context, Call),
    Context = maps:merge(CommonContext, CallContext),
    Work = call_work(Call, Args, Context),
    Deadline = call_deadline(Call, Config),
    TaskOpts = #{deadline => Deadline,
                 retention_ms => 0,
                 notify => self(),
                 owner => self(),
                 cancel_on_owner_down => true},
    case adk_task:start(Work, TaskOpts) of
        {ok, TaskRef} -> {TaskRef, started};
        {error, Reason} ->
            %% A placeholder reference is never awaited.
            {undefined, {start_error, Reason}}
    end.

valid_executor(Call) ->
    case maps:find(execute, Call) of
        {ok, Execute} -> is_function(Execute, 0);
        error ->
            case maps:find(module, Call) of
                {ok, Module} -> is_atom(Module);
                error -> false
            end
    end.

call_work(Call, Args, Context) ->
    case maps:find(execute, Call) of
        {ok, Execute} ->
            fun() ->
                try Execute() of
                    Result -> Result
                catch
                    throw:{adk_pause, _Reason, _Summary} = Pause -> Pause
                end
            end;
        error ->
            Module = maps:get(module, Call),
            fun() -> invoke_tool(Module, Args, Context) end
    end.

invoke_tool(Module, Args, Context) ->
    try Module:execute(Args, Context) of
        Result -> Result
    catch
        throw:{adk_pause, _Reason, _Summary} = Pause -> Pause
    end.

call_deadline(Call, Config) ->
    GroupDeadline = maps:get(deadline, Config),
    CallDeadline = case maps:find(deadline, Call) of
        {ok, Explicit} -> Explicit;
        error ->
            Timeout = maps:get(timeout, Call,
                               maps:get(tool_timeout, Config)),
            deadline_from_timeout(Timeout)
    end,
    earliest_deadline(GroupDeadline, CallDeadline).

earliest_deadline(infinity, Other) -> Other;
earliest_deadline(Other, infinity) -> Other;
earliest_deadline(A, B) when is_integer(A), is_integer(B) -> min(A, B);
earliest_deadline(_Group, Invalid) -> Invalid.

await_call(TaskRef, Call) ->
    receive
        {adk_task_terminal, TaskRef, Outcome} ->
            result_map(Call, tool_outcome(Outcome))
    end.

await_one_active(Active0, Results0) ->
    receive
        {adk_task_terminal, TaskRef, Outcome} ->
            case maps:take(TaskRef, Active0) of
                {Call, Active1} ->
                    Index = maps:get(index, Call),
                    Result = result_map(Call, tool_outcome(Outcome)),
                    {Active1, Results0#{Index => Result}};
                error ->
                    await_one_active(Active0, Results0)
            end
    end.

drain_active(Active, Results) when map_size(Active) =:= 0 ->
    Results;
drain_active(Active0, Results0) ->
    {Active1, Results1} = await_one_active(Active0, Results0),
    drain_active(Active1, Results1).

tool_outcome({completed, {ok, Result}}) ->
    {ok, Result};
tool_outcome({completed, {error, Reason}}) ->
    {error, adk_failure:sanitize(tool, execute, Reason)};
tool_outcome({completed, {adk_pause, Reason, Summary}}) ->
    {paused, Reason, Summary};
tool_outcome({completed, Other}) ->
    {error, adk_failure:external(tool, invalid_result, Other)};
tool_outcome({failed, Failure = {adk_failure, _Metadata}}) ->
    {error, Failure};
tool_outcome({failed, {exception, Class, Reason}}) ->
    {error, adk_failure:exception(tool, execute, Class, Reason)};
%% Accept the pre-0.3 internal shape while a rolling upgrade drains old task
%% workers, but never copy its stacktrace into the public per-call result.
tool_outcome({failed, {exception, Class, Reason, _LegacyStacktrace}}) ->
    {error, adk_failure:exception(tool, execute, Class, Reason)};
tool_outcome({failed, Reason}) ->
    {error, adk_failure:sanitize(tool, execute, Reason)};
tool_outcome({timed_out, deadline_exceeded}) ->
    {error, timeout};
tool_outcome({cancelled, Reason}) ->
    {error, adk_failure:sanitize(tool, cancel, Reason)}.

result_map(Call, Outcome) ->
    #{index => maps:get(index, Call),
      name => maps:get(name, Call),
      thought_signature => maps:get(thought_signature, Call),
      call_id => maps:get(call_id, Call),
      outcome => Outcome}.

ordered_results(_Results, 0) ->
    [];
ordered_results(Results, Count) ->
    [maps:get(Index, Results) || Index <- lists:seq(1, Count)].

-spec is_parallel_safe(resolved_call()) -> boolean().
is_parallel_safe(Call) when is_map(Call) ->
    not is_pause_capable(Call) andalso declared_parallel_safe(Call);
is_parallel_safe(_Call) ->
    false.

declared_parallel_safe(Call) ->
    case maps:find(parallel_safe, Call) of
        {ok, Value} -> Value =:= true;
        error ->
            case maps:get(metadata, Call, #{}) of
                #{parallel_safe := Value} -> Value =:= true;
                _ -> module_parallel_safe(maps:get(module, Call, undefined))
            end
    end.

-spec is_pause_capable(resolved_call()) -> boolean().
is_pause_capable(Call) when is_map(Call) ->
    case maps:find(pause_capable, Call) of
        {ok, Value} -> Value =:= true;
        error ->
            case maps:get(metadata, Call, #{}) of
                #{pause_capable := Value} -> Value =:= true;
                _ -> module_pause_capable(maps:get(module, Call, undefined))
            end
    end;
is_pause_capable(_Call) ->
    false.

module_parallel_safe(Module) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, parallel_safe, 0) of
                true ->
                    try Module:parallel_safe() =:= true
                    catch _:_ -> false
                    end;
                false ->
                    schema_parallel_safe(Module)
            end;
        _ ->
            false
    end;
module_parallel_safe(_Module) ->
    false.

module_pause_capable(adk_long_running_tool) ->
    true;
module_pause_capable(Module) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, pause_capable, 0) of
                true ->
                    try Module:pause_capable() =:= true
                    catch _:_ -> true
                    end;
                false ->
                    schema_boolean(Module, pause_capable,
                                   <<"pause_capable">>, false)
            end;
        _ ->
            false
    end;
module_pause_capable(_Module) ->
    false.

schema_parallel_safe(Module) ->
    schema_boolean(Module, parallel_safe, <<"parallel_safe">>, false).

schema_boolean(Module, AtomKey, BinaryKey, Default) ->
    case erlang:function_exported(Module, schema, 0) of
        false -> Default;
        true ->
            try Module:schema() of
                Schema when is_map(Schema) ->
                    case maps:find(AtomKey, Schema) of
                        {ok, Value} -> Value =:= true;
                        error ->
                            maps:get(BinaryKey, Schema, Default)
                            =:= true
                    end;
                _ -> Default
            catch
                _:_ -> Default
            end
    end.
