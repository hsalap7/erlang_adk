%% @private Deadline-bounded resolution of an opaque GCS credential handle.
-module(adk_artifact_gcs_credential).

-export([resolve/2, validate_handle/1]).

-define(MAX_TOKEN_BYTES, 16384).
-define(MAX_HEAP_WORDS, 262144).

-spec validate_handle(term()) -> ok | {error, invalid_credential_handle}.
validate_handle({Module, _Handle}) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, access_token, 1) of
                true -> ok;
                false -> {error, invalid_credential_handle}
            end;
        _ -> {error, invalid_credential_handle}
    end;
validate_handle(_Handle) ->
    {error, invalid_credential_handle}.

-spec resolve({module(), term()}, integer()) ->
    {ok, binary()} | {error, credential_unavailable | timeout}.
resolve({Module, Handle} = Credential, Deadline) when is_integer(Deadline) ->
    case validate_handle(Credential) of
        ok -> resolve_worker(Module, Handle, Deadline);
        {error, _} -> {error, credential_unavailable}
    end;
resolve(_Credential, _Deadline) ->
    {error, credential_unavailable}.

resolve_worker(Module, Handle, Deadline) ->
    case remaining(Deadline) of
        0 -> {error, timeout};
        _ ->
            Owner = self(),
            Alias = erlang:alias([explicit_unalias]),
            Ref = make_ref(),
            Fun = fun() ->
                _ = start_owner_watchdog(Owner, self()),
                Result = acquire(Module, Handle),
                CompletedAt = erlang:monotonic_time(millisecond),
                _ = erlang:send(Alias,
                                {gcs_credential, Ref, self(), CompletedAt,
                                 Result},
                                [noconnect, nosuspend])
            end,
            Options = [monitor, {message_queue_data, off_heap},
                       {max_heap_size,
                        #{size => ?MAX_HEAP_WORDS, kill => true,
                          error_logger => false,
                          include_shared_binaries => true}}],
            try erlang:spawn_opt(Fun, Options) of
                {Pid, Monitor} ->
                    await(Pid, Monitor, Alias, Ref, Deadline)
            catch
                _:_ ->
                    _ = erlang:unalias(Alias),
                    {error, credential_unavailable}
            end
    end.

start_owner_watchdog(Owner, Worker) ->
    Watchdog = fun() ->
        OwnerMonitor = erlang:monitor(process, Owner),
        WorkerMonitor = erlang:monitor(process, Worker),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
                exit(Worker, kill),
                _ = erlang:demonitor(WorkerMonitor, [flush]);
            {'DOWN', WorkerMonitor, process, Worker, _Reason} ->
                _ = erlang:demonitor(OwnerMonitor, [flush])
        end
    end,
    try erlang:spawn_opt(
          Watchdog,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]) of
        Pid when is_pid(Pid) -> ok
    catch
        _:_ -> error
    end.

await(Pid, Monitor, Alias, Ref, Deadline) ->
    receive
        {gcs_credential, Ref, Pid, CompletedAt, Result} ->
            _ = erlang:unalias(Alias),
            _ = erlang:demonitor(Monitor, [flush]),
            case CompletedAt =< Deadline of
                true -> Result;
                false -> {error, timeout}
            end;
        {'DOWN', Monitor, process, Pid, _Reason} ->
            _ = erlang:unalias(Alias),
            {error, credential_unavailable}
    after remaining(Deadline) ->
        _ = erlang:unalias(Alias),
        exit(Pid, kill),
        _ = erlang:demonitor(Monitor, [flush]),
        {error, timeout}
    end.

acquire(Module, Handle) ->
    try Module:access_token(Handle) of
        {ok, Token} -> normalize(Token);
        _ -> {error, credential_unavailable}
    catch
        _:_ -> {error, credential_unavailable}
    end.

normalize(Token) when is_list(Token) ->
    try unicode:characters_to_binary(Token) of
        Binary -> normalize(Binary)
    catch
        _:_ -> {error, credential_unavailable}
    end;
normalize(Token)
  when is_binary(Token), byte_size(Token) > 0,
       byte_size(Token) =< ?MAX_TOKEN_BYTES ->
    case lists:any(fun(Byte) -> Byte < 33 orelse Byte =:= 127 end,
                   binary_to_list(Token)) of
        true -> {error, credential_unavailable};
        false -> {ok, Token}
    end;
normalize(_Token) ->
    {error, credential_unavailable}.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
