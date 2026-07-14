%% @doc Authentication/authorization boundary for the A2A 1.0 server.
%%
%% Hooks receive the operation, raw request headers, and a bounded request
%% summary. They must return a stable principal id separately from the
%% principal passed to the executor. Only a SHA-256 scope is retained by the
%% task store; raw headers, credentials, and the principal are never retained
%% in A2A task or event data.
-module(adk_a2a_v1_auth).

-export([authorize/4, scope/1]).

-callback authorize(binary(), map(), map()) ->
    {ok, term(), binary()}
    | {error, unauthenticated | forbidden}.

-spec authorize(none | module() | fun((binary(), map(), map()) -> term()),
                binary(), map(), map()) ->
    {ok, map()} | {error, unauthenticated | forbidden}.
authorize(none, _Operation, Headers, _Summary) ->
    auth_context(#{<<"subject">> => <<"anonymous">>},
                 <<"anonymous">>, Headers);
authorize(Hook, Operation, Headers, Summary)
  when is_atom(Hook); is_function(Hook, 3) ->
    Result = try invoke(Hook, Operation, Headers, Summary) of
        Value -> Value
    catch
        _:_ -> {error, unauthenticated}
    end,
    normalize_result(Result, Headers);
authorize(_, _Operation, _Headers, _Summary) ->
    {error, unauthenticated}.

-spec scope(binary()) -> binary().
scope(PrincipalId) when is_binary(PrincipalId) ->
    crypto:hash(sha256, PrincipalId).

invoke(Hook, Operation, Headers, Summary) when is_atom(Hook) ->
    Hook:authorize(Operation, Headers, Summary);
invoke(Hook, Operation, Headers, Summary) ->
    Hook(Operation, Headers, Summary).

normalize_result({ok, Principal, PrincipalId}, Headers)
  when is_binary(PrincipalId), byte_size(PrincipalId) > 0,
       byte_size(PrincipalId) =< 512 ->
    auth_context(Principal, PrincipalId, Headers);
normalize_result({error, unauthenticated}, _Headers) ->
    {error, unauthenticated};
normalize_result({error, forbidden}, _Headers) ->
    {error, forbidden};
normalize_result(_, _Headers) ->
    {error, unauthenticated}.

auth_context(Principal, PrincipalId, Headers) ->
    {ok, #{principal => Principal,
           scope => scope(PrincipalId),
           secret_seeds => credential_seeds(Headers)}}.

credential_seeds(Headers) when is_map(Headers) ->
    lists:usort(
      lists:flatmap(
        fun({Name, Value}) ->
            case sensitive_header(lower(to_binary(Name))) of
                true -> header_seeds(to_binary(Value));
                false -> []
            end
        end, maps:to_list(Headers)));
credential_seeds(_) -> [].

header_seeds(<<>>) -> [];
header_seeds(Value) ->
    case binary:split(Value, <<" ">>, [global]) of
        [_Scheme, Credential] when byte_size(Credential) > 0 ->
            [Value, Credential];
        _ -> [Value]
    end.

sensitive_header(<<"authorization">>) -> true;
sensitive_header(<<"proxy-authorization">>) -> true;
sensitive_header(<<"cookie">>) -> true;
sensitive_header(<<"x-api-key">>) -> true;
sensitive_header(_) -> false.

lower(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.
