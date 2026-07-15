%% @doc Strict extraction of OAuth bearer credentials from HTTP headers.
%%
%% This module intentionally has no query-string API. Access tokens are
%% accepted only from a single Authorization header and are never included in
%% an error value.
-module(adk_bearer_auth).

-export([extract/1]).

-type error_reason() :: missing_bearer_token |
                        multiple_authorization_headers |
                        malformed_authorization_header |
                        unsupported_authorization_scheme.

-export_type([error_reason/0]).

-define(MAX_AUTHORIZATION_BYTES, 16384).

-spec extract(map() | [{term(), term()}]) ->
    {ok, binary()} | {error, error_reason()}.
extract(Headers) when is_map(Headers) ->
    extract_pairs(maps:to_list(Headers));
extract(Headers) when is_list(Headers) ->
    extract_pairs(Headers);
extract(_Headers) ->
    {error, malformed_authorization_header}.

extract_pairs(Pairs) ->
    case collect_authorization_values(Pairs, []) of
        {ok, []} ->
            {error, missing_bearer_token};
        {ok, [Value]} ->
            parse_value(Value);
        {ok, _Multiple} ->
            {error, multiple_authorization_headers};
        error ->
            {error, malformed_authorization_header}
    end.

collect_authorization_values([], Acc) ->
    {ok, lists:reverse(Acc)};
collect_authorization_values([{Name, Value} | Rest], Acc) ->
    case header_name(Name) of
        authorization ->
            case header_values(Value) of
                {ok, Values} ->
                    collect_authorization_values(Rest,
                                                 lists:reverse(Values, Acc));
                error ->
                    error
            end;
        other ->
            collect_authorization_values(Rest, Acc);
        error ->
            error
    end;
collect_authorization_values(_Invalid, _Acc) ->
    error.

header_name(authorization) -> authorization;
header_name(Name) when is_atom(Name) ->
    header_name(atom_to_binary(Name, utf8));
header_name(Name) when is_binary(Name) ->
    try string:lowercase(Name) of
        <<"authorization">> -> authorization;
        _ -> other
    catch
        _:_ -> error
    end;
header_name(Name) when is_list(Name) ->
    case to_binary(Name) of
        {ok, Binary} -> header_name(Binary);
        error -> error
    end;
header_name(_) -> error.

header_values(Value) when is_binary(Value) ->
    {ok, [Value]};
header_values(Value) when is_list(Value) ->
    case is_charlist(Value) of
        true ->
            case to_binary(Value) of
                {ok, Binary} -> {ok, [Binary]};
                error -> error
            end;
        false ->
            case all_binaries(Value) of
                true -> {ok, Value};
                false -> error
            end
    end;
header_values(_) -> error.

parse_value(Value0) when byte_size(Value0) =< ?MAX_AUTHORIZATION_BYTES ->
    Value = trim_ows(Value0),
    case split_scheme(Value) of
        {ok, Scheme, Token} ->
            case string:lowercase(Scheme) of
                <<"bearer">> ->
                    case valid_bearer_token(Token) of
                        true -> {ok, Token};
                        false -> {error, malformed_authorization_header}
                    end;
                _ ->
                    {error, unsupported_authorization_scheme}
            end;
        error ->
            {error, malformed_authorization_header}
    end;
parse_value(_Value) ->
    {error, malformed_authorization_header}.

split_scheme(<<>>) -> error;
split_scheme(Binary) -> split_scheme(Binary, 0).

split_scheme(Binary, Position) when Position < byte_size(Binary) ->
    case binary:at(Binary, Position) of
        $\s -> finish_split(Binary, Position);
        $\t -> finish_split(Binary, Position);
        _ -> split_scheme(Binary, Position + 1)
    end;
split_scheme(_Binary, _Position) -> error.

finish_split(Binary, Position) when Position > 0 ->
    Scheme = binary:part(Binary, 0, Position),
    RestLength = byte_size(Binary) - Position,
    Rest = binary:part(Binary, Position, RestLength),
    case trim_ows(Rest) of
        <<>> -> error;
        Token -> {ok, Scheme, Token}
    end;
finish_split(_Binary, _Position) -> error.

valid_bearer_token(Token) when byte_size(Token) > 0,
                               byte_size(Token) =< ?MAX_AUTHORIZATION_BYTES ->
    lists:all(fun valid_bearer_byte/1, binary:bin_to_list(Token));
valid_bearer_token(_Token) -> false.

valid_bearer_byte(Byte) when Byte >= $A, Byte =< $Z -> true;
valid_bearer_byte(Byte) when Byte >= $a, Byte =< $z -> true;
valid_bearer_byte(Byte) when Byte >= $0, Byte =< $9 -> true;
valid_bearer_byte($-) -> true;
valid_bearer_byte($.) -> true;
valid_bearer_byte($_) -> true;
valid_bearer_byte($~) -> true;
valid_bearer_byte($+) -> true;
valid_bearer_byte($/) -> true;
valid_bearer_byte($=) -> true;
valid_bearer_byte(_) -> false.

trim_ows(Binary) ->
    trim_ows_right(trim_ows_left(Binary)).

trim_ows_left(<<$\s, Rest/binary>>) -> trim_ows_left(Rest);
trim_ows_left(<<$\t, Rest/binary>>) -> trim_ows_left(Rest);
trim_ows_left(Binary) -> Binary.

trim_ows_right(<<>>) -> <<>>;
trim_ows_right(Binary) ->
    case binary:last(Binary) of
        $\s -> trim_ows_right(binary:part(Binary, 0, byte_size(Binary) - 1));
        $\t -> trim_ows_right(binary:part(Binary, 0, byte_size(Binary) - 1));
        _ -> Binary
    end.

is_charlist([]) -> true;
is_charlist([Head | Tail]) when is_integer(Head), Head >= 0 ->
    is_charlist(Tail);
is_charlist(_) -> false.

all_binaries([]) -> true;
all_binaries([Head | Tail]) when is_binary(Head) -> all_binaries(Tail);
all_binaries(_) -> false.

to_binary(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> error
    catch
        _:_ -> error
    end.
