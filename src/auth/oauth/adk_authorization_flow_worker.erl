%% @doc Secret-isolating worker for one claimed authorization callback.
-module(adk_authorization_flow_worker).

-behaviour(gen_server).

-export([start_link/2, start_link/4, perform/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {
    manager :: pid(),
    generation :: reference(),
    manager_monitor :: reference(),
    deadline_ms :: integer(),
    max_heap_words :: pos_integer(),
    exchange_pid = undefined :: undefined | pid(),
    exchange_monitor = undefined :: undefined | reference(),
    exchange_ref = undefined :: undefined | reference(),
    reply_alias = undefined :: undefined | reference(),
    deadline_timer = undefined :: undefined | reference()
}).

-spec start_link(pid(), reference()) -> gen_server:start_ret().
start_link(Manager, Generation)
  when is_pid(Manager), is_reference(Generation) ->
    start_link(Manager, Generation,
               erlang:monotonic_time(millisecond) + 30000, 262144).

-spec start_link(pid(), reference(), integer(), pos_integer()) ->
    gen_server:start_ret().
start_link(Manager, Generation, Deadline, MaxHeapWords)
  when is_pid(Manager), is_reference(Generation), is_integer(Deadline),
       is_integer(MaxHeapWords), MaxHeapWords >= 16384,
       MaxHeapWords =< 4000000 ->
    gen_server:start_link(
      ?MODULE, {Manager, Generation, Deadline, MaxHeapWords}, []).

-spec perform(pid(), map()) -> ok.
perform(Worker, Work) when is_pid(Worker), is_map(Work) ->
    gen_server:cast(Worker, {perform, Work}).

init({Manager, Generation, Deadline, MaxHeapWords}) ->
    Monitor = erlang:monitor(process, Manager),
    {ok, #state{manager = Manager,
                generation = Generation,
                manager_monitor = Monitor,
                deadline_ms = Deadline,
                max_heap_words = MaxHeapWords}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast({perform, Work}, State = #state{exchange_pid = undefined}) ->
    {noreply, start_exchange(Work, State)};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({authorization_exchange_callback, ExchangeRef, ExchangePid,
             CompletedAt, Result},
            State = #state{manager = Manager,
                           generation = Generation,
                           deadline_ms = Deadline,
                           exchange_pid = ExchangePid,
                           exchange_ref = ExchangeRef}) ->
    SafeResult = case CompletedAt =< Deadline of
        true -> Result;
        false -> {error, authorization_timeout}
    end,
    State1 = clear_exchange(State, false),
    Manager ! {authorization_exchange_result, Generation, self(), SafeResult},
    {stop, normal, State1};
handle_info({authorization_exchange_deadline, ExchangeRef, ExchangePid},
            State = #state{manager = Manager,
                           generation = Generation,
                           exchange_pid = ExchangePid,
                           exchange_ref = ExchangeRef}) ->
    State1 = clear_exchange(State, true),
    Manager ! {authorization_exchange_result, Generation, self(),
               {error, authorization_timeout}},
    {stop, normal, State1};
handle_info({'DOWN', Monitor, process, ExchangePid, _OpaqueReason},
            State = #state{manager = Manager,
                           generation = Generation,
                           exchange_pid = ExchangePid,
                           exchange_monitor = Monitor}) ->
    State1 = clear_exchange(State, false),
    Manager ! {authorization_exchange_result, Generation, self(),
               {error, authorization_failed}},
    {stop, normal, State1};
handle_info({'DOWN', Monitor, process, _Manager, _OpaqueReason},
            State = #state{manager_monitor = Monitor}) ->
    {stop, normal, clear_exchange(State, true)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = clear_exchange(State, true),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, #state{manager = Manager,
                        generation = Generation,
                        exchange_pid = ExchangePid}) ->
              #{manager => Manager,
                generation => Generation,
                exchange_running => is_pid(ExchangePid)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

start_exchange(Work, State = #state{deadline_ms = Deadline,
                                    max_heap_words = MaxHeapWords}) ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    ExchangeRef = make_ref(),
    Callback = fun() ->
        start_owner_watchdog(Owner, self()),
        Result = perform_exchange(Work),
        CompletedAt = erlang:monotonic_time(millisecond),
        _ = erlang:send(
              ReplyAlias,
              {authorization_exchange_callback, ExchangeRef, self(),
               CompletedAt, Result},
              [noconnect, nosuspend]),
        ok
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => MaxHeapWords, kill => true, error_logger => false,
            include_shared_binaries => true}}],
    {ExchangePid, ExchangeMonitor} = spawn_opt(Callback, SpawnOptions),
    Remaining = erlang:max(
                  0, Deadline - erlang:monotonic_time(millisecond)),
    Timer = erlang:send_after(
              Remaining, self(),
              {authorization_exchange_deadline, ExchangeRef, ExchangePid}),
    State#state{exchange_pid = ExchangePid,
                exchange_monitor = ExchangeMonitor,
                exchange_ref = ExchangeRef,
                reply_alias = ReplyAlias,
                deadline_timer = Timer}.

perform_exchange(#{adapter_module := Adapter,
                   adapter_context := AdapterContext,
                   code := Code,
                   exchange_opts := ExchangeOpts,
                   store_module := StoreModule,
                   store_handle := StoreHandle,
                   principal := Principal,
                   provider := Provider,
                   flow_ref := FlowRef,
                   pending_credential := Pending}) ->
    Result = safe_exchange(Adapter, AdapterContext, Code, ExchangeOpts),
    case Result of
        {ok, Credential} ->
            store_validated_credential(
              StoreModule, StoreHandle, Principal, Provider, FlowRef,
              Pending, Credential);
        {error, _} ->
            {error, authorization_failed}
    end;
perform_exchange(_Work) ->
    {error, authorization_failed}.

safe_exchange(Adapter, AdapterContext, Code, ExchangeOpts) ->
    try Adapter:exchange_code(AdapterContext, Code, ExchangeOpts) of
        {ok, Credential} when is_map(Credential) ->
            case valid_refresh_credential(Credential, ExchangeOpts) of
                true -> {ok, Credential};
                false -> {error, authorization_failed}
            end;
        {error, _Reason} -> {error, authorization_failed};
        _Other -> {error, authorization_failed}
    catch
        _:_ -> {error, authorization_failed}
    end.

valid_refresh_credential(
  #{kind := oauth_refresh_token,
    client_id := ClientId,
    client_secret := ClientSecret,
    refresh_token := RefreshToken,
    expected_subject := ExpectedSubject} = Credential,
  _ExchangeOpts) ->
    lists:sort(maps:keys(Credential)) =:=
        lists:sort([kind, client_id, client_secret, refresh_token,
                    expected_subject]) andalso
    valid_binary(ClientId, 4096) andalso
    valid_binary(ClientSecret, 16384) andalso
    valid_binary(RefreshToken, 65536) andalso
    valid_binary(ExpectedSubject, 4096) andalso
    safe_external_size(Credential) =< 131072;
valid_refresh_credential(_Credential, _ExchangeOpts) ->
    false.

store_validated_credential(StoreModule, StoreHandle, Principal, Provider,
                           FlowRef, Pending, Credential) ->
    try StoreModule:compare_and_swap(
          StoreHandle, Principal, Provider, FlowRef, Pending, Credential) of
        ok -> {ok, FlowRef};
        {error, conflict} -> {error, authorization_failed};
        {error, not_found} -> {error, authorization_failed};
        {error, _Reason} -> {error, credential_store_unavailable};
        _Other -> {error, credential_store_unavailable}
    catch
        _:_ -> {error, credential_store_unavailable}
    end.

clear_exchange(State = #state{exchange_pid = ExchangePid,
                              exchange_monitor = ExchangeMonitor,
                              reply_alias = ReplyAlias,
                              deadline_timer = Timer}, Kill) ->
    cancel_timer(Timer),
    safe_unalias(ReplyAlias),
    case Kill andalso is_pid(ExchangePid) of
        true -> exit(ExchangePid, kill);
        false -> ok
    end,
    safe_demonitor(ExchangeMonitor),
    State#state{exchange_pid = undefined,
                exchange_monitor = undefined,
                exchange_ref = undefined,
                reply_alias = undefined,
                deadline_timer = undefined}.

start_owner_watchdog(Owner, Callback) ->
    _ = spawn_opt(
          fun() -> owner_watchdog(Owner, Callback) end,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]),
    ok.

owner_watchdog(Owner, Callback) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    CallbackMonitor = erlang:monitor(process, Callback),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(Callback, kill),
            _ = erlang:demonitor(CallbackMonitor, [flush]),
            ok;
        {'DOWN', CallbackMonitor, process, Callback, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

valid_binary(Value, Max) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Max;
valid_binary(_, _) -> false.

safe_external_size(Term) ->
    try erlang:external_size(Term) catch _:_ -> 131073 end.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

safe_unalias(undefined) -> ok;
safe_unalias(Alias) ->
    _ = erlang:unalias(Alias),
    ok.

safe_demonitor(undefined) -> ok;
safe_demonitor(Monitor) ->
    _ = erlang:demonitor(Monitor, [flush]),
    ok.
