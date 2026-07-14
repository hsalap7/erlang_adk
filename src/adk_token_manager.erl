%% @doc Concurrent, scoped access-token cache and refresh coordinator.
%%
%% A request is keyed by principal, provider, credential reference, scopes, and
%% audience. The credential-consuming module and its base context come only
%% from immutable, operator-supplied provider profiles; callers cannot choose
%% either value. Concurrent callers for the same key share one supervised
%% refresh. Access tokens and pending provider context are retained only in
%% owner-private ETS tables, never in inspectable gen_server state.
-module(adk_token_manager).

-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         get_token/2, get_token/3, invalidate/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-type server() :: pid() | atom().
-type token_request() :: #{
    principal := adk_credential_store:principal(),
    provider := adk_credential_store:provider_id(),
    credential_ref := adk_credential_store:credential_ref(),
    scopes => [binary()],
    audience => undefined | binary(),
    %% Deprecated compatibility field. It is never used for dispatch; the
    %% immutable provider profile owns the module.
    provider_module => term(),
    %% Ignored unless the trusted provider profile explicitly enables it for
    %% a module exporting test_adapter/0. This exists for deterministic tests,
    %% not production providers.
    context => map()
}.
-type provider_profile() :: #{
    provider_module := module(),
    context => map(),
    allowed_scopes => [binary()],
    allowed_audiences => [binary()],
    resource_indicator => boolean(),
    allow_request_context => boolean()
}.
-type token() :: #{access_token := binary(), token_type := binary()}.
-type error_reason() :: invalid_request | manager_unavailable |
                        caller_timeout | credential_not_found |
                        credential_store_unavailable |
                        credential_rotation_conflict |
                        credential_rotation_failed |
                        invalid_provider_response | refresh_timeout |
                        refresh_worker_failed | refresh_start_failed |
                        unknown_provider | scope_not_allowed |
                        audience_not_allowed | refresh_capacity_reached |
                        waiter_capacity_reached | token_invalidated |
                        provider_process_failed | invalid_refresh_work |
                        {provider_error, term()} |
                        {provider_exception, atom(), term()}.

-export_type([server/0, token_request/0, provider_profile/0, token/0,
              error_reason/0]).

-define(DEFAULT_CALL_TIMEOUT_MS, 15000).
-define(DEFAULT_REFRESH_TIMEOUT_MS, 10000).
-define(DEFAULT_EXPIRY_SKEW_MS, 30000).
-define(DEFAULT_MAX_CACHE_ENTRIES, 1024).
-define(DEFAULT_MAX_INFLIGHT_REFRESHES, 256).
-define(DEFAULT_MAX_WAITERS_PER_REFRESH, 256).
-define(MAX_CALL_TIMEOUT_MS, 60000).
-define(MAX_REFRESH_TIMEOUT_MS, 60000).
-define(MAX_EXPIRY_SKEW_MS, 604800000).
-define(MAX_EXPIRY_MS, 604800000).
-define(MAX_CACHE_ENTRIES, 65536).
-define(MAX_INFLIGHT_REFRESHES, 4096).
-define(MAX_WAITERS_PER_REFRESH, 4096).
-define(MAX_PROVIDER_PROFILES, 1024).
-define(MAX_OPTIONS_BYTES, 8388608).
-define(MAX_PROFILES_BYTES, 4194304).
-define(MAX_PROFILE_BYTES, 262144).
-define(MAX_CONTEXT_BYTES, 65536).
-define(MAX_REQUEST_BYTES, 262144).
-define(MAX_INVALIDATION_BYTES, 16384).
-define(MAX_REFRESH_RESULT_BYTES, 1048576).
-define(MAX_ID_BYTES, 4096).
-define(MAX_SCOPES, 64).
-define(MAX_SCOPE_BYTES, 512).
-define(MAX_AUDIENCE_BYTES, 8192).
-define(MAX_ACCESS_TOKEN_BYTES, 131072).
-define(MAX_TOKEN_TYPE_BYTES, 64).
-define(MAX_CLOCK_ABS_MS, 9007199254740991).

-record(state, {
    store_module :: module(),
    store_handle :: adk_credential_store:handle(),
    refresh_sup :: pid() | atom(),
    cache_table :: ets:tid(),
    pending_table :: ets:tid(),
    expiry_skew_ms :: non_neg_integer(),
    refresh_timeout_ms :: pos_integer(),
    now_fun :: fun(() -> integer()),
    provider_profiles = #{} :: map(),
    max_cache_entries :: pos_integer(),
    max_inflight_refreshes :: pos_integer(),
    max_waiters_per_refresh :: pos_integer(),
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
    case valid_start_options(Opts) of
        true ->
            case maps:get(name, Opts, ?MODULE) of
                undefined -> gen_server:start_link(?MODULE, Opts, []);
                Name -> gen_server:start_link({local, Name}, ?MODULE,
                                              Opts, [])
            end;
        false ->
            {error, invalid_token_manager_options}
    end;
start_link(_Opts) ->
    {error, invalid_token_manager_options}.

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
       is_integer(Timeout), Timeout > 0, Timeout =< ?MAX_CALL_TIMEOUT_MS ->
    case bounded_term(Request, ?MAX_REQUEST_BYTES) of
        true -> request_token(Server, Request, Timeout);
        false -> {error, invalid_request}
    end;
get_token(_Server, _Request, _Timeout) ->
    {error, invalid_request}.

request_token(Server, Request, Timeout) ->
    Alias = erlang:alias([explicit_unalias]),
    ManagerMonitor = erlang:monitor(process, Server),
    case send_to_server(Server, {auth_get_token, self(), Alias, Request}) of
        ok ->
            await_reply(Server, Alias, ManagerMonitor, Timeout);
        error ->
            _ = erlang:unalias(Alias),
            _ = erlang:demonitor(ManagerMonitor, [flush]),
            {error, manager_unavailable}
    end.

%% @doc Invalidate cached tokens and cancel matching in-flight refreshes.
%%
%% The selector must contain `principal`, `provider`, and the opaque
%% `credential_ref`. Requiring the capability-like reference prevents a caller
%% from evicting every token for a guessed tenant/provider pair. The count
%% includes both deleted cache entries and cancelled refreshes. Waiters on a
%% cancelled refresh receive `{error, token_invalidated}`.
-spec invalidate(server(), map()) ->
    {ok, non_neg_integer()} | {error, invalid_request | manager_unavailable}.
invalidate(Server, Selector)
  when (is_pid(Server) orelse is_atom(Server)), is_map(Selector),
       map_size(Selector) =< 3 ->
    case bounded_term(Selector, ?MAX_INVALIDATION_BYTES) of
        true ->
            try gen_server:call(Server, {invalidate, Selector}, 5000) of
                Reply -> Reply
            catch
                exit:_ -> {error, manager_unavailable}
            end;
        false ->
            {error, invalid_request}
    end;
invalidate(_Server, _Selector) ->
    {error, invalid_request}.

init(Opts) ->
    StoreModule = maps:get(store_module, Opts, adk_credential_store_ets),
    StoreHandle = maps:get(store_handle, Opts, adk_credential_store_ets),
    RefreshSup = maps:get(refresh_sup, Opts, adk_token_refresh_sup),
    Skew = maps:get(expiry_skew_ms, Opts, ?DEFAULT_EXPIRY_SKEW_MS),
    RefreshTimeout = maps:get(refresh_timeout_ms, Opts,
                              ?DEFAULT_REFRESH_TIMEOUT_MS),
    Profiles0 = maps:get(provider_profiles, Opts, #{}),
    MaxCacheEntries = maps:get(max_cache_entries, Opts,
                               ?DEFAULT_MAX_CACHE_ENTRIES),
    MaxInflight = maps:get(max_inflight_refreshes, Opts,
                           ?DEFAULT_MAX_INFLIGHT_REFRESHES),
    MaxWaiters = maps:get(max_waiters_per_refresh, Opts,
                          ?DEFAULT_MAX_WAITERS_PER_REFRESH),
    NowFun = maps:get(now_fun, Opts,
                      fun() -> erlang:monotonic_time(millisecond) end),
    ok = validate_options(StoreModule, StoreHandle, RefreshSup, Skew,
                          RefreshTimeout, NowFun, MaxCacheEntries,
                          MaxInflight, MaxWaiters),
    Profiles = case normalize_provider_profiles(Profiles0) of
        {ok, NormalizedProfiles} -> NormalizedProfiles;
        {error, invalid_token_manager_options} ->
            erlang:error(invalid_token_manager_options)
    end,
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
                now_fun = NowFun,
                provider_profiles = Profiles,
                max_cache_entries = MaxCacheEntries,
                max_inflight_refreshes = MaxInflight,
                max_waiters_per_refresh = MaxWaiters}}.

handle_call({invalidate, Selector}, _From, State) ->
    case normalize_invalidation_selector(Selector) of
        {ok, Normalized} ->
            {Count, State1} = invalidate_matching(Normalized, State),
            {reply, {ok, Count}, State1};
        error ->
            {reply, {error, invalid_request}, State}
    end;
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
handle_info({ResultAlias, auth_refresh_result, Generation, Worker,
             CompletedAt, Result}, State)
  when is_reference(ResultAlias), is_reference(Generation), is_pid(Worker),
       is_integer(CompletedAt) ->
    {noreply,
     handle_refresh_result(ResultAlias, Generation, Worker, CompletedAt,
                           Result, State)};
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
          _ = safe_unalias(maps:get(result_alias, Flight)),
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
                provider_profile_count =>
                    map_size(State#state.provider_profiles),
                max_cache_entries => State#state.max_cache_entries,
                max_inflight_refreshes =>
                    State#state.max_inflight_refreshes,
                max_waiters_per_refresh =>
                    State#state.max_waiters_per_refresh,
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
    case normalize_request(Request, State#state.provider_profiles) of
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
        {error, _Reason} = Error ->
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

cache_token(Key, Token, ExpiresAt,
            #state{cache_table = Table,
                   max_cache_entries = Maximum}) ->
    case ets:member(Table, Key) orelse ets:info(Table, size) < Maximum of
        true -> ok;
        false -> evict_earliest_expiry(Table)
    end,
    true = ets:insert(Table, {Key, Token, ExpiresAt}),
    ok.

evict_earliest_expiry(Table) ->
    Candidate = ets:foldl(
                  fun({Key, _Token, ExpiresAt}, none) ->
                          {Key, ExpiresAt};
                     ({Key, _Token, ExpiresAt}, {_OldKey, OldExpiresAt})
                       when ExpiresAt < OldExpiresAt ->
                          {Key, ExpiresAt};
                     (_Entry, Acc) -> Acc
                  end, none, Table),
    case Candidate of
        {Key, _ExpiresAt} -> true = ets:delete(Table, Key);
        none -> ok
    end.

join_or_start(Key, Work, Caller, Alias,
              State = #state{inflight = Inflight}) ->
    case maps:find(Key, Inflight) of
        {ok, Flight} ->
            case map_size(maps:get(waiters, Flight)) <
                 State#state.max_waiters_per_refresh of
                true -> add_waiter(Key, Flight, Caller, Alias, State);
                false ->
                    send_reply(Alias, {error, waiter_capacity_reached}),
                    State
            end;
        error ->
            case map_size(Inflight) < State#state.max_inflight_refreshes of
                true -> start_refresh(Key, Work, Caller, Alias, State);
                false ->
                    send_reply(Alias, {error, refresh_capacity_reached}),
                    State
            end
    end.

start_refresh(Key, Work, Caller, Alias, State) ->
    Generation = make_ref(),
    ResultAlias = erlang:alias([explicit_unalias]),
    Deadline = monotonic_ms() + State#state.refresh_timeout_ms,
    PrivateWork = Work#{deadline_ms => Deadline,
                        manager_alias => ResultAlias},
    true = ets:insert(State#state.pending_table, {Generation, PrivateWork}),
    case safe_start_refresh(State#state.refresh_sup, Generation) of
        {ok, Worker} ->
            WorkerMonitor = erlang:monitor(process, Worker),
            Timer = erlang:send_after(
                      Deadline, self(),
                      {auth_refresh_timeout, Generation}, [{abs, true}]),
            CallerMonitor = erlang:monitor(process, Caller),
            Waiter = #{pid => Caller, monitor => CallerMonitor},
            Flight = #{generation => Generation,
                       worker => Worker,
                       worker_monitor => WorkerMonitor,
                       timer => Timer,
                       result_alias => ResultAlias,
                       deadline_ms => Deadline,
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
            _ = safe_unalias(ResultAlias),
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

handle_refresh_result(ResultAlias, Generation, Worker, CompletedAt, Result,
                      State = #state{generations = Generations,
                                     inflight = Inflight}) ->
    case maps:find(Generation, Generations) of
        {ok, Key} ->
            Flight = maps:get(Key, Inflight),
            case maps:get(worker, Flight) =:= Worker andalso
                 maps:get(result_alias, Flight) =:= ResultAlias of
                true ->
                    case CompletedAt =< maps:get(deadline_ms, Flight) of
                        false ->
                            adk_token_refresh_sup:cancel_refresh(
                              State#state.refresh_sup, Generation),
                            finish_generation(
                              Generation, {error, refresh_timeout}, State);
                        true ->
                            case normalize_refresh_result(Result, State) of
                                {cache, Token, ExpiresAt} ->
                                    cache_token(Key, Token, ExpiresAt, State),
                                    finish_generation(
                                      Generation, {ok, Token}, State);
                                {reply, Reply} ->
                                    finish_generation(Generation, Reply, State)
                            end
                    end;
                false -> State
            end;
        error ->
            State
    end.

normalize_refresh_result(Result, State) ->
    case bounded_term(Result, ?MAX_REFRESH_RESULT_BYTES) of
        true -> normalize_bounded_refresh_result(Result, State);
        false -> {reply, {error, invalid_provider_response}}
    end.

normalize_bounded_refresh_result({ok, Token0}, State) when is_map(Token0) ->
    case normalize_token(Token0) of
        {ok, Token, ExpiresIn} ->
            {cache, Token, now_ms(State) + ExpiresIn};
        error ->
            {reply, {error, invalid_provider_response}}
    end;
normalize_bounded_refresh_result({error, Reason}, _State) ->
    {reply, {error, normalize_refresh_error(Reason)}};
normalize_bounded_refresh_result(_Other, _State) ->
    {reply, {error, invalid_provider_response}}.

normalize_token(#{access_token := AccessToken,
                  expires_in_ms := ExpiresIn} = Token0)
  when is_binary(AccessToken), byte_size(AccessToken) > 0,
       byte_size(AccessToken) =< ?MAX_ACCESS_TOKEN_BYTES,
       is_integer(ExpiresIn), ExpiresIn > 0,
       ExpiresIn =< ?MAX_EXPIRY_MS ->
    TokenType = maps:get(token_type, Token0, <<"Bearer">>),
    case bounded_term(Token0, ?MAX_REFRESH_RESULT_BYTES) andalso
         valid_token_type(TokenType) of
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
normalize_refresh_error(refresh_timeout) -> refresh_timeout;
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
    _ = safe_unalias(maps:get(result_alias, Flight)),
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

safe_unalias(Alias) when is_reference(Alias) ->
    _ = catch erlang:unalias(Alias),
    ok.

monotonic_ms() ->
    erlang:monotonic_time(millisecond).

now_ms(#state{now_fun = NowFun}) ->
    try NowFun() of
        Value when is_integer(Value),
                   Value >= -?MAX_CLOCK_ABS_MS,
                   Value =< ?MAX_CLOCK_ABS_MS -> Value;
        _Invalid -> erlang:monotonic_time(millisecond)
    catch
        _Class:_Reason -> erlang:monotonic_time(millisecond)
    end.

normalize_request(#{principal := Principal,
                    provider := Provider,
                    credential_ref := CredentialRef} = Request,
                  Profiles) ->
    Scopes0 = maps:get(scopes, Request, []),
    Audience = maps:get(audience, Request, undefined),
    RequestContext = maps:get(context, Request, #{}),
    case known_request_keys(Request) andalso
         bounded_term(Request, ?MAX_REQUEST_BYTES) andalso
         valid_identity(Principal) andalso valid_identity(Provider) andalso
         adk_credential_store:is_ref(CredentialRef) andalso
         valid_scopes(Scopes0) andalso valid_audience(Audience) andalso
         is_map(RequestContext) andalso
         bounded_term(RequestContext, ?MAX_CONTEXT_BYTES) of
        true ->
            case maps:find(Provider, Profiles) of
                {ok, Profile} ->
                    normalize_profile_request(
                      Principal, Provider, CredentialRef,
                      lists:usort(Scopes0), Audience, RequestContext,
                      Profile);
                error ->
                    {error, unknown_provider}
            end;
        false ->
            {error, invalid_request}
    end;
normalize_request(_Request, _Profiles) ->
    {error, invalid_request}.

normalize_profile_request(Principal, Provider, CredentialRef, Scopes,
                          Audience, RequestContext, Profile) ->
    AllowedScopes = maps:get(allowed_scopes, Profile),
    AllowedAudiences = maps:get(allowed_audiences, Profile),
    case lists:all(fun(Scope) -> lists:member(Scope, AllowedScopes) end,
                   Scopes) of
        false ->
            {error, scope_not_allowed};
        true ->
            case allowed_audience(Audience, AllowedAudiences, Profile) of
                false ->
                    {error, audience_not_allowed};
                true ->
                    Context = provider_context(
                                Principal, Provider, Scopes, Audience,
                                RequestContext, Profile),
                    ProviderModule = maps:get(provider_module, Profile),
                    Key = {Principal, Provider, CredentialRef,
                           Scopes, Audience},
                    Work = #{principal => Principal,
                             provider => Provider,
                             provider_module => ProviderModule,
                             credential_ref => CredentialRef,
                             context => Context},
                    {ok, Key, Work}
            end
    end.

allowed_audience(undefined, _Allowed, Profile) ->
    maps:get(resource_indicator, Profile) =:= false;
allowed_audience(Audience, Allowed, _Profile) ->
    lists:member(Audience, Allowed).

provider_context(Principal, Provider, Scopes, Audience, RequestContext,
                 Profile) ->
    TrustedContext = maps:get(context, Profile),
    Base0 = case maps:get(allow_request_context, Profile) of
        true -> maps:merge(RequestContext, TrustedContext);
        false -> TrustedContext
    end,
    %% These fields are owned by the manager even for a test-only request
    %% context. In particular, a caller cannot smuggle a resource indicator or
    %% credential rotator through the context map.
    Base = maps:without(
             [principal, provider, scopes, audience, resource,
              credential_rotator], Base0),
    Context0 = Base#{principal => Principal,
                     provider => Provider,
                     scopes => Scopes,
                     audience => Audience},
    case maps:get(resource_indicator, Profile) of
        true -> Context0#{resource => Audience};
        false -> Context0
    end.

normalize_provider_profiles(Profiles)
  when is_map(Profiles), map_size(Profiles) =< ?MAX_PROVIDER_PROFILES ->
    case bounded_term(Profiles, ?MAX_PROFILES_BYTES) of
        true -> normalize_provider_profile_pairs(maps:to_list(Profiles), #{});
        false -> {error, invalid_token_manager_options}
    end;
normalize_provider_profiles(_Profiles) ->
    {error, invalid_token_manager_options}.

normalize_provider_profile_pairs([], Acc) ->
    {ok, Acc};
normalize_provider_profile_pairs([{Provider, Profile0} | Rest], Acc)
  when is_map(Profile0) ->
    case valid_identity(Provider) of
        true ->
            case normalize_provider_profile(Profile0) of
                {ok, Profile} ->
                    normalize_provider_profile_pairs(
                      Rest, maps:put(Provider, Profile, Acc));
                error ->
                    {error, invalid_token_manager_options}
            end;
        false ->
            {error, invalid_token_manager_options}
    end;
normalize_provider_profile_pairs(_Pairs, _Acc) ->
    {error, invalid_token_manager_options}.

normalize_provider_profile(#{provider_module := ProviderModule} = Profile0) ->
    AllowedKeys = [provider_module, context, allowed_scopes,
                   allowed_audiences, resource_indicator,
                   allow_request_context],
    Profile = Profile0#{context => maps:get(context, Profile0, #{}),
                        allowed_scopes =>
                            maps:get(allowed_scopes, Profile0, []),
                        allowed_audiences =>
                            maps:get(allowed_audiences, Profile0, []),
                        resource_indicator =>
                            maps:get(resource_indicator, Profile0, false),
                        allow_request_context =>
                            maps:get(allow_request_context, Profile0, false)},
    Context = maps:get(context, Profile),
    Scopes = maps:get(allowed_scopes, Profile),
    Audiences = maps:get(allowed_audiences, Profile),
    ResourceIndicator = maps:get(resource_indicator, Profile),
    AllowRequestContext = maps:get(allow_request_context, Profile),
    case bounded_term(Profile, ?MAX_PROFILE_BYTES) andalso
         lists:sort(maps:keys(Profile)) =:= lists:sort(AllowedKeys) andalso
         is_atom(ProviderModule) andalso ProviderModule =/= undefined andalso
         is_map(Context) andalso safe_profile_context(Context) andalso
         valid_scopes(Scopes) andalso valid_audiences(Audiences) andalso
         is_boolean(ResourceIndicator) andalso
         (ResourceIndicator =:= false orelse Audiences =/= []) andalso
         is_boolean(AllowRequestContext) andalso
         valid_request_context_policy(AllowRequestContext,
                                      ProviderModule) of
        true ->
            {ok, Profile#{allowed_scopes => lists:usort(Scopes),
                          allowed_audiences => lists:usort(Audiences)}};
        false ->
            error
    end;
normalize_provider_profile(_Profile) ->
    error.

valid_request_context_policy(false, _ProviderModule) -> true;
valid_request_context_policy(true, ProviderModule) ->
    case code:ensure_loaded(ProviderModule) of
        {module, ProviderModule} ->
            case erlang:function_exported(ProviderModule, test_adapter, 0) of
                true ->
                    try ProviderModule:test_adapter() =:= true
                    catch _:_ -> false
                    end;
                false -> false
            end;
        _ -> false
    end.

safe_profile_context(Context) ->
    bounded_term(Context, ?MAX_CONTEXT_BYTES) andalso
    not contains_sensitive_key(Context) andalso
    not lists:any(fun(Key) -> maps:is_key(Key, Context) end,
                  [principal, provider, scopes, audience, resource,
                   credential_rotator]).

contains_sensitive_key(Map) when is_map(Map) ->
    lists:any(fun({Key, Value}) ->
                  adk_context_guard:sensitive_key(Key) orelse
                  contains_sensitive_key(Value)
              end, maps:to_list(Map));
contains_sensitive_key([]) -> false;
contains_sensitive_key([Head | Tail]) ->
    contains_sensitive_key(Head) orelse contains_sensitive_key(Tail);
contains_sensitive_key(Tuple) when is_tuple(Tuple) ->
    contains_sensitive_key(tuple_to_list(Tuple));
contains_sensitive_key(_Value) -> false.

normalize_invalidation_selector(#{principal := Principal,
                                  provider := Provider,
                                  credential_ref := CredentialRef} = Selector) ->
    Keys = lists:sort(maps:keys(Selector)),
    ValidKeys = Keys =:= [credential_ref, principal, provider],
    ValidRef = adk_credential_store:is_ref(CredentialRef),
    case ValidKeys andalso valid_identity(Principal) andalso
         valid_identity(Provider) andalso ValidRef of
        true -> {ok, #{principal => Principal,
                       provider => Provider,
                       credential_ref => CredentialRef}};
        false -> error
    end;
normalize_invalidation_selector(_Selector) -> error.

invalidate_matching(Selector, State) ->
    CacheKeys = ets:foldl(
                  fun({Key, _Token, _ExpiresAt}, Acc) ->
                      case key_matches_selector(Key, Selector) of
                          true -> [Key | Acc];
                          false -> Acc
                      end
                  end, [], State#state.cache_table),
    lists:foreach(fun(Key) ->
                      true = ets:delete(State#state.cache_table, Key)
                  end, CacheKeys),
    FlightKeys = [Key || Key <- maps:keys(State#state.inflight),
                         key_matches_selector(Key, Selector)],
    State1 = lists:foldl(
               fun(Key, AccState) ->
                   case maps:find(Key, AccState#state.inflight) of
                       {ok, Flight} ->
                           Generation = maps:get(generation, Flight),
                           adk_token_refresh_sup:cancel_refresh(
                             AccState#state.refresh_sup, Generation),
                           finish_generation(
                             Generation, {error, token_invalidated},
                             AccState);
                       error -> AccState
                   end
               end, State, FlightKeys),
    {length(CacheKeys) + length(FlightKeys), State1}.

key_matches_selector({Principal, Provider, CredentialRef,
                      _Scopes, _Audience},
                     #{principal := Principal, provider := Provider,
                       credential_ref := CredentialRef}) ->
    true;
key_matches_selector(_Key, _Selector) -> false.

valid_identity(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< ?MAX_ID_BYTES;
valid_identity(Value) when is_atom(Value) -> Value =/= undefined;
valid_identity(_) -> false.

valid_scopes(Scopes) ->
    valid_text_list(Scopes, ?MAX_SCOPES, ?MAX_SCOPE_BYTES).

valid_audiences(Audiences) ->
    valid_text_list(Audiences, ?MAX_SCOPES, ?MAX_AUDIENCE_BYTES).

valid_audience(undefined) -> true;
valid_audience(Audience) when is_binary(Audience) ->
    byte_size(Audience) > 0 andalso
    byte_size(Audience) =< ?MAX_AUDIENCE_BYTES;
valid_audience(_) -> false.

validate_options(StoreModule, StoreHandle, RefreshSup, Skew,
                 RefreshTimeout, NowFun, MaxCacheEntries,
                 MaxInflight, MaxWaiters)
  when is_atom(StoreModule),
       (is_pid(StoreHandle) orelse is_atom(StoreHandle)),
       (is_pid(RefreshSup) orelse is_atom(RefreshSup)),
       StoreModule =/= undefined, StoreHandle =/= undefined,
       RefreshSup =/= undefined,
       is_integer(Skew), Skew >= 0, Skew =< ?MAX_EXPIRY_SKEW_MS,
       is_integer(RefreshTimeout), RefreshTimeout > 0,
       RefreshTimeout =< ?MAX_REFRESH_TIMEOUT_MS,
       is_function(NowFun, 0),
       is_integer(MaxCacheEntries), MaxCacheEntries > 0,
       MaxCacheEntries =< ?MAX_CACHE_ENTRIES,
       is_integer(MaxInflight), MaxInflight > 0,
       MaxInflight =< ?MAX_INFLIGHT_REFRESHES,
       is_integer(MaxWaiters), MaxWaiters > 0,
       MaxWaiters =< ?MAX_WAITERS_PER_REFRESH ->
    ok;
validate_options(_StoreModule, _StoreHandle, _RefreshSup, _Skew,
                 _RefreshTimeout, _NowFun, _MaxCacheEntries,
                 _MaxInflight, _MaxWaiters) ->
    erlang:error(invalid_token_manager_options).

valid_start_options(Opts) ->
    Allowed = [name, id, store_module, store_handle, refresh_sup,
               expiry_skew_ms, refresh_timeout_ms, now_fun,
               provider_profiles, max_cache_entries,
               max_inflight_refreshes, max_waiters_per_refresh],
    bounded_term(Opts, ?MAX_OPTIONS_BYTES) andalso
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Opts)) andalso
    valid_start_limits_and_profiles(Opts) andalso
    case maps:get(name, Opts, ?MODULE) of
        undefined -> true;
        Name when is_atom(Name) -> Name =/= undefined;
        _ -> false
    end.

valid_start_limits_and_profiles(Opts) ->
    try
        ok = validate_options(
               maps:get(store_module, Opts, adk_credential_store_ets),
               maps:get(store_handle, Opts, adk_credential_store_ets),
               maps:get(refresh_sup, Opts, adk_token_refresh_sup),
               maps:get(expiry_skew_ms, Opts, ?DEFAULT_EXPIRY_SKEW_MS),
               maps:get(refresh_timeout_ms, Opts,
                        ?DEFAULT_REFRESH_TIMEOUT_MS),
               maps:get(now_fun, Opts,
                        fun() -> erlang:monotonic_time(millisecond) end),
               maps:get(max_cache_entries, Opts,
                        ?DEFAULT_MAX_CACHE_ENTRIES),
               maps:get(max_inflight_refreshes, Opts,
                        ?DEFAULT_MAX_INFLIGHT_REFRESHES),
               maps:get(max_waiters_per_refresh, Opts,
                        ?DEFAULT_MAX_WAITERS_PER_REFRESH)),
        {ok, _} = normalize_provider_profiles(
                    maps:get(provider_profiles, Opts, #{})),
        true
    catch
        _:_ -> false
    end.

known_request_keys(Request) ->
    Allowed = [principal, provider, credential_ref, scopes, audience,
               provider_module, context],
    lists:all(fun(Key) -> lists:member(Key, Allowed) end,
              maps:keys(Request)).

valid_text_list(List, MaximumCount, MaximumBytes) ->
    valid_text_list(List, MaximumCount, MaximumBytes, 0, #{}).

valid_text_list([], _MaximumCount, _MaximumBytes, _Count, _Seen) -> true;
valid_text_list([Value | Rest], MaximumCount, MaximumBytes, Count, Seen)
  when Count < MaximumCount, is_binary(Value), byte_size(Value) > 0,
       byte_size(Value) =< MaximumBytes ->
    case maps:is_key(Value, Seen) of
        true -> false;
        false -> valid_text_list(Rest, MaximumCount, MaximumBytes,
                                 Count + 1, Seen#{Value => true})
    end;
valid_text_list(_List, _MaximumCount, _MaximumBytes, _Count, _Seen) -> false.

valid_token_type(TokenType)
  when is_binary(TokenType), byte_size(TokenType) > 0,
       byte_size(TokenType) =< ?MAX_TOKEN_TYPE_BYTES ->
    token_chars(TokenType);
valid_token_type(_TokenType) -> false.

token_chars(<<>>) -> true;
token_chars(<<Char, Rest/binary>>)
  when (Char >= $a andalso Char =< $z) orelse
       (Char >= $A andalso Char =< $Z) orelse
       (Char >= $0 andalso Char =< $9) orelse
       Char =:= $! orelse Char =:= $# orelse Char =:= $$ orelse
       Char =:= $% orelse Char =:= $& orelse Char =:= $' orelse
       Char =:= $* orelse Char =:= $+ orelse Char =:= $- orelse
       Char =:= $. orelse Char =:= $^ orelse Char =:= $_ orelse
       Char =:= $` orelse Char =:= $| orelse Char =:= $~ ->
    token_chars(Rest);
token_chars(_TokenType) -> false.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.
