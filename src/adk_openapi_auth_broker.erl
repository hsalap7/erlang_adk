%% @doc Per-principal OpenAPI credential broker.
%%
%% A broker is normally supervised by the host application and bound to one
%% principal. Its state contains opaque credential references and routing
%% metadata only. API keys and fixed bearer tokens are fetched from a private
%% credential store; OAuth access tokens come from adk_token_manager. Tool
%% arguments and Runner context are never accepted by this process.
-module(adk_openapi_auth_broker).

-behaviour(gen_server).
-behaviour(adk_openapi_auth_manager).

-export([start_link/1, child_spec/1, resolve/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {
    bindings :: map(),
    timeout_ms :: pos_integer(),
    max_inflight :: pos_integer(),
    inflight = #{} :: map(),
    monitors = #{} :: map()
}).

-define(DEFAULT_TIMEOUT_MS, 10000).
-define(MAX_TIMEOUT_MS, 60000).
-define(DEFAULT_MAX_INFLIGHT, 32).
-define(MAX_INFLIGHT, 1024).
-define(CALL_TIMEOUT_MS, 61000).
-define(MAX_OPTIONS_BYTES, 2097152).
-define(MAX_BINDINGS_BYTES, 1048576).
-define(MAX_BINDING_BYTES, 65536).
-define(MAX_BINDINGS, 256).
-define(MAX_REQUEST_BYTES, 65536).
-define(MAX_CREDENTIAL_BYTES, 1048576).
-define(MAX_ID_BYTES, 4096).
-define(MAX_NAME_BYTES, 256).
-define(MAX_PARAMETER_BYTES, 512).
-define(MAX_SCOPES, 64).
-define(MAX_SCOPE_BYTES, 512).
-define(MAX_AUDIENCE_BYTES, 8192).
-define(MAX_API_KEY_BYTES, 16384).
-define(MAX_BEARER_BYTES, 131072).
-define(WORKER_MAX_HEAP_WORDS, 300000).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    case valid_start_options(Opts) of
        true ->
            case maps:get(name, Opts, undefined) of
                undefined -> gen_server:start_link(?MODULE, Opts, []);
                Name -> gen_server:start_link({local, Name}, ?MODULE,
                                              Opts, [])
            end;
        false ->
            {error, invalid_openapi_auth_broker_options}
    end;
start_link(_Opts) ->
    {error, invalid_openapi_auth_broker_options}.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec resolve(adk_openapi_auth_manager:handle(),
              adk_openapi_auth_manager:request()) ->
    {ok, adk_openapi_auth_manager:credential()} | {error, term()}.
resolve(Server, Request) when (is_pid(Server) orelse is_atom(Server)),
                              is_map(Request) ->
    %% The broker enforces its own bounded timeout and always replies.  The
    %% small margin here allows that timeout message to be handled without an
    %% unbounded public call.
    case bounded_term(Request, ?MAX_REQUEST_BYTES) of
        true ->
            try gen_server:call(Server, {resolve, Request},
                                ?CALL_TIMEOUT_MS) of
                Reply -> Reply
            catch
                exit:{timeout, _} -> {error, auth_timeout};
                exit:_ -> {error, auth_unavailable}
            end;
        false ->
            {error, invalid_auth_request}
    end;
resolve(_Server, _Request) ->
    {error, invalid_auth_request}.

init(Opts) ->
    Bindings0 = maps:get(bindings, Opts, undefined),
    Timeout = maps:get(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
    MaxInflight = maps:get(max_inflight, Opts, ?DEFAULT_MAX_INFLIGHT),
    case {is_integer(Timeout) andalso Timeout > 0 andalso
              Timeout =< ?MAX_TIMEOUT_MS,
          is_integer(MaxInflight) andalso MaxInflight > 0 andalso
              MaxInflight =< ?MAX_INFLIGHT,
          normalize_bindings(Bindings0)} of
        {true, true, {ok, Bindings}} ->
            {ok, #state{bindings = Bindings, timeout_ms = Timeout,
                        max_inflight = MaxInflight}};
        _ ->
            {stop, invalid_openapi_auth_broker_options}
    end.

handle_call({resolve, Request}, From,
            State = #state{bindings = Bindings, timeout_ms = Timeout,
                           max_inflight = Maximum,
                           inflight = Inflight, monitors = Monitors}) ->
    case prepare_request(Request, Bindings) of
        {error, _} = Error ->
            {reply, Error, State};
        {ok, _Binding} when map_size(Inflight) >= Maximum ->
            {reply, {error, auth_capacity_exceeded}, State};
        {ok, Binding} ->
            JobRef = make_ref(),
            Manager = self(),
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            ReplyAlias = erlang:alias([explicit_unalias]),
            WorkerFun = fun() ->
                start_owner_watchdog(Manager, self()),
                Result = safe_resolve_binding(Binding, Request, Timeout),
                CompletedAt = erlang:monotonic_time(millisecond),
                _ = erlang:send(
                      ReplyAlias,
                      {openapi_auth_result, JobRef, self(),
                       CompletedAt, Result},
                      [noconnect, nosuspend]),
                ok
            end,
            case spawn_auth_worker(WorkerFun) of
                {ok, Worker, WorkerMonitor} ->
                    {Caller, _Tag} = From,
                    CallerMonitor = erlang:monitor(process, Caller),
                    Timer = erlang:send_after(
                              remaining_time(Deadline), self(),
                              {openapi_auth_timeout, JobRef}),
                    Entry = #{from => From, worker => Worker,
                              worker_monitor => WorkerMonitor,
                              caller_monitor => CallerMonitor, timer => Timer,
                              reply_alias => ReplyAlias,
                              deadline => Deadline},
                    {noreply,
                     State#state{
                       inflight = Inflight#{JobRef => Entry},
                       monitors =
                           Monitors#{WorkerMonitor => {worker, JobRef},
                                    CallerMonitor => {caller, JobRef}}}};
                error ->
                    _ = erlang:unalias(ReplyAlias),
                    {reply, {error, auth_unavailable}, State}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_auth_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info({openapi_auth_result, JobRef, Worker, CompletedAt, Result}, State) ->
    case maps:find(JobRef, State#state.inflight) of
        {ok, #{worker := Worker, from := From, deadline := Deadline}}
          when CompletedAt =< Deadline ->
            gen_server:reply(From, Result),
            {noreply, remove_job(JobRef, false, State)};
        {ok, #{worker := Worker, from := From}} ->
            exit(Worker, kill),
            gen_server:reply(From, {error, auth_timeout}),
            {noreply, remove_job(JobRef, false, State)};
        _ ->
            {noreply, State}
    end;
handle_info({openapi_auth_timeout, JobRef}, State) ->
    case maps:find(JobRef, State#state.inflight) of
        {ok, #{worker := Worker, from := From}} ->
            exit(Worker, kill),
            gen_server:reply(From, {error, auth_timeout}),
            {noreply, remove_job(JobRef, false, State)};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case maps:find(Monitor, State#state.monitors) of
        {ok, {worker, JobRef}} ->
            case maps:find(JobRef, State#state.inflight) of
                {ok, #{from := From}} ->
                    gen_server:reply(From, {error, auth_unavailable}),
                    {noreply, remove_job(JobRef, false, State)};
                error -> {noreply, State}
            end;
        {ok, {caller, JobRef}} ->
            {noreply, remove_job(JobRef, true, State)};
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, #state{inflight = Inflight}) ->
    maps:foreach(
      fun(_JobRef, #{worker := Worker, reply_alias := ReplyAlias}) ->
              _ = erlang:unalias(ReplyAlias),
              exit(Worker, kill)
      end,
      Inflight),
    ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Do not expose principal IDs, provider routing, opaque references, or
%% transient requests through sys:get_status/crash reports.
format_status(Status) ->
    maps:map(
      fun(state, #state{bindings = Bindings, timeout_ms = Timeout,
                        max_inflight = Maximum, inflight = Inflight}) ->
              #{binding_count => map_size(Bindings), timeout_ms => Timeout,
                max_inflight => Maximum,
                inflight_count => map_size(Inflight)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

prepare_request(#{scheme_name := Name, scheme_type := Type,
                  scopes := _Scopes} = Request, Bindings) ->
    case valid_auth_request(Request) of
        true ->
            case maps:find(Name, Bindings) of
                {ok, #{kind := Type} = Binding} ->
                    {ok, Binding};
                {ok, _DifferentType} -> {error, scheme_type_mismatch};
                error -> {error, unknown_auth_scheme}
            end;
        false ->
            {error, invalid_auth_request}
    end;
prepare_request(_Request, _Bindings) ->
    {error, invalid_auth_request}.

safe_resolve_binding(Binding, Request, Timeout) ->
    try resolve_binding(Binding, Request, Timeout) of
        {ok, {Kind, Secret}} = Result
          when (Kind =:= api_key orelse Kind =:= bearer),
               is_binary(Secret), byte_size(Secret) > 0 ->
            case valid_secret(Kind, Secret) of
                true -> Result;
                false -> {error, credential_unavailable}
            end;
        {error, Reason} when is_atom(Reason) -> {error, Reason};
        _ -> {error, credential_unavailable}
    catch
        _:_ -> {error, credential_unavailable}
    end.

remove_job(JobRef, KillWorker,
           State = #state{inflight = Inflight0, monitors = Monitors0}) ->
    case maps:take(JobRef, Inflight0) of
        {Entry, Inflight} ->
            Worker = maps:get(worker, Entry),
            _ = erlang:unalias(maps:get(reply_alias, Entry)),
            case KillWorker andalso is_process_alive(Worker) of
                true -> exit(Worker, kill);
                false -> ok
            end,
            _ = erlang:cancel_timer(maps:get(timer, Entry)),
            WorkerMonitor = maps:get(worker_monitor, Entry),
            CallerMonitor = maps:get(caller_monitor, Entry),
            erlang:demonitor(WorkerMonitor, [flush]),
            erlang:demonitor(CallerMonitor, [flush]),
            flush_job_result(JobRef, Worker),
            State#state{
              inflight = Inflight,
              monitors = maps:remove(
                           CallerMonitor,
                           maps:remove(WorkerMonitor, Monitors0))};
        error -> State
    end.

spawn_auth_worker(WorkerFun) ->
    Options =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?WORKER_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try spawn_opt(WorkerFun, Options) of
        {Worker, Monitor} -> {ok, Worker, Monitor}
    catch
        _:_ -> error
    end.

flush_job_result(JobRef, Worker) ->
    receive
        {openapi_auth_result, JobRef, Worker, _CompletedAt, _Result} -> ok
    after 0 -> ok
    end.

remaining_time(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

start_owner_watchdog(Owner, Worker) ->
    Watchdog = fun() -> owner_watchdog(Owner, Worker) end,
    _ = spawn_opt(
          Watchdog,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]),
    ok.

owner_watchdog(Owner, Worker) ->
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
    end.

resolve_binding(#{kind := api_key} = Binding, _Request, _Timeout) ->
    case fetch_credential(Binding) of
        {ok, #{kind := api_key, api_key := Secret}}
          when is_binary(Secret), byte_size(Secret) > 0,
               byte_size(Secret) =< ?MAX_API_KEY_BYTES ->
            {ok, {api_key, Secret}};
        _ -> {error, credential_unavailable}
    end;
resolve_binding(#{kind := bearer} = Binding, _Request, _Timeout) ->
    case fetch_credential(Binding) of
        {ok, #{kind := bearer_token, access_token := Secret}}
          when is_binary(Secret), byte_size(Secret) > 0,
               byte_size(Secret) =< ?MAX_BEARER_BYTES ->
            {ok, {bearer, Secret}};
        _ -> {error, credential_unavailable}
    end;
resolve_binding(#{kind := oauth2, allowed_scopes := Allowed} = Binding,
                #{scopes := Scopes}, Timeout) ->
    case valid_requested_scopes(Scopes, Allowed) of
        false -> {error, scope_not_allowed};
        true ->
            Request = #{principal => maps:get(principal, Binding),
                        provider => maps:get(provider, Binding),
                        credential_ref => maps:get(credential_ref, Binding),
                        scopes => lists:usort(Scopes),
                        audience => maps:get(audience, Binding)},
            case adk_token_manager:get_token(
                   maps:get(token_manager, Binding), Request, Timeout) of
                {ok, #{access_token := Secret}}
                  when is_binary(Secret), byte_size(Secret) > 0,
                       byte_size(Secret) =< ?MAX_BEARER_BYTES ->
                    {ok, {bearer, Secret}};
                _ -> {error, credential_unavailable}
            end
    end.

fetch_credential(Binding) ->
    Module = maps:get(store_module, Binding),
    try Module:fetch(maps:get(store_handle, Binding),
                     maps:get(principal, Binding),
                     maps:get(provider, Binding),
                     maps:get(credential_ref, Binding)) of
        {ok, Credential} when is_map(Credential) ->
            case bounded_term(Credential, ?MAX_CREDENTIAL_BYTES) of
                true -> {ok, Credential};
                false -> {error, unavailable}
            end;
        _ -> {error, unavailable}
    catch
        _:_ -> {error, unavailable}
    end.

normalize_bindings(Bindings)
  when is_map(Bindings), map_size(Bindings) > 0,
       map_size(Bindings) =< ?MAX_BINDINGS ->
    case bounded_term(Bindings, ?MAX_BINDINGS_BYTES) of
        true -> normalize_binding_pairs(maps:to_list(Bindings), #{});
        false -> false
    end;
normalize_bindings(_Bindings) -> false.

normalize_binding_pairs([], Acc) -> {ok, Acc};
normalize_binding_pairs([{Name, Binding} | Rest], Acc)
  when is_binary(Name), byte_size(Name) > 0,
       byte_size(Name) =< ?MAX_NAME_BYTES, is_map(Binding) ->
    case normalize_binding(Binding) of
        {ok, Normalized} ->
            normalize_binding_pairs(Rest, Acc#{Name => Normalized});
        error -> false
    end;
normalize_binding_pairs(_Pairs, _Acc) -> false.

normalize_binding(#{kind := Kind} = Binding)
  when Kind =:= api_key; Kind =:= bearer ->
    Allowed = [kind, store_module, store_handle, principal,
               provider, credential_ref],
    case bounded_term(Binding, ?MAX_BINDING_BYTES) andalso
         exact_keys(Binding, Allowed) andalso
         valid_store_binding(Binding) of
        true -> {ok, Binding};
        false -> error
    end;
normalize_binding(#{kind := oauth2} = Binding0) ->
    Allowed = [kind, token_manager, principal, provider, credential_ref,
               allowed_scopes, audience],
    Binding = Binding0#{allowed_scopes =>
                            maps:get(allowed_scopes, Binding0, []),
                        audience => maps:get(audience, Binding0, undefined)},
    case bounded_term(Binding, ?MAX_BINDING_BYTES) andalso
         exact_keys(Binding, Allowed) andalso valid_oauth_binding(Binding) of
        true -> {ok, Binding};
        false -> error
    end;
normalize_binding(_Binding) -> error.

valid_store_binding(#{store_module := Module, store_handle := Handle,
                      principal := Principal, provider := Provider,
                      credential_ref := Ref}) ->
    is_atom(Module) andalso Module =/= undefined andalso
    valid_server(Handle) andalso valid_identity(Principal) andalso
    valid_identity(Provider) andalso adk_credential_store:is_ref(Ref);
valid_store_binding(_) -> false.

valid_oauth_binding(#{token_manager := Manager, principal := Principal,
                      provider := Provider, credential_ref := Ref,
                      allowed_scopes := Scopes, audience := Audience}) ->
    valid_server(Manager) andalso valid_identity(Principal) andalso
    valid_identity(Provider) andalso adk_credential_store:is_ref(Ref) andalso
    valid_scopes(Scopes) andalso valid_audience(Audience);
valid_oauth_binding(_) -> false.

valid_requested_scopes(Scopes, Allowed) ->
    valid_scopes(Scopes) andalso
    lists:all(fun(Scope) -> lists:member(Scope, Allowed) end, Scopes).

valid_scopes(Scopes) when is_list(Scopes) ->
    valid_text_list(Scopes, ?MAX_SCOPES, ?MAX_SCOPE_BYTES);
valid_scopes(_) -> false.

valid_audience(undefined) -> true;
valid_audience(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< ?MAX_AUDIENCE_BYTES;
valid_audience(_) -> false.

valid_server(Value) when is_pid(Value) -> true;
valid_server(Value) when is_atom(Value) -> Value =/= undefined;
valid_server(_) -> false.

valid_identity(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< ?MAX_ID_BYTES;
valid_identity(Value) when is_atom(Value) -> Value =/= undefined;
valid_identity(_) -> false.

exact_keys(Map, Keys) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Keys).

valid_start_options(Opts) ->
    Allowed = [name, id, bindings, timeout_ms, max_inflight],
    bounded_term(Opts, ?MAX_OPTIONS_BYTES) andalso
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Opts)) andalso
    valid_start_limits(Opts) andalso
    case maps:get(name, Opts, undefined) of
        undefined -> true;
        Name when is_atom(Name) -> Name =/= undefined;
        _ -> false
    end.

valid_start_limits(Opts) ->
    Timeout = maps:get(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
    MaxInflight = maps:get(max_inflight, Opts, ?DEFAULT_MAX_INFLIGHT),
    is_integer(Timeout) andalso Timeout > 0 andalso
    Timeout =< ?MAX_TIMEOUT_MS andalso is_integer(MaxInflight) andalso
    MaxInflight > 0 andalso MaxInflight =< ?MAX_INFLIGHT andalso
    case normalize_bindings(maps:get(bindings, Opts, undefined)) of
        {ok, _} -> true;
        _ -> false
    end.

valid_auth_request(#{operation_id := OperationId,
                     scheme_name := Name,
                     scheme_type := Type,
                     scopes := Scopes} = Request) ->
    Allowed = [operation_id, scheme_name, scheme_type, scopes,
               location, parameter_name],
    lists:all(fun(Key) -> lists:member(Key, Allowed) end,
              maps:keys(Request)) andalso
    bounded_term(Request, ?MAX_REQUEST_BYTES) andalso
    valid_text(OperationId, ?MAX_NAME_BYTES) andalso
    valid_text(Name, ?MAX_NAME_BYTES) andalso
    (Type =:= api_key orelse Type =:= bearer orelse Type =:= oauth2) andalso
    valid_scopes(Scopes) andalso valid_optional_request_fields(Request);
valid_auth_request(_Request) -> false.

valid_optional_request_fields(Request) ->
    ValidLocation = case maps:find(location, Request) of
        error -> true;
        {ok, Location} -> Location =:= header orelse Location =:= query
    end,
    ValidParameter = case maps:find(parameter_name, Request) of
        error -> true;
        {ok, Parameter} -> valid_text(Parameter, ?MAX_PARAMETER_BYTES)
    end,
    ValidLocation andalso ValidParameter andalso
    (maps:is_key(location, Request) =:= maps:is_key(parameter_name, Request)).

valid_secret(api_key, Secret) ->
    byte_size(Secret) =< ?MAX_API_KEY_BYTES;
valid_secret(bearer, Secret) ->
    byte_size(Secret) =< ?MAX_BEARER_BYTES.

valid_text(Value, Maximum) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Maximum;
valid_text(_Value, _Maximum) -> false.

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

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.
