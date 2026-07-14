%% @doc Structured suspension contracts for external operations and user auth.
%%
%% Tools call long_running/2 or request_credential/2 from execute/2. Both use
%% the Runner's existing durable, invocation-scoped continuation mechanism.
%% Public metadata is JSON-safe; credentials remain in an
%% adk_credential_store and only opaque references cross the event boundary.
-module(adk_suspension).

-export([long_running/2, request_credential/2,
         prepare_pkce/5, complete_pkce/7, pause_details/1,
         validate_progress/3, validate_resume/4]).

-define(MAX_ID_BYTES, 256).
-define(MAX_SUMMARY_BYTES, 4096).
-define(MAX_SCOPES, 64).
-define(MAX_SCOPE_BYTES, 512).
-define(MAX_PKCE_AGE_MS, 600000).
-define(PKCE_CLOCK_SKEW_MS, 60000).

-spec long_running(binary(), binary()) -> no_return().
long_running(OperationId, Summary) ->
    case valid_text(OperationId, ?MAX_ID_BYTES) andalso
         valid_text(Summary, ?MAX_SUMMARY_BYTES) of
        true ->
            erlang:throw({adk_pause, {long_running, OperationId}, Summary});
        false ->
            erlang:error(invalid_long_running_suspension)
    end.

%% @doc Suspend for an application-managed OAuth/OIDC interaction. Request is
%% produced by prepare_pkce/5 plus the provider's public authorization URI and
%% scopes. Context must be the Runner tool context; it is checked here so this
%% helper cannot be used outside an authenticated session invocation.
-spec request_credential(map(), map()) -> no_return().
request_credential(Request0, Context) when is_map(Request0), is_map(Context) ->
    case {normalize_credential_request(Request0),
          maps:get(user_id, Context, undefined),
          maps:get(invocation_id, Context, undefined)} of
        {{ok, Request}, UserId, InvocationId}
          when is_binary(UserId), byte_size(UserId) > 0,
               is_binary(InvocationId), byte_size(InvocationId) > 0 ->
            Summary = maps:get(
                        <<"prompt">>, Request,
                        <<"Authentication and user consent are required.">>),
            erlang:throw(
              {adk_pause, {credential_required, Request}, Summary});
        _ ->
            erlang:error(invalid_credential_suspension)
    end;
request_credential(_Request, _Context) ->
    erlang:error(invalid_credential_suspension).

%% @doc Create an S256 PKCE verifier in private credential storage. The
%% verifier is never returned. The public result can be merged into the auth
%% request shown to a client. The flow reference is not a bearer token; store
%% lookup remains bound to Principal and Provider.
-spec prepare_pkce(module(), adk_credential_store:handle(), binary(),
                   binary(), binary()) -> {ok, map()} | {error, term()}.
prepare_pkce(StoreModule, Store, Principal, Provider, CorrelationId)
  when is_atom(StoreModule), is_binary(Principal), is_binary(Provider),
       is_binary(CorrelationId) ->
    case valid_text(Principal, ?MAX_ID_BYTES) andalso
         valid_text(Provider, ?MAX_ID_BYTES) andalso
         valid_text(CorrelationId, ?MAX_ID_BYTES) andalso
         store_module(StoreModule) of
        true ->
            Verifier = base64url(crypto:strong_rand_bytes(32)),
            Challenge = base64url(crypto:hash(sha256, Verifier)),
            Pending = #{kind => oauth_authorization_pending,
                        code_verifier => Verifier,
                        correlation_id => CorrelationId,
                        created_at => erlang:system_time(millisecond)},
            try StoreModule:put(Store, Principal, Provider, Pending) of
                {ok, FlowRef} ->
                    {ok, #{<<"credential_flow_ref">> => FlowRef,
                           <<"pkce_challenge">> => Challenge,
                           <<"pkce_method">> => <<"S256">>}};
                {error, _} = Error -> Error;
                _ -> {error, invalid_credential_store_reply}
            catch
                _:_ -> {error, credential_store_unavailable}
            end;
        false ->
            {error, invalid_pkce_request}
    end;
prepare_pkce(_StoreModule, _Store, _Principal, _Provider, _CorrelationId) ->
    {error, invalid_pkce_request}.

%% @doc Atomically replace a pending PKCE verifier with the provider-issued
%% credential while retaining the same opaque flow reference.  This is the
%% callback boundary applications (including Phoenix controllers) call after
%% exchanging the authorization code.  The exact pending value is used as the
%% compare-and-swap expectation, so two callbacks cannot both complete a flow.
%% Neither the verifier nor provider credential is returned.
-spec complete_pkce(module(), adk_credential_store:handle(), binary(),
                    binary(), binary(), binary(), map()) ->
    {ok, adk_credential_store:credential_ref()} | {error, term()}.
complete_pkce(StoreModule, Store, Principal, Provider, FlowRef,
              CorrelationId, Credential)
  when is_atom(StoreModule), is_binary(Principal), is_binary(Provider),
       is_binary(FlowRef), is_binary(CorrelationId), is_map(Credential) ->
    case valid_text(Principal, ?MAX_ID_BYTES) andalso
         valid_text(Provider, ?MAX_ID_BYTES) andalso
         valid_text(CorrelationId, ?MAX_ID_BYTES) andalso
         adk_credential_store:is_ref(FlowRef) andalso
         valid_completed_credential(Credential) andalso
         cas_store_module(StoreModule) of
        true ->
            complete_pending_pkce(StoreModule, Store, Principal, Provider,
                                  FlowRef, CorrelationId, Credential);
        false ->
            {error, invalid_pkce_completion}
    end;
complete_pkce(_StoreModule, _Store, _Principal, _Provider, _FlowRef,
              _CorrelationId, _Credential) ->
    {error, invalid_pkce_completion}.

complete_pending_pkce(StoreModule, Store, Principal, Provider, FlowRef,
                      CorrelationId, Credential) ->
    try StoreModule:fetch(Store, Principal, Provider, FlowRef) of
        {ok, Pending = #{kind := oauth_authorization_pending,
                         correlation_id := CorrelationId,
                         created_at := CreatedAt}} ->
            case valid_pending_age(CreatedAt) of
                true ->
                    case StoreModule:compare_and_swap(
                           Store, Principal, Provider, FlowRef,
                           Pending, Credential) of
                        ok -> {ok, FlowRef};
                        {error, conflict} ->
                            {error, credential_flow_already_completed};
                        {error, not_found} ->
                            {error, credential_scope_mismatch};
                        {error, _} = Error -> Error;
                        _ -> {error, invalid_credential_store_reply}
                    end;
                false ->
                    {error, credential_flow_expired}
            end;
        {ok, #{kind := oauth_authorization_pending,
               correlation_id := CorrelationId}} ->
            {error, invalid_stored_credential};
        {ok, #{kind := oauth_authorization_pending}} ->
            {error, credential_correlation_mismatch};
        {ok, _AlreadyCompleted} ->
            {error, credential_flow_already_completed};
        {error, not_found} ->
            {error, credential_scope_mismatch};
        {error, _} = Error ->
            Error;
        _ ->
            {error, invalid_stored_credential}
    catch
        _:_ -> {error, credential_store_unavailable}
    end.

valid_pending_age(CreatedAt) when is_integer(CreatedAt) ->
    Now = erlang:system_time(millisecond),
    CreatedAt =< Now + ?PKCE_CLOCK_SKEW_MS andalso
    CreatedAt >= Now - ?MAX_PKCE_AGE_MS;
valid_pending_age(_CreatedAt) ->
    false.

valid_completed_credential(Credential) ->
    Kind = maps:get(kind, Credential,
                    maps:get(<<"kind">>, Credential, undefined)),
    Kind =/= undefined andalso Kind =/= oauth_authorization_pending andalso
    Kind =/= <<"oauth_authorization_pending">> andalso
    not maps:is_key(code_verifier, Credential) andalso
    not maps:is_key(<<"code_verifier">>, Credential).

%% @private Convert the compatible three-tuple pause reason into a structured
%% public discriminator. Unknown/custom pauses keep their legacy behavior.
-spec pause_details(term()) -> undefined | map().
pause_details({long_running, OperationId})
  when is_binary(OperationId), byte_size(OperationId) > 0 ->
    #{<<"type">> => <<"long_running">>,
      <<"operation_id">> => OperationId};
pause_details({credential_required, Request}) when is_map(Request) ->
    case normalize_credential_request(Request) of
        {ok, Safe} -> Safe#{<<"type">> => <<"credential_request">>};
        {error, _} -> undefined
    end;
pause_details(_) ->
    undefined.

-spec validate_progress(map(), binary(), term()) ->
    {ok, map()} | {error, term()}.
validate_progress(#{<<"type">> := <<"long_running">>,
                    <<"operation_id">> := OperationId},
                  OperationId, Update0)
  when is_binary(OperationId), is_map(Update0) ->
    case normalize_public_map(Update0) of
        {ok, Update} ->
            Allowed = [<<"operation_id">>, <<"status">>, <<"progress">>,
                       <<"message">>, <<"metadata">>],
            Status = maps:get(<<"status">>, Update, undefined),
            case exact_keys(Update, Allowed) andalso
                 maps:get(<<"operation_id">>, Update, undefined) =:=
                     OperationId andalso
                 (Status =:= <<"pending">> orelse
                  Status =:= <<"running">>) andalso
                 not contains_secret(Update) of
                true -> {ok, Update};
                false -> {error, invalid_long_running_progress}
            end;
        {error, _} -> {error, invalid_long_running_progress}
    end;
validate_progress(_Details, _OperationId, _Update) ->
    {error, long_running_operation_mismatch}.

-spec validate_resume(undefined | map(), term(), term(), binary()) ->
    {ok, term()} | {error, term()}.
validate_resume(undefined, ToolResponse, _CredentialStore, _UserId) ->
    {ok, ToolResponse};
validate_resume(#{<<"type">> := <<"long_running">>,
                  <<"operation_id">> := OperationId},
                Response0, _CredentialStore, _UserId)
  when is_map(Response0) ->
    case normalize_public_map(Response0) of
        {ok, Response} ->
            Allowed = [<<"operation_id">>, <<"status">>, <<"result">>,
                       <<"error">>, <<"metadata">>],
            Status = maps:get(<<"status">>, Response, undefined),
            Terminal = Status =:= <<"completed">> orelse
                       Status =:= <<"failed">> orelse
                       Status =:= <<"cancelled">>,
            case exact_keys(Response, Allowed) andalso Terminal andalso
                 maps:get(<<"operation_id">>, Response, undefined) =:=
                     OperationId andalso not contains_secret(Response) of
                true -> {ok, Response};
                false -> {error, invalid_long_running_completion}
            end;
        {error, _} -> {error, invalid_long_running_completion}
    end;
validate_resume(#{<<"type">> := <<"long_running">>},
                _Response, _CredentialStore, _UserId) ->
    {error, invalid_long_running_completion};
validate_resume(#{<<"type">> := <<"credential_request">>} = Details,
                Response0, CredentialStore, UserId) ->
    validate_credential_resume(Details, Response0, CredentialStore, UserId);
validate_resume(_Details, ToolResponse, _CredentialStore, _UserId) ->
    {ok, ToolResponse}.

validate_credential_resume(Details, Response0,
                           {StoreModule, Store}, UserId)
  when is_atom(StoreModule), is_binary(UserId), is_map(Response0) ->
    case normalize_public_map(Response0) of
        {ok, Response} ->
            Allowed = [<<"credential_ref">>, <<"correlation_id">>],
            Ref = maps:get(<<"credential_ref">>, Response, undefined),
            Correlation = maps:get(<<"correlation_id">>, Response,
                                   undefined),
            ExpectedCorrelation = maps:get(<<"correlation_id">>, Details),
            ExpectedRef = maps:get(<<"credential_flow_ref">>, Details),
            Provider = maps:get(<<"provider">>, Details),
            case exact_keys(Response, Allowed) andalso
                 adk_credential_store:is_ref(Ref) andalso
                 store_module(StoreModule) of
                false ->
                    {error, invalid_credential_completion};
                true when Ref =/= ExpectedRef ->
                    {error, credential_flow_mismatch};
                true when Correlation =/= ExpectedCorrelation ->
                    {error, invalid_credential_completion};
                true ->
                    validate_stored_credential(
                      StoreModule, Store, UserId, Provider, Ref, Response)
            end;
        {error, _} ->
            {error, invalid_credential_completion}
    end;
validate_credential_resume(_Details, _Response, undefined, _UserId) ->
    {error, credential_store_required};
validate_credential_resume(_Details, _Response, _Store, _UserId) ->
    {error, invalid_credential_store}.

validate_stored_credential(StoreModule, Store, UserId, Provider, Ref,
                           Response) ->
    try StoreModule:fetch(Store, UserId, Provider, Ref) of
        {ok, #{kind := oauth_authorization_pending}} ->
            {error, credential_authorization_incomplete};
        {ok, Credential} when is_map(Credential) ->
            {ok, Response};
        {error, not_found} ->
            {error, credential_scope_mismatch};
        _ ->
            {error, invalid_stored_credential}
    catch
        _:_ -> {error, credential_store_unavailable}
    end.

normalize_credential_request(Request0) ->
    case normalize_public_map(Request0) of
        {ok, Request} ->
            Allowed = [<<"provider">>, <<"scheme">>,
                       <<"authorization_uri">>, <<"scopes">>,
                       <<"correlation_id">>, <<"credential_flow_ref">>,
                       <<"pkce_challenge">>, <<"pkce_method">>,
                       <<"prompt">>],
            Provider = maps:get(<<"provider">>, Request, undefined),
            Scheme = maps:get(<<"scheme">>, Request, undefined),
            Uri = maps:get(<<"authorization_uri">>, Request, undefined),
            Scopes = maps:get(<<"scopes">>, Request, undefined),
            Correlation = maps:get(<<"correlation_id">>, Request,
                                   undefined),
            FlowRef = maps:get(<<"credential_flow_ref">>, Request,
                               undefined),
            Challenge = maps:get(<<"pkce_challenge">>, Request, undefined),
            Method = maps:get(<<"pkce_method">>, Request, undefined),
            Prompt = maps:get(<<"prompt">>, Request,
                              <<"Authentication and user consent are required.">>),
            case exact_keys(Request, Allowed) andalso
                 valid_text(Provider, ?MAX_ID_BYTES) andalso
                 (Scheme =:= <<"oauth2">> orelse Scheme =:= <<"oidc">>) andalso
                 valid_authorization_uri(Uri) andalso valid_scopes(Scopes) andalso
                 valid_text(Correlation, ?MAX_ID_BYTES) andalso
                 adk_credential_store:is_ref(FlowRef) andalso
                 valid_pkce_challenge(Challenge) andalso
                 Method =:= <<"S256">> andalso
                 valid_text(Prompt, ?MAX_SUMMARY_BYTES) andalso
                 not contains_secret(Request) of
                true -> {ok, Request};
                false -> {error, invalid_credential_request}
            end;
        {error, _} ->
            {error, invalid_credential_request}
    end.

normalize_public_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Normalized} when is_map(Normalized) -> {ok, Normalized};
        _ -> {error, invalid_json_value}
    end.

valid_authorization_uri(Uri) when is_binary(Uri) ->
    try uri_string:parse(Uri) of
        Parsed when is_map(Parsed) ->
            Scheme = to_binary(maps:get(scheme, Parsed, <<>>)),
            Host = to_binary(maps:get(host, Parsed, <<>>)),
            Scheme =:= <<"https">> andalso byte_size(Host) > 0 andalso
            not maps:is_key(userinfo, Parsed) andalso
            not maps:is_key(fragment, Parsed) andalso
            adk_secret_redactor:redact(Uri) =:= Uri;
        _ -> false
    catch
        _:_ -> false
    end;
valid_authorization_uri(_) -> false.

valid_scopes(Scopes) when is_list(Scopes), Scopes =/= [],
                          length(Scopes) =< ?MAX_SCOPES ->
    lists:all(fun(Scope) -> valid_text(Scope, ?MAX_SCOPE_BYTES) end, Scopes)
    andalso length(lists:usort(Scopes)) =:= length(Scopes);
valid_scopes(_) -> false.

valid_pkce_challenge(Value) when is_binary(Value),
                                 byte_size(Value) >= 43,
                                 byte_size(Value) =< 128 ->
    base64url_chars(Value);
valid_pkce_challenge(_) -> false.

base64url_chars(<<>>) -> true;
base64url_chars(<<Char, Rest/binary>>)
  when (Char >= $A andalso Char =< $Z) orelse
       (Char >= $a andalso Char =< $z) orelse
       (Char >= $0 andalso Char =< $9) orelse
       Char =:= $- orelse Char =:= $_ ->
    base64url_chars(Rest);
base64url_chars(_) -> false.

valid_text(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                            byte_size(Value) =< Max ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end;
valid_text(_, _) -> false.

exact_keys(Map, Allowed) ->
    map_size(maps:without(Allowed, Map)) =:= 0.

contains_secret(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          sensitive_key(Key) orelse contains_secret(Value)
      end, maps:to_list(Map));
contains_secret(List) when is_list(List) ->
    lists:any(fun contains_secret/1, List);
contains_secret(Binary) when is_binary(Binary) ->
    adk_secret_redactor:redact(Binary) =/= Binary;
contains_secret(_Value) ->
    false.

sensitive_key(Key) ->
    Sentinel = <<"__adk_public_value__">>,
    Redacted = adk_secret_redactor:redact(#{Key => Sentinel}),
    maps:get(Key, Redacted, Sentinel) =:= adk_secret_redactor:marker().

store_module(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            erlang:function_exported(Module, put, 4) andalso
            erlang:function_exported(Module, fetch, 4);
        _ -> false
    end.

cas_store_module(Module) ->
    store_module(Module) andalso
    erlang:function_exported(Module, compare_and_swap, 6).

base64url(Binary) ->
    Encoded0 = base64:encode(Binary),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    binary:replace(Encoded2, <<"=">>, <<>>, [global]).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(_) -> <<>>.
