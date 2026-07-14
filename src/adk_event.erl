%% @doc Immutable, versioned events for the ADK event system.
%%
%% Events are the fundamental unit of communication in the Runner architecture.
%% `encode/1' and `decode/1' are the checked persistence/JSON boundary.  They
%% deliberately accept only JSON values in generic fields; Erlang terms are not
%% rendered with `~p' because that loses type information and can leak internal
%% values into an external protocol.
-module(adk_event).

-export([
    codec_version/0,
    new/2,
    new/3,
    with_state_delta/2,
    is_final_response/1,
    encode_content/1,
    decode_content/1,
    encode/1,
    decode/1,
    to_map/1,
    from_map/1
]).

-include("../include/adk_event.hrl").

-define(CODEC_VERSION, 1).

-type event() :: #adk_event{}.
-type json_path() :: [binary() | non_neg_integer()].
-type codec_error() ::
    {invalid_event, json_path(), term()}
    | {invalid_content, json_path(), term()}
    | {invalid_json_value, json_path(), term()}
    | {unsupported_schema_version, term()}.
-export_type([event/0, codec_error/0]).

%% @doc The schema version emitted by `encode/1' and `to_map/1'.
-spec codec_version() -> pos_integer().
codec_version() ->
    ?CODEC_VERSION.

%% @doc Create a new immutable event with an auto-generated ID and timestamp.
%% Author is the name of the agent or the binary string `<<"user">>'.
%% Content can be text, tool calls, or a tool response.
-spec new(Author :: binary(), Content :: term()) -> event().
new(Author, Content) ->
    new(Author, Content, #{}).

%% @doc Create a new immutable event with options.
%% Options can include `partial', `is_final', `actions', and `invocation_id'.
-spec new(Author :: binary(), Content :: term(), Opts :: map()) -> event().
new(Author, Content, Opts) ->
    #adk_event{
        id = generate_id(),
        invocation_id = maps:get(invocation_id, Opts, generate_id()),
        author = Author,
        content = Content,
        actions = maps:get(actions, Opts, #{}),
        timestamp = erlang:system_time(millisecond),
        partial = maps:get(partial, Opts, false),
        is_final = maps:get(is_final, Opts, false)
    }.

%% @doc Attach a state delta map to an existing event.
-spec with_state_delta(Event :: event(), Delta :: map()) -> event().
with_state_delta(Event, Delta) ->
    Actions = Event#adk_event.actions,
    NewActions = Actions#{<<"state_delta">> => Delta},
    Event#adk_event{actions = NewActions}.

%% @doc Check whether this is the terminal event in an invocation.
-spec is_final_response(Event :: event()) -> boolean().
is_final_response(#adk_event{is_final = true}) -> true;
is_final_response(_) -> false.

%% @doc Encode one event content value without constructing an event.
%% This is useful for durable continuations which embed tool calls but must use
%% exactly the same canonical representation as externally visible events.
-spec encode_content(term()) -> {ok, map()} | {error, codec_error()}.
encode_content(Content) ->
    format_content(Content).

%% @doc Decode canonical version-1 content produced by `encode_content/1'.
-spec decode_content(term()) -> {ok, term()} | {error, codec_error()}.
decode_content(EncodedContent) ->
    decode_content(EncodedContent, canonical).

%% @doc Encode an event to the canonical JSON-safe map representation.
%%
%% Tool-call tuples are represented as maps.  A three-field call always has a
%% `thought_signature' key and a four-field call always has both optional keys;
%% JSON `null' represents Erlang `undefined'.  This makes tuple arity survive a
%% JSON encode/decode round trip.
-spec encode(event()) -> {ok, map()} | {error, codec_error()}.
encode(#adk_event{id = Id, invocation_id = InvId, author = Author,
                  content = Content, actions = Actions, timestamp = Timestamp,
                  partial = Partial, is_final = IsFinal}) ->
    case validate_event_header(Id, InvId, Author, Timestamp, Partial, IsFinal) of
        ok ->
            case format_content(Content) of
                {ok, EncodedContent} ->
                    case json_safe(Actions, [<<"actions">>]) of
                        {ok, EncodedActions} when is_map(EncodedActions) ->
                            {ok, #{
                                <<"schema_version">> => ?CODEC_VERSION,
                                <<"id">> => Id,
                                <<"invocation_id">> => InvId,
                                <<"author">> => Author,
                                <<"content">> => EncodedContent,
                                <<"actions">> => EncodedActions,
                                <<"timestamp">> => Timestamp,
                                <<"partial">> => Partial,
                                <<"is_final">> => IsFinal
                            }};
                        {ok, _NotAMap} ->
                            invalid_event([<<"actions">>], expected_map);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
encode(Other) ->
    invalid_event([], {expected_adk_event, term_type(Other)}).

%% @doc Decode either a canonical event map or a map persisted by v0.2.x.
%% Maps without `schema_version' use the legacy decoder.  New, unknown versions
%% are rejected so that a future schema is never misinterpreted as version 1.
-spec decode(map()) -> {ok, event()} | {error, codec_error()}.
decode(Map) when is_map(Map) ->
    case maps:find(<<"schema_version">>, Map) of
        error -> decode_event(Map, legacy);
        {ok, ?CODEC_VERSION} -> decode_event(Map, canonical);
        {ok, Version} -> {error, {unsupported_schema_version, Version}}
    end;
decode(Other) ->
    invalid_event([], {expected_map, term_type(Other)}).

%% @doc Strict compatibility wrapper around `encode/1'.
%% Prefer `encode/1' at external boundaries where a typed error can be handled.
-spec to_map(event()) -> map().
to_map(Event) ->
    case encode(Event) of
        {ok, Map} -> Map;
        {error, Reason} -> erlang:error({adk_event_codec, Reason})
    end.

%% @doc Strict compatibility wrapper around `decode/1'.
%% Prefer `decode/1' when reading untrusted data.
-spec from_map(map()) -> event().
from_map(Map) ->
    case decode(Map) of
        {ok, Event} -> Event;
        {error, Reason} -> erlang:error({adk_event_codec, Reason})
    end.

%% Internal functions

%% @private Generate a pseudo-random UUID-like binary.
generate_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    List = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                         [A, B, C band 16#0fff,
                          D band 16#3fff bor 16#8000, E]),
    list_to_binary(List).

validate_event_header(Id, InvId, Author, Timestamp, Partial, IsFinal) ->
    Validators = [
        {Id, [<<"id">>], binary},
        {InvId, [<<"invocation_id">>], binary},
        {Author, [<<"author">>], binary},
        {Timestamp, [<<"timestamp">>], integer},
        {Partial, [<<"partial">>], boolean},
        {IsFinal, [<<"is_final">>], boolean}
    ],
    validate_header_values(Validators).

validate_header_values([]) ->
    ok;
validate_header_values([{Value, Path, binary} | Rest]) when is_binary(Value) ->
    case valid_utf8(Value) of
        true -> validate_header_values(Rest);
        false -> invalid_event(Path, invalid_utf8)
    end;
validate_header_values([{Value, _Path, integer} | Rest]) when is_integer(Value) ->
    validate_header_values(Rest);
validate_header_values([{Value, _Path, boolean} | Rest]) when is_boolean(Value) ->
    validate_header_values(Rest);
validate_header_values([{_Value, Path, Expected} | _Rest]) ->
    invalid_event(Path, {expected, Expected}).

format_content({tool_calls, Calls}) when is_list(Calls) ->
    case format_tool_calls(Calls, 0, []) of
        {ok, EncodedCalls} ->
            {ok, #{<<"type">> => <<"tool_calls">>,
                   <<"calls">> => EncodedCalls}};
        {error, _} = Error ->
            Error
    end;
format_content({tool_calls, _Calls}) ->
    invalid_content([<<"content">>, <<"calls">>], expected_list);
format_content({tool_response, Name, Result}) ->
    format_tool_response(Name, Result, absent, absent);
format_content({tool_response, Name, Result, Signature}) ->
    format_tool_response(Name, Result, {present, Signature}, absent);
format_content({tool_response, Name, Result, Signature, CallId}) ->
    format_tool_response(Name, Result, {present, Signature},
                         {present, CallId});
format_content(Content) when is_map(Content) ->
    case adk_content:validate(Content, adk_content:safety_limits()) of
        {ok, Canonical} ->
            {ok, #{<<"type">> => <<"model_content">>,
                   <<"value">> => Canonical}};
        {error, Reason} ->
            invalid_content([<<"content">>],
                            {invalid_model_content, Reason})
    end;
format_content(Text) when is_binary(Text) ->
    case valid_utf8(Text) of
        true -> {ok, #{<<"type">> => <<"text">>, <<"text">> => Text}};
        false -> invalid_content([<<"content">>, <<"text">>], invalid_utf8)
    end;
format_content(Text) when is_list(Text) ->
    try unicode:characters_to_binary(Text) of
        Encoded when is_binary(Encoded) ->
            {ok, #{<<"type">> => <<"text">>, <<"text">> => Encoded}};
        {error, _Encoded, _Rest} ->
            invalid_content([<<"content">>], invalid_unicode);
        {incomplete, _Encoded, _Rest} ->
            invalid_content([<<"content">>], incomplete_unicode)
    catch
        error:badarg ->
            invalid_content([<<"content">>], invalid_unicode)
    end;
format_content(Other) ->
    invalid_content([<<"content">>], {unsupported_type, term_type(Other)}).

format_tool_calls([], _Index, Acc) ->
    {ok, lists:reverse(Acc)};
format_tool_calls([Call | Rest], Index, Acc) ->
    Path = [<<"content">>, <<"calls">>, Index],
    case format_tool_call(Call, Path) of
        {ok, EncodedCall} ->
            format_tool_calls(Rest, Index + 1, [EncodedCall | Acc]);
        {error, _} = Error ->
            Error
    end.

format_tool_call({Name, Args}, Path) ->
    format_tool_call_fields(Name, Args, absent, absent, Path);
format_tool_call({Name, Args, Signature}, Path) ->
    format_tool_call_fields(Name, Args, {present, Signature}, absent, Path);
format_tool_call({Name, Args, Signature, CallId}, Path) ->
    format_tool_call_fields(Name, Args, {present, Signature},
                            {present, CallId}, Path);
format_tool_call(Call, Path) ->
    invalid_content(Path, {invalid_tool_call, term_type(Call)}).

format_tool_call_fields(Name, Args, Signature, CallId, Path) ->
    case validate_binary(Name, Path ++ [<<"name">>], invalid_content) of
        ok ->
            case json_safe(Args, Path ++ [<<"args">>]) of
                {ok, SafeArgs} ->
                    Base = #{<<"name">> => Name, <<"args">> => SafeArgs},
                    case put_optional_binary(Base, <<"thought_signature">>,
                                             Signature, Path, invalid_content) of
                        {ok, WithSignature} ->
                            put_optional_binary(WithSignature, <<"call_id">>,
                                                CallId, Path, invalid_content);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

format_tool_response(Name, Result, Signature, CallId) ->
    Path = [<<"content">>],
    case validate_binary(Name, Path ++ [<<"name">>], invalid_content) of
        ok ->
            case json_safe(Result, Path ++ [<<"result">>]) of
                {ok, SafeResult} ->
                    Base = #{
                        <<"type">> => <<"tool_response">>,
                        <<"name">> => Name,
                        <<"result">> => SafeResult
                    },
                    case put_optional_binary(Base, <<"signature">>, Signature,
                                             Path, invalid_content) of
                        {ok, WithSignature} ->
                            put_optional_binary(WithSignature, <<"call_id">>,
                                                CallId, Path, invalid_content);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

put_optional_binary(Map, _Key, absent, _Path, _ErrorType) ->
    {ok, Map};
put_optional_binary(Map, Key, {present, undefined}, _Path, _ErrorType) ->
    {ok, Map#{Key => null}};
put_optional_binary(Map, Key, {present, Value}, Path, _ErrorType)
  when is_binary(Value) ->
    case valid_utf8(Value) of
        true -> {ok, Map#{Key => Value}};
        false ->
            invalid_content(Path ++ [Key], invalid_utf8)
    end;
put_optional_binary(_Map, Key, {present, _Value}, Path, invalid_content) ->
    invalid_content(Path ++ [Key], {expected, binary_or_undefined}).

decode_event(Map, Mode) ->
    Specs = [
        {<<"id">>, utf8_binary},
        {<<"invocation_id">>, utf8_binary},
        {<<"author">>, utf8_binary},
        {<<"content">>, any},
        {<<"timestamp">>, integer}
    ],
    case read_fields(Map, Specs, #{}) of
        {ok, Fields} ->
            Actions = maps:get(<<"actions">>, Map, #{}),
            Partial = maps:get(<<"partial">>, Map, false),
            IsFinal = maps:get(<<"is_final">>, Map, false),
            case validate_decoded_metadata(Actions, Partial, IsFinal, Mode) of
                {ok, DecodedActions} ->
                    EncodedContent = maps:get(<<"content">>, Fields),
                    case decode_content(EncodedContent, Mode) of
                        {ok, Content} ->
                            {ok, #adk_event{
                                id = maps:get(<<"id">>, Fields),
                                invocation_id = maps:get(<<"invocation_id">>, Fields),
                                author = maps:get(<<"author">>, Fields),
                                content = Content,
                                actions = DecodedActions,
                                timestamp = maps:get(<<"timestamp">>, Fields),
                                partial = Partial,
                                is_final = IsFinal
                            }};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

decode_content(EncodedContent, legacy) ->
    parse_content(EncodedContent, legacy);
decode_content(EncodedContent, canonical) ->
    case json_safe(EncodedContent, [<<"content">>]) of
        {ok, SafeContent} -> parse_content(SafeContent, canonical);
        {error, _} = Error -> Error
    end.

read_fields(_Map, [], Acc) ->
    {ok, Acc};
read_fields(Map, [{Key, Expected} | Rest], Acc) ->
    case maps:find(Key, Map) of
        error ->
            invalid_event([Key], missing_required_field);
        {ok, Value} ->
            case value_matches(Value, Expected) of
                true -> read_fields(Map, Rest, Acc#{Key => Value});
                false -> invalid_event([Key], {expected, Expected})
            end
    end.

value_matches(_Value, any) -> true;
value_matches(Value, utf8_binary) -> is_binary(Value) andalso valid_utf8(Value);
value_matches(Value, integer) -> is_integer(Value).

validate_decoded_metadata(Actions, Partial, IsFinal, Mode)
  when is_map(Actions), is_boolean(Partial), is_boolean(IsFinal) ->
    case Mode of
        legacy -> {ok, Actions};
        canonical -> json_safe(Actions, [<<"actions">>])
    end;
validate_decoded_metadata(Actions, _Partial, _IsFinal, _Mode)
  when not is_map(Actions) ->
    invalid_event([<<"actions">>], expected_map);
validate_decoded_metadata(_Actions, Partial, _IsFinal, _Mode)
  when not is_boolean(Partial) ->
    invalid_event([<<"partial">>], {expected, boolean});
validate_decoded_metadata(_Actions, _Partial, _IsFinal, _Mode) ->
    invalid_event([<<"is_final">>], {expected, boolean}).

parse_content(#{<<"type">> := <<"tool_calls">>,
                <<"calls">> := Calls}, _Mode) when is_list(Calls) ->
    parse_tool_calls(Calls, 0, []);
parse_content(#{<<"type">> := <<"tool_calls">>}, _Mode) ->
    invalid_content([<<"content">>, <<"calls">>], expected_list);
parse_content(#{<<"type">> := <<"tool_response">>} = Content, _Mode) ->
    parse_tool_response(Content);
parse_content(#{<<"type">> := <<"model_content">>,
                <<"value">> := Content}, _Mode) ->
    case adk_content:validate(Content, adk_content:safety_limits()) of
        {ok, Canonical} -> {ok, Canonical};
        {error, Reason} ->
            invalid_content([<<"content">>, <<"value">>],
                            {invalid_model_content, Reason})
    end;
parse_content(#{<<"type">> := <<"model_content">>}, _Mode) ->
    invalid_content([<<"content">>, <<"value">>],
                    missing_required_field);
parse_content(#{<<"type">> := <<"text">>, <<"text">> := Text}, _Mode)
  when is_binary(Text) ->
    {ok, Text};
parse_content(#{<<"type">> := <<"text">>}, _Mode) ->
    invalid_content([<<"content">>, <<"text">>], {expected, binary});
%% v0.2.x stringified unsupported content under this tag.  It cannot be
%% reconstructed, but returning the persisted data preserves previous behavior.
parse_content(#{<<"type">> := <<"unknown">>, <<"data">> := Data}, legacy) ->
    {ok, Data};
%% Legacy maps were accepted permissively by from_map/1.  Keep that read path;
%% canonical versioned maps remain strict.
parse_content(Other, legacy) ->
    {ok, Other};
parse_content(#{<<"type">> := Type}, canonical) ->
    invalid_content([<<"content">>, <<"type">>],
                    {unsupported_content_type, Type});
parse_content(Other, canonical) ->
    invalid_content([<<"content">>],
                    {expected_content_map, term_type(Other)}).

parse_tool_calls([], _Index, Acc) ->
    {ok, {tool_calls, lists:reverse(Acc)}};
parse_tool_calls([Call | Rest], Index, Acc) ->
    Path = [<<"content">>, <<"calls">>, Index],
    case parse_tool_call(Call, Path) of
        {ok, ParsedCall} ->
            parse_tool_calls(Rest, Index + 1, [ParsedCall | Acc]);
        {error, _} = Error ->
            Error
    end.

%% Tuple clauses are the persisted Erlang-map representation emitted before
%% version 1.  Map clauses are the canonical JSON representation.
parse_tool_call({Name, Args}, Path) ->
    validate_parsed_tool_call(Name, Args, absent, absent, Path);
parse_tool_call({Name, Args, Signature}, Path) ->
    validate_parsed_tool_call(Name, Args, {present, Signature}, absent, Path);
parse_tool_call({Name, Args, Signature, CallId}, Path) ->
    validate_parsed_tool_call(Name, Args, {present, Signature},
                              {present, CallId}, Path);
parse_tool_call(Call, Path) when is_map(Call) ->
    case {maps:find(<<"name">>, Call), find_args(Call)} of
        {{ok, Name}, {ok, Args}} ->
            Signature = find_optional(Call,
                                      [<<"thought_signature">>, <<"signature">>]),
            CallId = find_optional(Call, [<<"call_id">>, <<"id">>]),
            validate_parsed_tool_call(Name, Args, Signature, CallId, Path);
        {error, _} ->
            invalid_content(Path ++ [<<"name">>], missing_required_field);
        {_, error} ->
            invalid_content(Path ++ [<<"args">>], missing_required_field)
    end;
parse_tool_call(Call, Path) ->
    invalid_content(Path, {invalid_tool_call, term_type(Call)}).

find_args(Call) ->
    case maps:find(<<"args">>, Call) of
        error -> maps:find(<<"arguments">>, Call);
        Found -> Found
    end.

find_optional(Map, [Key | Rest]) ->
    case maps:find(Key, Map) of
        error -> find_optional(Map, Rest);
        {ok, Value} -> {present, from_json_optional(Value)}
    end;
find_optional(_Map, []) ->
    absent.

validate_parsed_tool_call(Name, Args, Signature, CallId, Path) ->
    case validate_binary(Name, Path ++ [<<"name">>], invalid_content) of
        ok ->
            case json_safe(Args, Path ++ [<<"args">>]) of
                {ok, _SafeArgs} ->
                    case validate_optional_binary(Signature,
                                                  Path ++ [<<"thought_signature">>]) of
                        ok ->
                            case validate_optional_binary(CallId,
                                                          Path ++ [<<"call_id">>]) of
                                ok ->
                                    {ok, make_tool_call(Name, Args,
                                                        Signature, CallId)};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

make_tool_call(Name, Args, absent, absent) ->
    {Name, Args};
make_tool_call(Name, Args, {present, Signature}, absent) ->
    {Name, Args, Signature};
make_tool_call(Name, Args, absent, {present, CallId}) ->
    {Name, Args, undefined, CallId};
make_tool_call(Name, Args, {present, Signature}, {present, CallId}) ->
    {Name, Args, Signature, CallId}.

parse_tool_response(Content) ->
    Path = [<<"content">>],
    case {maps:find(<<"name">>, Content),
          maps:find(<<"result">>, Content)} of
        {{ok, Name}, {ok, Result}} ->
            Signature = find_optional(Content,
                                      [<<"signature">>, <<"thought_signature">>]),
            CallId = find_optional(Content, [<<"call_id">>, <<"id">>]),
            case validate_binary(Name, Path ++ [<<"name">>], invalid_content) of
                ok ->
                    case json_safe(Result, Path ++ [<<"result">>]) of
                        {ok, _SafeResult} ->
                            case validate_optional_binary(Signature,
                                                          Path ++ [<<"signature">>]) of
                                ok ->
                                    case validate_optional_binary(
                                           CallId, Path ++ [<<"call_id">>]) of
                                        ok ->
                                            {ok, make_tool_response(
                                                   Name, Result,
                                                   Signature, CallId)};
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} ->
            invalid_content(Path ++ [<<"name">>], missing_required_field);
        {_, error} ->
            invalid_content(Path ++ [<<"result">>], missing_required_field)
    end.

make_tool_response(Name, Result, absent, absent) ->
    {tool_response, Name, Result};
make_tool_response(Name, Result, {present, Signature}, absent) ->
    {tool_response, Name, Result, Signature};
make_tool_response(Name, Result, absent, {present, CallId}) ->
    {tool_response, Name, Result, undefined, CallId};
make_tool_response(Name, Result, {present, Signature}, {present, CallId}) ->
    {tool_response, Name, Result, Signature, CallId}.

from_json_optional(null) -> undefined;
from_json_optional(Value) -> Value.

validate_optional_binary(absent, _Path) ->
    ok;
validate_optional_binary({present, undefined}, _Path) ->
    ok;
validate_optional_binary({present, Value}, Path) when is_binary(Value) ->
    case valid_utf8(Value) of
        true -> ok;
        false -> invalid_content(Path, invalid_utf8)
    end;
validate_optional_binary({present, _Value}, Path) ->
    invalid_content(Path, {expected, binary_or_null}).

validate_binary(Value, Path, invalid_content) when is_binary(Value) ->
    case valid_utf8(Value) of
        true -> ok;
        false -> invalid_content(Path, invalid_utf8)
    end;
validate_binary(_Value, Path, invalid_content) ->
    invalid_content(Path, {expected, binary}).

%% JSON values are deliberately narrower than Erlang terms.  Object keys must
%% be binaries and only the JSON atoms true, false and null are accepted.
json_safe(Value, Path) when is_binary(Value) ->
    case valid_utf8(Value) of
        true -> {ok, Value};
        false -> {error, {invalid_json_value, Path, invalid_utf8}}
    end;
json_safe(Value, _Path) when is_integer(Value); is_float(Value) ->
    {ok, Value};
json_safe(true, _Path) -> {ok, true};
json_safe(false, _Path) -> {ok, false};
json_safe(null, _Path) -> {ok, null};
json_safe(Value, Path) when is_list(Value) ->
    json_safe_list(Value, Path, 0, []);
json_safe(Value, Path) when is_map(Value) ->
    json_safe_map(maps:to_list(Value), Path, #{});
json_safe(Value, Path) when is_atom(Value) ->
    {error, {invalid_json_value, Path, {unsupported_atom, Value}}};
json_safe(Value, Path) ->
    {error, {invalid_json_value, Path,
             {unsupported_type, term_type(Value)}}}.

json_safe_list([], _Path, _Index, Acc) ->
    {ok, lists:reverse(Acc)};
json_safe_list([Value | Rest], Path, Index, Acc) ->
    case json_safe(Value, Path ++ [Index]) of
        {ok, SafeValue} ->
            json_safe_list(Rest, Path, Index + 1, [SafeValue | Acc]);
        {error, _} = Error ->
            Error
    end.

json_safe_map([], _Path, Acc) ->
    {ok, Acc};
json_safe_map([{Key, Value} | Rest], Path, Acc) when is_binary(Key) ->
    case valid_utf8(Key) of
        true ->
            case json_safe(Value, Path ++ [Key]) of
                {ok, SafeValue} ->
                    json_safe_map(Rest, Path, Acc#{Key => SafeValue});
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, {invalid_json_value, Path,
                     {invalid_object_key, invalid_utf8}}}
    end;
json_safe_map([{Key, _Value} | _Rest], Path, _Acc) ->
    {error, {invalid_json_value, Path,
             {invalid_object_key, term_type(Key)}}}.

invalid_event(Path, Reason) ->
    {error, {invalid_event, Path, Reason}}.

invalid_content(Path, Reason) ->
    {error, {invalid_content, Path, Reason}}.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

term_type(Value) when is_boolean(Value) -> boolean;
term_type(Value) when is_atom(Value) -> atom;
term_type(Value) when is_binary(Value) -> binary;
term_type(Value) when is_bitstring(Value) -> bitstring;
term_type(Value) when is_float(Value) -> float;
term_type(Value) when is_function(Value) -> function;
term_type(Value) when is_integer(Value) -> integer;
term_type(Value) when is_list(Value) -> list;
term_type(Value) when is_map(Value) -> map;
term_type(Value) when is_pid(Value) -> pid;
term_type(Value) when is_port(Value) -> port;
term_type(Value) when is_reference(Value) -> reference;
term_type(Value) when is_tuple(Value) -> tuple;
term_type(_Value) -> other.
