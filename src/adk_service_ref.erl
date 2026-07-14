%% @doc Validation and bounded invocation for optional ADK services.
-module(adk_service_ref).

-export([validate/2, call/4]).

-type kind() :: memory | artifact.
-type service_ref() :: {module(), term()}.
-export_type([kind/0, service_ref/0]).

-spec validate(kind(), undefined | term()) ->
    {ok, undefined | service_ref()} | {error, term()}.
validate(_Kind, undefined) ->
    {ok, undefined};
validate(Kind, {Module, Handle}) when is_atom(Module), Handle =/= undefined ->
    case required_callbacks(Kind) of
        {ok, Callbacks} -> validate_module(Module, Handle, Callbacks);
        error -> {error, {unknown_service_kind, Kind}}
    end;
validate(Kind, _Other) ->
    {error, {invalid_service_ref, Kind, expected_module_handle_tuple}}.

%% @doc Invoke a service callback in an isolated lightweight process.
%% The service handle is prepended to Args. Exceptions, exits, and timeouts are
%% converted to values so a third-party adapter cannot crash or indefinitely
%% block an invocation process.
-spec call(service_ref(), atom(), [term()], pos_integer()) -> term().
call({Module, Handle}, Function, Args, Timeout)
  when is_atom(Module), is_atom(Function), is_list(Args),
       is_integer(Timeout), Timeout > 0 ->
    Caller = self(),
    Ref = make_ref(),
    {Coordinator, Monitor} = spawn_monitor(
                               fun() ->
                                   service_call_coordinator(
                                     Caller, Ref, Module, Handle,
                                     Function, Args, Timeout)
                               end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Coordinator, Reason} ->
            flush_service_reply(Ref),
            {error, {service_coordinator_down, Reason}}
    after Timeout + 100 ->
        %% The coordinator enforces the actual deadline. This outer guard only
        %% handles an implementation bug in the coordinator itself.
        exit(Coordinator, kill),
        receive
            {'DOWN', Monitor, process, Coordinator, _} -> ok
        after 100 ->
            erlang:demonitor(Monitor, [flush])
        end,
        flush_service_reply(Ref),
        {error, service_timeout}
    end;
call(_ServiceRef, _Function, _Args, Timeout) ->
    {error, {invalid_service_timeout, Timeout}}.

service_call_coordinator(Caller, Ref, Module, Handle,
                         Function, Args, Timeout) ->
    process_flag(trap_exit, true),
    CallerMonitor = erlang:monitor(process, Caller),
    Coordinator = self(),
    Worker = spawn_link(
               fun() ->
                   Reply = try apply(Module, Function, [Handle | Args]) of
                       Result -> Result
                   catch
                       Class:Reason ->
                           {error, {service_exception, Class, Reason}}
                   end,
                   Coordinator ! {service_result, self(), Reply}
               end),
    receive
        {service_result, Worker, Reply} ->
            unlink(Worker),
            erlang:demonitor(CallerMonitor, [flush]),
            Caller ! {Ref, Reply};
        {'EXIT', Worker, Reason} ->
            erlang:demonitor(CallerMonitor, [flush]),
            Caller ! {Ref, {error, {service_process_down, Reason}}};
        {'DOWN', CallerMonitor, process, Caller, _Reason} ->
            exit(Worker, kill),
            ok
    after Timeout ->
        exit(Worker, kill),
        receive {'EXIT', Worker, _} -> ok after 100 -> ok end,
        erlang:demonitor(CallerMonitor, [flush]),
        Caller ! {Ref, {error, service_timeout}}
    end.

required_callbacks(memory) ->
    {ok, [{add, 3}, {search, 4}, {delete, 2},
          {add_session_to_memory, 3}]};
required_callbacks(artifact) ->
    {ok, [{put, 5}, {get, 4}, {list, 2}, {delete, 4}]};
required_callbacks(_) ->
    error.

validate_module(Module, Handle, Callbacks) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Missing = [Callback || {Function, Arity} = Callback <- Callbacks,
                                    not erlang:function_exported(
                                          Module, Function, Arity)],
            case Missing of
                [] -> {ok, {Module, Handle}};
                _ -> {error, {missing_service_callbacks, Module, Missing}}
            end;
        {error, Reason} ->
            {error, {service_module_unavailable, Module, Reason}}
    end.

flush_service_reply(Ref) ->
    receive {Ref, _} -> ok after 0 -> ok end.
