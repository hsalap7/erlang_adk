%% @doc Bounded, secret-free capability metadata shared by provider profiles.
%%
%% Capability names and values remain ordinary Erlang terms because adapters
%% use richer values than booleans (for example `synchronous' function calls
%% or a list of input modalities). This module never creates atoms from input
%% and rejects executable, opaque, secret-bearing, or excessively large terms.
-module(adk_provider_capabilities).

-export([normalize/1, merge/2, constrain/2, supports/2]).

-define(MAX_CAPABILITIES_BYTES, 262144).
-define(MAX_MAP_ENTRIES, 128).
-define(MAX_LIST_ENTRIES, 128).
-define(MAX_TEXT_BYTES, 65536).
-define(MAX_KEY_BYTES, 128).
-define(MAX_DEPTH, 8).
-define(MAX_SAFE_INTEGER, 9007199254740991).

-type capabilities() :: map().
-export_type([capabilities/0]).

-spec normalize(term()) ->
    {ok, capabilities()} | {error, invalid_provider_capabilities}.
normalize(Capabilities)
  when is_map(Capabilities), map_size(Capabilities) =< ?MAX_MAP_ENTRIES ->
    case bounded_term(Capabilities, ?MAX_CAPABILITIES_BYTES)
         andalso valid_map(Capabilities, 0) of
        true -> {ok, Capabilities};
        false -> {error, invalid_provider_capabilities}
    end;
normalize(_Capabilities) ->
    {error, invalid_provider_capabilities}.

%% @doc Merge a profile-wide capability floor with model-specific metadata.
%% The model map is authoritative for duplicate keys.
-spec merge(term(), term()) ->
    {ok, capabilities()} | {error, invalid_provider_capabilities}.
merge(Base, Override) ->
    case {normalize(Base), normalize(Override)} of
        {{ok, CheckedBase}, {ok, CheckedOverride}} ->
            normalize(maps:merge(CheckedBase, CheckedOverride));
        _ ->
            {error, invalid_provider_capabilities}
    end.

%% @doc Narrow model/profile metadata to the behavior implemented by an
%% adapter. The first map is an implementation ceiling: an override may turn
%% supported behavior off, select a subset of a list/map, or retain an exact
%% scalar value, but it can never introduce a key or value the adapter did not
%% advertise. Unknown profile keys are deliberately omitted.
-spec constrain(term(), term()) ->
    {ok, capabilities()} | {error, invalid_provider_capabilities}.
constrain(Ceiling, Restrictions) ->
    case {normalize(Ceiling), normalize(Restrictions)} of
        {{ok, CheckedCeiling}, {ok, CheckedRestrictions}} ->
            normalize(constrain_map(CheckedCeiling, CheckedRestrictions));
        _ ->
            {error, invalid_provider_capabilities}
    end.

%% @doc A capability is supported when it is present and does not carry an
%% explicit negative/empty marker. This accommodates richer provider values
%% such as `synchronous', `[audio]', or a configuration map.
-spec supports(map(), atom() | binary()) -> boolean().
supports(Capabilities, Name)
  when is_map(Capabilities), (is_atom(Name) orelse is_binary(Name)) ->
    case maps:find(Name, Capabilities) of
        error -> false;
        {ok, false} -> false;
        {ok, undefined} -> false;
        {ok, unsupported} -> false;
        {ok, none} -> false;
        {ok, []} -> false;
        {ok, Value} when is_map(Value), map_size(Value) =:= 0 -> false;
        {ok, _Value} -> true
    end;
supports(_Capabilities, _Name) ->
    false.

valid_map(Map, Depth)
  when Depth =< ?MAX_DEPTH, map_size(Map) =< ?MAX_MAP_ENTRIES ->
    lists:all(
      fun({Key, Value}) ->
              valid_key(Key) andalso
              not sensitive_capability_key(Key) andalso
              valid_value(Value, Depth + 1)
      end, maps:to_list(Map));
valid_map(_Map, _Depth) ->
    false.

valid_key(Key) when is_atom(Key) -> Key =/= undefined;
valid_key(Key) when is_binary(Key) ->
    valid_text(Key, ?MAX_KEY_BYTES);
valid_key(_Key) -> false.

valid_value(_Value, Depth) when Depth > ?MAX_DEPTH -> false;
valid_value(Value, _Depth) when is_boolean(Value) -> true;
valid_value(Value, _Depth) when is_atom(Value) -> Value =/= undefined;
valid_value(Value, _Depth) when is_integer(Value) ->
    abs(Value) =< ?MAX_SAFE_INTEGER;
valid_value(Value, _Depth) when is_float(Value) ->
    try Value =:= Value andalso abs(Value) =< ?MAX_SAFE_INTEGER
    catch _:_ -> false
    end;
valid_value(Value, _Depth) when is_binary(Value) ->
    valid_text(Value, ?MAX_TEXT_BYTES);
valid_value(Value, Depth) when is_map(Value) ->
    valid_map(Value, Depth);
valid_value(Value, Depth) when is_list(Value) ->
    valid_list(Value, Depth, 0);
valid_value(_Value, _Depth) ->
    false.

valid_list([], _Depth, _Count) -> true;
valid_list([Head | Tail], Depth, Count) when Count < ?MAX_LIST_ENTRIES ->
    valid_value(Head, Depth + 1) andalso
    valid_list(Tail, Depth, Count + 1);
valid_list(_ImproperOrLong, _Depth, _Count) -> false.

valid_text(Value, Maximum) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Maximum andalso
    try
        case unicode:characters_to_binary(Value, utf8, utf8) of
            Value -> true;
            _ -> false
        end
    catch _:_ -> false
    end.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.

constrain_map(Ceiling, Restrictions) ->
    maps:map(
      fun(Key, CeilingValue) ->
          case maps:find(Key, Restrictions) of
              error -> CeilingValue;
              {ok, RestrictedValue} ->
                  constrain_value(CeilingValue, RestrictedValue)
          end
      end, Ceiling).

constrain_value(Ceiling, Restricted) ->
    case negative_capability(Ceiling) of
        true -> Ceiling;
        false ->
            case negative_capability(Restricted) of
                true -> false;
                false -> constrain_supported_value(Ceiling, Restricted)
            end
    end.

constrain_supported_value(true, true) -> true;
constrain_supported_value(Ceiling, Restricted)
  when is_list(Ceiling), is_list(Restricted) ->
    unique_supported_values(Restricted, Ceiling, []);
constrain_supported_value(Ceiling, Restricted)
  when is_map(Ceiling), is_map(Restricted) ->
    constrain_map(Ceiling, Restricted);
constrain_supported_value(Value, Value) -> Value;
constrain_supported_value(_Ceiling, _Restricted) -> false.

unique_supported_values([], _Ceiling, Acc) ->
    lists:reverse(Acc);
unique_supported_values([Value | Rest], Ceiling, Acc) ->
    case lists:member(Value, Ceiling) andalso not lists:member(Value, Acc) of
        true -> unique_supported_values(Rest, Ceiling, [Value | Acc]);
        false -> unique_supported_values(Rest, Ceiling, Acc)
    end.

negative_capability(false) -> true;
negative_capability(undefined) -> true;
negative_capability(unsupported) -> true;
negative_capability(none) -> true;
negative_capability([]) -> true;
negative_capability(Value) when is_map(Value), map_size(Value) =:= 0 -> true;
negative_capability(_Value) -> false.

%% Capability names legitimately contain words such as `tokens' (for
%% example `minimum_prefix_tokens'). The general context redactor therefore
%% over-matches this schema. Reject only names which denote credential
%% material rather than every occurrence of the word token.
sensitive_capability_key(Key) ->
    case normalized_key(Key) of
        undefined -> true;
        Normalized ->
            lists:member(
              Normalized,
              [<<"apikey">>, <<"accesstoken">>, <<"refreshtoken">>,
               <<"idtoken">>, <<"bearertoken">>, <<"privatekey">>,
               <<"signingkey">>, <<"clientassertion">>, <<"bearer">>,
               <<"cookie">>, <<"setcookie">>, <<"otp">>, <<"pin">>])
            orelse contains_sensitive_name(Normalized)
    end.

contains_sensitive_name(Name) ->
    lists:any(
      fun(Pattern) -> binary:match(Name, Pattern) =/= nomatch end,
      [<<"credential">>, <<"authorization">>, <<"password">>,
       <<"passwd">>, <<"secret">>]).

normalized_key(Key) when is_atom(Key) ->
    normalized_key(atom_to_binary(Key, utf8));
normalized_key(Key) when is_binary(Key) ->
    try
        Lower = unicode:characters_to_binary(string:lowercase(Key)),
        lists:foldl(
          fun(Separator, Acc) ->
              binary:replace(Acc, Separator, <<>>, [global])
          end, Lower, [<<"_">>, <<"-">>, <<" ">>, <<".">>, <<":">>])
    catch _:_ -> undefined
    end;
normalized_key(_Key) -> undefined.
