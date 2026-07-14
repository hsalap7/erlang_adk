%% @doc Public API for bounded supervised work.
%%
%% Task references are stable binaries. Work is owned by adk_task_worker under
%% adk_task_sup, not by the process that starts or awaits it. A task has exactly
%% one outcome:
%%
%%   {completed, Value}
%%   {failed, Reason}
%%   {timed_out, deadline_exceeded}
%%   {cancelled, Reason}
%%
%% The deadline option is an absolute Erlang monotonic millisecond value. A
%% relative timeout is converted to that absolute deadline once, before the
%% supervised task starts, so queue/startup time consumes the same budget.
-module(adk_task).

-export([start/1, start/2,
         await/1, await/2,
         cancel/1, cancel/2,
         status/1,
         deadline_after/1]).

-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_CALL_TIMEOUT, 5000).
-define(DEFAULT_RETENTION_MS, 30000).

-type task_ref() :: binary().
-type outcome() ::
    {completed, term()}
    | {failed, term()}
    | {timed_out, deadline_exceeded}
    | {cancelled, term()}.
-export_type([task_ref/0, outcome/0]).

-spec start(fun(() -> term()) | {module(), atom(), [term()]}) ->
    {ok, task_ref()} | {error, term()}.
start(Work) ->
    start(Work, #{}).

-spec start(fun(() -> term()) | {module(), atom(), [term()]}, map()) ->
    {ok, task_ref()} | {error, term()}.
start(Work, Opts0) when is_map(Opts0) ->
    case validate_work(Work) of
        ok ->
            case normalize_options(Opts0) of
                {ok, Opts} ->
                    TaskRef = generate_task_ref(),
                    try adk_task_sup:start_task(TaskRef, Work, Opts) of
                        {ok, _Pid} -> {ok, TaskRef};
                        {ok, _Pid, _Info} -> {ok, TaskRef};
                        {error, Reason} -> {error, Reason}
                    catch
                        exit:{noproc, _} ->
                            {error, task_supervisor_not_started};
                        exit:Reason ->
                            {error, adk_failure:external(
                                      adk_task, start, Reason)}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
start(_Work, Opts) ->
    {error, {invalid_task_options, Opts}}.

-spec await(task_ref()) -> outcome() | {error, term()}.
await(TaskRef) ->
    await(TaskRef, infinity).

-spec await(task_ref(), timeout()) -> outcome() | {error, term()}.
await(TaskRef, Timeout)
  when Timeout =:= infinity;
       is_integer(Timeout), Timeout >= 0 ->
    call_task(TaskRef, await, Timeout);
await(_TaskRef, Timeout) ->
    {error, {invalid_await_timeout, Timeout}}.

-spec cancel(task_ref()) -> ok | {error, term()}.
cancel(TaskRef) ->
    cancel(TaskRef, user_cancelled).

-spec cancel(task_ref(), term()) -> ok | {error, term()}.
cancel(TaskRef, Reason) ->
    call_task(TaskRef, {cancel, Reason}, ?DEFAULT_CALL_TIMEOUT).

-spec status(task_ref()) -> {ok, map()} | {error, term()}.
status(TaskRef) ->
    case call_task(TaskRef, status, ?DEFAULT_CALL_TIMEOUT) of
        Status when is_map(Status) -> {ok, Status};
        {error, _} = Error -> Error
    end.

-spec deadline_after(non_neg_integer() | infinity) -> integer() | infinity.
deadline_after(infinity) ->
    infinity;
deadline_after(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout.

normalize_options(Opts0) ->
    Timeout = maps:get(
                timeout, Opts0,
                application:get_env(erlang_adk, task_timeout,
                                    ?DEFAULT_TIMEOUT)),
    Deadline = maps:get(deadline, Opts0, deadline_from_timeout(Timeout)),
    Retention = maps:get(
                  retention_ms, Opts0,
                  application:get_env(erlang_adk, task_retention_ms,
                                      ?DEFAULT_RETENTION_MS)),
    Notify = maps:get(notify, Opts0, undefined),
    Owner = maps:get(owner, Opts0, undefined),
    CancelOnOwnerDown = maps:get(cancel_on_owner_down, Opts0, false),
    case valid_options(Deadline, Retention, Notify, Owner,
                       CancelOnOwnerDown) of
        true ->
            {ok, Opts0#{deadline => Deadline,
                        retention_ms => Retention,
                        notify => Notify,
                        owner => Owner,
                        cancel_on_owner_down => CancelOnOwnerDown}};
        false ->
            {error, {invalid_task_options,
                     #{deadline => Deadline,
                       retention_ms => Retention,
                       notify => Notify,
                       owner => Owner,
                       cancel_on_owner_down => CancelOnOwnerDown}}}
    end.

deadline_from_timeout(infinity) ->
    infinity;
deadline_from_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    deadline_after(Timeout);
deadline_from_timeout(Invalid) ->
    {invalid_timeout, Invalid}.

valid_options(Deadline, Retention, Notify, Owner, CancelOnOwnerDown) ->
    (Deadline =:= infinity orelse is_integer(Deadline))
    andalso is_integer(Retention) andalso Retention >= 0
    andalso (Notify =:= undefined orelse is_pid(Notify))
    andalso (Owner =:= undefined orelse is_pid(Owner))
    andalso is_boolean(CancelOnOwnerDown)
    andalso (CancelOnOwnerDown =:= false orelse is_pid(Owner)).

validate_work(Work) when is_function(Work, 0) ->
    ok;
validate_work({Module, Function, Args})
  when is_atom(Module), is_atom(Function), is_list(Args) ->
    ok;
validate_work(Work) ->
    {error, {invalid_task_work, Work}}.

call_task(TaskRef, Request, Timeout) when is_binary(TaskRef) ->
    try adk_task_registry:lookup(TaskRef) of
        {ok, Pid} -> safe_call(Pid, Request, Timeout);
        {error, not_found} = Error -> Error
    catch
        exit:{noproc, _} -> {error, task_registry_not_started};
        exit:Reason ->
            {error, adk_failure:external(adk_task, registry_lookup, Reason)}
    end;
call_task(TaskRef, _Request, _Timeout) ->
    {error, {invalid_task_ref, TaskRef}}.

safe_call(Pid, Request, Timeout) ->
    try gen_statem:call(Pid, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, not_found};
        exit:{normal, _} -> {error, not_found};
        exit:{shutdown, _} -> {error, not_found};
        exit:Reason ->
            {error, adk_failure:external(adk_task, call, Reason)}
    end.

generate_task_ref() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    list_to_binary(
      io_lib:format(
        "task-~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C band 16#0fff,
         D band 16#3fff bor 16#8000, E])).
