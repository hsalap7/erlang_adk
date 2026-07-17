%% @doc Strict W3C Trace Context parsing and propagation.
%%
%% Trace identifiers are correlation data, never authorization data.  Callers
%% decide whether an inbound parent is trusted before passing the extracted
%% context to an invocation.  This module only validates and serializes the
%% wire representation; it never changes a sampling policy implicitly.
-module(adk_trace_context).

-export([parse/1, format/1, extract/1, inject/2,
         validate_trace_id/1, validate_span_id/1,
         validate_tracestate/1]).

-define(MAX_TRACESTATE_BYTES, 512).
-define(MAX_TRACESTATE_MEMBERS, 32).

-type trace_context() :: #{trace_id := binary(),
                           span_id := binary(),
                           trace_flags := 0..255,
                           remote => boolean(),
                           tracestate => null | binary()}.
-export_type([trace_context/0]).

%% @doc Parse the W3C version-00 traceparent representation.
-spec parse(binary()) -> {ok, trace_context()} | {error, term()}.
parse(<<"00-", TraceId:32/binary, "-", SpanId:16/binary,
        "-", FlagsHex:2/binary>>) ->
    case {validate_trace_id(TraceId), validate_span_id(SpanId),
          decode_hex_byte(FlagsHex)} of
        {ok, ok, {ok, Flags}} ->
            {ok, #{trace_id => TraceId, span_id => SpanId,
                   trace_flags => Flags, remote => true,
                   tracestate => null}};
        {{error, Reason}, _, _} -> traceparent_error(Reason);
        {_, {error, Reason}, _} -> traceparent_error(Reason);
        {_, _, {error, Reason}} -> traceparent_error(Reason)
    end;
parse(<<Version:2/binary, "-", _/binary>>) ->
    case hex_binary(Version) of
        false -> traceparent_error(invalid_version);
        true when Version =:= <<"ff">> -> traceparent_error(forbidden_version);
        true -> traceparent_error(unsupported_version)
    end;
parse(_) ->
    traceparent_error(invalid_length_or_delimiters).

%% @doc Format a local or extracted context as a version-00 traceparent.
-spec format(map()) -> {ok, binary()} | {error, term()}.
format(Context) when is_map(Context) ->
    TraceId = context_value(Context, trace_id, <<"trace_id">>, undefined),
    SpanId = context_value(Context, span_id, <<"span_id">>, undefined),
    Flags0 = context_value(Context, trace_flags, <<"trace_flags">>, 0),
    case {validate_trace_id(TraceId), validate_span_id(SpanId),
          normalize_flags(Flags0)} of
        {ok, ok, {ok, Flags}} ->
            {ok, <<"00-", TraceId/binary, "-", SpanId/binary, "-",
                   (hex_byte(Flags))/binary>>};
        {{error, Reason}, _, _} -> traceparent_error(Reason);
        {_, {error, Reason}, _} -> traceparent_error(Reason);
        {_, _, {error, Reason}} -> traceparent_error(Reason)
    end;
format(_) ->
    traceparent_error(invalid_context).

%% @doc Extract exactly one traceparent and at most one tracestate header.
-spec extract(map() | list()) ->
    {ok, trace_context()} | {error, term()} | not_found.
extract(Headers) when is_map(Headers); is_list(Headers) ->
    case header_values(<<"traceparent">>, Headers) of
        [] -> not_found;
        [Traceparent] ->
            case parse_header_value(Traceparent, traceparent) of
                {ok, Value} ->
                    case parse(Value) of
                        {ok, Context0} -> extract_tracestate(Headers, Context0);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ -> traceparent_error(duplicate_header)
    end;
extract(_) ->
    traceparent_error(invalid_headers).

%% @doc Inject traceparent/tracestate into a map or proplist of headers.
-spec inject(map(), map() | list()) ->
    {ok, map() | list()} | {error, term()}.
inject(Context, Headers) when is_map(Context),
                              (is_map(Headers) orelse is_list(Headers)) ->
    Tracestate0 = context_value(Context, tracestate, <<"tracestate">>, null),
    case {format(Context), validate_tracestate(Tracestate0)} of
        {{ok, Traceparent}, {ok, Tracestate}} ->
            Base = remove_trace_headers(Headers),
            WithParent = put_header(<<"traceparent">>, Traceparent, Base),
            case Tracestate of
                null -> {ok, WithParent};
                _ -> {ok, put_header(<<"tracestate">>, Tracestate,
                                     WithParent)}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
inject(_, _) ->
    traceparent_error(invalid_injection_arguments).

-spec validate_trace_id(term()) -> ok | {error, term()}.
validate_trace_id(Value) when is_binary(Value), byte_size(Value) =:= 32 ->
    case hex_binary(Value) andalso Value =/= <<"00000000000000000000000000000000">> of
        true -> ok;
        false -> {error, invalid_trace_id}
    end;
validate_trace_id(_) -> {error, invalid_trace_id}.

-spec validate_span_id(term()) -> ok | {error, term()}.
validate_span_id(Value) when is_binary(Value), byte_size(Value) =:= 16 ->
    case hex_binary(Value) andalso Value =/= <<"0000000000000000">> of
        true -> ok;
        false -> {error, invalid_span_id}
    end;
validate_span_id(_) -> {error, invalid_span_id}.

%% @doc Validate and canonicalize W3C tracestate.  OWS around members is
%% removed; member order is preserved because the left-most entry is special.
-spec validate_tracestate(term()) ->
    {ok, null | binary()} | {error, term()}.
validate_tracestate(null) -> {ok, null};
validate_tracestate(undefined) -> {ok, null};
validate_tracestate(<<>>) -> {error, {invalid_tracestate, empty}};
validate_tracestate(Value) when is_binary(Value),
                                byte_size(Value) =< ?MAX_TRACESTATE_BYTES ->
    Members0 = binary:split(Value, <<",">>, [global]),
    Members = [trim_ows(Member) || Member <- Members0],
    case length(Members) =< ?MAX_TRACESTATE_MEMBERS of
        false -> {error, {invalid_tracestate, too_many_members}};
        true -> validate_tracestate_members(Members, #{}, [])
    end;
validate_tracestate(Value) when is_binary(Value) ->
    {error, {invalid_tracestate, too_large}};
validate_tracestate(_) ->
    {error, {invalid_tracestate, invalid_type}}.

extract_tracestate(Headers, Context) ->
    case header_values(<<"tracestate">>, Headers) of
        [] -> {ok, Context};
        [Raw] ->
            case parse_header_value(Raw, tracestate) of
                {ok, Value} ->
                    case validate_tracestate(Value) of
                        {ok, Tracestate} ->
                            {ok, Context#{tracestate => Tracestate}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, {invalid_tracestate, duplicate_header}}
    end.

validate_tracestate_members([], _Seen, Acc) ->
    {ok, iolist_to_binary(lists:join(<<",">>, lists:reverse(Acc)))};
validate_tracestate_members([Member | Rest], Seen, Acc) ->
    case binary:split(Member, <<"=">>) of
        [Key, Value] ->
            case {valid_tracestate_key(Key), valid_tracestate_value(Value),
                  maps:is_key(Key, Seen)} of
                {true, true, false} ->
                    validate_tracestate_members(
                      Rest, Seen#{Key => true},
                      [<<Key/binary, "=", Value/binary>> | Acc]);
                {false, _, _} ->
                    {error, {invalid_tracestate, invalid_key}};
                {_, false, _} ->
                    {error, {invalid_tracestate, invalid_value}};
                {_, _, true} ->
                    {error, {invalid_tracestate, duplicate_key}}
            end;
        _ -> {error, {invalid_tracestate, invalid_member}}
    end.

valid_tracestate_key(Key) when byte_size(Key) >= 1,
                               byte_size(Key) =< 256 ->
    case binary:split(Key, <<"@">>, [global]) of
        [Simple] -> valid_simple_key(Simple, 256, false);
        [Tenant, System] ->
            valid_simple_key(Tenant, 241, true) andalso
            valid_simple_key(System, 14, false);
        _ -> false
    end;
valid_tracestate_key(_) -> false.

valid_simple_key(<<First, Rest/binary>>, Max, AllowDot)
  when byte_size(Rest) + 1 =< Max ->
    lower_or_digit(First) andalso
    lists:all(fun(Char) -> key_char(Char, AllowDot) end,
              binary_to_list(Rest));
valid_simple_key(_, _, _) -> false.

key_char(Char, _AllowDot) when Char >= $a, Char =< $z -> true;
key_char(Char, _AllowDot) when Char >= $0, Char =< $9 -> true;
key_char($_, _AllowDot) -> true;
key_char($-, _AllowDot) -> true;
key_char($*, _AllowDot) -> true;
key_char($/, _AllowDot) -> true;
key_char($., true) -> true;
key_char(_, _) -> false.

lower_or_digit(Char) when Char >= $a, Char =< $z -> true;
lower_or_digit(Char) when Char >= $0, Char =< $9 -> true;
lower_or_digit(_) -> false.

valid_tracestate_value(<<>>) -> false;
valid_tracestate_value(Value) when byte_size(Value) =< 256 ->
    binary:last(Value) =/= $\s andalso
    lists:all(fun(Char) ->
                      Char >= 16#20 andalso Char =< 16#7e andalso
                      Char =/= $, andalso Char =/= $=
              end, binary_to_list(Value));
valid_tracestate_value(_) -> false.

header_values(Name, Headers) when is_map(Headers) ->
    [Value || {Key, Value} <- maps:to_list(Headers),
              normalized_header_name(Key) =:= Name];
header_values(Name, Headers) when is_list(Headers) ->
    [Value || {Key, Value} <- Headers,
              normalized_header_name(Key) =:= Name];
header_values(_, _) -> [].

normalized_header_name(Key) when is_binary(Key) ->
    try string:lowercase(Key) catch _:_ -> invalid end;
normalized_header_name(Key) when is_list(Key) ->
    try string:lowercase(unicode:characters_to_binary(Key))
    catch _:_ -> invalid
    end;
normalized_header_name(Key) when is_atom(Key) ->
    normalized_header_name(atom_to_binary(Key, utf8));
normalized_header_name(_) -> invalid.

parse_header_value(Value, _Kind) when is_binary(Value),
                                      byte_size(Value) =< 1024 ->
    {ok, Value};
parse_header_value(Value, Kind) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary), byte_size(Binary) =< 1024 ->
            {ok, Binary};
        _ -> {error, {invalid_trace_header, Kind}}
    catch _:_ -> {error, {invalid_trace_header, Kind}}
    end;
parse_header_value(_, Kind) -> {error, {invalid_trace_header, Kind}}.

remove_trace_headers(Headers) when is_map(Headers) ->
    maps:filter(
      fun(Key, _Value) ->
              Name = normalized_header_name(Key),
              Name =/= <<"traceparent">> andalso Name =/= <<"tracestate">>
      end, Headers);
remove_trace_headers(Headers) when is_list(Headers) ->
    [{Key, Value} || {Key, Value} <- Headers,
                     normalized_header_name(Key) =/= <<"traceparent">>,
                     normalized_header_name(Key) =/= <<"tracestate">>].

put_header(Name, Value, Headers) when is_map(Headers) ->
    Headers#{Name => Value};
put_header(Name, Value, Headers) when is_list(Headers) ->
    [{Name, Value} | Headers].

context_value(Context, AtomKey, BinaryKey, Default) ->
    case maps:find(AtomKey, Context) of
        {ok, Value} -> Value;
        error -> maps:get(BinaryKey, Context, Default)
    end.

normalize_flags(Value) when is_integer(Value), Value >= 0, Value =< 255 ->
    {ok, Value};
normalize_flags(Value) when is_binary(Value), byte_size(Value) =:= 2 ->
    decode_hex_byte(Value);
normalize_flags(_) -> {error, invalid_trace_flags}.

decode_hex_byte(Value) ->
    case hex_binary(Value) of
        true -> {ok, binary_to_integer(Value, 16)};
        false -> {error, invalid_trace_flags}
    end.

hex_byte(Value) ->
    <<(hex(Value bsr 4)), (hex(Value band 16#0f))>>.

hex_binary(Value) ->
    lists:all(fun(Char) ->
                      (Char >= $0 andalso Char =< $9) orelse
                      (Char >= $a andalso Char =< $f)
              end, binary_to_list(Value)).

hex(Value) when Value < 10 -> $0 + Value;
hex(Value) -> $a + Value - 10.

trim_ows(Value) ->
    trim_ows_right(trim_ows_left(Value)).

trim_ows_left(<<Char, Rest/binary>>) when Char =:= $\s; Char =:= $\t ->
    trim_ows_left(Rest);
trim_ows_left(Value) -> Value.

trim_ows_right(<<>>) -> <<>>;
trim_ows_right(Value) ->
    case binary:last(Value) of
        Char when Char =:= $\s; Char =:= $\t ->
            trim_ows_right(binary:part(Value, 0, byte_size(Value) - 1));
        _ -> Value
    end.

traceparent_error(Reason) -> {error, {invalid_traceparent, Reason}}.
