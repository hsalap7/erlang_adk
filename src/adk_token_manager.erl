%% @doc Concurrent, scoped access-token cache and refresh coordinator.
%%
%% A request is keyed by principal, provider, credential reference, provider
%% module, scopes, and audience. Concurrent callers for the same key share one
%% supervised refresh. Access tokens and pending provider context are retained
%% only in owner-private ETS tables, never in inspectable gen_server state.
-module(adk_token_manager).

-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         get_token/2, get_token/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-type server() :: pid() | atom().
-type token_request() :: #{
    principal := adk_credential_store:principal(),
    provider := adk_credential_store:provider_id(),
    provider_module := module(),
    credential_ref := adk_credential_store:credential_ref(),
    scopes => [binary()],
    audience => undefined | binary(),
    context => map()
}.
-type token() :: #{access_token := binary(), token_type := binary()}.
-type error_reason() :: invalid_request | manager_unavailable |
                        caller_timeout | credential_not_found |
                        credential_store_unavailable |
                        credential_rotation_conflict |
                        credential_rotation_failed |
                        invalid_provider_response | refresh_timeout |
                        refresh_worker_failed | refresh_start_failed |
                        provider_process_failed | invalid_refresh_work |
                        {provider_error, term()} |
                        {provider_exception, atom(), term()}.

-export_type([server/0, token_request/0, token/0, error_reason/0]).

-define(DEFAULT_CALL_TIMEOUT_MS, 15000).
-define(DEFAULT_REFRESH_TIMEOUT_MS, 10000).
-define(DEFAULT_EXPIRY_SKEW_MS, 30000).

-record(state, {
    store_module :: module(),
    store_handle :: adk_credential_store:handle(),
    refresh_sup :: pid() | atom(),
    cache_table :: ets:tid(),
    pending_table :: ets:tid(),
    expiry_skew_ms :: non_neg_integer(),
    refresh_timeout_ms :: pos_integer(),
    now_fun :: fun(() -> integer()),
    inflight = #{} :: map(),
    generations = #{} :: map(),
    aliases = #{} :: map(),
    caller_monitors = #{} :: map(),
    worker_monitors = #{} :: map()
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, ?MODULE) of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, [])
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec get_token(server(), token_request()) ->
    {ok, token()} | {error, error_reason()}.
get_token(Server, Request) ->
    get_token(Server, Request, ?DEFAULT_CALL_TIMEOUT_MS).

%% @doc Resolve a cached token or join/start a refresh. The caller-side alias
%% is explicitly disabled on timeout, so a late token can never remain in the
%% caller's mailbox.
-spec get_token(server(), token_request(), pos_integer()) ->
    {ok, token()} | {error, error_reason()}.
get_token(Server, Request, Timeout)
  when (is_pid(Server) orelse is_atom(Server)), is_map(Request),
       is_integer(Timeout), Timeout > 0 ->
    Alias = erlang:alias([explicit_unalias]),
    ManagerMonitor = erlang:monitor(process, Server),
    case send_to_server(Server, {auth_get_token, self(), Alias, Request}) of
        ok ->
            await_reply(Server, Alias, ManagerMonitor, Timeout);
        error ->
            _ = erlang:unalias(Alias),
            _ = erlang:demonitor(ManagerMonitor, [flush]),
            {error, manager_unavailable}
    end;
get_token(_Server, _Request, _Timeout) ->
    {error, invalid_request}.

init(Opts) ->
    StoreModule = maps:get(store_module, Opts, adk_credential_store_ets),
    StoreHandle = maps:get(store_handle, Opts, adk_credential_store_ets),
    RefreshSup = maps:get(refresh_sup, Opts, adk_token_refresh_sup),
    Skew = maps:get(expiry_skew_ms, Opts, ?DEFAULT_EXPIRY_SKEW_MS),
    RefreshTimeout = maps:get(refresh_timeout_ms, Opts,
                              ?DEFAULT_REFRESH_TIMEOUT_MS),
    NowFun = maps:get(now_fun, Opts,
                      fun() -> erlang:monotonic_time(millisecond) end),
    ok = validate_options(StoreModule, StoreHandle, RefreshSup, Skew,
                          RefreshTimeout, NowFun),
    CacheTable = ets:new(adk_token_cache,
                         [set, private, {read_concurrency, true},
                          {write_concurrency, true}]),
    PendingTable = ets:new(adk_token_pending,
                           [set, private, {read_concurrency, true},
                            {write_concurrency, true}]),
    {ok, #state{store_module = StoreModule,
                store_handle = StoreHandle,
                refresh_sup = RefreshSup,
                cache_table = CacheTable,
                pending_table = PendingTable,
                expiry_skew_ms = Skew,
                refresh_timeout_ms = RefreshTimeout,
                now_fun = NowFun}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({auth_get_token, Caller, Alias, Request}, State)
  when is_pid(Caller), is_reference(Alias), is_map(Request) ->
    {noreply, handle_token_request(Caller, Alias, Request, State)};
handle_info({auth_cancel_token, Caller, Alias}, State)
  when is_pid(Caller), is_reference(Alias) ->
    {noreply, remove_waiter(Alias, Caller, State)};
handle_info({auth_refresh_ready, Generation, Worker}, State)
  when is_reference(Generation), is_pid(Worker) ->
    {noreply, dispatch_refresh(Generation, Worker, State)};
handle_info({auth_refresh_result, Generation, Worker, Result}, State)
  when is_reference(Generation), is_pid(Worker) ->
    {noreply, handle_refresh_result(Generation, Worker, Result, State)};
handle_info({auth_refresh_timeout, Generation}, State)
  when is_reference(Generation) ->
    {noreply, handle_refresh_timeout(Generation, State)};
handle_info({'DOWN', Monitor, process, _Object, _Reason}, State) ->
    {noreply, handle_monitor_down(Monitor, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
      fun(_Key, Flight) ->
          cancel_timer(maps:get(timer, Flight)),
          adk_token_refresh_sup:cancel_refresh(
            State#state.refresh_sup, maps:get(generation, Flight))
      end, State#state.inflight),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% The cache and pending-work tables are private, but the current gen_server
%% message may transiently contain a provider token or context. Return a
%% bounded operational summary and suppress messages/log history entirely.
format_status(Status) ->
    maps:map(
      fun(state, State = #state{}) ->
              #{store_module => State#state.store_module,
                store_handle => State#state.store_handle,
                refresh_sup => State#state.refresh_sup,
                cache_entries => safe_table_size(State#state.cache_table),
                pending_refreshes => map_size(State#state.inflight),
                expiry_skew_ms => State#state.expiry_skew_ms,
                refresh_timeout_ms => State#state.refresh_timeout_ms};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

safe_table_size(Table) ->
    case ets:info(Table, size) of
        Size when is_integer(Size) -> Size;
        undefined -> 0
    end.

await_reply(Server, Alias, ManagerMonitor, Timeout) ->
    receive
        {Alias, Reply} ->
            _ = erlang:unalias(Alias),
            _ = erlang:demonitor(ManagerMonitor, [flush]),
            Reply;
        {'DOWN', ManagerMonitor, process, _Object, _Reason} ->
            _ = erlang:unalias(Alias),
            {error, manager_unavailable}
    after Timeout ->
        _ = erlang:unalias(Alias),
        _ = send_to_server(Server, {auth_cancel_token, self(), Alias}),
        _ = erlang:demonitor(ManagerMonitor, [flush]),
        {error, caller_timeout}
    end.

send_to_server(Server, Message) ->
    try erlang:send(Server, Message, [nosuspend, noconnect]) of
        ok -> ok;
        _ -> error
    catch
        error:badarg -> error
    end.

handle_token_request(Caller, Alias, Request, State) ->
    case normalize_request(Request) of
        {ok, Key, Work0} ->
            case cached_token(Key, State) of
                {ok, Token} ->
                    send_reply(Alias, {ok, Token}),
                    State;
                not_found ->
                    Work = Work0#{store_module => State#state.store_module,
                                  store_handle => State#state.store_handle},
                    join_or_start(Key, Work, Caller, Alias, State)
            end;
        {error, invalid_request} = Error ->
            send_reply(Alias, Error),
            State
    end.

cached_token(Key, #state{cache_table = Table,
                         expiry_skew_ms = Skew} = State) ->
    case ets:lookup(Table, Key) of
        [{Key, Token, ExpiresAt}] ->
            case now_ms(State) + Skew < ExpiresAt of
                true -> {ok, Token};
                false ->
                    true = ets:delete(Table, Key),
                    not_found
            end;
        [] ->
            not_found
    end.

join_or_start(Key, Work, Caller, Alias,
              State = #state{inflight = Inflight}) ->
    case maps:find(Key, Inflight) of
        {ok, Flight} ->
            add_waiter(Key, Flight, Caller, Alias, State);
        error ->
            start_refresh(Key, Work, Caller, Alias, State)
    end.

start_refresh(Key, Work, Caller, Alias, State) ->
    Generation = make_ref(),
    true = ets:insert(State#state.pending_table, {Generation, Work}),
    case safe_start_refresh(State#state.refresh_sup, Generation) of
        {ok, Worker} ->
            WorkerMonitor = erlang:monitor(process, Worker),
            Timer = erlang:send_after(State#state.refresh_timeout_ms, self(),
                                      {auth_refresh_timeout, Generation}),
            CallerMonitor = erlang:monitor(process, Caller),
            Waiter = #{pid => Caller, monitor => CallerMonitor},
            Flight = #{generation => Generation,
                       worker => Worker,
                       worker_monitor => WorkerMonitor,
                       timer => Timer,
                       waiters => #{Alias => Waiter}},
            State#state{
              inflight = maps:put(Key, Flight, State#state.inflight),
              generations = maps:put(Generation, Key,
                                     State#state.generations),
              aliases = maps:put(Alias, {Key, Caller, CallerMonitor},
                                 State#state.aliases),
              caller_monitors = maps:put(CallerMonitor, Alias,
                                         State#state.caller_monitors),
              worker_monitors = maps:put(WorkerMonitor, Generation,
                                         State#state.worker_monitors)};
        error ->
            true = ets:delete(State#state.pending_table, Generation),
            send_reply(Alias, {error, refresh_start_failed}),
            State
    end.

safe_start_refresh(RefreshSup, Generation) ->
    try adk_token_refresh_sup:start_refresh(RefreshSup, self(), Generation) of
        {ok, Worker} when is_pid(Worker) -> {ok, Worker};
        {ok, Worker, _Info} when is_pid(Worker) -> {ok, Worker};
        _ -> error
    catch
        _Class:_Reason -> error
    end.

add_waiter(Key, Flight, Caller, Alias, State) ->
    CallerMonitor = erlang:monitor(process, Caller),
    Waiter = #{pid => Caller, monitor => CallerMonitor},
    Waiters = maps:put(Alias, Waiter, maps:get(waiters, Flight)),
    Flight1 = Flight#{waiters => Waiters},
    State#state{
      inflight = maps:put(Key, Flight1, State#state.inflight),
      aliases = maps:put(Alias, {Key, Caller, CallerMonitor},
                         State#state.aliases),
      caller_monitors = maps:put(CallerMonitor, Alias,
                                 State#state.caller_monitors)}.

dispatch_refresh(Generation, Worker,
                 State = #state{generations = Generations,
                                inflight = Inflight,
                                pending_table = Pending}) ->
    case maps:find(Generation, Generations) of
        {ok, Key} ->
            Flight = maps:get(Key, Inflight),
            case maps:get(worker, Flight) =:= Worker of
                true ->
                    case ets:take(Pending, Generation) of
                        [{Generation, Work}] ->
                            adk_token_refresh_worker:perform(Worker, Work),
                            State;
                        [] ->
                            finish_generation(Generation,
                                              {error, refresh_worker_failed},
                                              State)
                    end;
                false -> State
            end;
        error ->
            State
    end.

handle_refresh_result(Generation, Worker, Result,
                      State = #state{generations = Generations,
                                     inflight = Inflight}) ->
    case maps:find(Generation, Generations) of
        {ok, Key} ->
            Flight = maps:get(Key, Inflight),
            case maps:get(worker, Flight) =:= Worker of
                true ->
                    case normalize_refresh_result(Result, State) of
                        {cache, Token, ExpiresAt} ->
                            true = ets:insert(State#state.cache_table,
                                              {Key, Token, ExpiresAt}),
                            finish_generation(Generation, {ok, Token}, State);
                        {reply, Reply} ->
                            finish_generation(Generation, Reply, State)
                    end;
                false -> State
            end;
        error ->
            State
    end.

normalize_refresh_result({ok, Token0}, State) when is_map(Token0) ->
    case normalize_token(Token0) of
        {ok, Token, ExpiresIn} ->
            {cache, Token, now_ms(State) + ExpiresIn};
        error ->
            {reply, {error, invalid_provider_response}}
    end;
normalize_refresh_result({error, Reason}, _State) ->
    {reply, {error, normalize_refresh_error(Reason)}};
normalize_refresh_result(_Other, _State) ->
    {reply, {error, invalid_provider_response}}.

normalize_token(#{access_token := AccessToken,
                  expires_in_ms := ExpiresIn} = Token0)
  when is_binary(AccessToken), byte_size(AccessToken) > 0,
       is_integer(ExpiresIn), ExpiresIn > 0 ->
    TokenType = maps:get(token_type, Token0, <<"Bearer">>),
    case is_binary(TokenType) andalso byte_size(TokenType) > 0 of
        true ->
            {ok, #{access_token => AccessToken, token_type => TokenType},
             ExpiresIn};
        false -> error
    end;
normalize_token(_Token) ->
    error.

normalize_refresh_error({provider_error, Redacted}) ->
    {provider_error, adk_secret_redactor:redact(Redacted)};
normalize_refresh_error({provider_exception, Class, Redacted})
  when is_atom(Class) ->
    {provider_exception, Class, adk_secret_redactor:redact(Redacted)};
normalize_refresh_error(credential_not_found) -> credential_not_found;
normalize_refresh_error(credential_store_unavailable) ->
    credential_store_unavailable;
normalize_refresh_error(credential_rotation_conflict) ->
    credential_rotation_conflict;
normalize_refresh_error(credential_rotation_failed) ->
    credential_rotation_failed;
normalize_refresh_error(invalid_provider_response) ->
    invalid_provider_response;
normalize_refresh_error(provider_process_failed) -> provider_process_failed;
normalize_refresh_error(invalid_refresh_work) -> invalid_refresh_work;
normalize_refresh_error(_Other) -> refresh_worker_failed.

handle_refresh_timeout(Generation, State = #state{generations = Generations}) ->
    case maps:find(Generation, Generations) of
        {ok, _Key} ->
            adk_token_refresh_sup:cancel_refresh(State#state.refresh_sup,
                                                 Generation),
            finish_generation(Generation, {error, refresh_timeout}, State);
        error ->
            State
    end.

handle_monitor_down(Monitor, State = #state{worker_monitors = WorkerMonitors,
                                            caller_monitors = CallerMonitors}) ->
    case maps:find(Monitor, WorkerMonitors) of
        {ok, Generation} ->
            finish_generation(Generation, {error, refresh_worker_failed},
                              State);
        error ->
            case maps:find(Monitor, CallerMonitors) of
                {ok, Alias} -> remove_waiter(Alias, any, State);
                error -> State
            end
    end.

remove_waiter(Alias, ExpectedCaller,
              State = #state{aliases = Aliases, inflight = Inflight}) ->
    case maps:find(Alias, Aliases) of
        {ok, {Key, Caller, CallerMonitor}}
          when ExpectedCaller =:= any; ExpectedCaller =:= Caller ->
            Flight = maps:get(Key, Inflight),
            Waiters = maps:remove(Alias, maps:get(waiters, Flight)),
            _ = erlang:demonitor(CallerMonitor, [flush]),
            State1 = State#state{
              aliases = maps:remove(Alias, Aliases),
              caller_monitors = maps:remove(CallerMonitor,
                                            State#state.caller_monitors)},
            case map_size(Waiters) of
                0 ->
                    Generation = maps:get(generation, Flight),
                    adk_token_refresh_sup:cancel_refresh(
                      State#state.refresh_sup, Generation),
                    Flight1 = Flight#{waiters => Waiters},
                    Inflight1 = maps:put(Key, Flight1,
                                        State1#state.inflight),
                    discard_generation(Generation,
                                       State1#state{inflight = Inflight1});
                _ ->
                    Flight1 = Flight#{waiters => Waiters},
                    State1#state{inflight = maps:put(Key, Flight1,
                                                    State1#state.inflight)}
            end;
        _ ->
            State
    end.

finish_generation(Generation, Reply,
                  State = #state{generations = Generations,
                                 inflight = Inflight}) ->
    case maps:find(Generation, Generations) of
        {ok, Key} ->
            Flight = maps:get(Key, Inflight),
            maps:foreach(
              fun(Alias, _Waiter) -> send_reply(Alias, Reply) end,
              maps:get(waiters, Flight)),
            cleanup_generation(Key, Flight, State);
        error ->
            State
    end.

discard_generation(Generation,
                   State = #state{generations = Generations,
                                  inflight = Inflight}) ->
    case maps:find(Generation, Generations) of
        {ok, Key} ->
            cleanup_generation(Key, maps:get(Key, Inflight), State);
        error -> State
    end.

cleanup_generation(Key, Flight, State) ->
    Generation = maps:get(generation, Flight),
    WorkerMonitor = maps:get(worker_monitor, Flight),
    cancel_timer(maps:get(timer, Flight)),
    _ = erlang:demonitor(WorkerMonitor, [flush]),
    true = ets:delete(State#state.pending_table, Generation),
    {Aliases1, CallerMonitors1} = maps:fold(
      fun(Alias, Waiter, {AliasesAcc, MonitorsAcc}) ->
          CallerMonitor = maps:get(monitor, Waiter),
          _ = erlang:demonitor(CallerMonitor, [flush]),
          {maps:remove(Alias, AliasesAcc),
           maps:remove(CallerMonitor, MonitorsAcc)}
      end, {State#state.aliases, State#state.caller_monitors},
      maps:get(waiters, Flight)),
    State#state{
      inflight = maps:remove(Key, State#state.inflight),
      generations = maps:remove(Generation, State#state.generations),
      aliases = Aliases1,
      caller_monitors = CallerMonitors1,
      worker_monitors = maps:remove(WorkerMonitor,
                                    State#state.worker_monitors)}.

send_reply(Alias, Reply) ->
    _ = catch erlang:send(Alias, {Alias, Reply}, [nosuspend]),
    ok.

cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

now_ms(#state{now_fun = NowFun}) ->
    try NowFun() of
        Value when is_integer(Value) -> Value
    catch
        _Class:_Reason -> erlang:monotonic_time(millisecond)
    end.

normalize_request(#{principal := Principal,
                    provider := Provider,
                    provider_module := ProviderModule,
                    credential_ref := CredentialRef} = Request) ->
    Scopes0 = maps:get(scopes, Request, []),
    Audience = maps:get(audience, Request, undefined),
    Context0 = maps:get(context, Request, #{}),
    case valid_identity(Principal) andalso valid_identity(Provider) andalso
         is_atom(ProviderModule) andalso ProviderModule =/= undefined andalso
         adk_credential_store:is_ref(CredentialRef) andalso
         valid_scopes(Scopes0) andalso valid_audience(Audience) andalso
         is_map(Context0) of
        true ->
            Scopes = lists:usort(Scopes0),
            Context = Context0#{principal => Principal,
                                provider => Provider,
                                scopes => Scopes,
                                audience => Audience},
            Key = {Principal, Provider, ProviderModule, CredentialRef,
                   Scopes, Audience},
            Work = #{principal => Principal,
                     provider => Provider,
                     provider_module => ProviderModule,
                     credential_ref => CredentialRef,
                     context => Context},
            {ok, Key, Work};
        false ->
            {error, invalid_request}
    end;
normalize_request(_Request) ->
    {error, invalid_request}.

valid_identity(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_identity(Value) when is_atom(Value) -> Value =/= undefined;
valid_identity(_) -> false.

valid_scopes([]) -> true;
valid_scopes([Scope | Rest]) when is_binary(Scope), byte_size(Scope) > 0 ->
    valid_scopes(Rest);
valid_scopes(_Scopes) -> false.

valid_audience(undefined) -> true;
valid_audience(Audience) when is_binary(Audience) ->
    byte_size(Audience) > 0;
valid_audience(_) -> false.

validate_options(StoreModule, StoreHandle, RefreshSup, Skew,
                 RefreshTimeout, NowFun)
  when is_atom(StoreModule),
       (is_pid(StoreHandle) orelse is_atom(StoreHandle)),
       (is_pid(RefreshSup) orelse is_atom(RefreshSup)),
       is_integer(Skew), Skew >= 0,
       is_integer(RefreshTimeout), RefreshTimeout > 0,
       is_function(NowFun, 0) ->
    ok;
validate_options(_StoreModule, _StoreHandle, _RefreshSup, _Skew,
                 _RefreshTimeout, _NowFun) ->
    erlang:error(invalid_token_manager_options).
