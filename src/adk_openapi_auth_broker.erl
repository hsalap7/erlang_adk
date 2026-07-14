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
    timeout_ms :: pos_integer()
}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, undefined) of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name), Name =/= undefined ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, []);
        _ -> {error, invalid_openapi_auth_broker_name}
    end.

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
    try gen_server:call(Server, {resolve, Request}, 15000) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, auth_timeout};
        exit:_ -> {error, auth_unavailable}
    end;
resolve(_Server, _Request) ->
    {error, invalid_auth_request}.

init(Opts) ->
    Bindings0 = maps:get(bindings, Opts, undefined),
    Timeout = maps:get(timeout_ms, Opts, 10000),
    case {is_integer(Timeout) andalso Timeout > 0,
          normalize_bindings(Bindings0)} of
        {true, {ok, Bindings}} ->
            {ok, #state{bindings = Bindings, timeout_ms = Timeout}};
        _ ->
            {stop, invalid_openapi_auth_broker_options}
    end.

handle_call({resolve, Request}, _From, State) ->
    {reply, resolve_request(Request, State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_auth_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Do not expose principal IDs, provider routing, opaque references, or
%% transient requests through sys:get_status/crash reports.
format_status(Status) ->
    maps:map(
      fun(state, #state{bindings = Bindings, timeout_ms = Timeout}) ->
              #{binding_count => map_size(Bindings), timeout_ms => Timeout};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

resolve_request(#{scheme_name := Name, scheme_type := Type,
                  scopes := Scopes} = Request,
                #state{bindings = Bindings, timeout_ms = Timeout})
  when is_binary(Name), byte_size(Name) > 0,
       is_list(Scopes) ->
    case maps:find(Name, Bindings) of
        {ok, #{kind := Type} = Binding} ->
            resolve_binding(Binding, Request, Timeout);
        {ok, _DifferentType} -> {error, scheme_type_mismatch};
        error -> {error, unknown_auth_scheme}
    end;
resolve_request(_Request, _State) ->
    {error, invalid_auth_request}.

resolve_binding(#{kind := api_key} = Binding, _Request, _Timeout) ->
    case fetch_credential(Binding) of
        {ok, #{kind := api_key, api_key := Secret}}
          when is_binary(Secret), byte_size(Secret) > 0 ->
            {ok, {api_key, Secret}};
        _ -> {error, credential_unavailable}
    end;
resolve_binding(#{kind := bearer} = Binding, _Request, _Timeout) ->
    case fetch_credential(Binding) of
        {ok, #{kind := bearer_token, access_token := Secret}}
          when is_binary(Secret), byte_size(Secret) > 0 ->
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
                        provider_module => maps:get(provider_module, Binding),
                        credential_ref => maps:get(credential_ref, Binding),
                        scopes => lists:usort(Scopes),
                        audience => maps:get(audience, Binding),
                        context => maps:get(context, Binding)},
            case adk_token_manager:get_token(
                   maps:get(token_manager, Binding), Request, Timeout) of
                {ok, #{access_token := Secret}}
                  when is_binary(Secret), byte_size(Secret) > 0 ->
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
        {ok, Credential} when is_map(Credential) -> {ok, Credential};
        _ -> {error, unavailable}
    catch
        _:_ -> {error, unavailable}
    end.

normalize_bindings(Bindings) when is_map(Bindings), map_size(Bindings) > 0 ->
    normalize_binding_pairs(maps:to_list(Bindings), #{});
normalize_bindings(_Bindings) -> false.

normalize_binding_pairs([], Acc) -> {ok, Acc};
normalize_binding_pairs([{Name, Binding} | Rest], Acc)
  when is_binary(Name), byte_size(Name) > 0, is_map(Binding) ->
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
    case exact_keys(Binding, Allowed) andalso
         valid_store_binding(Binding) of
        true -> {ok, Binding};
        false -> error
    end;
normalize_binding(#{kind := oauth2} = Binding0) ->
    Allowed = [kind, token_manager, principal, provider, provider_module,
               credential_ref, allowed_scopes, audience, context],
    Binding = Binding0#{allowed_scopes =>
                            maps:get(allowed_scopes, Binding0, []),
                        audience => maps:get(audience, Binding0, undefined),
                        context => maps:get(context, Binding0, #{})},
    case exact_keys(Binding, Allowed) andalso valid_oauth_binding(Binding) of
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
                      provider := Provider, provider_module := ProviderModule,
                      credential_ref := Ref, allowed_scopes := Scopes,
                      audience := Audience, context := Context}) ->
    valid_server(Manager) andalso valid_identity(Principal) andalso
    valid_identity(Provider) andalso is_atom(ProviderModule) andalso
    ProviderModule =/= undefined andalso adk_credential_store:is_ref(Ref)
    andalso valid_scopes(Scopes) andalso valid_audience(Audience) andalso
    is_map(Context) andalso not contains_sensitive_key(Context);
valid_oauth_binding(_) -> false.

valid_requested_scopes(Scopes, Allowed) ->
    valid_scopes(Scopes) andalso
    lists:all(fun(Scope) -> lists:member(Scope, Allowed) end, Scopes).

valid_scopes(Scopes) when is_list(Scopes) ->
    lists:all(fun(Scope) -> is_binary(Scope) andalso byte_size(Scope) > 0 end,
              Scopes) andalso
    length(Scopes) =:= length(lists:usort(Scopes));
valid_scopes(_) -> false.

valid_audience(undefined) -> true;
valid_audience(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_audience(_) -> false.

valid_server(Value) when is_pid(Value) -> true;
valid_server(Value) when is_atom(Value) -> Value =/= undefined;
valid_server(_) -> false.

valid_identity(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_identity(Value) when is_atom(Value) -> Value =/= undefined;
valid_identity(_) -> false.

exact_keys(Map, Keys) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Keys).

contains_sensitive_key(Map) when is_map(Map) ->
    lists:any(fun({Key, Value}) ->
                  adk_context_guard:sensitive_key(Key) orelse
                  contains_sensitive_key(Value)
              end, maps:to_list(Map));
contains_sensitive_key(List) when is_list(List) ->
    lists:any(fun contains_sensitive_key/1, List);
contains_sensitive_key(Tuple) when is_tuple(Tuple) ->
    contains_sensitive_key(tuple_to_list(Tuple));
contains_sensitive_key(_Value) -> false.
