%% @doc Behaviour and shared types for credential stores.
%%
%% A credential reference is an opaque, random capability. Stores must also
%% verify the principal and provider scope before returning a credential.
-module(adk_credential_store).

-opaque credential_ref() :: binary().
-type handle() :: pid() | atom().
-type principal() :: binary() | atom().
-type provider_id() :: binary() | atom().
-type credential() :: adk_auth_provider:credential().
-type error_reason() :: invalid_scope | invalid_credential | not_found |
                        conflict | unavailable.

-export_type([credential_ref/0, handle/0, principal/0, provider_id/0,
              credential/0, error_reason/0]).
-export([new_ref/0, is_ref/1]).

-callback put(Handle :: handle(), Principal :: principal(),
              Provider :: provider_id(), Credential :: credential()) ->
    {ok, credential_ref()} | {error, error_reason()}.
-callback fetch(Handle :: handle(), Principal :: principal(),
                Provider :: provider_id(), Ref :: credential_ref()) ->
    {ok, credential()} | {error, error_reason()}.
-callback delete(Handle :: handle(), Principal :: principal(),
                 Provider :: provider_id(), Ref :: credential_ref()) ->
    ok | {error, error_reason()}.

%% @doc Atomically replace a credential only if its current value still
%% matches Expected. Implementations must preserve the opaque reference and
%% principal/provider scope. A stale expected value returns conflict and must
%% never overwrite a newer credential.
-callback compare_and_swap(Handle :: handle(), Principal :: principal(),
                           Provider :: provider_id(), Ref :: credential_ref(),
                           Expected :: credential(),
                           Replacement :: credential()) ->
    ok | {error, error_reason()}.

%% @private Generate an unguessable reference without embedding scope or secret
%% material in the reference itself.
-spec new_ref() -> credential_ref().
new_ref() ->
    Encoded0 = base64:encode(crypto:strong_rand_bytes(24)),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    Encoded = binary:replace(Encoded2, <<"=">>, <<>>, [global]),
    <<"cred_", Encoded/binary>>.

-spec is_ref(term()) -> boolean().
is_ref(<<"cred_", Encoded/binary>>) ->
    byte_size(Encoded) >= 32;
is_ref(_) ->
    false.
