%% @doc Shared fail-closed validation for outbound model HTTP headers.
%%
%% Both the provider-neutral client and the built-in sync/stream transport use
%% this boundary. Header names are RFC token bytes, authority is transport
%% owned, names are unique case-insensitively, and aggregate storage is
%% bounded before any socket is opened.
-module(adk_model_http_headers).

-export([validate/1]).

-define(MAX_HEADERS, 128).
-define(MAX_HEADER_NAME_BYTES, 256).
-define(MAX_HEADER_BYTES, 65536).

-spec validate(term()) -> ok | {error, invalid_model_http_headers}.
validate(Headers) when is_list(Headers) ->
    validate(Headers, 0, 0, #{});
validate(_Headers) ->
    {error, invalid_model_http_headers}.

validate([], _Count, _Bytes, _Seen) ->
    ok;
validate(_Headers, Count, _Bytes, _Seen) when Count >= ?MAX_HEADERS ->
    {error, invalid_model_http_headers};
validate([{Name, Value} | Rest], Count, Bytes, Seen)
  when is_binary(Name), byte_size(Name) > 0,
       byte_size(Name) =< ?MAX_HEADER_NAME_BYTES,
       is_binary(Value) ->
    NewBytes = Bytes + byte_size(Name) + byte_size(Value),
    case NewBytes =< ?MAX_HEADER_BYTES andalso valid_name(Name) andalso
         not has_control(Value) of
        false ->
            {error, invalid_model_http_headers};
        true ->
            Normalized = lowercase_ascii(Name),
            case forbidden_or_duplicate(Normalized, Seen) of
                true -> {error, invalid_model_http_headers};
                false ->
                    validate(Rest, Count + 1, NewBytes,
                             Seen#{Normalized => true})
            end
    end;
validate(_ImproperOrInvalid, _Count, _Bytes, _Seen) ->
    {error, invalid_model_http_headers}.

forbidden_or_duplicate(<<"host">>, _Seen) -> true;
forbidden_or_duplicate(<<":authority">>, _Seen) -> true;
forbidden_or_duplicate(Name, Seen) -> maps:is_key(Name, Seen).

valid_name(Name) ->
    lists:all(fun valid_name_byte/1, binary_to_list(Name)).

valid_name_byte(Byte) when Byte >= $a, Byte =< $z -> true;
valid_name_byte(Byte) when Byte >= $A, Byte =< $Z -> true;
valid_name_byte(Byte) when Byte >= $0, Byte =< $9 -> true;
valid_name_byte(Byte) ->
    lists:member(Byte, "!#$%&'*+-.^_`|~").

has_control(Value) ->
    lists:any(fun(Byte) -> Byte < 32 orelse Byte =:= 127 end,
              binary_to_list(Value)).

lowercase_ascii(Value) ->
    <<<<(lowercase_byte(Byte))>> || <<Byte>> <= Value>>.

lowercase_byte(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lowercase_byte(Byte) -> Byte.
