%% @doc Supervised, bounded OAuth/OIDC authorization-code flow manager.
%%
%% Provider profiles are immutable operator configuration. Public calls select
%% only a configured provider and an allowed scope subset; adapter modules,
%% client credentials, redirect URIs, resources, nonce and PKCE material never
%% come from the browser. Callback state is claimed atomically before a
%% short-lived supervised worker exchanges the code and stores the validated
%% credential under the original opaque flow reference.
-module(adk_authorization_flow).

-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         begin_flow/2, complete/3, complete/4, cancel/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_PENDING, 1024).
-define(DEFAULT_LIFETIME_MS, 600000).
-define(DEFAULT_EXCHANGE_TIMEOUT_MS, 30000).
-define(DEFAULT_AUTHORIZATION_URI_TIMEOUT_MS, 2000).
-define(DEFAULT_ADAPTER_MAX_HEAP_WORDS, 262144).
-define(DEFAULT_SWEEP_INTERVAL_MS, 1000).
-define(MAX_CODE_BYTES, 8192).
-define(MAX_ID_BYTES, 256).
-define(MAX_URI_BYTES, 8192).
-define(MAX_SCOPES, 64).
-define(MAX_SCOPE_BYTES, 512).
-define(MAX_PROVIDER_PROFILES, 256).
-define(MAX_AUTHORIZATION_URI_TIMEOUT_MS, 4000).
-define(MAX_ADAPTER_HEAP_WORDS, 4000000).
-define(MAX_AUTHORIZATION_RESULT_BYTES, 16384).

-record(state, {
    store_module :: module(),
    store_handle :: adk_credential_store:handle(),
    exchange_sup :: supervisor:sup_ref(),
    profile_table :: ets:tid(),
    flow_table :: ets:tid(),
    profile_count = 0 :: non_neg_integer(),
    pending_count = 0 :: non_neg_integer(),
    inflight_count = 0 :: non_neg_integer(),
    max_pending_flows = ?DEFAULT_MAX_PENDING :: pos_integer(),
    default_lifetime_ms = ?DEFAULT_LIFETIME_MS :: pos_integer(),
    exchange_timeout_ms = ?DEFAULT_EXCHANGE_TIMEOUT_MS :: pos_integer(),
    authorization_uri_timeout_ms =
        ?DEFAULT_AUTHORIZATION_URI_TIMEOUT_MS :: pos_integer(),
    adapter_max_heap_words =
        ?DEFAULT_ADAPTER_MAX_HEAP_WORDS :: pos_integer(),
    sweep_interval_ms = ?DEFAULT_SWEEP_INTERVAL_MS :: pos_integer(),
    sweep_timer :: reference(),
    now_fun :: fun(() -> integer())
}).

-type server() :: gen_server:server_ref().

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, ?MODULE) of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name), Name =/= undefined ->
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

%% @doc Begin a flow. The returned map is directly compatible with
%% adk_suspension:request_credential/2. Its correlation_id is the OAuth state
%% consumed by complete/3 or cancel/2.
-spec begin_flow(server(), map()) -> {ok, map()} | {error, atom()}.
begin_flow(Server, Request)
  when (is_pid(Server) orelse is_atom(Server)), is_map(Request) ->
    safe_call(Server, {begin_flow, Request}, 5000);
begin_flow(_Server, _Request) ->
    {error, invalid_request}.

-spec complete(server(), binary(), binary()) ->
    {ok, map()} | {error, atom()}.
complete(Server, State, Code) ->
    complete(Server, State, Code, 35000).

-spec complete(server(), binary(), binary(), timeout()) ->
    {ok, map()} | {error, atom()}.
complete(Server, State, Code, Timeout)
  when (is_pid(Server) orelse is_atom(Server)), is_binary(State),
       is_binary(Code), is_integer(Timeout), Timeout > 0 ->
    safe_call(Server, {complete, State, Code}, Timeout);
complete(_Server, _State, _Code, _Timeout) ->
    {error, invalid_callback}.

-spec cancel(server(), binary()) -> ok | {error, atom()}.
cancel(Server, State)
  when (is_pid(Server) orelse is_atom(Server)), is_binary(State) ->
    safe_call(Server, {cancel, State}, 5000);
cancel(_Server, _State) ->
    {error, invalid_callback}.

init(Opts) ->
    StoreModule = maps:get(store_module, Opts, adk_credential_store_ets),
    StoreHandle = maps:get(store_handle, Opts, adk_credential_store_ets),
    ExchangeSup = maps:get(exchange_sup, Opts,
                           adk_authorization_flow_exchange_sup),
    %% The application tree deliberately omits profiles from its child spec so
    %% client secrets cannot be printed in a supervisor report. Standalone
    %% supervisors may still inject profiles explicitly for deterministic
    %% testing or an embedding application's own protected configuration.
    Profiles0 = load_provider_profiles(Opts),
    MaxPending = maps:get(max_pending_flows, Opts, ?DEFAULT_MAX_PENDING),
    DefaultLifetime = maps:get(default_lifetime_ms, Opts,
                               ?DEFAULT_LIFETIME_MS),
    ExchangeTimeout = maps:get(exchange_timeout_ms, Opts,
                               ?DEFAULT_EXCHANGE_TIMEOUT_MS),
    AuthorizationUriTimeout = maps:get(
                                authorization_uri_timeout_ms, Opts,
                                ?DEFAULT_AUTHORIZATION_URI_TIMEOUT_MS),
    AdapterMaxHeap = maps:get(adapter_max_heap_words, Opts,
                              ?DEFAULT_ADAPTER_MAX_HEAP_WORDS),
    SweepInterval = maps:get(sweep_interval_ms, Opts,
                             ?DEFAULT_SWEEP_INTERVAL_MS),
    NowFun = maps:get(now_fun, Opts,
                      fun() -> erlang:monotonic_time(millisecond) end),
    ok = validate_options(StoreModule, ExchangeSup, MaxPending,
                          DefaultLifetime, ExchangeTimeout,
                          AuthorizationUriTimeout, AdapterMaxHeap,
                          SweepInterval, NowFun),
    Profiles = case normalize_profiles(Profiles0, DefaultLifetime) of
        {ok, Normalized} -> Normalized;
        error -> erlang:error(invalid_authorization_flow_options)
    end,
    ProfileTable = ets:new(adk_authorization_profiles,
                           [set, private, {read_concurrency, true}]),
    true = ets:insert(ProfileTable, maps:to_list(Profiles)),
    FlowTable = ets:new(adk_authorization_flows,
                        [set, private, {read_concurrency, true},
                         {write_concurrency, true}]),
    Timer = erlang:send_after(SweepInterval, self(), sweep_expired_flows),
    {ok, #state{store_module = StoreModule,
                store_handle = StoreHandle,
                exchange_sup = ExchangeSup,
                profile_table = ProfileTable,
                flow_table = FlowTable,
                profile_count = map_size(Profiles),
                max_pending_flows = MaxPending,
                default_lifetime_ms = DefaultLifetime,
                exchange_timeout_ms = ExchangeTimeout,
                authorization_uri_timeout_ms = AuthorizationUriTimeout,
                adapter_max_heap_words = AdapterMaxHeap,
                sweep_interval_ms = SweepInterval,
                sweep_timer = Timer,
                now_fun = NowFun}}.

handle_call({begin_flow, Request}, _From, State0) ->
    State = cleanup_expired(State0),
    case normalize_begin_request(Request, State#state.profile_table) of
        {ok, Principal, Provider, Scopes, Profile} ->
            case flow_count(State) < State#state.max_pending_flows of
                true ->
                    {Reply, State1} = create_flow(
                                        Principal, Provider, Scopes,
                                        Profile, State),
                    {reply, Reply, State1};
                false ->
                    {reply, {error, capacity_exceeded}, State}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({complete, StateToken, Code}, From, State0) ->
    State = cleanup_expired(State0),
    case valid_state(StateToken) andalso valid_code(Code) of
        false ->
            {reply, {error, invalid_callback}, State};
        true ->
            claim_callback(StateToken, Code, From, State)
    end;
handle_call({cancel, StateToken}, _From, State0) ->
    State = cleanup_expired(State0),
    cancel_flow(StateToken, State);
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({authorization_exchange_result, Generation, Worker, Result},
            State) ->
    {noreply, finish_exchange(Generation, Worker, Result, State)};
handle_info({authorization_exchange_timeout, Generation}, State) ->
    {noreply, timeout_exchange(Generation, State)};
handle_info({'DOWN', Monitor, process, Worker, _Reason}, State) ->
    {noreply, failed_worker(Monitor, Worker, State)};
handle_info(sweep_expired_flows, State0) ->
    State1 = cleanup_expired(State0),
    Timer = erlang:send_after(State1#state.sweep_interval_ms,
                              self(), sweep_expired_flows),
    {noreply, State1#state{sweep_timer = Timer}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = erlang:cancel_timer(State#state.sweep_timer),
    ets:foldl(
      fun({{state, _StateToken}, pending, Flow}, ok) ->
              delete_pending(Flow, State);
         ({{state, _StateToken}, inflight, Flight}, ok) ->
              cancel_timer(maps:get(timer, Flight)),
              adk_authorization_flow_exchange_sup:cancel_exchange(
                State#state.exchange_sup, maps:get(generation, Flight)),
              delete_pending(maps:get(flow, Flight), State),
              safe_reply(maps:get(from, Flight),
                         {error, authorization_service_unavailable});
         (_Index, ok) -> ok
      end, ok, State#state.flow_table),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Profiles, PKCE values, nonce, codes, client credentials, callback From
%% references and raw adapter results are intentionally absent from status.
format_status(Status) ->
    maps:map(
      fun(state, State) when is_record(State, state) ->
              #{configured_providers => State#state.profile_count,
                pending_flows => State#state.pending_count,
                inflight_exchanges => State#state.inflight_count,
                max_pending_flows => State#state.max_pending_flows,
                authorization_uri_timeout_ms =>
                    State#state.authorization_uri_timeout_ms,
                adapter_max_heap_words =>
                    State#state.adapter_max_heap_words};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

safe_call(Server, Request, Timeout) ->
    try gen_server:call(Server, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, authorization_timeout};
        exit:_ -> {error, authorization_service_unavailable}
    end.

load_provider_profiles(Opts) ->
    case maps:find(provider_profiles, Opts) of
        {ok, Profiles} -> Profiles;
        error ->
            case maps:find(profile_loader, Opts) of
                {ok, {Module, Function}}
                  when is_atom(Module), Module =/= undefined,
                       is_atom(Function), Function =/= undefined ->
                    load_profiles(Module, Function);
                {ok, _InvalidLoader} ->
                    erlang:error(invalid_authorization_flow_options);
                error ->
                    application:get_env(
                      erlang_adk, auth_authorization_profiles, #{})
            end
    end.

load_profiles(Module, Function) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, Function, 0) of
                true ->
                    try Module:Function() of
                        Profiles when is_map(Profiles) -> Profiles;
                        _ -> erlang:error(invalid_authorization_flow_options)
                    catch
                        _:_ -> erlang:error(invalid_authorization_flow_options)
                    end;
                false -> erlang:error(invalid_authorization_flow_options)
            end;
        _ -> erlang:error(invalid_authorization_flow_options)
    end.

create_flow(Principal, Provider, Scopes, Profile, State) ->
    StateToken = opaque_value(<<"oauth_state_">>),
    Nonce = opaque_value(<<"oauth_nonce_">>),
    Verifier = base64url(crypto:strong_rand_bytes(32)),
    Challenge = base64url(crypto:hash(sha256, Verifier)),
    Resource = maps:get(resource, Profile),
    RedirectUri = maps:get(redirect_uri, Profile),
    Adapter = maps:get(adapter_module, Profile),
    AdapterContext = maps:get(adapter_context, Profile),
    FlowOpts = #{state => StateToken,
                 nonce => Nonce,
                 pkce_verifier => Verifier,
                 redirect_uri => RedirectUri,
                 scopes => Scopes,
                 resource => Resource},
    case safe_authorization_uri(
           Adapter, AdapterContext, FlowOpts, Challenge,
           State#state.authorization_uri_timeout_ms,
           State#state.adapter_max_heap_words) of
        {ok, AuthorizationUri} ->
            CreatedAt = erlang:system_time(millisecond),
            PendingCredential = #{kind => oauth_authorization_pending,
                                  correlation_id => StateToken,
                                  created_at => CreatedAt},
            case put_pending_credential(Principal, Provider,
                                        PendingCredential, State) of
                {ok, FlowRef} ->
                    ExpiresAt = now_ms(State) + maps:get(lifetime_ms, Profile),
                    Flow = #{principal => Principal,
                             provider => Provider,
                             flow_ref => FlowRef,
                             pending_credential => PendingCredential,
                             adapter_module => Adapter,
                             adapter_context => AdapterContext,
                             nonce => Nonce,
                             pkce_verifier => Verifier,
                             redirect_uri => RedirectUri,
                             scopes => Scopes,
                             resource => Resource,
                             expires_at => ExpiresAt},
                    Public = #{<<"provider">> => Provider,
                               <<"scheme">> => <<"oidc">>,
                               <<"authorization_uri">> => AuthorizationUri,
                               <<"scopes">> => Scopes,
                               <<"correlation_id">> => StateToken,
                               <<"credential_flow_ref">> => FlowRef,
                               <<"pkce_challenge">> => Challenge,
                               <<"pkce_method">> => <<"S256">>,
                               <<"prompt">> => maps:get(prompt, Profile)},
                    true = ets:insert(
                             State#state.flow_table,
                             {{state, StateToken}, pending, Flow}),
                    {{ok, Public},
                     State#state{pending_count =
                                     State#state.pending_count + 1}};
                {error, _} = Error ->
                    {Error, State}
            end;
        {error, _} = Error ->
            {Error, State}
    end.

safe_authorization_uri(Adapter, AdapterContext, FlowOpts, Challenge,
                       Timeout, MaxHeapWords) ->
    Callback = fun() ->
        Adapter:authorization_uri(AdapterContext, FlowOpts)
    end,
    Normalizer = fun(Result) ->
        normalize_authorization_uri_result(Result, FlowOpts, Challenge)
    end,
    case adk_auth_callback_guard:run(
           Callback, Normalizer, Timeout, MaxHeapWords,
           ?MAX_AUTHORIZATION_RESULT_BYTES) of
        {ok, Result} -> Result;
        timeout -> {error, authorization_unavailable};
        failed -> {error, authorization_unavailable}
    end.

normalize_authorization_uri_result(Result, FlowOpts, Challenge) ->
    case Result of
        {ok, Uri0} ->
            case to_binary(Uri0) of
                {ok, Uri} -> validate_authorization_uri(
                               Uri, FlowOpts, Challenge);
                error -> {error, authorization_unavailable}
            end;
        {error, _Reason} -> {error, authorization_unavailable};
        _Other -> {error, authorization_unavailable}
    end.

validate_authorization_uri(Uri, FlowOpts, Challenge)
  when byte_size(Uri) =< ?MAX_URI_BYTES ->
    try uri_string:parse(Uri) of
        #{scheme := <<"https">>, host := Host, query := Query} = Parsed
          when is_binary(Host), byte_size(Host) > 0 ->
            Pairs = uri_string:dissect_query(Query),
            Required = [{<<"state">>, maps:get(state, FlowOpts)},
                        {<<"nonce">>, maps:get(nonce, FlowOpts)},
                        {<<"redirect_uri">>, maps:get(redirect_uri, FlowOpts)},
                        {<<"code_challenge">>, Challenge},
                        {<<"code_challenge_method">>, <<"S256">>}],
            ResourceOk = case maps:get(resource, FlowOpts) of
                undefined -> true;
                Resource -> exact_query_value(<<"resource">>, Resource, Pairs)
            end,
            ScopeOk = valid_scope_query(
                        maps:get(scopes, FlowOpts), Pairs),
            case not maps:is_key(userinfo, Parsed) andalso
                 not maps:is_key(fragment, Parsed) andalso
                 lists:all(fun({Key, Value}) ->
                               exact_query_value(Key, Value, Pairs)
                           end, Required) andalso ResourceOk andalso ScopeOk of
                true -> {ok, Uri};
                false -> {error, authorization_unavailable}
            end;
        _ -> {error, authorization_unavailable}
    catch
        _:_ -> {error, authorization_unavailable}
    end;
validate_authorization_uri(_Uri, _FlowOpts, _Challenge) ->
    {error, authorization_unavailable}.

exact_query_value(Key, Expected, Pairs) ->
    [Value || {PairKey, Value} <- Pairs, PairKey =:= Key] =:= [Expected].

valid_scope_query(ExpectedScopes, Pairs) ->
    case [Value || {<<"scope">>, Value} <- Pairs] of
        [ScopeValue] when is_binary(ScopeValue) ->
            lists:usort(binary:split(ScopeValue, <<" ">>, [global])) =:=
                lists:usort(ExpectedScopes);
        _ -> false
    end.

put_pending_credential(Principal, Provider, Pending, State) ->
    try (State#state.store_module):put(
          State#state.store_handle, Principal, Provider, Pending) of
        {ok, FlowRef} ->
            case adk_credential_store:is_ref(FlowRef) of
                true -> {ok, FlowRef};
                false -> {error, credential_store_unavailable}
            end;
        {error, _Reason} -> {error, credential_store_unavailable};
        _Other -> {error, credential_store_unavailable}
    catch
        _:_ -> {error, credential_store_unavailable}
    end.

claim_callback(StateToken, Code, From, State) ->
    case ets:lookup(State#state.flow_table, {state, StateToken}) of
        [{{state, StateToken}, pending, Flow}] ->
            true = ets:delete(State#state.flow_table,
                              {state, StateToken}),
            State1 = State#state{pending_count =
                                     State#state.pending_count - 1},
            start_exchange(StateToken, Code, From, Flow, State1);
        _ ->
            {reply, {error, invalid_or_expired_state}, State}
    end.

start_exchange(StateToken, Code, From, Flow, State) ->
    Generation = make_ref(),
    Deadline = erlang:monotonic_time(millisecond)
               + State#state.exchange_timeout_ms,
    case adk_authorization_flow_exchange_sup:start_exchange(
           State#state.exchange_sup, self(), Generation, Deadline,
           State#state.adapter_max_heap_words) of
        {ok, Worker} when is_pid(Worker) ->
            Monitor = erlang:monitor(process, Worker),
            Timer = erlang:send_after(
                      State#state.exchange_timeout_ms, self(),
                      {authorization_exchange_timeout, Generation}),
            Flight = #{generation => Generation,
                       worker => Worker,
                       monitor => Monitor,
                       timer => Timer,
                       from => From,
                       flow => Flow},
            true = ets:insert(
                     State#state.flow_table,
                     [{{state, StateToken}, inflight, Flight},
                      {{generation, Generation}, StateToken},
                      {{monitor, Monitor}, StateToken}]),
            Work = exchange_work(Code, Flow, State),
            ok = adk_authorization_flow_worker:perform(Worker, Work),
            {noreply, State#state{inflight_count =
                                      State#state.inflight_count + 1}};
        _ ->
            delete_pending(Flow, State),
            {reply, {error, authorization_service_unavailable}, State}
    end.

exchange_work(Code, Flow, State) ->
    ExchangeOpts = #{state => maps:get(correlation_id,
                                       maps:get(pending_credential, Flow)),
                     nonce => maps:get(nonce, Flow),
                     pkce_verifier => maps:get(pkce_verifier, Flow),
                     redirect_uri => maps:get(redirect_uri, Flow),
                     scopes => maps:get(scopes, Flow),
                     resource => maps:get(resource, Flow)},
    #{adapter_module => maps:get(adapter_module, Flow),
      adapter_context => maps:get(adapter_context, Flow),
      code => Code,
      exchange_opts => ExchangeOpts,
      store_module => State#state.store_module,
      store_handle => State#state.store_handle,
      principal => maps:get(principal, Flow),
      provider => maps:get(provider, Flow),
      flow_ref => maps:get(flow_ref, Flow),
      pending_credential => maps:get(pending_credential, Flow)}.

finish_exchange(Generation, Worker, Result, State) ->
    case flight_by_generation(Generation, State) of
        {ok, StateToken, #{worker := Worker} = Flight} ->
            Flow = maps:get(flow, Flight),
            ExpectedFlowRef = maps:get(flow_ref, Flow),
            Reply = case Result of
                {ok, ExpectedFlowRef} ->
                    {ok, #{<<"credential_ref">> => ExpectedFlowRef,
                           <<"correlation_id">> => StateToken}};
                {error, credential_store_unavailable} ->
                    delete_pending(Flow, State),
                    {error, credential_store_unavailable};
                {error, authorization_timeout} ->
                    delete_pending(Flow, State),
                    {error, authorization_timeout};
                _ ->
                    delete_pending(Flow, State),
                    {error, authorization_failed}
            end,
            safe_reply(maps:get(from, Flight), Reply),
            remove_flight(StateToken, Flight, State);
        _ -> State
    end.

timeout_exchange(Generation, State) ->
    case flight_by_generation(Generation, State) of
        {ok, StateToken, Flight} ->
            adk_authorization_flow_exchange_sup:cancel_exchange(
              State#state.exchange_sup, Generation),
            delete_pending(maps:get(flow, Flight), State),
            safe_reply(maps:get(from, Flight),
                       {error, authorization_timeout}),
            remove_flight(StateToken, Flight, State);
        error -> State
    end.

failed_worker(Monitor, Worker, State) ->
    case flight_by_monitor(Monitor, Worker, State) of
        {ok, StateToken, Flight} ->
            delete_pending(maps:get(flow, Flight), State),
            safe_reply(maps:get(from, Flight),
                       {error, authorization_failed}),
            remove_flight(StateToken, Flight, State);
        error -> State
    end.

cancel_flow(StateToken, State) ->
    case ets:take(State#state.flow_table, {state, StateToken}) of
        [{{state, StateToken}, pending, Flow}] ->
            delete_pending(Flow, State),
            {reply, ok,
             State#state{pending_count = State#state.pending_count - 1}};
        [{{state, StateToken}, inflight, Flight}] ->
                    Generation = maps:get(generation, Flight),
                    adk_authorization_flow_exchange_sup:cancel_exchange(
                      State#state.exchange_sup, Generation),
                    delete_pending(maps:get(flow, Flight), State),
                    safe_reply(maps:get(from, Flight),
                               {error, authorization_cancelled}),
            {reply, ok, remove_flight(StateToken, Flight, State)};
        _ ->
            {reply, {error, invalid_or_expired_state}, State}
    end.

remove_flight(StateToken, Flight, State) ->
    cancel_timer(maps:get(timer, Flight)),
    _ = erlang:demonitor(maps:get(monitor, Flight), [flush]),
    Generation = maps:get(generation, Flight),
    Monitor = maps:get(monitor, Flight),
    true = ets:delete(State#state.flow_table, {state, StateToken}),
    true = ets:delete(State#state.flow_table, {generation, Generation}),
    true = ets:delete(State#state.flow_table, {monitor, Monitor}),
    State#state{inflight_count = State#state.inflight_count - 1}.

flight_by_generation(Generation, State) ->
    case ets:lookup(State#state.flow_table, {generation, Generation}) of
        [{{generation, Generation}, StateToken}] ->
            case ets:lookup(State#state.flow_table, {state, StateToken}) of
                [{{state, StateToken}, inflight, Flight}] ->
                    {ok, StateToken, Flight};
                _ -> error
            end;
        _ -> error
    end.

flight_by_monitor(Monitor, Worker, State) ->
    case ets:lookup(State#state.flow_table, {monitor, Monitor}) of
        [{{monitor, Monitor}, StateToken}] ->
            case ets:lookup(State#state.flow_table, {state, StateToken}) of
                [{{state, StateToken}, inflight,
                  #{worker := Worker} = Flight}] ->
                    {ok, StateToken, Flight};
                _ -> error
            end;
        _ -> error
    end.

cleanup_expired(State) ->
    Now = now_ms(State),
    Expired = ets:foldl(
      fun({{state, StateToken}, pending, Flow}, Acc) ->
              case maps:get(expires_at, Flow) =< Now of
                  true -> [{StateToken, Flow} | Acc];
                  false -> Acc
              end;
         (_Index, Acc) -> Acc
      end, [], State#state.flow_table),
    lists:foreach(
      fun({StateToken, Flow}) ->
          true = ets:delete(State#state.flow_table, {state, StateToken}),
          delete_pending(Flow, State)
      end, Expired),
    State#state{pending_count =
                    State#state.pending_count - length(Expired)}.

delete_pending(Flow, State) ->
    try (State#state.store_module):delete(
          State#state.store_handle, maps:get(principal, Flow),
          maps:get(provider, Flow), maps:get(flow_ref, Flow)) of
        _ -> ok
    catch
        _:_ -> ok
    end.

normalize_begin_request(#{principal := Principal,
                          provider := Provider} = Request, ProfileTable) ->
    case exact_keys(Request, [principal, provider, scopes]) andalso
         valid_text(Principal, ?MAX_ID_BYTES) andalso
         valid_text(Provider, ?MAX_ID_BYTES) of
        false -> {error, invalid_request};
        true ->
            case ets:lookup(ProfileTable, Provider) of
                [] -> {error, unknown_provider};
                [{Provider, Profile}] ->
                    Scopes = maps:get(scopes, Request,
                                      maps:get(default_scopes, Profile)),
                    case valid_scopes(Scopes) andalso
                         lists:all(
                           fun(Scope) ->
                               lists:member(Scope,
                                            maps:get(allowed_scopes, Profile))
                           end, Scopes) of
                        true -> {ok, Principal, Provider,
                                 lists:usort(Scopes), Profile};
                        false -> {error, scope_not_allowed}
                    end
            end
    end;
normalize_begin_request(_Request, _Profiles) ->
    {error, invalid_request}.

normalize_profiles(Profiles, DefaultLifetime)
  when is_map(Profiles), map_size(Profiles) =< ?MAX_PROVIDER_PROFILES ->
    maps:fold(
      fun(_Provider, _Profile, error) -> error;
         (Provider, Profile0, {ok, Acc}) ->
              case normalize_profile(Provider, Profile0,
                                     DefaultLifetime) of
                  {ok, Profile} -> {ok, maps:put(Provider, Profile, Acc)};
                  error -> error
              end
      end, {ok, #{}}, Profiles);
normalize_profiles(_Profiles, _DefaultLifetime) -> error.

normalize_profile(Provider, #{adapter_module := Adapter,
                              adapter_context := AdapterContext,
                              redirect_uri := RedirectUri,
                              allowed_scopes := AllowedScopes} = Profile0,
                  DefaultLifetime) ->
    AllowedKeys = [adapter_module, adapter_context, redirect_uri,
                   allowed_scopes, default_scopes, resource,
                   lifetime_ms, prompt],
    Profile = Profile0#{default_scopes =>
                           maps:get(default_scopes, Profile0,
                                    AllowedScopes),
                       resource => maps:get(resource, Profile0, undefined),
                       lifetime_ms => maps:get(lifetime_ms, Profile0,
                                               DefaultLifetime),
                       prompt => maps:get(
                                   prompt, Profile0,
                                   <<"Authentication and user consent are required.">>)},
    DefaultScopes = maps:get(default_scopes, Profile),
    Lifetime = maps:get(lifetime_ms, Profile),
    case valid_text(Provider, ?MAX_ID_BYTES) andalso
         exact_keys(Profile, AllowedKeys) andalso
         is_atom(Adapter) andalso Adapter =/= undefined andalso
         is_map(AdapterContext) andalso adapter_context_valid(
                                           Adapter, AdapterContext) andalso
         safe_external_size(AdapterContext, 65536) andalso
         valid_https_uri(RedirectUri) andalso
         valid_scopes(AllowedScopes) andalso valid_scopes(DefaultScopes) andalso
         lists:all(fun(Scope) -> lists:member(Scope, AllowedScopes) end,
                   DefaultScopes) andalso
         valid_resource(maps:get(resource, Profile)) andalso
         is_integer(Lifetime) andalso Lifetime > 0 andalso
         Lifetime =< ?DEFAULT_LIFETIME_MS andalso
         valid_text(maps:get(prompt, Profile), 4096) andalso
         safe_external_size(Profile, 262144) of
        true ->
            {ok, Profile#{allowed_scopes => lists:usort(AllowedScopes),
                          default_scopes => lists:usort(DefaultScopes)}};
        false -> error
    end;
normalize_profile(_Provider, _Profile, _DefaultLifetime) -> error.

adapter_context_valid(Adapter, Context) ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            case erlang:function_exported(Adapter, validate_context, 1) andalso
                 erlang:function_exported(Adapter, authorization_uri, 2) andalso
                 erlang:function_exported(Adapter, exchange_code, 3) of
                true ->
                    try Adapter:validate_context(Context) of
                        ok -> true;
                        _ -> false
                    catch _:_ -> false
                    end;
                false -> false
            end;
        _ -> false
    end.

validate_options(StoreModule, ExchangeSup, MaxPending, Lifetime,
                 ExchangeTimeout, AuthorizationUriTimeout,
                 AdapterMaxHeap, SweepInterval, NowFun) ->
    case is_atom(StoreModule) andalso StoreModule =/= undefined andalso
         (is_atom(ExchangeSup) orelse is_pid(ExchangeSup)) andalso
         is_integer(MaxPending) andalso MaxPending > 0 andalso
         MaxPending =< 100000 andalso
         is_integer(Lifetime) andalso Lifetime > 0 andalso
         Lifetime =< ?DEFAULT_LIFETIME_MS andalso
         is_integer(ExchangeTimeout) andalso ExchangeTimeout > 0 andalso
         ExchangeTimeout =< 300000 andalso
         is_integer(AuthorizationUriTimeout) andalso
         AuthorizationUriTimeout > 0 andalso
         AuthorizationUriTimeout =< ?MAX_AUTHORIZATION_URI_TIMEOUT_MS andalso
         is_integer(AdapterMaxHeap) andalso AdapterMaxHeap >= 16384 andalso
         AdapterMaxHeap =< ?MAX_ADAPTER_HEAP_WORDS andalso
         is_integer(SweepInterval) andalso SweepInterval > 0 andalso
         SweepInterval =< Lifetime andalso is_function(NowFun, 0) of
        true -> ok;
        false -> erlang:error(invalid_authorization_flow_options)
    end.

valid_https_uri(Uri) when is_binary(Uri), byte_size(Uri) > 0,
                               byte_size(Uri) =< ?MAX_URI_BYTES ->
    try uri_string:parse(Uri) of
        #{scheme := <<"https">>, host := Host} = Parsed
          when is_binary(Host), byte_size(Host) > 0 ->
            not maps:is_key(userinfo, Parsed) andalso
            not maps:is_key(fragment, Parsed);
        _ -> false
    catch _:_ -> false
    end;
valid_https_uri(_) -> false.

valid_resource(undefined) -> true;
valid_resource(Resource) -> valid_https_uri(Resource).

valid_scopes(Scopes) when is_list(Scopes), Scopes =/= [],
                          length(Scopes) =< ?MAX_SCOPES ->
    lists:all(fun(Scope) -> valid_text(Scope, ?MAX_SCOPE_BYTES) end,
              Scopes) andalso
    length(lists:usort(Scopes)) =:= length(Scopes);
valid_scopes(_) -> false.

valid_state(<<"oauth_state_", Encoded/binary>>) ->
    byte_size(Encoded) =:= 43 andalso base64url_chars(Encoded);
valid_state(_) -> false.

valid_code(Code) ->
    byte_size(Code) > 0 andalso byte_size(Code) =< ?MAX_CODE_BYTES.

valid_text(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                            byte_size(Value) =< Max ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end;
valid_text(_, _) -> false.

safe_external_size(Term, Max) ->
    try erlang:external_size(Term) =< Max catch _:_ -> false end.

exact_keys(Map, Allowed) ->
    map_size(maps:without(Allowed, Map)) =:= 0.

flow_count(State) ->
    State#state.pending_count + State#state.inflight_count.

now_ms(#state{now_fun = NowFun}) ->
    try NowFun() of
        Value when is_integer(Value) -> Value
    catch
        _:_ -> erlang:monotonic_time(millisecond)
    end.

opaque_value(Prefix) ->
    Encoded = base64url(crypto:strong_rand_bytes(32)),
    <<Prefix/binary, Encoded/binary>>.

base64url(Binary) ->
    base64:encode(Binary, #{mode => urlsafe, padding => false}).

base64url_chars(<<>>) -> true;
base64url_chars(<<Char, Rest/binary>>)
  when (Char >= $A andalso Char =< $Z) orelse
       (Char >= $a andalso Char =< $z) orelse
       (Char >= $0 andalso Char =< $9) orelse
       Char =:= $- orelse Char =:= $_ ->
    base64url_chars(Rest);
base64url_chars(_) -> false.

to_binary(Value) ->
    try erlang:iolist_size(Value) of
        Size when Size > 0, Size =< ?MAX_URI_BYTES ->
            {ok, iolist_to_binary(Value)};
        _ -> error
    catch _:_ -> error
    end.

safe_reply(From, Reply) ->
    try gen_server:reply(From, Reply) catch _:_ -> ok end.

cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.
