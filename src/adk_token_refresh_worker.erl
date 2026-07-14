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
    provider_pid = undefined :: undefined | pid()
}).

-spec start_link(pid(), reference()) -> gen_server:start_ret().
start_link(Manager, Generation)
  when is_pid(Manager), is_reference(Generation) ->
    gen_server:start_link(?MODULE, {Manager, Generation}, []).

-spec perform(pid(), map()) -> ok.
perform(Worker, Work) when is_pid(Worker), is_map(Work) ->
    gen_server:cast(Worker, {perform, Work}).

init({Manager, Generation}) ->
    process_flag(trap_exit, true),
    ManagerMonitor = erlang:monitor(process, Manager),
    Manager ! {auth_refresh_ready, Generation, self()},
    {ok, #state{manager = Manager,
                generation = Generation,
                manager_monitor = ManagerMonitor}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast({perform, Work}, State = #state{provider_pid = undefined}) ->
    Worker = self(),
    ProviderPid = spawn_link(fun() ->
        Result = perform_refresh(Work),
        Worker ! {provider_result, self(), Result}
    end),
    {noreply, State#state{provider_pid = ProviderPid}};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({provider_result, ProviderPid, Result},
            State = #state{manager = Manager,
                           generation = Generation,
                           provider_pid = ProviderPid}) ->
    unlink(ProviderPid),
    Manager ! {auth_refresh_result, Generation, self(), Result},
    {stop, normal, State#state{provider_pid = undefined}};
handle_info({'EXIT', ProviderPid, normal},
            State = #state{provider_pid = ProviderPid}) ->
    %% A message sent before exit by the same process is delivered first. Keep
    %% waiting defensively in case a custom runtime violates that assumption.
    {noreply, State};
handle_info({'EXIT', ProviderPid, _Reason},
            State = #state{manager = Manager,
                           generation = Generation,
                           provider_pid = ProviderPid}) ->
    Manager ! {auth_refresh_result, Generation, self(),
               {error, provider_process_failed}},
    {stop, normal, State#state{provider_pid = undefined}};
handle_info({'DOWN', Monitor, process, _Manager, _Reason},
            State = #state{manager_monitor = Monitor}) ->
    stop_provider(State#state.provider_pid),
    {stop, normal, State#state{provider_pid = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{provider_pid = ProviderPid}) ->
    stop_provider(ProviderPid),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% A cast can transiently contain provider context and a result can contain an
%% access token. Suppress both from status/error logging.
format_status(Status) ->
    maps:map(
      fun(state, #state{manager = Manager,
                        generation = Generation,
                        provider_pid = ProviderPid}) ->
              #{manager => Manager,
                generation => Generation,
                provider_running => is_pid(ProviderPid)};
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
                  context := Context}) ->
    case fetch_credential(StoreModule, StoreHandle, Principal, Provider,
                          CredentialRef) of
        {ok, Credential} ->
            invoke_provider(ProviderModule, Credential, Context,
                            StoreModule, StoreHandle, Principal, Provider,
                            CredentialRef);
        {error, _} = Error ->
            Error
    end;
perform_refresh(_InvalidWork) ->
    {error, invalid_refresh_work}.

fetch_credential(StoreModule, StoreHandle, Principal, Provider,
                 CredentialRef) ->
    try StoreModule:fetch(StoreHandle, Principal, Provider, CredentialRef) of
        {ok, Credential} when is_map(Credential) -> {ok, Credential};
        {error, not_found} -> {error, credential_not_found};
        {error, _Reason} -> {error, credential_store_unavailable};
        _Other -> {error, credential_store_unavailable}
    catch
        _Class:_Reason -> {error, credential_store_unavailable}
    end.

invoke_provider(ProviderModule, Credential, Context,
                StoreModule, StoreHandle, Principal, Provider,
                CredentialRef) ->
    Seeds = safe_seed_values(Credential),
    Rotator = credential_rotator(StoreModule, StoreHandle, Principal,
                                 Provider, CredentialRef, Credential),
    ProviderContext = Context#{credential_rotator => Rotator},
    try ProviderModule:refresh(Credential, ProviderContext) of
        {ok, Token} ->
            {ok, Token};
        {error, credential_rotation_conflict} ->
            {error, credential_rotation_conflict};
        {error, credential_rotation_failed} ->
            {error, credential_rotation_failed};
        {error, Reason} ->
            {error, {provider_error,
                     safe_redact(Reason, Seeds)}};
        _Other ->
            {error, invalid_provider_response}
    catch
        Class:Reason ->
            {error, {provider_exception, Class,
                     safe_redact(Reason, Seeds)}}
    end.

credential_rotator(StoreModule, StoreHandle, Principal, Provider,
                   CredentialRef, _ExpectedCredential) ->
    fun(ExpectedCredential, NewRefreshToken) ->
        rotate_refresh_token(StoreModule, StoreHandle, Principal, Provider,
                             CredentialRef, ExpectedCredential,
                             NewRefreshToken)
    end.

rotate_refresh_token(_StoreModule, _StoreHandle, _Principal, _Provider,
                     _CredentialRef,
                     #{refresh_token := CurrentRefreshToken},
                     CurrentRefreshToken)
  when is_binary(CurrentRefreshToken), byte_size(CurrentRefreshToken) > 0 ->
    ok;
rotate_refresh_token(StoreModule, StoreHandle, Principal, Provider,
                     CredentialRef,
                     #{refresh_token := CurrentRefreshToken} = Expected,
                     NewRefreshToken)
  when is_binary(CurrentRefreshToken), byte_size(CurrentRefreshToken) > 0,
       is_binary(NewRefreshToken), byte_size(NewRefreshToken) > 0 ->
    Replacement = Expected#{refresh_token => NewRefreshToken},
    safe_compare_and_swap(StoreModule, StoreHandle, Principal, Provider,
                          CredentialRef, Expected, Replacement);
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
