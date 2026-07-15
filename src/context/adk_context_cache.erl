%% @doc Owner-bound registry for provider-managed model-request prefix caches.
%%
%% Entries are scoped by application, user, model, policy, provider, prefix,
%% and TTL policy. Concurrent misses for the same key use one provider create
%% operation. Provider resource names remain private behind runtime leases;
%% public results contain only versioned, JSON-safe lifecycle and telemetry
%% metadata. This module never stores or returns a model response.
-module(adk_context_cache).

-behaviour(gen_server).

-export([version/0, capabilities/0, compile/1,
         start/1, start_link/1, stop/1,
         acquire/5, resolve/2,
         invalidate/3, invalidate/4, status/1,
         scope_status/4, invalidate_scope/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(VERSION, 1).
-define(DEFAULT_MAX_ENTRIES, 256).
-define(DEFAULT_TTL_MS, 300000).
-define(DEFAULT_MAX_TTL_MS, 3600000).
-define(DEFAULT_CREATE_TIMEOUT_MS, 5000).
-define(DEFAULT_DELETE_TIMEOUT_MS, 2000).
-define(DEFAULT_MAX_PREFIX_BYTES, 4194304).
-define(DEFAULT_MAX_SCOPE_BYTES, 16384).
-define(DEFAULT_MAX_PROVIDER_METADATA_BYTES, 65536).
-define(DEFAULT_MAX_WAITERS, 128).
-define(DEFAULT_MAX_HEAP_WORDS, 2000000).
-define(DEFAULT_BYTES_PER_TOKEN, 4).
-define(DEFAULT_MIN_PREFIX_TOKENS, 1).
-define(MAX_RESOURCE_NAME_BYTES, 8192).

-type lease() :: {adk_context_cache_lease, pid(), binary(), pos_integer()}.
-type policy() :: map().
-export_type([lease/0, policy/0]).

-spec version() -> pos_integer().
version() -> ?VERSION.

-spec capabilities() -> map().
capabilities() ->
    #{version => ?VERSION,
      semantics => provider_request_prefix_cache,
      response_cache => false,
      scope => [app, user, model, policy, provider, prefix, ttl],
      lifecycle => [create, reuse, expire, invalidate, resolve_private_lease],
      concurrency => #{single_flight => true,
                       caller_deadlines => true,
                       owner_cancellation => true,
                       bounded_registry => true},
      public_metadata => #{json_safe => true,
                           provider_resource_names => omitted,
                           credentials => omitted}}.

-spec compile(map()) -> {ok, policy()} | {error, term()}.
compile(Opts) when is_map(Opts) ->
    case unknown_keys(Opts, option_keys()) of
        [] -> compile_known(Opts);
        Unknown ->
            {error, {invalid_context_cache_options,
                     {unknown_keys, lists:sort(Unknown)}}}
    end;
compile(_) ->
    {error, {invalid_context_cache_options, expected_map}}.

-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Opts) ->
    case compile(Opts) of
        {ok, Policy} -> gen_server:start(?MODULE, {self(), Policy}, []);
        {error, _} = Error -> Error
    end.

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    case compile(Opts) of
        {ok, Policy} -> gen_server:start_link(?MODULE, {self(), Policy}, []);
        {error, _} = Error -> Error
    end.

-spec stop(pid()) -> ok.
stop(Cache) -> gen_server:call(Cache, graceful_stop, infinity).

%% @doc Acquire or create a private prefix-cache lease.
%%
%% Scope must contain exactly `app', `user', `model', and `policy'. Prefix is
%% secret-pruned before hashing or provider delivery. Options are `ttl_ms', an
%% absolute monotonic `deadline_ms', and optional provider `estimated_tokens'.
-spec acquire(pid(), module(), map(), map(), map()) ->
    {ok, lease(), map()} | {bypass, map()} | {error, term()}.
acquire(Cache, Provider, Scope, Prefix, Opts)
  when is_pid(Cache), is_atom(Provider), is_map(Opts) ->
    gen_server:call(Cache, {acquire, Provider, Scope, Prefix, Opts}, infinity);
acquire(_, _, _, _, _) -> {error, invalid_context_cache_arguments}.

%% @doc Resolve a lease for immediate provider-adapter use.
%%
%% The returned resource name is runtime-private and must never be persisted in
%% events, telemetry, logs, checkpoints, or developer API results.
-spec resolve(pid(), lease()) -> {ok, binary()} | {error, term()}.
resolve(Cache, Lease) when is_pid(Cache) ->
    gen_server:call(Cache, {resolve, Lease}, infinity);
resolve(_, _) -> {error, invalid_context_cache_lease}.

%% @doc Invalidate all entries and in-flight creates for one provider scope.
-spec invalidate(pid(), module(), map()) -> {ok, map()} | {error, term()}.
invalidate(Cache, Provider, Scope) ->
    gen_server:call(Cache, {invalidate_scope, Provider, Scope}, infinity).

%% @doc Invalidate one provider scope and sanitized prefix, across TTLs.
-spec invalidate(pid(), module(), map(), map()) ->
    {ok, map()} | {error, term()}.
invalidate(Cache, Provider, Scope, Prefix) ->
    gen_server:call(Cache, {invalidate_prefix, Provider, Scope, Prefix},
                    infinity).

-spec status(pid()) -> {ok, map()}.
status(Cache) -> gen_server:call(Cache, status, infinity).

%% @doc Return content-free lifecycle counts for one exact provider scope.
%%
%% Filtering stays inside the private registry. The result never includes a
%% cache pid, lease, provider resource name, prefix, policy value, or
%% credential. `deadline_ms' is an absolute monotonic deadline and is checked
%% again by the registry before it examines its entries.
-spec scope_status(pid(), module(), map(), map()) ->
    {ok, map()} | {error, term()}.
scope_status(Cache, Provider, Scope, Opts)
  when is_pid(Cache), is_atom(Provider), is_map(Scope), is_map(Opts) ->
    gen_server:call(Cache, {scope_status, Provider, Scope, Opts}, infinity);
scope_status(_, _, _, _) -> {error, invalid_context_cache_arguments}.

%% @doc Invalidate one exact provider scope with an absolute deadline.
%%
%% This is intentionally distinct from the compatibility invalidate/3 API so
%% checked administrative callers can fail closed if a queued request reaches
%% the registry after its authorization window has expired.
-spec invalidate_scope(pid(), module(), map(), map()) ->
    {ok, map()} | {error, term()}.
invalidate_scope(Cache, Provider, Scope, Opts)
  when is_pid(Cache), is_atom(Provider), is_map(Scope), is_map(Opts) ->
    gen_server:call(Cache,
                    {invalidate_scope_checked, Provider, Scope, Opts},
                    infinity);
invalidate_scope(_, _, _, _) -> {error, invalid_context_cache_arguments}.

init({Owner, Policy}) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    {ok, #{owner => Owner,
           owner_monitor => OwnerMonitor,
           policy => Policy,
           entries => #{},
           flights => #{},
           monitors => #{},
           delete_workers => #{}}}.

handle_call({acquire, Provider, Scope0, Prefix0, Opts}, From, State0) ->
    Policy = maps:get(policy, State0),
    case prepare_acquire(Provider, Scope0, Prefix0, Opts, Policy) of
        {ok, Prepared} -> handle_acquire(Prepared, From, State0);
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({resolve, Lease}, _From, State0) ->
    handle_resolve(Lease, State0);
handle_call({invalidate_scope, Provider, Scope0}, _From, State0) ->
    case prepare_scope(Provider, Scope0, maps:get(policy, State0)) of
        {ok, ScopeInfo} ->
            {Reply, State} = invalidate_matching(
                               fun(Entry) ->
                                   entry_scope_match(Entry, ScopeInfo)
                               end,
                               fun(Flight) ->
                                   flight_scope_match(Flight, ScopeInfo)
                               end, State0),
            {reply, {ok, Reply}, State};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({invalidate_prefix, Provider, Scope0, Prefix0}, _From, State0) ->
    Policy = maps:get(policy, State0),
    case {prepare_scope(Provider, Scope0, Policy),
          sanitize_prefix(Prefix0, Policy)} of
        {{ok, ScopeInfo}, {ok, _Prefix, PrefixFingerprint, _Bytes}} ->
            {Reply, State} = invalidate_matching(
                               fun(Entry) ->
                                   entry_scope_match(Entry, ScopeInfo)
                                   andalso maps:get(prefix_fingerprint, Entry)
                                           =:= PrefixFingerprint
                               end,
                               fun(Flight) ->
                                   flight_scope_match(Flight, ScopeInfo)
                                   andalso maps:get(prefix_fingerprint, Flight)
                                           =:= PrefixFingerprint
                               end, State0),
            {reply, {ok, Reply}, State};
        {{error, _} = Error, _} -> {reply, Error, State0};
        {_, {error, _} = Error} -> {reply, Error, State0}
    end;
handle_call(graceful_stop, _From, State0) ->
    %% Provider deletes run in parallel and share one bounded timeout window.
    %% A hard process crash cannot perform this handshake and remains covered
    %% by the provider TTL configured when each resource was created.
    graceful_delete_entries(State0),
    {stop, normal, ok, State0#{entries => #{}}};
handle_call({scope_status, Provider, Scope0, Opts}, _From, State0) ->
    State = purge_expired(State0),
    case prepare_lifecycle_scope(Provider, Scope0, Opts, State) of
        {ok, ScopeInfo} ->
            {reply, {ok, scope_status_metadata(ScopeInfo, State)}, State};
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call({invalidate_scope_checked, Provider, Scope0, Opts}, _From,
            State0) ->
    State1 = purge_expired(State0),
    case prepare_lifecycle_scope(Provider, Scope0, Opts, State1) of
        {ok, ScopeInfo} ->
            {Invalidated0, State} = invalidate_matching(
                                      fun(Entry) ->
                                          entry_scope_match(Entry, ScopeInfo)
                                      end,
                                      fun(Flight) ->
                                          flight_scope_match(Flight, ScopeInfo)
                                      end, State1),
            Invalidated = Invalidated0#{
                            <<"scope_fingerprint">> =>
                                maps:get(scope_fingerprint, ScopeInfo),
                            <<"provider">> =>
                                maps:get(provider_name, ScopeInfo),
                            <<"model">> =>
                                maps:get(<<"model">>,
                                         maps:get(scope, ScopeInfo))},
            {reply, {ok, Invalidated}, State};
        {error, _} = Error -> {reply, Error, State1}
    end;
handle_call(status, _From, State0) ->
    State = purge_expired(State0),
    {reply, {ok, status_metadata(State)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_context_cache_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({cache_provider_result, Key, WorkerRef, Outcome}, State0) ->
    case maps:find(Key, maps:get(flights, State0)) of
        {ok, #{worker_ref := WorkerRef} = Flight} ->
            State = finish_flight(Key, Flight, Outcome, State0),
            {noreply, State};
        _ -> {noreply, State0}
    end;
handle_info({flight_deadline, Key, WorkerRef}, State0) ->
    case maps:find(Key, maps:get(flights, State0)) of
        {ok, #{worker_ref := WorkerRef} = Flight} ->
            stop_worker(maps:get(worker, Flight),
                        maps:get(worker_monitor, Flight)),
            State = finish_flight(Key, Flight,
                                  {error, provider_deadline_exceeded}, State0),
            {noreply, State};
        _ -> {noreply, State0}
    end;
handle_info({waiter_deadline, Key, WaiterId}, State0) ->
    {noreply, expire_waiter(Key, WaiterId, State0)};
handle_info({delete_deadline, Pid, Monitor}, State0) ->
    case maps:find(Pid, maps:get(delete_workers, State0)) of
        {ok, #{monitor := Monitor}} ->
            stop_worker(Pid, Monitor),
            DeleteWorkers = maps:remove(
                              Pid, maps:get(delete_workers, State0)),
            State = remove_monitor(
                      Monitor, State0#{delete_workers => DeleteWorkers}),
            {noreply, State};
        _ -> {noreply, State0}
    end;
handle_info({'DOWN', Ref, process, Pid, Reason}, State0) ->
    handle_down(Ref, Pid, Reason, State0);
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
      fun(_Key, Flight) ->
          exit(maps:get(worker, Flight), kill)
      end, maps:get(flights, State, #{})),
    maps:foreach(fun(Pid, _Tracking) -> exit(Pid, kill) end,
                 maps:get(delete_workers, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

compile_known(Opts) ->
    Values = [
        positive(max_entries, Opts, ?DEFAULT_MAX_ENTRIES, 1, 10000),
        positive(default_ttl_ms, Opts, ?DEFAULT_TTL_MS, 1, 86400000),
        positive(max_ttl_ms, Opts, ?DEFAULT_MAX_TTL_MS, 1, 86400000),
        positive(create_timeout_ms, Opts, ?DEFAULT_CREATE_TIMEOUT_MS,
                 1, 300000),
        positive(delete_timeout_ms, Opts, ?DEFAULT_DELETE_TIMEOUT_MS,
                 1, 300000),
        positive(max_prefix_bytes, Opts, ?DEFAULT_MAX_PREFIX_BYTES,
                 1, 67108864),
        positive(max_scope_bytes, Opts, ?DEFAULT_MAX_SCOPE_BYTES,
                 128, 1048576),
        positive(max_provider_metadata_bytes, Opts,
                 ?DEFAULT_MAX_PROVIDER_METADATA_BYTES, 1, 1048576),
        positive(max_waiters_per_key, Opts, ?DEFAULT_MAX_WAITERS,
                 1, 10000),
        positive(max_heap_words, Opts, ?DEFAULT_MAX_HEAP_WORDS,
                 1024, 16000000),
        positive(bytes_per_token, Opts, ?DEFAULT_BYTES_PER_TOKEN, 1, 1024),
        non_negative(min_prefix_tokens, Opts, ?DEFAULT_MIN_PREFIX_TOKENS,
                     0, 1000000000),
        failure_mode(maps:get(failure_mode, Opts, bypass))
    ],
    case first_error(Values) of
        {error, _} = Error -> Error;
        none ->
            [MaxEntries, DefaultTtl, MaxTtl, CreateTimeout, DeleteTimeout,
             MaxPrefix, MaxScope, MaxMetadata, MaxWaiters, MaxHeap,
             BytesPerToken, MinTokens, FailureMode] =
                [Value || {ok, Value} <- Values],
            case DefaultTtl =< MaxTtl of
                true ->
                    {ok, #{'$adk_context_cache_policy' => ?VERSION,
                           max_entries => MaxEntries,
                           default_ttl_ms => DefaultTtl,
                           max_ttl_ms => MaxTtl,
                           create_timeout_ms => CreateTimeout,
                           delete_timeout_ms => DeleteTimeout,
                           max_prefix_bytes => MaxPrefix,
                           max_scope_bytes => MaxScope,
                           max_provider_metadata_bytes => MaxMetadata,
                           max_waiters_per_key => MaxWaiters,
                           max_heap_words => MaxHeap,
                           bytes_per_token => BytesPerToken,
                           min_prefix_tokens => MinTokens,
                           failure_mode => FailureMode}};
                false ->
                    {error, {invalid_context_cache_options,
                             default_ttl_exceeds_max_ttl}}
            end
    end.

option_keys() ->
    [max_entries, default_ttl_ms, max_ttl_ms, create_timeout_ms,
     delete_timeout_ms, max_prefix_bytes, max_scope_bytes,
     max_provider_metadata_bytes, max_waiters_per_key, max_heap_words,
     bytes_per_token, min_prefix_tokens, failure_mode].

positive(Key, Opts, Default, Minimum, Maximum) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value >= Minimum, Value =< Maximum ->
            {ok, Value};
        _ -> {error, {invalid_context_cache_options, Key}}
    end.

non_negative(Key, Opts, Default, Minimum, Maximum) ->
    positive(Key, Opts, Default, Minimum, Maximum).

failure_mode(bypass) -> {ok, bypass};
failure_mode(error) -> {ok, error};
failure_mode(_) -> {error, {invalid_context_cache_options, failure_mode}}.

first_error([]) -> none;
first_error([{error, _} = Error | _]) -> Error;
first_error([_ | Rest]) -> first_error(Rest).

unknown_keys(Map, Allowed) -> maps:keys(maps:without(Allowed, Map)).

prepare_acquire(Provider, Scope0, Prefix0, Opts, Policy) ->
    case unknown_keys(Opts, [ttl_ms, deadline_ms, estimated_tokens]) of
        [] ->
            case {prepare_scope(Provider, Scope0, Policy),
                  sanitize_prefix(Prefix0, Policy),
                  acquire_values(Opts, Policy)} of
                {{ok, ScopeInfo},
                 {ok, Prefix, PrefixFingerprint, PrefixBytes},
                 {ok, Ttl, Deadline, Tokens0}} ->
                    Tokens = case Tokens0 of
                        automatic -> estimate_tokens(PrefixBytes, Policy);
                        Value -> Value
                    end,
                    ProviderName = maps:get(provider_name, ScopeInfo),
                    Scope = maps:get(scope, ScopeInfo),
                    Key = fingerprint(
                            {?VERSION, ProviderName, Scope,
                             PrefixFingerprint, Ttl}),
                    {ok, ScopeInfo#{key => Key,
                                   prefix => Prefix,
                                   prefix_fingerprint => PrefixFingerprint,
                                   prefix_bytes => PrefixBytes,
                                   ttl_ms => Ttl,
                                   deadline_ms => Deadline,
                                   estimated_tokens => Tokens}};
                {{error, _} = Error, _, _} -> Error;
                {_, {error, _} = Error, _} -> Error;
                {_, _, {error, _} = Error} -> Error
            end;
        Unknown ->
            {error, {invalid_context_cache_acquire_options,
                     {unknown_keys, lists:sort(Unknown)}}}
    end.

acquire_values(Opts, Policy) ->
    Ttl = maps:get(ttl_ms, Opts, maps:get(default_ttl_ms, Policy)),
    Deadline = maps:get(deadline_ms, Opts,
                        monotonic_ms() + maps:get(create_timeout_ms, Policy)),
    Tokens = maps:get(estimated_tokens, Opts, automatic),
    case is_integer(Ttl) andalso Ttl > 0
         andalso Ttl =< maps:get(max_ttl_ms, Policy)
         andalso is_integer(Deadline)
         andalso (Tokens =:= automatic orelse
                  (is_integer(Tokens) andalso Tokens >= 0)) of
        true -> {ok, Ttl, Deadline, Tokens};
        false -> {error, invalid_context_cache_acquire_options}
    end.

prepare_scope(Provider, Scope0, Policy) when is_atom(Provider), is_map(Scope0) ->
    case validate_provider(Provider) of
        ok ->
            case contains_sensitive_key(Scope0) of
                true -> {error, sensitive_context_cache_scope};
                false -> normalize_scope(Provider, Scope0, Policy)
            end;
        {error, _} = Error -> Error
    end;
prepare_scope(_, _, _) -> {error, invalid_context_cache_scope}.

normalize_scope(Provider, Scope0, Policy) ->
    case adk_json:normalize(Scope0) of
        {ok, Scope} when is_map(Scope) ->
            Required = [<<"app">>, <<"user">>, <<"model">>, <<"policy">>],
            case lists:sort(maps:keys(Scope)) =:= lists:sort(Required) of
                true -> validate_scope_values(Provider, Scope, Policy);
                false -> {error, invalid_context_cache_scope_keys}
            end;
        _ -> {error, invalid_context_cache_scope}
    end.

prepare_lifecycle_scope(Provider, Scope0, Opts, State) ->
    case maps:keys(Opts) of
        [deadline_ms] ->
            Deadline = maps:get(deadline_ms, Opts),
            case is_integer(Deadline) andalso Deadline > monotonic_ms() of
                true -> prepare_scope(Provider, Scope0, maps:get(policy, State));
                false -> {error, context_cache_deadline_exceeded}
            end;
        _ -> {error, invalid_context_cache_lifecycle_options}
    end.

validate_scope_values(Provider, Scope, Policy) ->
    App = maps:get(<<"app">>, Scope),
    User = maps:get(<<"user">>, Scope),
    Model = maps:get(<<"model">>, Scope),
    ScopeBytes = byte_size(jsx:encode(Scope)),
    case valid_identity(App) andalso valid_identity(User)
         andalso valid_identity(Model)
         andalso is_map(maps:get(<<"policy">>, Scope))
         andalso ScopeBytes =< maps:get(max_scope_bytes, Policy) of
        true ->
            ProviderName = atom_to_binary(Provider, utf8),
            {ok, #{provider => Provider,
                   provider_name => ProviderName,
                   scope => Scope,
                   scope_fingerprint => fingerprint(Scope)}};
        false -> {error, invalid_context_cache_scope}
    end.

valid_identity(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0
    andalso byte_size(Value) =< 256 andalso valid_utf8(Value).

validate_provider(Provider) ->
    case code:ensure_loaded(Provider) of
        {module, Provider} ->
            case erlang:function_exported(Provider, create, 2)
                 andalso erlang:function_exported(Provider, delete, 2) of
                true -> validate_provider_capabilities(Provider);
                false -> {error, {invalid_context_cache_provider,
                                  missing_callback}}
            end;
        _ -> {error, {invalid_context_cache_provider, unavailable}}
    end.

validate_provider_capabilities(Provider) ->
    case erlang:function_exported(Provider, capabilities, 0) of
        false -> ok;
        true ->
            try Provider:capabilities() of
                Capabilities when is_map(Capabilities) -> ok;
                _ -> {error, {invalid_context_cache_provider,
                              capabilities}}
            catch _:_ ->
                {error, {invalid_context_cache_provider, capabilities}}
            end
    end.

sanitize_prefix(Prefix0, Policy) when is_map(Prefix0) ->
    case adk_context_guard:sanitize_value(Prefix0) of
        {ok, Prefix} when is_map(Prefix) ->
            Bytes = byte_size(jsx:encode(Prefix)),
            case Bytes > 0 andalso Bytes =< maps:get(max_prefix_bytes, Policy) of
                true -> {ok, Prefix, fingerprint(Prefix), Bytes};
                false -> {error, context_cache_prefix_size}
            end;
        _ -> {error, invalid_context_cache_prefix}
    end;
sanitize_prefix(_, _) -> {error, invalid_context_cache_prefix}.

handle_acquire(Prepared, From, State0) ->
    Policy = maps:get(policy, State0),
    Tokens = maps:get(estimated_tokens, Prepared),
    case {maps:get(deadline_ms, Prepared) =< monotonic_ms(),
          Tokens < maps:get(min_prefix_tokens, Policy)} of
        {true, _} ->
            {reply, failure_reply(deadline_exceeded, Prepared, State0),
             State0};
        {false, true} ->
            Meta = public_metadata(<<"below_minimum">>, Prepared, State0,
                                   #{<<"estimated_context_units">> => Tokens}),
            {reply, {bypass, Meta}, State0};
        {false, false} ->
            handle_eligible_acquire(Prepared, From, State0)
    end.

handle_eligible_acquire(Prepared, From, State0) ->
    Key = maps:get(key, Prepared),
    State1 = expire_key(Key, State0),
    case maps:find(Key, maps:get(entries, State1)) of
        {ok, Entry} ->
            Meta = public_metadata(<<"hit">>, Entry, State1, #{}),
            {reply, {ok, lease(self(), Key, Entry), Meta}, State1};
        error ->
            case maps:find(Key, maps:get(flights, State1)) of
                {ok, Flight} -> join_flight(Key, Flight, Prepared,
                                            From, State1);
                error -> start_flight_or_fallback(Prepared, From, State1)
            end
    end.

join_flight(Key, Flight, Prepared, From, State) ->
    Max = maps:get(max_waiters_per_key, maps:get(policy, State)),
    case map_size(maps:get(waiters, Flight)) >= Max of
        true ->
            Reply = failure_reply(waiter_limit, Prepared, State),
            {reply, Reply, State};
        false ->
            {Flight1, State1} = add_waiter(Key, Flight, Prepared, From, State),
            Flights = (maps:get(flights, State1))#{Key => Flight1},
            {noreply, State1#{flights => Flights}}
    end.

start_flight_or_fallback(Prepared, From, State) ->
    Policy = maps:get(policy, State),
    Reserved = map_size(maps:get(entries, State))
               + map_size(maps:get(flights, State)),
    case Reserved >= maps:get(max_entries, Policy) of
        true ->
            {reply, failure_reply(registry_full, Prepared, State), State};
        false -> start_flight(Prepared, From, State)
    end.

start_flight(Prepared, From, State0) ->
    Parent = self(),
    Key = maps:get(key, Prepared),
    WorkerRef = make_ref(),
    Policy = maps:get(policy, State0),
    Provider = maps:get(provider, Prepared),
    Deadline = monotonic_ms() + maps:get(create_timeout_ms, Policy),
    Request = provider_request(Prepared, Deadline),
    WorkerFun = fun() ->
        Outcome = try Provider:create(maps:get(prefix, Prepared), Request) of
            Result -> normalize_provider_outcome(Result, Policy)
        catch
            Class:_Reason -> {error, {provider_crashed, Class}}
        end,
        Parent ! {cache_provider_result, Key, WorkerRef, Outcome}
    end,
    SpawnOpts = [monitor,
                 {max_heap_size,
                  #{size => maps:get(max_heap_words, Policy),
                    kill => true, error_logger => false}}],
    {Worker, WorkerMonitor} = spawn_opt(WorkerFun, SpawnOpts),
    Timer = erlang:send_after(maps:get(create_timeout_ms, Policy), self(),
                              {flight_deadline, Key, WorkerRef}),
    Flight0 = Prepared#{worker => Worker,
                        worker_ref => WorkerRef,
                        worker_monitor => WorkerMonitor,
                        provider_deadline_ms => Deadline,
                        provider_timer => Timer,
                        waiters => #{}},
    Monitors0 = maps:get(monitors, State0),
    State1 = State0#{monitors =>
                         Monitors0#{WorkerMonitor => {worker, Key}}},
    {Flight, State2} = add_waiter(Key, Flight0, Prepared, From, State1),
    Flights = (maps:get(flights, State2))#{Key => Flight},
    {noreply, State2#{flights => Flights}}.

provider_request(Prepared, Deadline) ->
    #{<<"schema_version">> => ?VERSION,
      <<"scope">> => maps:get(scope, Prepared),
      <<"ttl_ms">> => maps:get(ttl_ms, Prepared),
      <<"estimated_context_units">> =>
          maps:get(estimated_tokens, Prepared),
      <<"deadline_ms">> => Deadline}.

add_waiter(Key, Flight, Prepared, From, State0) ->
    WaiterId = make_ref(),
    Pid = element(1, From),
    Monitor = erlang:monitor(process, Pid),
    Delay = erlang:max(0, maps:get(deadline_ms, Prepared) - monotonic_ms()),
    Timer = erlang:send_after(Delay, self(),
                              {waiter_deadline, Key, WaiterId}),
    Waiter = #{id => WaiterId, from => From, owner => Pid,
               monitor => Monitor, timer => Timer,
               deadline_ms => maps:get(deadline_ms, Prepared)},
    Waiters = (maps:get(waiters, Flight))#{WaiterId => Waiter},
    Monitors = (maps:get(monitors, State0))#{Monitor =>
                                                {waiter, Key, WaiterId}},
    {Flight#{waiters => Waiters}, State0#{monitors => Monitors}}.

finish_flight(Key, Flight, Outcome, State0) ->
    State1 = remove_worker_tracking(Flight, State0),
    case Outcome of
        {ok, Resource, ProviderMeta} ->
            finish_success(Key, Flight, Resource, ProviderMeta, State1);
        {error, Reason} ->
            reply_flight_failure(Key, Flight, Reason, State1)
    end.

normalize_provider_outcome({ok, Resource}, Policy) ->
    normalize_provider_outcome({ok, Resource, #{}}, Policy);
normalize_provider_outcome({ok, Resource, Metadata}, Policy)
  when is_binary(Resource), is_map(Metadata) ->
    case valid_utf8(Resource) andalso byte_size(Resource) > 0
         andalso byte_size(Resource) =< ?MAX_RESOURCE_NAME_BYTES of
        false -> {error, invalid_provider_resource};
        true ->
            case adk_context_guard:sanitize_value(Metadata) of
                {ok, SafeMeta} when is_map(SafeMeta) ->
                    case byte_size(jsx:encode(SafeMeta)) =<
                         maps:get(max_provider_metadata_bytes, Policy) of
                        true -> {ok, Resource, SafeMeta};
                        false -> {error, provider_metadata_too_large}
                    end;
                _ -> {error, invalid_provider_metadata}
            end
    end;
normalize_provider_outcome({error, Reason}, _Policy) ->
    {error, reason_tag(Reason)};
normalize_provider_outcome(_, _Policy) -> {error, invalid_provider_return}.

finish_success(Key, Flight, Resource, ProviderMeta, State0) ->
    %% Timer and provider-result messages have different senders, so mailbox
    %% order alone cannot enforce an absolute caller deadline. Recheck every
    %% waiter synchronously before installing the provider resource. If the
    %% result was queued first but processed after all deadlines, delete the
    %% orphan resource instead of turning it into a successful cache entry.
    {LiveFlight, State1} = expire_overdue_waiters(Flight, State0),
    case map_size(maps:get(waiters, LiveFlight)) of
        0 ->
            State2 = spawn_delete(LiveFlight#{resource => Resource}, State1),
            remove_flight(Key, State2);
        _ ->
            Generation = erlang:unique_integer([monotonic, positive]),
            Entry = (maps:without(
                       [prefix, worker, worker_ref, worker_monitor,
                        provider_timer, waiters, deadline_ms,
                        provider_deadline_ms],
                       LiveFlight))#{resource => Resource,
                                     provider_metadata => ProviderMeta,
                                     generation => Generation,
                                     created_ms => monotonic_ms(),
                                     expires_ms => monotonic_ms()
                                                   + maps:get(ttl_ms,
                                                              LiveFlight)},
            Entries = (maps:get(entries, State1))#{Key => Entry},
            State2 = State1#{entries => Entries},
            %% Provider metadata stays registry-private because a provider can
            %% accidentally repeat its resource name in that map. Public
            %% lifecycle metadata is generated only from core-owned fields.
            Meta = public_metadata(<<"created">>, Entry, State2, #{}),
            Reply = {ok, lease(self(), Key, Entry), Meta},
            State3 = reply_waiters(LiveFlight, Reply, State2),
            remove_flight(Key, State3)
    end.

expire_overdue_waiters(Flight, State0) ->
    Now = monotonic_ms(),
    {Live, State} = maps:fold(
      fun(Id, Waiter, {WaitersAcc, StateAcc}) ->
          case maps:get(deadline_ms, Waiter) =< Now of
              true ->
                  cleanup_waiter(Waiter, StateAcc),
                  gen_server:reply(
                    maps:get(from, Waiter),
                    failure_reply(deadline_exceeded, Flight, StateAcc)),
                  {WaitersAcc, remove_waiter_monitor(Waiter, StateAcc)};
              false ->
                  {WaitersAcc#{Id => Waiter}, StateAcc}
          end
      end,
      {#{}, State0},
      maps:get(waiters, Flight)),
    {Flight#{waiters => Live}, State}.

reply_flight_failure(Key, Flight, Reason, State0) ->
    Reply = failure_reply(Reason, Flight, State0),
    State1 = reply_waiters(Flight, Reply, State0),
    remove_flight(Key, State1).

remove_worker_tracking(Flight, State0) ->
    _ = erlang:cancel_timer(maps:get(provider_timer, Flight)),
    Monitor = maps:get(worker_monitor, Flight),
    erlang:demonitor(Monitor, [flush]),
    Monitors = maps:remove(Monitor, maps:get(monitors, State0)),
    State0#{monitors => Monitors}.

reply_waiters(Flight, Reply, State0) ->
    maps:fold(
      fun(_Id, Waiter, StateAcc) ->
          cleanup_waiter(Waiter, StateAcc),
          gen_server:reply(maps:get(from, Waiter), Reply),
          remove_waiter_monitor(Waiter, StateAcc)
      end, State0, maps:get(waiters, Flight)).

cleanup_waiter(Waiter, _State) ->
    _ = erlang:cancel_timer(maps:get(timer, Waiter)),
    erlang:demonitor(maps:get(monitor, Waiter), [flush]),
    ok.

remove_waiter_monitor(Waiter, State) ->
    Monitor = maps:get(monitor, Waiter),
    State#{monitors => maps:remove(Monitor, maps:get(monitors, State))}.

remove_flight(Key, State) ->
    State#{flights => maps:remove(Key, maps:get(flights, State))}.

expire_waiter(Key, WaiterId, State0) ->
    case maps:find(Key, maps:get(flights, State0)) of
        {ok, Flight} ->
            case maps:take(WaiterId, maps:get(waiters, Flight)) of
                {Waiter, Remaining} ->
                    cleanup_waiter(Waiter, State0),
                    gen_server:reply(maps:get(from, Waiter),
                                     failure_reply(deadline_exceeded,
                                                   Flight, State0)),
                    State1 = remove_waiter_monitor(Waiter, State0),
                    Flight1 = Flight#{waiters => Remaining},
                    case map_size(Remaining) of
                        0 -> cancel_empty_flight(Key, Flight1, State1);
                        _ ->
                            Flights = (maps:get(flights, State1))#{Key => Flight1},
                            State1#{flights => Flights}
                    end;
                error -> State0
            end;
        error -> State0
    end.

cancel_empty_flight(Key, Flight, State0) ->
    stop_worker(maps:get(worker, Flight), maps:get(worker_monitor, Flight)),
    State1 = remove_worker_tracking(Flight, State0),
    remove_flight(Key, State1).

handle_resolve({adk_context_cache_lease, Cache, Key, Generation}, State0)
  when Cache =:= self(), is_binary(Key), is_integer(Generation) ->
    State = expire_key(Key, State0),
    case maps:find(Key, maps:get(entries, State)) of
        {ok, #{generation := Generation, resource := Resource}} ->
            {reply, {ok, Resource}, State};
        _ -> {reply, {error, context_cache_lease_expired}, State}
    end;
handle_resolve(_, State) ->
    {reply, {error, invalid_context_cache_lease}, State}.

lease(Cache, Key, Entry) ->
    {adk_context_cache_lease, Cache, Key, maps:get(generation, Entry)}.

expire_key(Key, State0) ->
    case maps:find(Key, maps:get(entries, State0)) of
        {ok, Entry} ->
            case maps:get(expires_ms, Entry) =< monotonic_ms() of
                true ->
                    Entries = maps:remove(Key, maps:get(entries, State0)),
                    spawn_delete(Entry, State0#{entries => Entries});
                false -> State0
            end;
        error -> State0
    end.

purge_expired(State0) ->
    lists:foldl(fun expire_key/2, State0,
                maps:keys(maps:get(entries, State0))).

invalidate_matching(EntryPred, FlightPred, State0) ->
    {EntriesRemoved, State1} = remove_matching_entries(EntryPred, State0),
    {FlightsRemoved, State2} = remove_matching_flights(FlightPred, State1),
    Meta = #{<<"schema_version">> => ?VERSION,
             <<"status">> => <<"invalidated">>,
             <<"entries">> => EntriesRemoved,
             <<"in_flight">> => FlightsRemoved,
             <<"telemetry">> =>
                 #{<<"event">> => <<"erlang_adk.context_cache.invalidate">>,
                   <<"measurements">> =>
                       #{<<"entries">> => EntriesRemoved,
                         <<"in_flight">> => FlightsRemoved},
                   <<"metadata">> =>
                       #{<<"schema_version">> => ?VERSION}}},
    {Meta, State2}.

remove_matching_entries(Pred, State0) ->
    maps:fold(
      fun(Key, Entry, {Count, StateAcc}) ->
          case Pred(Entry) of
              true ->
                  Entries = maps:remove(Key, maps:get(entries, StateAcc)),
                  {Count + 1,
                   spawn_delete(Entry, StateAcc#{entries => Entries})};
              false -> {Count, StateAcc}
          end
      end, {0, State0}, maps:get(entries, State0)).

remove_matching_flights(Pred, State0) ->
    maps:fold(
      fun(Key, Flight, {Count, StateAcc}) ->
          case Pred(Flight) of
              true ->
                  Reply = failure_reply(invalidated, Flight, StateAcc),
                  State1 = reply_waiters(Flight, Reply, StateAcc),
                  stop_worker(maps:get(worker, Flight),
                              maps:get(worker_monitor, Flight)),
                  State2 = remove_worker_tracking(Flight, State1),
                  {Count + 1, remove_flight(Key, State2)};
              false -> {Count, StateAcc}
          end
      end, {0, State0}, maps:get(flights, State0)).

entry_scope_match(Entry, ScopeInfo) ->
    maps:get(provider, Entry) =:= maps:get(provider, ScopeInfo)
    andalso maps:get(scope, Entry) =:= maps:get(scope, ScopeInfo).

flight_scope_match(Flight, ScopeInfo) ->
    maps:get(provider, Flight) =:= maps:get(provider, ScopeInfo)
    andalso maps:get(scope, Flight) =:= maps:get(scope, ScopeInfo).

spawn_delete(Entry, State0) ->
    Policy = maps:get(policy, State0),
    case map_size(maps:get(delete_workers, State0)) >=
         maps:get(max_entries, Policy) of
        true ->
            %% The provider TTL remains the final cleanup boundary. Skipping
            %% best-effort deletion under bounded cleanup pressure is safer
            %% than growing an unbounded set of stuck delete workers.
            State0;
        false ->
            Provider = maps:get(provider, Entry),
            Resource = maps:get(resource, Entry),
            Timeout = maps:get(delete_timeout_ms, Policy),
            Request = #{<<"schema_version">> => ?VERSION,
                        <<"scope">> => maps:get(scope, Entry),
                        <<"deadline_ms">> => monotonic_ms() + Timeout},
            Fun = fun() ->
                _ = try Provider:delete(Resource, Request)
                    catch _:_ -> {error, provider_delete_crashed}
                    end,
                ok
            end,
            {Pid, Monitor} = spawn_monitor(Fun),
            Timer = erlang:send_after(
                      Timeout, self(), {delete_deadline, Pid, Monitor}),
            DeleteWorkers = (maps:get(delete_workers, State0))#{
                                Pid => #{monitor => Monitor, timer => Timer}},
            Monitors = (maps:get(monitors, State0))#{Monitor => {delete, Pid}},
            State0#{delete_workers => DeleteWorkers, monitors => Monitors}
    end.

graceful_delete_entries(State) ->
    Entries = maps:values(maps:get(entries, State)),
    Policy = maps:get(policy, State),
    Timeout = maps:get(delete_timeout_ms, Policy),
    Deadline = monotonic_ms() + Timeout,
    Parent = self(),
    Ref = make_ref(),
    Workers = lists:foldl(
      fun(Entry, Acc) ->
          Pid = spawn(fun() ->
              Provider = maps:get(provider, Entry),
              Resource = maps:get(resource, Entry),
              Request = #{<<"schema_version">> => ?VERSION,
                          <<"scope">> => maps:get(scope, Entry),
                          <<"deadline_ms">> => Deadline},
              _ = try Provider:delete(Resource, Request)
                  catch _:_ -> {error, provider_delete_crashed}
                  end,
              Parent ! {graceful_cache_delete_done, Ref, self()}
          end),
          Acc#{Pid => true}
      end, #{}, Entries),
    await_graceful_deletes(Ref, Workers, Deadline).

await_graceful_deletes(_Ref, Workers, _Deadline)
  when map_size(Workers) =:= 0 -> ok;
await_graceful_deletes(Ref, Workers, Deadline) ->
    Remaining = Deadline - monotonic_ms(),
    case Remaining > 0 of
        false -> stop_graceful_delete_workers(Workers);
        true ->
            receive
                {graceful_cache_delete_done, Ref, Pid} ->
                    await_graceful_deletes(
                      Ref, maps:remove(Pid, Workers), Deadline)
            after Remaining ->
                stop_graceful_delete_workers(Workers)
            end
    end.

stop_graceful_delete_workers(Workers) ->
    maps:foreach(
      fun(Pid, _Value) ->
          case is_process_alive(Pid) of
              true -> exit(Pid, kill);
              false -> ok
          end
      end, Workers),
    ok.

failure_reply(Reason, Prepared, State) ->
    Meta = public_metadata(<<"bypass">>, Prepared, State,
                           #{<<"reason">> => reason_binary(Reason)}),
    case maps:get(failure_mode, maps:get(policy, State)) of
        bypass -> {bypass, Meta};
        error -> {error, {context_cache_unavailable, reason_tag(Reason)}}
    end.

public_metadata(Status, Info, State, Extra) ->
    Ttl = maps:get(ttl_ms, Info, 0),
    Base = #{<<"schema_version">> => ?VERSION,
             <<"semantics">> => <<"provider_request_prefix_cache">>,
             <<"response_cache">> => false,
             <<"status">> => Status,
             <<"key_fingerprint">> => maps:get(key, Info),
             <<"scope_fingerprint">> => maps:get(scope_fingerprint, Info),
             <<"prefix_fingerprint">> => maps:get(prefix_fingerprint, Info),
             <<"provider">> => maps:get(provider_name, Info),
             <<"model">> => maps:get(<<"model">>, maps:get(scope, Info)),
             <<"ttl_ms">> => Ttl},
    SafeExtra = case adk_context_guard:sanitize_value(Extra) of
        {ok, Map} when is_map(Map) -> Map;
        _ -> #{}
    end,
    Meta0 = maps:merge(Base, SafeExtra),
    Telemetry = #{<<"event">> => <<"erlang_adk.context_cache.acquire">>,
                  <<"measurements">> =>
                      #{<<"entries">> => map_size(maps:get(entries, State)),
                        <<"in_flight">> => map_size(maps:get(flights, State)),
                        <<"ttl_ms">> => Ttl},
                  <<"metadata">> =>
                      #{<<"schema_version">> => ?VERSION,
                        <<"status">> => Status,
                        <<"provider">> => maps:get(provider_name, Info),
                        <<"model">> => maps:get(
                                           <<"model">>, maps:get(scope, Info)),
                        <<"key_fingerprint">> => maps:get(key, Info),
                        <<"scope_fingerprint">> =>
                            maps:get(scope_fingerprint, Info)}},
    Meta0#{<<"telemetry">> => Telemetry}.

status_metadata(State) ->
    Policy = maps:get(policy, State),
    Waiters = maps:fold(
                fun(_Key, Flight, Count) ->
                    Count + map_size(maps:get(waiters, Flight))
                end, 0, maps:get(flights, State)),
    #{<<"schema_version">> => ?VERSION,
      <<"semantics">> => <<"provider_request_prefix_cache">>,
      <<"response_cache">> => false,
      <<"entries">> => map_size(maps:get(entries, State)),
      <<"in_flight">> => map_size(maps:get(flights, State)),
      <<"waiters">> => Waiters,
      <<"max_entries">> => maps:get(max_entries, Policy),
      <<"max_waiters_per_key">> => maps:get(max_waiters_per_key, Policy)}.

scope_status_metadata(ScopeInfo, State) ->
    EntryCount = maps:fold(
                   fun(_Key, Entry, Count) ->
                       case entry_scope_match(Entry, ScopeInfo) of
                           true -> Count + 1;
                           false -> Count
                       end
                   end, 0, maps:get(entries, State)),
    {FlightCount, WaiterCount} = maps:fold(
      fun(_Key, Flight, {Flights, Waiters}) ->
          case flight_scope_match(Flight, ScopeInfo) of
              true -> {Flights + 1,
                       Waiters + map_size(maps:get(waiters, Flight))};
              false -> {Flights, Waiters}
          end
      end, {0, 0}, maps:get(flights, State)),
    Status = case EntryCount + FlightCount of
        0 -> <<"empty">>;
        _ -> <<"active">>
    end,
    Scope = maps:get(scope, ScopeInfo),
    #{<<"schema_version">> => ?VERSION,
      <<"semantics">> => <<"provider_request_prefix_cache">>,
      <<"response_cache">> => false,
      <<"status">> => Status,
      <<"scope_fingerprint">> => maps:get(scope_fingerprint, ScopeInfo),
      <<"provider">> => maps:get(provider_name, ScopeInfo),
      <<"model">> => maps:get(<<"model">>, Scope),
      <<"entries">> => EntryCount,
      <<"in_flight">> => FlightCount,
      <<"waiters">> => WaiterCount}.

handle_down(Ref, Pid, Reason, State0) ->
    case Ref =:= maps:get(owner_monitor, State0) of
        true -> {stop, normal, State0};
        false ->
            case maps:find(Ref, maps:get(monitors, State0)) of
                {ok, {waiter, Key, WaiterId}} ->
                    {noreply, remove_dead_waiter(Key, WaiterId, State0)};
                {ok, {worker, Key}} ->
                    case maps:find(Key, maps:get(flights, State0)) of
                        {ok, Flight} ->
                            State = finish_flight(
                                      Key, Flight,
                                      {error, {provider_worker_down,
                                               reason_tag(Reason)}}, State0),
                            {noreply, State};
                        error -> {noreply, remove_monitor(Ref, State0)}
                    end;
                {ok, {delete, Pid}} ->
                    #{timer := Timer} = maps:get(
                                          Pid,
                                          maps:get(delete_workers, State0)),
                    _ = erlang:cancel_timer(Timer),
                    DeleteWorkers = maps:remove(
                                      Pid, maps:get(delete_workers, State0)),
                    State = remove_monitor(Ref,
                                           State0#{delete_workers =>
                                                       DeleteWorkers}),
                    {noreply, State};
                error -> {noreply, State0}
            end
    end.

remove_dead_waiter(Key, WaiterId, State0) ->
    case maps:find(Key, maps:get(flights, State0)) of
        {ok, Flight} ->
            case maps:take(WaiterId, maps:get(waiters, Flight)) of
                {Waiter, Remaining} ->
                    _ = erlang:cancel_timer(maps:get(timer, Waiter)),
                    State1 = remove_waiter_monitor(Waiter, State0),
                    Flight1 = Flight#{waiters => Remaining},
                    case map_size(Remaining) of
                        0 -> cancel_empty_flight(Key, Flight1, State1);
                        _ ->
                            Flights = (maps:get(flights, State1))#{Key => Flight1},
                            State1#{flights => Flights}
                    end;
                error -> State0
            end;
        error -> State0
    end.

remove_monitor(Ref, State) ->
    State#{monitors => maps:remove(Ref, maps:get(monitors, State))}.

stop_worker(Pid, Monitor) ->
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush])
    end.

estimate_tokens(0, _Policy) -> 0;
estimate_tokens(Bytes, Policy) ->
    Divisor = maps:get(bytes_per_token, Policy),
    (Bytes + Divisor - 1) div Divisor.

contains_sensitive_key(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          adk_context_guard:sensitive_key(Key)
          orelse contains_sensitive_key(Value)
      end, maps:to_list(Map));
contains_sensitive_key(List) when is_list(List) ->
    lists:any(fun contains_sensitive_key/1, List);
contains_sensitive_key(_) -> false.

reason_binary(Reason) -> atom_to_binary(reason_tag(Reason), utf8).

reason_tag(Reason) when is_atom(Reason) -> Reason;
reason_tag(Reason) when is_tuple(Reason), tuple_size(Reason) > 0,
                        is_atom(element(1, Reason)) -> element(1, Reason);
reason_tag(_) -> unspecified.

fingerprint(Value) ->
    hex(crypto:hash(sha256, term_to_binary(Value, [deterministic]))).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>
       || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.

monotonic_ms() -> erlang:monotonic_time(millisecond).

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end.
