%% @doc Deadline-aware actor for one stateful plugin instance.
-module(adk_plugin_instance).
-behaviour(gen_server).

-export([start_link/1, invoke/5, status/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_MAX_QUEUE, 64).
-define(DEFAULT_MAX_HEAP_WORDS, 250000).
-define(DEFAULT_MAX_STATE_BYTES, 1048576).
-define(DEFAULT_INIT_TIMEOUT_MS, 1000).
-define(CALL_GUARD_MS, 250).
-define(MAX_ID_BYTES, 256).
-define(MAX_CONFIG_BYTES, 1048576).
-define(MAX_QUEUE, 4096).
-define(MAX_HEAP_WORDS, 10000000).
-define(MAX_STATE_BYTES, 67108864).
-define(MAX_INIT_TIMEOUT_MS, 30000).
-define(MAX_INVOKE_TIMEOUT_MS, 120000).

-record(state, {
    id,
    module,
    plugin_state,
    max_queue,
    max_heap_words,
    max_state_bytes,
    queue = queue:new(),
    current = undefined,
    generation = 0
}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Spec) -> gen_server:start_link(?MODULE, Spec, []).

-spec invoke(pid(), adk_plugin:hook(), map(), term(), pos_integer()) ->
    {ok, adk_plugin:result()} | {error, term()}.
invoke(Pid, Hook, Context, Value, Timeout)
  when is_pid(Pid), is_map(Context), is_integer(Timeout), Timeout > 0,
       Timeout =< ?MAX_INVOKE_TIMEOUT_MS ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    try gen_server:call(
          Pid, {invoke, self(), Hook, Context, Value, Deadline},
          Timeout + ?CALL_GUARD_MS) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, instance_unavailable};
        exit:{normal, _} -> {error, instance_stopped};
        exit:Reason -> {error, {instance_call_failed, reason_tag(Reason)}}
    end;
invoke(_Pid, _Hook, _Context, _Value, _Timeout) ->
    {error, invalid_plugin_instance_invocation}.

-spec status(pid()) -> {ok, map()} | {error, term()}.
status(Pid) when is_pid(Pid) ->
    try gen_server:call(Pid, status, 1000) of
        Reply -> Reply
    catch
        exit:_ -> {error, instance_unavailable}
    end;
status(_) -> {error, invalid_plugin_instance}.

-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) -> gen_server:stop(Pid);
stop(_) -> ok.

init(Spec) when is_map(Spec) ->
    process_flag(trap_exit, true),
    case validate_spec(Spec) of
        {ok, Id, Module, Config, MaxQueue, MaxHeap, MaxStateBytes,
         InitTimeout} ->
            case initialize_plugin(Module, Config, MaxStateBytes,
                                   MaxHeap, InitTimeout) of
                {ok, PluginState} ->
                    {ok, #state{id = Id,
                                module = Module,
                                plugin_state = PluginState,
                                max_queue = MaxQueue,
                                max_heap_words = MaxHeap,
                                max_state_bytes = MaxStateBytes}};
                {error, Reason} -> {stop, Reason}
            end;
        {error, Reason} -> {stop, Reason}
    end;
init(_) -> {stop, invalid_plugin_instance_spec}.

handle_call(status, _From, State) ->
    Reply = #{id => State#state.id,
              identity => pid,
              restart_policy => temporary,
              busy => State#state.current =/= undefined,
              queued => queue:len(State#state.queue),
              generation => State#state.generation,
              state_bytes => external_size(State#state.plugin_state)},
    {reply, {ok, Reply}, State};
handle_call({invoke, Owner, Hook, Context0, Value, Deadline}, From, State)
  when is_pid(Owner), is_integer(Deadline) ->
    case validate_invocation(Hook, Context0) of
        {ok, Context} ->
            OwnerMonitor = erlang:monitor(process, Owner),
            Entry = #{from => From, owner => Owner,
                      owner_monitor => OwnerMonitor,
                      hook => Hook, context => Context,
                      value => Value, deadline => Deadline},
            enqueue_or_start(Entry, State);
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_plugin_instance_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({plugin_instance_complete, Generation, Worker,
             CompletedAt, Outcome},
            State = #state{current =
                               #{generation := Generation,
                                 worker := Worker} = Current}) ->
    finish_current(CompletedAt, Outcome, Current, State);
handle_info({plugin_instance_timeout, Generation},
            State = #state{current =
                               #{generation := Generation} = Current}) ->
    %% Prefer an already-delivered completion and use its worker timestamp.
    ExpectedWorker = maps:get(worker, Current),
    receive
        {plugin_instance_complete, Generation,
         Worker, CompletedAt, Outcome}
          when Worker =:= ExpectedWorker ->
            finish_current(CompletedAt, Outcome, Current, State)
    after 0 ->
        cancel_current(timeout, Current, State)
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason},
            State = #state{current = Current}) when is_map(Current) ->
    case {Monitor =:= maps:get(owner_monitor, Current),
          Monitor =:= maps:get(worker_monitor, Current)} of
        {true, _} -> cancel_current(owner_down, Current, State);
        {_, true} -> cancel_current(worker_down, Current, State);
        _ -> remove_queued_owner(Monitor, State)
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    remove_queued_owner(Monitor, State);
handle_info({'EXIT', _Pid, _Reason}, State) -> {noreply, State};
handle_info(_Message, State) -> {noreply, State}.

terminate(Reason, State) ->
    maybe_kill_current(State#state.current),
    fail_queue(State#state.queue, instance_stopped),
    Module = State#state.module,
    case erlang:function_exported(Module, terminate, 2) of
        true -> _ = catch Module:terminate(Reason, State#state.plugin_state);
        false -> ok
    end,
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

enqueue_or_start(Entry, State = #state{current = undefined}) ->
    {noreply, start_entry(Entry, State)};
enqueue_or_start(Entry, State) ->
    case queue:len(State#state.queue) < State#state.max_queue of
        true ->
            {noreply, State#state{queue =
                                      queue:in(Entry, State#state.queue)}};
        false ->
            _ = erlang:demonitor(
                  maps:get(owner_monitor, Entry), [flush]),
            {reply, {error, queue_full}, State}
    end.

start_entry(Entry, State) ->
    Now = erlang:monotonic_time(millisecond),
    Owner = maps:get(owner, Entry),
    Deadline = maps:get(deadline, Entry),
    case is_process_alive(Owner) andalso Deadline > Now of
        false ->
            _ = erlang:demonitor(
                  maps:get(owner_monitor, Entry), [flush]),
            gen_server:reply(maps:get(from, Entry), {error, timeout}),
            advance(State);
        true ->
            Generation = State#state.generation + 1,
            Server = self(),
            Module = State#state.module,
            Hook = maps:get(hook, Entry),
            Context = maps:get(context, Entry),
            Value = maps:get(value, Entry),
            PluginState = State#state.plugin_state,
            WorkerFun = fun() ->
                Outcome = try Module:handle_hook(
                                Hook, Context, Value, PluginState) of
                    CallbackOutcome -> CallbackOutcome
                catch
                    _Class:_Reason -> {worker_failure, exception}
                end,
                Server ! {plugin_instance_complete, Generation, self(),
                          erlang:monotonic_time(millisecond), Outcome}
            end,
            SpawnOpts = [monitor, {message_queue_data, off_heap},
                         {max_heap_size,
                          #{size => State#state.max_heap_words,
                            kill => true,
                            error_logger => false,
                            include_shared_binaries => true}}],
            {Worker, WorkerMonitor} = spawn_opt(WorkerFun, SpawnOpts),
            Timer = erlang:send_after(
                      erlang:max(1, Deadline - Now), self(),
                      {plugin_instance_timeout, Generation}),
            Current = Entry#{generation => Generation,
                             worker => Worker,
                             worker_monitor => WorkerMonitor,
                             timer => Timer},
            State#state{current = Current,
                        generation = Generation}
    end.

finish_current(CompletedAt, Outcome, Current, State) ->
    Deadline = maps:get(deadline, Current),
    %% Completion and an owner-monitor DOWN originate from different processes
    %% and can therefore be dequeued in either order. Keep the owner monitor
    %% armed through result/state validation and check again at the commit
    %% point; a large state validation cannot open a commit-after-death window.
    case {CompletedAt =< Deadline, owner_alive_for_commit(Current)} of
        {_, false} ->
            cleanup_current(Current, false),
            {noreply, advance(State#state{current = undefined})};
        {false, true} ->
            cleanup_current(Current, false),
            reply_if_alive(Current, {error, timeout}),
            {noreply, advance(State#state{current = undefined})};
        {true, true} ->
            finish_current_outcome(
              Outcome, Current, State#state{current = undefined})
    end.

owner_alive_for_commit(Current) ->
    Monitor = maps:get(owner_monitor, Current),
    Owner = maps:get(owner, Current),
    receive
        {'DOWN', Monitor, process, Owner, _Reason} -> false
    after 0 ->
        is_process_alive(Owner)
    end.

finish_current_outcome({ok, Result, NewPluginState}, Current, State) ->
    case bounded_state(NewPluginState, State#state.max_state_bytes) of
        true ->
            commit_if_owner_alive(
              Result, NewPluginState, Current, State);
        false ->
            cleanup_current(Current, false),
            reply_if_alive(Current, {error, state_too_large}),
            {noreply, advance(State)}
    end;
finish_current_outcome({stop, Reason, NewPluginState}, Current, State) ->
    NextState = case bounded_state(
                         NewPluginState, State#state.max_state_bytes) of
        true -> State#state{plugin_state = NewPluginState};
        false -> State
    end,
    case owner_alive_for_commit(Current) of
        true ->
            cleanup_current(Current, false),
            case is_process_alive(maps:get(owner, Current)) of
                false ->
                    {noreply, advance(State)};
                true ->
                    reply_if_alive(
                      Current, {error,
                                {plugin_stopped, reason_tag(Reason)}}),
                    fail_queue(NextState#state.queue, instance_stopped),
                    {stop, normal,
                     NextState#state{queue = queue:new()}}
            end;
        false ->
            cleanup_current(Current, false),
            {noreply, advance(State)}
    end;
finish_current_outcome({worker_failure, Failure}, Current, State) ->
    cleanup_current(Current, false),
    reply_if_alive(Current, {error, Failure}),
    {noreply, advance(State)};
finish_current_outcome(_Invalid, Current, State) ->
    cleanup_current(Current, false),
    reply_if_alive(Current, {error, invalid_stateful_plugin_result}),
    {noreply, advance(State)}.

commit_if_owner_alive(Result, NewPluginState, Current, State) ->
    case owner_alive_for_commit(Current) of
        false ->
            cleanup_current(Current, false),
            {noreply, advance(State)};
        true ->
            cleanup_current(Current, false),
            %% A final scheduler-local liveness check closes the interval
            %% introduced by timer/monitor cleanup before the state swap.
            case is_process_alive(maps:get(owner, Current)) of
                false -> {noreply, advance(State)};
                true ->
                    gen_server:reply(maps:get(from, Current), {ok, Result}),
                    {noreply, advance(
                                State#state{plugin_state = NewPluginState})}
            end
    end.

cancel_current(Reason, Current, State) ->
    cleanup_current(Current, true),
    case Reason of
        owner_down -> ok;
        _ -> reply_if_alive(Current, {error, Reason})
    end,
    {noreply, advance(State#state{current = undefined})}.

cleanup_current(Current, KillWorker) ->
    _ = erlang:cancel_timer(maps:get(timer, Current)),
    _ = erlang:demonitor(maps:get(owner_monitor, Current), [flush]),
    _ = erlang:demonitor(maps:get(worker_monitor, Current), [flush]),
    case KillWorker of
        true -> exit(maps:get(worker, Current), kill);
        false -> ok
    end.

advance(State = #state{queue = Queue}) ->
    case queue:out(Queue) of
        {{value, Entry}, Rest} ->
            start_entry(Entry, State#state{queue = Rest});
        {empty, _} -> State
    end.

remove_queued_owner(Monitor, State) ->
    Entries = queue:to_list(State#state.queue),
    {Removed, Kept} = lists:partition(
                        fun(Entry) ->
                            maps:get(owner_monitor, Entry) =:= Monitor
                        end, Entries),
    case Removed of
        [] -> {noreply, State};
        _ -> {noreply, State#state{queue = queue:from_list(Kept)}}
    end.

reply_if_alive(Current, Reply) ->
    case is_process_alive(maps:get(owner, Current)) of
        true -> gen_server:reply(maps:get(from, Current), Reply);
        false -> ok
    end.

maybe_kill_current(undefined) -> ok;
maybe_kill_current(Current) -> cleanup_current(Current, true).

fail_queue(Queue, Reason) ->
    lists:foreach(
      fun(Entry) ->
          _ = erlang:demonitor(maps:get(owner_monitor, Entry), [flush]),
          reply_if_alive(Entry, {error, Reason})
      end, queue:to_list(Queue)).

validate_spec(Spec) ->
    Allowed = [id, module, config, max_queue, max_heap_words,
               max_state_bytes, init_timeout_ms],
    KnownCount = length([Key || Key <- Allowed, maps:is_key(Key, Spec)]),
    UnknownCount = map_size(Spec) - KnownCount,
    Id = maps:get(id, Spec, undefined),
    Module = maps:get(module, Spec, undefined),
    Config = maps:get(config, Spec, #{}),
    MaxQueue = maps:get(max_queue, Spec, ?DEFAULT_MAX_QUEUE),
    MaxHeap = maps:get(max_heap_words, Spec, ?DEFAULT_MAX_HEAP_WORDS),
    MaxStateBytes = maps:get(max_state_bytes, Spec,
                             ?DEFAULT_MAX_STATE_BYTES),
    InitTimeout = maps:get(init_timeout_ms, Spec,
                           ?DEFAULT_INIT_TIMEOUT_MS),
    case UnknownCount =:= 0 andalso
         is_binary(Id) andalso byte_size(Id) > 0 andalso
         byte_size(Id) =< ?MAX_ID_BYTES andalso
         is_atom(Module) andalso valid_config(Config) andalso
         is_integer(MaxQueue) andalso MaxQueue >= 0 andalso
         MaxQueue =< ?MAX_QUEUE andalso
         is_integer(MaxHeap) andalso MaxHeap >= 1000 andalso
         MaxHeap =< ?MAX_HEAP_WORDS andalso
         is_integer(MaxStateBytes) andalso MaxStateBytes > 0 andalso
         MaxStateBytes =< ?MAX_STATE_BYTES andalso
         is_integer(InitTimeout) andalso InitTimeout > 0 andalso
         InitTimeout =< ?MAX_INIT_TIMEOUT_MS of
        true -> validate_stateful_module(
                  Id, Module, Config, MaxQueue,
                  MaxHeap, MaxStateBytes, InitTimeout);
        false -> {error, invalid_plugin_instance_spec}
    end.

validate_stateful_module(Id, Module, Config, MaxQueue,
                         MaxHeap, MaxStateBytes, InitTimeout) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, init, 1) andalso
                 erlang:function_exported(Module, handle_hook, 4) of
                true -> {ok, Id, Module, Config, MaxQueue,
                         MaxHeap, MaxStateBytes, InitTimeout};
                false -> {error, invalid_stateful_plugin_module}
            end;
        {error, _} -> {error, stateful_plugin_module_unavailable}
    end.

initialize_plugin(Module, Config, MaxStateBytes, MaxHeap, Timeout) ->
    Alias = erlang:alias([reply]),
    WorkerFun = fun() ->
        Result = try Module:init(Config) of
            {ok, PluginState} ->
                case bounded_state(PluginState, MaxStateBytes) of
                    true -> {ok, PluginState};
                    false -> {error, initial_state_too_large}
                end;
            {stop, Reason} ->
                {error, {plugin_init_stopped, reason_tag(Reason)}};
            _ -> {error, invalid_stateful_plugin_init_result}
        catch
            _Class:_Reason -> {error, stateful_plugin_init_failed}
        end,
        Alias ! {plugin_instance_init, Alias, self(), Result}
    end,
    {Pid, Monitor} = spawn_opt(
                       WorkerFun,
                       [link, monitor, {message_queue_data, off_heap},
                        {max_heap_size,
                         #{size => MaxHeap, kill => true,
                           error_logger => false,
                           include_shared_binaries => true}}]),
    receive
        {plugin_instance_init, Alias, Pid, Result} ->
            _ = erlang:unalias(Alias),
            unlink(Pid),
            erlang:demonitor(Monitor, [flush]),
            flush_exit(Pid),
            Result;
        {'DOWN', Monitor, process, Pid, _Reason} ->
            _ = erlang:unalias(Alias),
            unlink(Pid),
            flush_exit(Pid),
            {error, stateful_plugin_init_worker_down}
    after Timeout ->
        _ = erlang:unalias(Alias),
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 100 -> erlang:demonitor(Monitor, [flush])
        end,
        unlink(Pid),
        flush_exit(Pid),
        {error, stateful_plugin_init_timeout}
    end.

flush_exit(Pid) ->
    receive {'EXIT', Pid, _} -> ok after 0 -> ok end.

validate_invocation(Hook, Context) ->
    case adk_plugin:is_hook(Hook) of
        false -> {error, unknown_plugin_hook};
        true ->
            case adk_context_guard:sanitize_value(Context) of
                {ok, SafeContext} when is_map(SafeContext) ->
                    {ok, SafeContext};
                _ -> {error, invalid_plugin_context}
            end
    end.

bounded_state(State, MaxBytes) ->
    case safe_external_size(State) of
        {ok, Size} -> Size =< MaxBytes;
        error -> false
    end.

valid_config(Config) when is_map(Config) ->
    case safe_external_size(Config) of
        {ok, Size} -> Size =< ?MAX_CONFIG_BYTES;
        error -> false
    end;
valid_config(_Config) -> false.

external_size(Term) ->
    case safe_external_size(Term) of
        {ok, Size} -> Size;
        error -> -1
    end.

safe_external_size(Term) ->
    try erlang:external_size(Term) of
        Size -> {ok, Size}
    catch
        _:_ -> error
    end.

reason_tag({Tag, _}) when is_atom(Tag) -> Tag;
reason_tag({Tag, _, _}) when is_atom(Tag) -> Tag;
reason_tag(Tag) when is_atom(Tag) -> Tag;
reason_tag(_) -> external_failure.
