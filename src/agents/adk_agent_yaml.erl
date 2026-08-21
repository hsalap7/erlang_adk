%% @doc Strict, allocation-bounded YAML subset for Agent Config files.
%%
%% This is intentionally not a general YAML implementation.  It accepts the
%% block mappings/sequences and JSON-schema scalars needed by Agent Config,
%% plus empty flow collections.  Anchors, aliases, tags, merge keys,
%% directives, multiple documents, non-JSON scalar types, and non-empty flow
%% collections are rejected before an Erlang configuration term is returned.
%% Map keys are always UTF-8 binaries and duplicate keys fail closed.
-module(adk_agent_yaml).

-export([decode/1]).

-define(MAX_BYTES, 1048576).
-define(MAX_DEPTH, 64).
-define(MAX_NODES, 50000).
-define(MAX_LINES, 100000).
-define(MAX_NUMBER_BYTES, 128).

-type yaml_error() :: {invalid_yaml, atom(), pos_integer()} |
                      {yaml_limit_exceeded, atom()}.

-spec decode(binary()) -> {ok, term()} | {error, yaml_error()}.
decode(Binary) when is_binary(Binary), byte_size(Binary) =< ?MAX_BYTES ->
    case valid_utf8(Binary) of
        false -> {error, {invalid_yaml, invalid_utf8, 1}};
        true ->
            Lines0 = binary:split(Binary, <<"\n">>, [global]),
            case preprocess(Lines0, 1, 0, []) of
                {ok, []} -> {error, {invalid_yaml, empty_document, 1}};
                {ok, Lines} -> parse_document(Lines);
                {error, _} = Error -> Error
            end
    end;
decode(Binary) when is_binary(Binary) ->
    {error, {yaml_limit_exceeded, bytes}};
decode(_Binary) ->
    {error, {invalid_yaml, invalid_input, 1}}.

parse_document([{_Line, 0, _Content} | _] = Lines) ->
    case parse_block(Lines, 0, 1, 0) of
        {ok, Value, [], _Count} -> {ok, Value};
        {ok, _Value, [{RestLine, _, _} | _], _Count} ->
            {error, {invalid_yaml, trailing_document, RestLine}};
        {error, _} = Error -> Error
    end;
parse_document([{Line, _Indent, _Content} | _]) ->
    {error, {invalid_yaml, root_must_start_at_column_zero, Line}}.

preprocess([], _Line, _Count, Acc) ->
    {ok, lists:reverse(Acc)};
preprocess(_Lines, _Line, Count, _Acc) when Count >= ?MAX_LINES ->
    {error, {yaml_limit_exceeded, lines}};
preprocess([Raw0 | Rest], Line, Count, Acc) ->
    Raw = drop_cr(Raw0),
    case valid_line_bytes(Raw) of
        false -> {error, {invalid_yaml, invalid_character, Line}};
        true ->
            {Indent, Content0} = indentation(Raw, 0),
            case Indent rem 2 of
                1 -> {error, {invalid_yaml, invalid_indentation, Line}};
                0 ->
                    case strip_comment(Content0) of
                        {error, _} ->
                            {error, {invalid_yaml, unterminated_quote, Line}};
                        {ok, Content1} ->
                            Content = trim(Content1),
                            preprocess_content(
                              Content, Indent, Rest, Line, Count, Acc)
                    end
            end
    end.

preprocess_content(<<>>, _Indent, Rest, Line, Count, Acc) ->
    preprocess(Rest, Line + 1, Count, Acc);
preprocess_content(<<"---">>, _Indent, _Rest, Line, _Count, _Acc) ->
    {error, {invalid_yaml, document_marker_not_allowed, Line}};
preprocess_content(<<"...">>, _Indent, _Rest, Line, _Count, _Acc) ->
    {error, {invalid_yaml, document_marker_not_allowed, Line}};
preprocess_content(<<$%, _/binary>>, _Indent, _Rest, Line, _Count, _Acc) ->
    {error, {invalid_yaml, directive_not_allowed, Line}};
preprocess_content(Content, Indent, Rest, Line, Count, Acc) ->
    preprocess(Rest, Line + 1, Count + 1,
               [{Line, Indent, Content} | Acc]).

parse_block(_Lines, _Indent, Depth, _Count) when Depth > ?MAX_DEPTH ->
    {error, {yaml_limit_exceeded, depth}};
parse_block([{Line, Actual, _} | _], Indent, _Depth, _Count)
  when Actual =/= Indent ->
    {error, {invalid_yaml, invalid_indentation, Line}};
parse_block([{_Line, _Indent, Content} | _] = Lines,
            Indent, Depth, Count) ->
    case sequence_content(Content) of
        {yes, _} -> parse_sequence(Lines, Indent, Depth, Count, []);
        no -> parse_mapping(Lines, Indent, Depth, Count, #{})
    end.

parse_mapping([], _Indent, _Depth, Count, Acc) ->
    {ok, Acc, [], Count};
parse_mapping([{_Line, Actual, _} | _] = Lines,
              Indent, _Depth, Count, Acc)
  when Actual < Indent ->
    {ok, Acc, Lines, Count};
parse_mapping([{Line, Actual, _} | _], Indent, _Depth, _Count, _Acc)
  when Actual > Indent ->
    {error, {invalid_yaml, invalid_indentation, Line}};
parse_mapping([{_Line, Indent, Content} | _] = Lines,
              _Indent, _Depth, Count, Acc) ->
    case sequence_content(Content) of
        {yes, _} -> {ok, Acc, Lines, Count};
        no -> parse_mapping_entry(Lines, Indent, Count, Acc)
    end.

parse_mapping_entry([{Line, Indent, Content} | Rest], Indent, Count, Acc) ->
    case split_mapping(Content) of
        no -> {error, {invalid_yaml, expected_mapping_entry, Line}};
        {ok, KeyToken, ValueToken} ->
            case parse_key(KeyToken, Line) of
                {ok, <<"<<">>} ->
                    {error, {invalid_yaml, merge_key_not_allowed, Line}};
                {ok, Key} ->
                    case maps:is_key(Key, Acc) of
                        true ->
                            {error, {invalid_yaml, duplicate_key, Line}};
                        false ->
                            case increment(Count) of
                                {error, _} = Error -> Error;
                                {ok, Count1} ->
                                    parse_mapping_value(
                                      Rest, Indent, Line, ValueToken,
                                      Count1, Acc, Key)
                            end
                    end;
                {error, _} = Error -> Error
            end
    end.

parse_mapping_value(Rest, Indent, _Line, <<>>, Count, Acc, Key) ->
    case Rest of
        [{_NextLine, NextIndent, _} | _] when NextIndent =:= Indent + 2 ->
            case parse_block(Rest, Indent + 2, (Indent div 2) + 2, Count) of
                {ok, Value, Remaining, Count1} ->
                    parse_mapping(Remaining, Indent, (Indent div 2) + 1,
                                  Count1, Acc#{Key => Value});
                {error, _} = Error -> Error
            end;
        [{NextLine, NextIndent, _} | _] when NextIndent > Indent ->
            {error, {invalid_yaml, invalid_indentation, NextLine}};
        _ ->
            parse_mapping(Rest, Indent, (Indent div 2) + 1,
                          Count, Acc#{Key => null})
    end;
parse_mapping_value(Rest, Indent, Line, ValueToken, Count, Acc, Key) ->
    case parse_scalar(ValueToken, Line) of
        {ok, Value} ->
            parse_mapping(Rest, Indent, (Indent div 2) + 1,
                          Count, Acc#{Key => Value});
        {error, _} = Error -> Error
    end.

parse_sequence([], _Indent, _Depth, Count, Acc) ->
    {ok, lists:reverse(Acc), [], Count};
parse_sequence([{_Line, Actual, _} | _] = Lines,
               Indent, _Depth, Count, Acc)
  when Actual < Indent ->
    {ok, lists:reverse(Acc), Lines, Count};
parse_sequence([{Line, Actual, _} | _], Indent, _Depth, _Count, _Acc)
  when Actual > Indent ->
    {error, {invalid_yaml, invalid_indentation, Line}};
parse_sequence([{Line, Indent, Content} | Rest], Indent, Depth, Count, Acc) ->
    case sequence_content(Content) of
        no -> {ok, lists:reverse(Acc),
               [{Line, Indent, Content} | Rest], Count};
        {yes, ItemToken} ->
            case increment(Count) of
                {error, _} = Error -> Error;
                {ok, Count1} ->
                    parse_sequence_item(
                      Rest, Indent, Depth, Line, ItemToken,
                      Count1, Acc)
            end
    end.

parse_sequence_item(Rest, Indent, Depth, _Line, <<>>, Count, Acc) ->
    case Rest of
        [{_NextLine, NextIndent, _} | _] when NextIndent =:= Indent + 2 ->
            case parse_block(Rest, Indent + 2, Depth + 1, Count) of
                {ok, Value, Remaining, Count1} ->
                    parse_sequence(Remaining, Indent, Depth, Count1,
                                   [Value | Acc]);
                {error, _} = Error -> Error
            end;
        [{NextLine, NextIndent, _} | _] when NextIndent > Indent ->
            {error, {invalid_yaml, invalid_indentation, NextLine}};
        _ ->
            parse_sequence(Rest, Indent, Depth, Count, [null | Acc])
    end;
parse_sequence_item(Rest, Indent, Depth, Line, ItemToken, Count, Acc) ->
    case split_mapping(ItemToken) of
        {ok, _Key, _Value} ->
            Synthetic = {Line, Indent + 2, ItemToken},
            case parse_block([Synthetic | Rest], Indent + 2,
                             Depth + 1, Count) of
                {ok, Value, Remaining, Count1} ->
                    parse_sequence(Remaining, Indent, Depth, Count1,
                                   [Value | Acc]);
                {error, _} = Error -> Error
            end;
        no ->
            case parse_scalar(ItemToken, Line) of
                {ok, Value} ->
                    parse_sequence(Rest, Indent, Depth, Count,
                                   [Value | Acc]);
                {error, _} = Error -> Error
            end
    end.

parse_key(Token0, Line) ->
    Token = trim(Token0),
    case parse_scalar(Token, Line) of
        {ok, Key} when is_binary(Key), byte_size(Key) > 0 ->
            {ok, Key};
        {ok, _Other} ->
            {error, {invalid_yaml, non_string_key, Line}};
        {error, _} = Error -> Error
    end.

parse_scalar(<<>>, Line) ->
    {error, {invalid_yaml, empty_scalar, Line}};
parse_scalar(Token0, Line) ->
    Token = trim(Token0),
    case forbidden_plain_token(Token) of
        true -> {error, {invalid_yaml, yaml_feature_not_allowed, Line}};
        false -> parse_allowed_scalar(Token, Line)
    end.

parse_allowed_scalar(<<"{}">>, _Line) -> {ok, #{}};
parse_allowed_scalar(<<"[]">>, _Line) -> {ok, []};
parse_allowed_scalar(<<${, _/binary>>, Line) ->
    {error, {invalid_yaml, flow_collection_not_allowed, Line}};
parse_allowed_scalar(<<$[, _/binary>>, Line) ->
    {error, {invalid_yaml, flow_collection_not_allowed, Line}};
parse_allowed_scalar(<<$", _/binary>> = Token, Line) ->
    parse_double_quoted(Token, Line);
parse_allowed_scalar(<<$', _/binary>> = Token, Line) ->
    parse_single_quoted(Token, Line);
parse_allowed_scalar(<<"true">>, _Line) -> {ok, true};
parse_allowed_scalar(<<"false">>, _Line) -> {ok, false};
parse_allowed_scalar(<<"null">>, _Line) -> {ok, null};
parse_allowed_scalar(Token, Line) ->
    case parse_number(Token) of
        {ok, Number} -> {ok, Number};
        not_number -> parse_plain_string(Token, Line);
        invalid_number -> {error, {invalid_yaml, invalid_number, Line}}
    end.

parse_double_quoted(Token, Line) ->
    try jsx:decode(Token, [return_maps]) of
        Value when is_binary(Value) -> {ok, Value};
        _ -> {error, {invalid_yaml, invalid_quoted_scalar, Line}}
    catch
        _:_ -> {error, {invalid_yaml, invalid_quoted_scalar, Line}}
    end.

parse_single_quoted(Token, Line) when byte_size(Token) >= 2 ->
    Size = byte_size(Token),
    case Token of
        <<$', Body:(Size - 2)/binary, $'>> ->
            case single_body(Body, []) of
                {ok, Value} -> {ok, Value};
                error -> {error, {invalid_yaml, invalid_quoted_scalar, Line}}
            end;
        _ -> {error, {invalid_yaml, invalid_quoted_scalar, Line}}
    end;
parse_single_quoted(_Token, Line) ->
    {error, {invalid_yaml, invalid_quoted_scalar, Line}}.

single_body(<<>>, Acc) ->
    Value = iolist_to_binary(lists:reverse(Acc)),
    case valid_utf8(Value) of true -> {ok, Value}; false -> error end;
single_body(<<$', $', Rest/binary>>, Acc) ->
    single_body(Rest, [<<$'>> | Acc]);
single_body(<<$', _/binary>>, _Acc) -> error;
single_body(<<Byte, Rest/binary>>, Acc) ->
    single_body(Rest, [<<Byte>> | Acc]).

parse_number(Token) when byte_size(Token) > ?MAX_NUMBER_BYTES ->
    case numeric_prefix(Token) of true -> invalid_number; false -> not_number end;
parse_number(Token) ->
    case re:run(Token, <<"^-?(0|[1-9][0-9]*)$">>,
                [{capture, none}]) of
        match ->
            try {ok, binary_to_integer(Token)}
            catch _:_ -> invalid_number
            end;
        nomatch -> parse_float(Token)
    end.

parse_float(Token) ->
    Pattern = <<"^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)$|^-?(0|[1-9][0-9]*)\\.[0-9]+$">>,
    case re:run(Token, Pattern, [{capture, none}]) of
        match ->
            try
                FloatToken = ensure_float_decimal(Token),
                Value = binary_to_float(FloatToken),
                case finite_float(Value) of
                    true -> {ok, Value};
                    false -> invalid_number
                end
            catch _:_ -> invalid_number
            end;
        nomatch ->
            case invalid_numeric_form(Token) of
                true -> invalid_number;
                false -> not_number
            end
    end.

ensure_float_decimal(Token) ->
    case binary:match(Token, <<".">>) of
        {_, _} -> Token;
        nomatch ->
            case exponent_position(Token) of
                {Pos, 1} ->
                    <<Prefix:Pos/binary, Marker, Rest/binary>> = Token,
                    <<Prefix/binary, ".0", Marker, Rest/binary>>
            end
    end.

exponent_position(Token) ->
    case binary:match(Token, <<"e">>) of
        nomatch -> binary:match(Token, <<"E">>);
        Match -> Match
    end.

finite_float(Value) ->
    Value =:= Value andalso abs(Value) =< 1.7976931348623157e308.

invalid_numeric_form(Token) ->
    Lower = string:lowercase(Token),
    lists:member(Lower,
                 [<<".nan">>, <<".inf">>, <<"+.inf">>, <<"-.inf">>])
    orelse re:run(Token,
                  <<"^[+-]?(0[0-9]+|[0-9]+\\.|\\.[0-9]+|0[xXoObB][0-9A-Fa-f]+)$">>,
                  [{capture, none}]) =:= match.

numeric_prefix(<<C, _/binary>>) ->
    (C >= $0 andalso C =< $9) orelse C =:= $- orelse
    C =:= $+ orelse C =:= $.;
numeric_prefix(<<>>) -> false.

parse_plain_string(Token, Line) ->
    Lower = string:lowercase(Token),
    case (Lower =:= <<"true">> orelse Lower =:= <<"false">> orelse
          Lower =:= <<"null">>) andalso
         Token =/= Lower of
        true -> {error, {invalid_yaml, ambiguous_scalar, Line}};
        false ->
            case valid_utf8(Token) of
                true -> {ok, Token};
                false -> {error, {invalid_yaml, invalid_utf8, Line}}
            end
    end.

forbidden_plain_token(<<C, _/binary>>)
  when C =:= $"; C =:= $'; C =:= ${; C =:= $[ -> false;
forbidden_plain_token(<<C, _/binary>>)
  when C =:= $&; C =:= $*; C =:= $! -> true;
forbidden_plain_token(<<C, _/binary>>)
  when C =:= $|; C =:= $>; C =:= $?; C =:= $@; C =:= $` -> true;
forbidden_plain_token(<<"~">>) -> true;
forbidden_plain_token(Token) ->
    forbidden_indicator_after_space(Token).

forbidden_indicator_after_space(Token) ->
    re:run(Token, <<"(^|[ ])(?:&|\\*|!)[^ ]+">>,
           [{capture, none}]) =:= match.

sequence_content(<<$->>) -> {yes, <<>>};
sequence_content(<<$-, $\s, Rest/binary>>) -> {yes, trim(Rest)};
sequence_content(_Content) -> no.

split_mapping(Content) ->
    split_mapping(Content, plain, []).

split_mapping(<<>>, _State, _Acc) -> no;
split_mapping(<<$:, Rest/binary>>, plain, Acc) ->
    case Rest of
        <<>> -> {ok, trim(iolist_to_binary(lists:reverse(Acc))), <<>>};
        <<$\s, Value/binary>> ->
            {ok, trim(iolist_to_binary(lists:reverse(Acc))), trim(Value)};
        _ -> split_mapping(Rest, plain, [<<$:>> | Acc])
    end;
split_mapping(<<$", Rest/binary>>, plain, Acc) ->
    split_mapping(Rest, double, [<<$">> | Acc]);
split_mapping(<<$', Rest/binary>>, plain, Acc) ->
    split_mapping(Rest, single, [<<$'>> | Acc]);
split_mapping(<<$\\, Next, Rest/binary>>, double, Acc) ->
    split_mapping(Rest, double, [<<Next>>, <<$\\>> | Acc]);
split_mapping(<<$", Rest/binary>>, double, Acc) ->
    split_mapping(Rest, plain, [<<$">> | Acc]);
split_mapping(<<$', $', Rest/binary>>, single, Acc) ->
    split_mapping(Rest, single, [<<$', $'>> | Acc]);
split_mapping(<<$', Rest/binary>>, single, Acc) ->
    split_mapping(Rest, plain, [<<$'>> | Acc]);
split_mapping(<<Byte, Rest/binary>>, State, Acc) ->
    split_mapping(Rest, State, [<<Byte>> | Acc]).

strip_comment(Content) -> strip_comment(Content, plain, []).

strip_comment(<<>>, plain, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
strip_comment(<<>>, _Quoted, _Acc) -> {error, unterminated_quote};
strip_comment(<<$#, _/binary>>, plain, []) ->
    {ok, <<>>};
strip_comment(<<$#, _/binary>>, plain, [<<$\s>> | _] = Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
strip_comment(<<$#, Rest/binary>>, plain, Acc) ->
    strip_comment(Rest, plain, [<<$#>> | Acc]);
strip_comment(<<$", Rest/binary>>, plain, Acc) ->
    strip_comment(Rest, double, [<<$">> | Acc]);
strip_comment(<<$', Rest/binary>>, plain, Acc) ->
    strip_comment(Rest, single, [<<$'>> | Acc]);
strip_comment(<<$\\, Next, Rest/binary>>, double, Acc) ->
    strip_comment(Rest, double, [<<Next>>, <<$\\>> | Acc]);
strip_comment(<<$", Rest/binary>>, double, Acc) ->
    strip_comment(Rest, plain, [<<$">> | Acc]);
strip_comment(<<$', $', Rest/binary>>, single, Acc) ->
    strip_comment(Rest, single, [<<$', $'>> | Acc]);
strip_comment(<<$', Rest/binary>>, single, Acc) ->
    strip_comment(Rest, plain, [<<$'>> | Acc]);
strip_comment(<<Byte, Rest/binary>>, State, Acc) ->
    strip_comment(Rest, State, [<<Byte>> | Acc]).

increment(Count) when Count >= ?MAX_NODES ->
    {error, {yaml_limit_exceeded, nodes}};
increment(Count) -> {ok, Count + 1}.

indentation(<<$\s, Rest/binary>>, Count) ->
    indentation(Rest, Count + 1);
indentation(Rest, Count) -> {Count, Rest}.

drop_cr(<<>>) -> <<>>;
drop_cr(Binary) ->
    case binary:last(Binary) of
        $\r -> binary:part(Binary, 0, byte_size(Binary) - 1);
        _ -> Binary
    end.

valid_line_bytes(Binary) ->
    not lists:any(
          fun(Byte) -> Byte =:= 0 orelse Byte =:= $\t orelse Byte < 32 end,
          binary_to_list(Binary)).

trim(Binary) -> string:trim(Binary, both, " ").

valid_utf8(Binary) ->
    try unicode:characters_to_binary(Binary, utf8, utf8) of
        Binary -> true;
        _ -> false
    catch _:_ -> false
    end.
