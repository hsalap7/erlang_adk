%% @doc Short-lived worker that resolves an opaque credential reference and
%% invokes an authentication provider.
%%
%% The child specification contains no secret material. Raw credentials exist
%% only on this process' callback stack and in its linked provider process;
%% neither is retained in gen_server state or emitted as an error.
-module(adk_token_refresh_worker).

-behaviour(gen_server).

-export([start_link/2, perform/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {
    manager :: pid(),
    generation :: reference(),
    manager_monitor :: reference(),
    provider_pid = undefined :: undefined | pid(),
    provider_alias = undefined :: undefined | reference(),
    manager_alias = undefined :: undefined | reference(),
    deadline_ms = undefined :: undefined | integer()
}).

-define(MAX_WORK_BYTES, 262144).
-define(MAX_CONTEXT_BYTES, 131072).
-define(MAX_CREDENTIAL_BYTES, 1048576).
-define(MAX_PROVIDER_RESULT_BYTES, 1048576).
-define(MAX_REFRESH_TOKEN_BYTES, 65536).
-define(MAX_ID_BYTES, 4096).
-define(WORKER_MAX_HEAP_WORDS, 500000).
-define(PROVIDER_MAX_HEAP_WORDS, 300000).

-spec start_link(pid(), reference()) -> gen_server:start_ret().
start_link(Manager, Generation)
  when is_pid(Manager), is_reference(Generation) ->
    gen_server:start_link(?MODULE, {Manager, Generation}, []).

-spec perform(pid(), map()) -> ok.
perform(Worker, Work) when is_pid(Worker), is_map(Work) ->
    case bounded_term(Work, ?MAX_WORK_BYTES) of
        true -> gen_server:cast(Worker, {perform, Work});
        false -> gen_server:cast(Worker, invalid_perform)
    end;
perform(Worker, _Work) when is_pid(Worker) ->
    gen_server:cast(Worker, invalid_perform).

init({Manager, Generation}) ->
    process_flag(trap_exit, true),
    _ = process_flag(message_queue_data, off_heap),
    _ = process_flag(
          max_heap_size,
          #{size => ?WORKER_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}),
    ManagerMonitor = erlang:monitor(process, Manager),
    Manager ! {auth_refresh_ready, Generation, self()},
    {ok, #state{manager = Manager,
                generation = Generation,
                manager_monitor = ManagerMonitor}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast({perform, Work}, State = #state{provider_pid = undefined}) ->
    case valid_work(Work) of
        true ->
            ProviderAlias = erlang:alias([explicit_unalias]),
            ManagerAlias = maps:get(manager_alias, Work),
            Deadline = maps:get(deadline_ms, Work),
            ProviderFun = fun() ->
                Result = perform_refresh(Work),
                CompletedAt = monotonic_ms(),
                _ = erlang:send(
                      ProviderAlias,
                      {ProviderAlias, provider_result, self(), CompletedAt,
                       Result},
                      [noconnect, nosuspend]),
                ok
            end,
            ProviderPid = spawn_opt(
                            ProviderFun,
                            [link, {message_queue_data, off_heap},
                             {max_heap_size,
                              #{size => ?PROVIDER_MAX_HEAP_WORDS,
                                kill => true, error_logger => false,
                                include_shared_binaries => true}}]),
            {noreply, State#state{provider_pid = ProviderPid,
                                  provider_alias = ProviderAlias,
                                  manager_alias = ManagerAlias,
                                  deadline_ms = Deadline}};
        false ->
            send_invalid_work_result(Work, State),
            {stop, normal, State}
    end;
handle_cast(invalid_perform, State = #state{provider_pid = undefined}) ->
    {stop, normal, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({ProviderAlias, provider_result, ProviderPid, CompletedAt, Result},
            State = #state{generation = Generation,
                           provider_pid = ProviderPid,
                           provider_alias = ProviderAlias,
                           manager_alias = ManagerAlias,
                           deadline_ms = Deadline}) ->
    unlink(ProviderPid),
    _ = safe_unalias(ProviderAlias),
    SafeResult = case CompletedAt =< Deadline of
        false -> {error, refresh_timeout};
        true ->
            case bounded_term(Result, ?MAX_PROVIDER_RESULT_BYTES) of
                true -> Result;
                false -> {error, invalid_provider_response}
            end
    end,
    _ = send_manager_result(ManagerAlias, Generation, CompletedAt, SafeResult),
    {stop, normal,
     State#state{provider_pid = undefined, provider_alias = undefined}};
handle_info({'EXIT', ProviderPid, _Reason},
            State = #state{generation = Generation,
                           provider_pid = ProviderPid,
                           provider_alias = ProviderAlias,
                           manager_alias = ManagerAlias}) ->
    _ = safe_unalias(ProviderAlias),
    _ = send_manager_result(
          ManagerAlias, Generation, monotonic_ms(),
          {error, provider_process_failed}),
    {stop, normal,
     State#state{provider_pid = undefined, provider_alias = undefined}};
handle_info({'DOWN', Monitor, process, _Manager, _Reason},
            State = #state{manager_monitor = Monitor}) ->
    clear_provider(State),
    {stop, normal,
     State#state{provider_pid = undefined, provider_alias = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    clear_provider(State),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% A cast can transiently contain provider context and a result can contain an
%% access token. Suppress both from status/error logging.
format_status(Status) ->
    maps:map(
      fun(state, #state{manager = Manager,
                        generation = Generation,
                        provider_pid = ProviderPid,
                        deadline_ms = Deadline}) ->
              #{manager => Manager,
                generation => Generation,
                provider_running => is_pid(ProviderPid),
                deadline_ms => Deadline};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

perform_refresh(#{store_module := StoreModule,
                  store_handle := StoreHandle,
                  principal := Principal,
                  provider := Provider,
                  credential_ref := CredentialRef,
                  provider_module := ProviderModule,
                  context := Context,
                  deadline_ms := Deadline}) ->
    case within_deadline(Deadline) of
        false ->
            {error, refresh_timeout};
        true ->
            case fetch_credential(StoreModule, StoreHandle, Principal,
                                  Provider, CredentialRef) of
                {ok, Credential} ->
                    case within_deadline(Deadline) of
                        true ->
                            invoke_provider(
                              ProviderModule, Credential, Context,
                              StoreModule, StoreHandle, Principal, Provider,
                              CredentialRef, Deadline);
                        false ->
                            {error, refresh_timeout}
                    end;
                {error, _} = Error ->
                    Error
            end
    end;
perform_refresh(_InvalidWork) ->
    {error, invalid_refresh_work}.

fetch_credential(StoreModule, StoreHandle, Principal, Provider,
                 CredentialRef) ->
    try StoreModule:fetch(StoreHandle, Principal, Provider, CredentialRef) of
        {ok, Credential} when is_map(Credential) ->
            case bounded_term(Credential, ?MAX_CREDENTIAL_BYTES) of
                true -> {ok, Credential};
                false -> {error, invalid_provider_response}
            end;
        {error, not_found} -> {error, credential_not_found};
        {error, _Reason} -> {error, credential_store_unavailable};
        _Other -> {error, credential_store_unavailable}
    catch
        _Class:_Reason -> {error, credential_store_unavailable}
    end.

invoke_provider(ProviderModule, Credential, Context,
                StoreModule, StoreHandle, Principal, Provider,
                CredentialRef, Deadline) ->
    Seeds = safe_seed_values(Credential),
    Rotator = credential_rotator(StoreModule, StoreHandle, Principal,
                                 Provider, CredentialRef, Credential,
                                 Deadline),
    ProviderContext = Context#{credential_rotator => Rotator},
    try ProviderModule:refresh(Credential, ProviderContext) of
        {ok, Token} = Success ->
            case bounded_term(Success, ?MAX_PROVIDER_RESULT_BYTES) of
                true -> {ok, Token};
                false -> {error, invalid_provider_response}
            end;
        {error, credential_rotation_conflict} ->
            {error, credential_rotation_conflict};
        {error, credential_rotation_failed} ->
            {error, credential_rotation_failed};
        {error, Reason} = Failure ->
            case bounded_term(Failure, ?MAX_PROVIDER_RESULT_BYTES) of
                true ->
                    {error, {provider_error,
                             safe_redact(Reason, Seeds)}};
                false ->
                    {error, invalid_provider_response}
            end;
        _Other ->
            {error, invalid_provider_response}
    catch
        Class:Reason ->
            case bounded_term({Class, Reason},
                              ?MAX_PROVIDER_RESULT_BYTES) of
                true ->
                    {error, {provider_exception, Class,
                             safe_redact(Reason, Seeds)}};
                false ->
                    {error, invalid_provider_response}
            end
    end.

credential_rotator(StoreModule, StoreHandle, Principal, Provider,
                   CredentialRef, OriginalCredential, Deadline) ->
    fun(ExpectedCredential, NewRefreshToken) ->
        case monotonic_ms() =< Deadline of
            false ->
                {error, deadline_exceeded};
            true ->
                case ExpectedCredential =:= OriginalCredential of
                    true ->
                        rotate_refresh_token(
                          StoreModule, StoreHandle, Principal, Provider,
                          CredentialRef, ExpectedCredential,
                          NewRefreshToken);
                    false ->
                        {error, invalid_credential}
                end
        end
    end.

rotate_refresh_token(_StoreModule, _StoreHandle, _Principal, _Provider,
                     _CredentialRef,
                     #{refresh_token := CurrentRefreshToken},
                     CurrentRefreshToken)
  when is_binary(CurrentRefreshToken), byte_size(CurrentRefreshToken) > 0,
       byte_size(CurrentRefreshToken) =< ?MAX_REFRESH_TOKEN_BYTES ->
    ok;
rotate_refresh_token(StoreModule, StoreHandle, Principal, Provider,
                     CredentialRef,
                     #{refresh_token := CurrentRefreshToken} = Expected,
                     NewRefreshToken)
  when is_binary(CurrentRefreshToken), byte_size(CurrentRefreshToken) > 0,
       byte_size(CurrentRefreshToken) =< ?MAX_REFRESH_TOKEN_BYTES,
       is_binary(NewRefreshToken), byte_size(NewRefreshToken) > 0,
       byte_size(NewRefreshToken) =< ?MAX_REFRESH_TOKEN_BYTES,
       is_map(Expected) ->
    Replacement = Expected#{refresh_token => NewRefreshToken},
    case bounded_term(Expected, ?MAX_CREDENTIAL_BYTES) andalso
         bounded_term(Replacement, ?MAX_CREDENTIAL_BYTES) of
        true ->
            safe_compare_and_swap(StoreModule, StoreHandle, Principal,
                                  Provider, CredentialRef, Expected,
                                  Replacement);
        false ->
            {error, invalid_credential}
    end;
rotate_refresh_token(_StoreModule, _StoreHandle, _Principal, _Provider,
                     _CredentialRef, _Expected, _NewRefreshToken) ->
    {error, invalid_credential}.

safe_compare_and_swap(StoreModule, StoreHandle, Principal, Provider,
                      CredentialRef, Expected, Replacement) ->
    try StoreModule:compare_and_swap(
          StoreHandle, Principal, Provider, CredentialRef,
          Expected, Replacement) of
        ok -> ok;
        {error, conflict} -> {error, conflict};
        {error, _Reason} -> {error, unavailable};
        _Other -> {error, unavailable}
    catch
        _:_ -> {error, unavailable}
    end.

safe_seed_values(Credential) ->
    try adk_secret_redactor:seed_values(Credential)
    catch _:_ -> []
    end.

safe_redact(Reason, Seeds) ->
    try adk_secret_redactor:redact(Reason, Seeds)
    catch _:_ -> adk_secret_redactor:marker()
    end.

stop_provider(undefined) -> ok;
stop_provider(ProviderPid) when is_pid(ProviderPid) ->
    unlink(ProviderPid),
    exit(ProviderPid, kill),
    ok.

clear_provider(#state{provider_pid = ProviderPid,
                      provider_alias = ProviderAlias}) ->
    _ = safe_unalias(ProviderAlias),
    stop_provider(ProviderPid).

safe_unalias(undefined) -> ok;
safe_unalias(Alias) when is_reference(Alias) ->
    _ = catch erlang:unalias(Alias),
    ok.

send_manager_result(ManagerAlias, Generation, CompletedAt, Result)
  when is_reference(ManagerAlias), is_reference(Generation),
       is_integer(CompletedAt) ->
    _ = catch erlang:send(
                ManagerAlias,
                {ManagerAlias, auth_refresh_result, Generation, self(),
                 CompletedAt, Result},
                [noconnect, nosuspend]),
    ok.

send_invalid_work_result(Work, #state{generation = Generation}) ->
    case {maps:find(manager_alias, Work), maps:find(deadline_ms, Work)} of
        {{ok, ManagerAlias}, {ok, _Deadline}}
          when is_reference(ManagerAlias) ->
            send_manager_result(
              ManagerAlias, Generation, monotonic_ms(),
              {error, invalid_refresh_work});
        _ ->
            ok
    end,
    ok.

valid_work(#{store_module := StoreModule,
             store_handle := StoreHandle,
             principal := Principal,
             provider := Provider,
             credential_ref := CredentialRef,
             provider_module := ProviderModule,
             context := Context,
             deadline_ms := Deadline,
             manager_alias := ManagerAlias} = Work) ->
    lists:sort(maps:keys(Work)) =:=
        [context, credential_ref, deadline_ms, manager_alias, principal,
         provider, provider_module, store_handle, store_module] andalso
    bounded_term(Work, ?MAX_WORK_BYTES) andalso
    is_atom(StoreModule) andalso StoreModule =/= undefined andalso
    valid_server(StoreHandle) andalso
    valid_identity(Principal) andalso valid_identity(Provider) andalso
    adk_credential_store:is_ref(CredentialRef) andalso
    is_atom(ProviderModule) andalso ProviderModule =/= undefined andalso
    is_map(Context) andalso bounded_term(Context, ?MAX_CONTEXT_BYTES) andalso
    is_integer(Deadline) andalso is_reference(ManagerAlias);
valid_work(_Work) -> false.

valid_server(Value) when is_pid(Value) -> true;
valid_server(Value) when is_atom(Value) -> Value =/= undefined;
valid_server(_Value) -> false.

valid_identity(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< ?MAX_ID_BYTES;
valid_identity(Value) when is_atom(Value) -> Value =/= undefined;
valid_identity(_Value) -> false.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.

monotonic_ms() ->
    erlang:monotonic_time(millisecond).

within_deadline(Deadline) when is_integer(Deadline) ->
    monotonic_ms() =< Deadline.
