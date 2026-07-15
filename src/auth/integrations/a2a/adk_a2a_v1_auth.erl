%% @doc Authentication/authorization boundary for the A2A 1.0 server.
%%
%% Hooks receive the operation, raw request headers, and a bounded request
%% summary. They must return a stable principal id separately from the
%% principal passed to the executor. Only a SHA-256 scope is retained by the
%% task store; raw headers, credentials, and the principal are never retained
%% in A2A task or event data.
-module(adk_a2a_v1_auth).

-export([authorize/4, authorize/5, scope/1]).

-define(DEFAULT_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_HEAP_WORDS, 300000).
-define(MAX_TIMEOUT_MS, 30000).
-define(MAX_HEAP_WORDS, 2000000).
-define(MAX_RESULT_BYTES, 1048576).
-define(WATCHDOG_MAX_HEAP_WORDS, 8192).
-define(WORKER_DOWN_TIMEOUT_MS, 100).

-callback authorize(binary(), map(), map()) ->
    {ok, term(), binary()}
    | {error, unauthenticated | forbidden}.

-spec authorize(none | module() | fun((binary(), map(), map()) -> term()),
                binary(), map(), map()) ->
    {ok, map()} | {error, unauthenticated | forbidden}.
authorize(none, _Operation, Headers, _Summary) ->
    auth_context(#{<<"subject">> => <<"anonymous">>},
                 <<"anonymous">>, Headers);
authorize(Hook, Operation, Headers, Summary)
  when is_atom(Hook); is_function(Hook, 3) ->
    authorize(Hook, Operation, Headers, Summary, #{});
authorize(_, _Operation, _Headers, _Summary) ->
    {error, unauthenticated}.

-spec authorize(none | module() | fun((binary(), map(), map()) -> term()),
                binary(), map(), map(), map()) ->
    {ok, map()} | {error, unauthenticated | forbidden}.
authorize(none, _Operation, Headers, _Summary, _Options) ->
    auth_context(#{<<"subject">> => <<"anonymous">>},
                 <<"anonymous">>, Headers);
authorize(Hook, Operation, Headers, Summary, Options)
  when (is_atom(Hook) orelse is_function(Hook, 3)), is_map(Options) ->
    Timeout = maps:get(timeout_ms, Options, ?DEFAULT_TIMEOUT_MS),
    MaxHeap = maps:get(max_heap_words, Options, ?DEFAULT_MAX_HEAP_WORDS),
    case valid_worker_options(Timeout, MaxHeap) of
        true ->
            invoke_isolated(Hook, Operation, Headers, Summary,
                            Timeout, MaxHeap);
        false ->
            {error, unauthenticated}
    end;
authorize(_, _Operation, _Headers, _Summary, _Options) ->
    {error, unauthenticated}.

-spec scope(binary()) -> binary().
scope(PrincipalId) when is_binary(PrincipalId) ->
    crypto:hash(sha256, PrincipalId).

invoke(Hook, Operation, Headers, Summary) when is_atom(Hook) ->
    Hook:authorize(Operation, Headers, Summary);
invoke(Hook, Operation, Headers, Summary) ->
    Hook(Operation, Headers, Summary).

invoke_isolated(Hook, Operation, Headers, Summary, Timeout, MaxHeap) ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Ref = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Worker = fun() ->
        case start_owner_watchdog(Owner, self(), Deadline) of
            ok ->
                Result = try invoke(Hook, Operation, Headers, Summary) of
                    Value -> Value
                catch
                    _:_ -> {error, unauthenticated}
                end,
                SafeResult = normalize_isolated_result(Result, Headers),
                CompletedAt = erlang:monotonic_time(millisecond),
                _ = erlang:send(
                      ReplyAlias,
                      {a2a_server_auth_result, Ref, self(), CompletedAt,
                       SafeResult},
                      [noconnect, nosuspend]),
                ok;
            error ->
                ok
        end
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => MaxHeap, kill => true, error_logger => false,
            include_shared_binaries => true}}],
    try erlang:spawn_opt(Worker, SpawnOptions) of
        {Pid, Monitor} ->
            await_isolated(Pid, Monitor, ReplyAlias, Ref, Deadline)
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            {error, unauthenticated}
    end.

await_isolated(Pid, Monitor, ReplyAlias, Ref, Deadline) ->
    receive
        {a2a_server_auth_result, Ref, Pid, CompletedAt, Result}
          when CompletedAt =< Deadline ->
            worker_complete(ReplyAlias, Monitor),
            Result;
        {a2a_server_auth_result, Ref, Pid, _CompletedAt, _LateResult} ->
            stop_worker(Pid, Monitor, ReplyAlias),
            {error, unauthenticated};
        {'DOWN', Monitor, process, Pid, _OpaqueReason} ->
            _ = erlang:unalias(ReplyAlias),
            {error, unauthenticated}
    after remaining(Deadline) ->
        stop_worker(Pid, Monitor, ReplyAlias),
        {error, unauthenticated}
    end.

worker_complete(ReplyAlias, Monitor) ->
    _ = erlang:unalias(ReplyAlias),
    _ = erlang:demonitor(Monitor, [flush]),
    ok.

stop_worker(Pid, Monitor, ReplyAlias) ->
    _ = erlang:unalias(ReplyAlias),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _OpaqueReason} -> ok
    after ?WORKER_DOWN_TIMEOUT_MS ->
        _ = erlang:demonitor(Monitor, [flush]),
        ok
    end.

start_owner_watchdog(Owner, Worker, Deadline) ->
    Watchdog = fun() -> owner_watchdog(Owner, Worker, Deadline) end,
    SpawnOptions =
        [{message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?WATCHDOG_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try erlang:spawn_opt(Watchdog, SpawnOptions) of
        Pid when is_pid(Pid) -> ok
    catch
        _:_ -> error
    end.

owner_watchdog(Owner, Worker, Deadline) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, Worker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(Worker, kill),
            _ = erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', WorkerMonitor, process, Worker, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    after remaining(Deadline) ->
        exit(Worker, kill),
        _ = erlang:demonitor(OwnerMonitor, [flush]),
        _ = erlang:demonitor(WorkerMonitor, [flush]),
        ok
    end.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

normalize_isolated_result(Result, Headers) ->
    case bounded_result(Result) of
        false -> {error, unauthenticated};
        true ->
            Normalized = normalize_result(Result, Headers),
            case bounded_result(Normalized) of
                true -> Normalized;
                false -> {error, unauthenticated}
            end
    end.

valid_worker_options(Timeout, MaxHeap) ->
    is_integer(Timeout) andalso Timeout > 0 andalso
    Timeout =< ?MAX_TIMEOUT_MS andalso
    is_integer(MaxHeap) andalso MaxHeap >= 1000 andalso
    MaxHeap =< ?MAX_HEAP_WORDS.

bounded_result(Result) ->
    try erlang:external_size(Result) =< ?MAX_RESULT_BYTES
    catch _:_ -> false
    end.

normalize_result({ok, Principal, PrincipalId}, Headers)
  when is_binary(PrincipalId), byte_size(PrincipalId) > 0,
       byte_size(PrincipalId) =< 512 ->
    auth_context(Principal, PrincipalId, Headers);
normalize_result({error, unauthenticated}, _Headers) ->
    {error, unauthenticated};
normalize_result({error, forbidden}, _Headers) ->
    {error, forbidden};
normalize_result(_, _Headers) ->
    {error, unauthenticated}.

auth_context(Principal, PrincipalId, Headers) ->
    {ok, #{principal => Principal,
           scope => scope(PrincipalId),
           secret_seeds => credential_seeds(Headers)}}.

credential_seeds(Headers) when is_map(Headers) ->
    lists:usort(
      lists:flatmap(
        fun({Name, Value}) ->
            case sensitive_header(lower(to_binary(Name))) of
                true -> header_seeds(to_binary(Value));
                false -> []
            end
        end, maps:to_list(Headers)));
credential_seeds(_) -> [].

header_seeds(<<>>) -> [];
header_seeds(Value) ->
    case binary:split(Value, <<" ">>, [global]) of
        [_Scheme, Credential] when byte_size(Credential) > 0 ->
            [Value, Credential];
        _ -> [Value]
    end.

sensitive_header(<<"authorization">>) -> true;
sensitive_header(<<"proxy-authorization">>) -> true;
sensitive_header(<<"cookie">>) -> true;
sensitive_header(<<"x-api-key">>) -> true;
sensitive_header(_) -> false.

lower(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.
