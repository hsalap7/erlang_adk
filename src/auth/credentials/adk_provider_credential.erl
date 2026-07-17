%% @doc Credential resolver for trusted model-provider profiles.
%%
%% Normal callers resolve a binary profile ID. Direct credential sources are
%% accepted only through `resolve(Source, trusted)', which is intended for
%% trusted Erlang integration code and deterministic tests. Errors never carry
%% credential values.
-module(adk_provider_credential).

-export([resolve/1, resolve/2, resolve_snapshot/2, describe/1,
         snapshot_token/2]).

-define(MAX_ENV_NAME_BYTES, 128).
-define(MAX_CREDENTIAL_BYTES, 131072).
-define(MAX_PROFILES, 128).
-define(MAX_PROFILES_BYTES, 4194304).
-define(SNAPSHOT_KEY, {?MODULE, profile_snapshot_hmac_key}).

-type source() :: none |
                  {env, binary() | string()} |
                  {application_env, atom(), atom()} |
                  {literal, binary()}.
-type descriptor() :: #{source := none | env | application_env | literal}.
-export_type([source/0, descriptor/0]).

%% @doc Resolve the credential source owned by a configured binary profile.
-spec resolve(term()) ->
    {ok, none | binary()} | {error, term()}.
resolve(ProfileId) when is_binary(ProfileId) ->
    case raw_profile(ProfileId) of
        {ok, Profile, _Normalized} ->
            Source = maps:get(credential, Profile, none),
            resolve(Source, trusted);
        {error, _} = Error -> Error
    end;
resolve(_ProfileId) ->
    {error, invalid_provider_profile_id}.

%% @doc Resolve from the same immutable profile generation used to select the
%% adapter, endpoint and model. The environment is read once; a changed raw
%% profile fails before its credential source is touched.
-spec resolve_snapshot(term(), term()) ->
    {ok, none | binary()} | {error, term()}.
resolve_snapshot(ProfileId, ExpectedSnapshot)
  when is_binary(ProfileId), is_binary(ExpectedSnapshot),
       byte_size(ExpectedSnapshot) =:= 32 ->
    case raw_profile(ProfileId) of
        {ok, Profile, Normalized} ->
            case maps:get(profile_snapshot, Normalized) =:=
                 ExpectedSnapshot of
                true ->
                    resolve(maps:get(credential, Profile, none), trusted);
                false -> {error, provider_profile_changed}
            end;
        {error, _} = Error -> Error
    end;
resolve_snapshot(ProfileId, _ExpectedSnapshot) when is_binary(ProfileId) ->
    {error, invalid_provider_profile_snapshot};
resolve_snapshot(_ProfileId, _ExpectedSnapshot) ->
    {error, invalid_provider_profile_id}.

%% @private Produce an opaque, per-runtime token for one exact raw profile.
%% The random HMAC key never crosses this trusted runtime boundary. In
%% particular, the returned token is not an unkeyed digest that could expose
%% a low-entropy literal credential to offline guessing.
-spec snapshot_token(binary(), map()) -> binary().
snapshot_token(ProfileId, Profile)
  when is_binary(ProfileId), is_map(Profile) ->
    crypto:mac(
      hmac, sha256, snapshot_key(),
      term_to_binary({provider_profile, ProfileId, Profile},
                     [deterministic])).

snapshot_key() ->
    case persistent_term:get(?SNAPSHOT_KEY, undefined) of
        Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
        undefined -> initialize_snapshot_key()
    end.

initialize_snapshot_key() ->
    LockId = {?SNAPSHOT_KEY, self()},
    global:trans(
      LockId,
      fun() ->
          case persistent_term:get(?SNAPSHOT_KEY, undefined) of
              Key when is_binary(Key), byte_size(Key) =:= 32 -> Key;
              undefined ->
                  Key = crypto:strong_rand_bytes(32),
                  persistent_term:put(?SNAPSHOT_KEY, Key),
                  Key
          end
      end,
      [node()]).

%% @doc Resolve an explicit source only at a trusted-code boundary. The
%% `untrusted' form is deliberately fail-closed, including for environment
%% sources, so callers cannot probe arbitrary process/application variables.
-spec resolve(term(), trusted | untrusted) ->
    {ok, none | binary()} | {error, term()}.
resolve(Source, trusted) ->
    resolve_trusted(Source);
resolve(_Source, untrusted) ->
    {error, credential_source_not_allowed};
resolve(_Source, _Trust) ->
    {error, invalid_provider_credential_source}.

%% @doc Validate and project a source without returning credential material.
-spec describe(term()) -> {ok, descriptor()} | {error, term()}.
describe(none) ->
    {ok, #{source => none}};
describe({env, Name}) ->
    case normalize_env_name(Name) of
        {ok, BinaryName} ->
            {ok, #{source => env, name => BinaryName}};
        error -> {error, invalid_provider_credential_source}
    end;
describe({application_env, App, Key})
  when is_atom(App), App =/= undefined,
       is_atom(Key), Key =/= undefined ->
    {ok, #{source => application_env, application => App, key => Key}};
describe({literal, Credential})
  when is_binary(Credential), byte_size(Credential) > 0,
       byte_size(Credential) =< ?MAX_CREDENTIAL_BYTES ->
    {ok, #{source => literal}};
describe(_Source) ->
    {error, invalid_provider_credential_source}.

resolve_trusted(none) ->
    {ok, none};
resolve_trusted({env, Name}) ->
    case normalize_env_name(Name) of
        {ok, BinaryName} ->
            case os:getenv(binary_to_list(BinaryName)) of
                false -> {error, provider_credential_not_configured};
                Value -> checked_credential(Value)
            end;
        error -> {error, invalid_provider_credential_source}
    end;
resolve_trusted({application_env, App, Key})
  when is_atom(App), App =/= undefined,
       is_atom(Key), Key =/= undefined ->
    case application:get_env(App, Key) of
        {ok, Value} -> checked_credential(Value);
        undefined -> {error, provider_credential_not_configured}
    end;
resolve_trusted({literal, Credential})
  when is_binary(Credential), byte_size(Credential) > 0,
       byte_size(Credential) =< ?MAX_CREDENTIAL_BYTES ->
    {ok, Credential};
resolve_trusted(_Source) ->
    {error, invalid_provider_credential_source}.

raw_profile(ProfileId) ->
    Profiles = application:get_env(erlang_adk, provider_profiles, #{}),
    case valid_profiles_container(Profiles) of
        false -> {error, invalid_provider_profiles};
        true ->
            case maps:find(ProfileId, Profiles) of
                error -> {error, unknown_provider_profile};
                {ok, Profile} ->
                    case adk_provider_profile:normalize(ProfileId, Profile) of
                        {ok, Normalized} ->
                            {ok, Profile, Normalized};
                        {error, Reason} ->
                            {error, {invalid_provider_profile,
                                     ProfileId, Reason}}
                    end
            end
    end.

valid_profiles_container(Profiles)
  when is_map(Profiles), map_size(Profiles) =< ?MAX_PROFILES ->
    bounded_term(Profiles, ?MAX_PROFILES_BYTES);
valid_profiles_container(_Profiles) -> false.

checked_credential(Value) when is_binary(Value) ->
    case byte_size(Value) > 0 andalso
         byte_size(Value) =< ?MAX_CREDENTIAL_BYTES of
        true -> {ok, Value};
        false -> {error, invalid_provider_credential}
    end;
checked_credential(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary -> checked_credential(Binary)
    catch
        _:_ -> {error, invalid_provider_credential}
    end;
checked_credential(_Value) ->
    {error, invalid_provider_credential}.

normalize_env_name(Name) when is_list(Name) ->
    try normalize_env_name(unicode:characters_to_binary(Name))
    catch _:_ -> error
    end;
normalize_env_name(Name) when is_binary(Name), byte_size(Name) > 0,
                              byte_size(Name) =< ?MAX_ENV_NAME_BYTES ->
    case valid_env_chars(binary_to_list(Name), first) of
        true -> {ok, Name};
        false -> error
    end;
normalize_env_name(_Name) -> error.

valid_env_chars([], _Position) -> true;
valid_env_chars([Char | Rest], first)
  when (Char >= $A andalso Char =< $Z) orelse Char =:= $_ ->
    valid_env_chars(Rest, remaining);
valid_env_chars([Char | Rest], remaining)
  when (Char >= $A andalso Char =< $Z) orelse
       (Char >= $0 andalso Char =< $9) orelse Char =:= $_ ->
    valid_env_chars(Rest, remaining);
valid_env_chars(_Chars, _Position) -> false.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.
