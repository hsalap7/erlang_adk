%% @doc Versioned, JSON-safe model content.
%%
%% A content value is independent of any model provider. Binary payloads are
%% base64 encoded at this boundary so the canonical value can be persisted,
%% replayed, and encoded as JSON without retaining an ambiguous Erlang binary.
%% Validation is deliberately bounded; callers can lower (but not exceed) the
%% library safety ceilings through `content_limits' in a provider config.
-module(adk_content).

-export([codec_version/0,
         default_limits/0, safety_limits/0,
         normalize_limits/1,
         new/1, new/2,
         validate/1, validate/2,
         parts/1, part_types/1,
         text/1,
         inline_data/2, inline_data/3,
         file_data/2, file_data/3,
         function_call/2, function_call/3,
         function_response/2, function_response/3]).

-define(CODEC_VERSION, 1).
-define(MAX_PARTS_CEILING, 256).
-define(MAX_TEXT_BYTES_CEILING, 8388608).
-define(MAX_INLINE_BYTES_CEILING, 20971520).
-define(MAX_URI_BYTES_CEILING, 8192).
-define(MAX_FUNCTION_BYTES_CEILING, 8388608).

-type content() :: #{binary() => term()}.
-type part() :: #{binary() => term()}.
-type limits() :: #{atom() => pos_integer()}.
-type error_reason() :: term().
-export_type([content/0, part/0, limits/0, error_reason/0]).

-spec codec_version() -> pos_integer().
codec_version() ->
    ?CODEC_VERSION.

-spec default_limits() -> limits().
default_limits() ->
    #{max_parts => 64,
      max_text_bytes => 1048576,
      max_inline_data_bytes => 10485760,
      max_total_inline_data_bytes => 15728640,
      max_uri_bytes => 4096,
      max_function_payload_bytes => 1048576}.

%% @doc Hard codec ceilings used by trusted persistence boundaries. Provider
%% configs may lower any value, but no public content can exceed this map.
-spec safety_limits() -> limits().
safety_limits() ->
    #{max_parts => ?MAX_PARTS_CEILING,
      max_text_bytes => ?MAX_TEXT_BYTES_CEILING,
      max_inline_data_bytes => ?MAX_INLINE_BYTES_CEILING,
      max_total_inline_data_bytes => ?MAX_INLINE_BYTES_CEILING,
      max_uri_bytes => ?MAX_URI_BYTES_CEILING,
      max_function_payload_bytes => ?MAX_FUNCTION_BYTES_CEILING}.

%% @doc Validate limit overrides and return a complete limit map. Unknown keys,
%% zero/negative limits, and values above hard safety ceilings are rejected.
-spec normalize_limits(map()) -> {ok, limits()} | {error, error_reason()}.
normalize_limits(Overrides) when is_map(Overrides) ->
    Defaults = default_limits(),
    Unknown = maps:keys(maps:without(maps:keys(Defaults), Overrides)),
    case Unknown of
        [] ->
            Limits = maps:merge(Defaults, Overrides),
            validate_limits(Limits);
        _ ->
            {error, {invalid_content_limits, {unknown_keys, lists:sort(Unknown)}}}
    end;
normalize_limits(Value) ->
    {error, {invalid_content_limits, {expected_map, term_type(Value)}}}.

-spec new([part()]) -> {ok, content()} | {error, error_reason()}.
new(Parts) ->
    new(Parts, #{}).

-spec new([part()], map()) -> {ok, content()} | {error, error_reason()}.
new(Parts, LimitOverrides) ->
    validate(#{<<"schema_version">> => ?CODEC_VERSION,
               <<"parts">> => Parts}, LimitOverrides).

-spec validate(term()) -> {ok, content()} | {error, error_reason()}.
validate(Content) ->
    validate(Content, #{}).

-spec validate(term(), map()) -> {ok, content()} | {error, error_reason()}.
validate(Content, LimitOverrides) ->
    case normalize_limits(LimitOverrides) of
        {ok, Limits} -> validate_content(Content, Limits);
        {error, _} = Error -> Error
    end.

-spec parts(content()) -> [part()].
parts(#{<<"schema_version">> := ?CODEC_VERSION, <<"parts">> := Parts}) ->
    Parts.

-spec part_types(content()) -> [binary()].
part_types(Content) ->
    [maps:get(<<"type">>, Part) || Part <- parts(Content)].

-spec text(term()) -> {ok, part()} | {error, error_reason()}.
text(Value) ->
    case unicode_binary(Value) of
        {ok, Text} ->
            validate_one_part(#{<<"type">> => <<"text">>,
                                <<"text">> => Text}, #{});
        {error, _} = Error -> Error
    end.

%% @doc Construct an inline-data part from raw bytes. The canonical part stores
%% RFC 4648 base64, never raw bytes.
-spec inline_data(binary(), binary()) ->
    {ok, part()} | {error, error_reason()}.
inline_data(MimeType, Bytes) ->
    inline_data(MimeType, Bytes, #{}).

-spec inline_data(binary(), binary(), map()) ->
    {ok, part()} | {error, error_reason()}.
inline_data(MimeType, Bytes, LimitOverrides) when is_binary(Bytes) ->
    case normalize_limits(LimitOverrides) of
        {ok, Limits} ->
            Size = byte_size(Bytes),
            MaxPart = maps:get(max_inline_data_bytes, Limits),
            MaxTotal = maps:get(max_total_inline_data_bytes, Limits),
            Max = erlang:min(MaxPart, MaxTotal),
            case Size > 0 andalso Size =< Max of
                true ->
                    validate_one_part(
                      #{<<"type">> => <<"inline_data">>,
                        <<"mime_type">> => MimeType,
                        <<"data">> => base64:encode(Bytes)}, Limits);
                false ->
                    {error, {content_size_limit_exceeded,
                             max_inline_data_bytes, Size, Max}}
            end;
        {error, _} = Error -> Error
    end;
inline_data(_MimeType, Bytes, _LimitOverrides) ->
    {error, {invalid_content_part, [],
             {expected_binary_data, term_type(Bytes)}}}.

-spec file_data(binary(), binary()) ->
    {ok, part()} | {error, error_reason()}.
file_data(MimeType, Uri) ->
    file_data(MimeType, Uri, #{}).

-spec file_data(binary(), binary(), map()) ->
    {ok, part()} | {error, error_reason()}.
file_data(MimeType, Uri, LimitOverrides) ->
    validate_one_part(#{<<"type">> => <<"file_data">>,
                        <<"mime_type">> => MimeType,
                        <<"uri">> => Uri}, LimitOverrides).

-spec function_call(binary(), map()) ->
    {ok, part()} | {error, error_reason()}.
function_call(Name, Args) ->
    function_call(Name, Args, #{}).

%% Options are the JSON-safe binary keys `id' and `thought_signature'.
-spec function_call(binary(), map(), map()) ->
    {ok, part()} | {error, error_reason()}.
function_call(Name, Args, Options) when is_map(Options) ->
    validate_one_part(maps:merge(
                        #{<<"type">> => <<"function_call">>,
                          <<"name">> => Name,
                          <<"args">> => Args},
                        canonical_function_options(Options)), #{});
function_call(_Name, _Args, Options) ->
    {error, {invalid_content_part, [],
             {invalid_function_options, term_type(Options)}}}.

-spec function_response(binary(), map()) ->
    {ok, part()} | {error, error_reason()}.
function_response(Name, Response) ->
    function_response(Name, Response, #{}).

-spec function_response(binary(), map(), map()) ->
    {ok, part()} | {error, error_reason()}.
function_response(Name, Response, Options) when is_map(Options) ->
    validate_one_part(maps:merge(
                        #{<<"type">> => <<"function_response">>,
                          <<"name">> => Name,
                          <<"response">> => Response},
                        canonical_function_options(Options)), #{});
function_response(_Name, _Response, Options) ->
    {error, {invalid_content_part, [],
             {invalid_function_options, term_type(Options)}}}.

canonical_function_options(Options) ->
    maps:fold(
      fun(id, Value, Acc) -> Acc#{<<"id">> => Value};
         (thought, Value, Acc) -> Acc#{<<"thought">> => Value};
         (thought_signature, Value, Acc) ->
              Acc#{<<"thought_signature">> => Value};
         (Key, Value, Acc) -> Acc#{Key => Value}
      end, #{}, Options).

validate_one_part(Part, LimitOverrides) ->
    case new([Part], LimitOverrides) of
        {ok, Content} -> {ok, hd(parts(Content))};
        {error, _} = Error -> Error
    end.

validate_limits(Limits) ->
    Checks = [{max_parts, ?MAX_PARTS_CEILING},
              {max_text_bytes, ?MAX_TEXT_BYTES_CEILING},
              {max_inline_data_bytes, ?MAX_INLINE_BYTES_CEILING},
              {max_total_inline_data_bytes, ?MAX_INLINE_BYTES_CEILING},
              {max_uri_bytes, ?MAX_URI_BYTES_CEILING},
              {max_function_payload_bytes, ?MAX_FUNCTION_BYTES_CEILING}],
    case first_invalid_limit(Checks, Limits) of
        none ->
            case maps:get(max_inline_data_bytes, Limits) =<
                 maps:get(max_total_inline_data_bytes, Limits) of
                true -> {ok, Limits};
                false ->
                    {error, {invalid_content_limits,
                             max_inline_exceeds_total}}
            end;
        Error -> {error, {invalid_content_limits, Error}}
    end.

first_invalid_limit([], _Limits) -> none;
first_invalid_limit([{Key, Ceiling} | Rest], Limits) ->
    Value = maps:get(Key, Limits),
    case is_integer(Value) andalso Value > 0 andalso Value =< Ceiling of
        true -> first_invalid_limit(Rest, Limits);
        false -> {Key, Value, {allowed_range, 1, Ceiling}}
    end.

validate_content(Content, Limits) when is_map(Content) ->
    case exact_keys(Content, [<<"schema_version">>, <<"parts">>]) of
        ok ->
            case maps:get(<<"schema_version">>, Content) of
                ?CODEC_VERSION ->
                    validate_parts(maps:get(<<"parts">>, Content), Limits);
                Version -> {error, {unsupported_content_version, Version}}
            end;
        {error, _} = Error -> Error
    end;
validate_content(Value, _Limits) ->
    {error, {invalid_content, [], {expected_map, term_type(Value)}}}.

validate_parts(Parts, Limits) when is_list(Parts) ->
    Max = maps:get(max_parts, Limits),
    case bounded_list_length(Parts, Max) of
        {ok, Count} when Count > 0 ->
            validate_parts(Parts, Limits, 0, [], 0);
        {ok, Count} ->
            {error, {invalid_content, [<<"parts">>],
                     {invalid_part_count, Count, Max}}};
        too_many ->
            {error, {invalid_content, [<<"parts">>],
                     {part_count_exceeds_limit, Max}}};
        improper ->
            {error, {invalid_content, [<<"parts">>], improper_list}}
    end;
validate_parts(Value, _Limits) ->
    {error, {invalid_content, [<<"parts">>],
             {expected_list, term_type(Value)}}}.

bounded_list_length(Value, Max) ->
    bounded_list_length(Value, Max, 0).

bounded_list_length([], _Max, Count) -> {ok, Count};
bounded_list_length([_ | _], Max, Count) when Count >= Max -> too_many;
bounded_list_length([_ | Rest], Max, Count) ->
    bounded_list_length(Rest, Max, Count + 1);
bounded_list_length(_, _Max, _Count) -> improper.

validate_parts([], _Limits, _Index, Acc, _InlineTotal) ->
    {ok, #{<<"schema_version">> => ?CODEC_VERSION,
           <<"parts">> => lists:reverse(Acc)}};
validate_parts([Part | Rest], Limits, Index, Acc, InlineTotal) ->
    Path = [<<"parts">>, Index],
    case validate_part(Part, Limits, Path) of
        {ok, Canonical, InlineBytes} ->
            NewTotal = InlineTotal + InlineBytes,
            MaxTotal = maps:get(max_total_inline_data_bytes, Limits),
            case NewTotal =< MaxTotal of
                true -> validate_parts(Rest, Limits, Index + 1,
                                       [Canonical | Acc], NewTotal);
                false ->
                    {error, {content_size_limit_exceeded,
                             max_total_inline_data_bytes,
                             NewTotal, MaxTotal}}
            end;
        {error, _} = Error -> Error
    end.

validate_part(Part, Limits, Path) when is_map(Part) ->
    case maps:find(<<"type">>, Part) of
        {ok, <<"text">>} -> validate_text_part(Part, Limits, Path);
        {ok, <<"inline_data">>} ->
            validate_inline_part(Part, Limits, Path);
        {ok, <<"file_data">>} -> validate_file_part(Part, Limits, Path);
        {ok, <<"function_call">>} ->
            validate_function_part(call, Part, Limits, Path);
        {ok, <<"function_response">>} ->
            validate_function_part(response, Part, Limits, Path);
        {ok, Type} ->
            {error, {unsupported_content_part, Path, Type}};
        error ->
            {error, {invalid_content_part, Path, missing_type}}
    end;
validate_part(Value, _Limits, Path) ->
    {error, {invalid_content_part, Path,
             {expected_map, term_type(Value)}}}.

validate_text_part(Part, Limits, Path) ->
    case exact_keys(Part,
                    [<<"type">>, <<"text">>, <<"thought">>,
                     <<"thought_signature">>],
                    [<<"type">>, <<"text">>]) of
        ok ->
            Text = maps:get(<<"text">>, Part),
            case valid_utf8_binary(Text) of
                true ->
                    case validate_common_metadata(Part) of
                        ok -> validate_size(
                                text, Text,
                                maps:get(max_text_bytes, Limits),
                                Part, Path);
                        {error, Reason} ->
                            {error, {invalid_content_part, Path, Reason}}
                    end;
                false -> {error, {invalid_content_part,
                                  Path ++ [<<"text">>], invalid_utf8}}
            end;
        {error, _} = Error -> prefix_part_error(Error, Path)
    end.

validate_inline_part(Part, Limits, Path) ->
    Required = [<<"type">>, <<"mime_type">>, <<"data">>],
    Allowed = Required ++ [<<"thought">>, <<"thought_signature">>],
    case exact_keys(Part, Allowed, Required) of
        ok ->
            case validate_mime(maps:get(<<"mime_type">>, Part), Path) of
                ok ->
                    Data = maps:get(<<"data">>, Part),
                    Max = maps:get(max_inline_data_bytes, Limits),
                    MaxEncoded = ((Max + 2) div 3) * 4,
                    case is_binary(Data) andalso
                         byte_size(Data) =< MaxEncoded of
                        false ->
                            {error, {invalid_content_part,
                                     Path ++ [<<"data">>],
                                     {encoded_data_exceeds_limit,
                                      encoded_size(Data), MaxEncoded}}};
                        true ->
                            case validate_common_metadata(Part) of
                                ok -> validate_inline_base64(
                                        Data, Part, Path, Max);
                                {error, Reason} ->
                                    {error, {invalid_content_part,
                                             Path, Reason}}
                            end
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> prefix_part_error(Error, Path)
    end.

validate_inline_base64(Data, Part, Path, Max) ->
    case decode_canonical_base64(Data) of
                        {ok, Bytes} when byte_size(Bytes) > 0 ->
                            Size = byte_size(Bytes),
                            case Size =< Max of
                                true -> {ok, Part, Size};
                                false ->
                                    {error, {content_size_limit_exceeded,
                                             max_inline_data_bytes,
                                             Size, Max}}
                            end;
                        {ok, <<>>} ->
                            {error, {invalid_content_part,
                                     Path ++ [<<"data">>], empty_data}};
                        {error, Reason} ->
                            {error, {invalid_content_part,
                                     Path ++ [<<"data">>], Reason}}
    end.

validate_file_part(Part, Limits, Path) ->
    Required = [<<"type">>, <<"mime_type">>, <<"uri">>],
    Allowed = Required ++ [<<"thought">>, <<"thought_signature">>],
    case exact_keys(Part, Allowed, Required) of
        ok ->
            case validate_mime(maps:get(<<"mime_type">>, Part), Path) of
                ok ->
                    Uri = maps:get(<<"uri">>, Part),
                    Max = maps:get(max_uri_bytes, Limits),
                    case valid_utf8_binary(Uri) andalso byte_size(Uri) =< Max of
                        true ->
                            case validate_file_uri(Uri) of
                                ok ->
                                    case validate_common_metadata(Part) of
                                        ok -> {ok, Part, 0};
                                        {error, Reason} ->
                                            {error, {invalid_content_part,
                                                     Path, Reason}}
                                    end;
                                {error, Reason} ->
                                    {error, {invalid_content_part,
                                             Path ++ [<<"uri">>], Reason}}
                            end;
                        false ->
                            {error, {invalid_content_part,
                                     Path ++ [<<"uri">>],
                                     {invalid_or_oversized_uri, Max}}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> prefix_part_error(Error, Path)
    end.

validate_function_part(Kind, Part, Limits, Path) ->
    {Required, PayloadKey} = case Kind of
        call -> {[<<"type">>, <<"name">>, <<"args">>], <<"args">>};
        response -> {[<<"type">>, <<"name">>, <<"response">>],
                     <<"response">>}
    end,
    Allowed = Required ++ [<<"id">>, <<"thought">>,
                           <<"thought_signature">>],
    case exact_keys(Part, Allowed, Required) of
        ok ->
            Name = maps:get(<<"name">>, Part),
            Payload = maps:get(PayloadKey, Part),
            case {valid_identifier(Name), is_map(Payload),
                  strict_json(Payload, Path ++ [PayloadKey]),
                  validate_function_metadata(Part, Path)} of
                {true, true, ok, ok} ->
                    Size = iolist_size(jsx:encode(Payload)),
                    Max = maps:get(max_function_payload_bytes, Limits),
                    case Size =< Max of
                        true -> {ok, Part, 0};
                        false -> {error, {content_size_limit_exceeded,
                                          max_function_payload_bytes,
                                          Size, Max}}
                    end;
                {false, _, _, _} ->
                    {error, {invalid_content_part,
                             Path ++ [<<"name">>], invalid_name}};
                {_, false, _, _} ->
                    {error, {invalid_content_part,
                             Path ++ [PayloadKey], expected_map}};
                {_, _, {error, Reason}, _} ->
                    {error, {invalid_content_part,
                             Path ++ [PayloadKey], Reason}};
                {_, _, _, {error, Reason}} ->
                    {error, {invalid_content_part, Path, Reason}}
            end;
        {error, _} = Error -> prefix_part_error(Error, Path)
    end.

validate_function_metadata(Part, _Path) ->
    case validate_optional_binary_keys(
           [<<"id">>, <<"thought_signature">>], Part) of
        ok -> validate_optional_thought(Part);
        {error, _} = Error -> Error
    end.

validate_common_metadata(Part) ->
    case validate_optional_binary_keys([<<"thought_signature">>], Part) of
        ok -> validate_optional_thought(Part);
        {error, _} = Error -> Error
    end.

validate_optional_thought(Part) ->
    case maps:find(<<"thought">>, Part) of
        error -> ok;
        {ok, Value} when is_boolean(Value) -> ok;
        {ok, _} -> {error, {<<"thought">>, expected_boolean}}
    end.

validate_optional_binary_keys([], _Part) -> ok;
validate_optional_binary_keys([Key | Rest], Part) ->
    case maps:find(Key, Part) of
        error -> validate_optional_binary_keys(Rest, Part);
        {ok, Value} when is_binary(Value), byte_size(Value) > 0,
                         byte_size(Value) =< 65536 ->
            case valid_utf8_binary(Value) of
                true -> validate_optional_binary_keys(Rest, Part);
                false -> {error, {Key, invalid_utf8}}
            end;
        {ok, _} -> {error, {Key, invalid_binary}}
    end.

validate_size(_Kind, Value, Max, Part, _Path) when byte_size(Value) =< Max ->
    {ok, Part, 0};
validate_size(Kind, Value, Max, _Part, _Path) ->
    {error, {content_size_limit_exceeded, Kind, byte_size(Value), Max}}.

validate_mime(Mime, Path) when is_binary(Mime), byte_size(Mime) =< 129 ->
    case re:run(Mime,
                <<"^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}$">>,
                [{capture, none}]) of
        match -> ok;
        nomatch -> {error, {invalid_content_part,
                            Path ++ [<<"mime_type">>], invalid_mime_type}}
    end;
validate_mime(_Mime, Path) ->
    {error, {invalid_content_part,
             Path ++ [<<"mime_type">>], invalid_mime_type}}.

validate_file_uri(Uri) when is_binary(Uri), byte_size(Uri) > 0 ->
    try uri_string:parse(Uri) of
        #{scheme := <<"https">>, host := Host} = Parsed
          when is_binary(Host), byte_size(Host) > 0 ->
            reject_uri_secrets_and_fragments(Parsed);
        #{scheme := <<"gs">>, host := Bucket} = Parsed
          when is_binary(Bucket), byte_size(Bucket) > 0 ->
            reject_uri_secrets_and_fragments(Parsed);
        #{scheme := Scheme} when is_binary(Scheme) ->
            {error, {unsupported_uri_scheme, Scheme}};
        _ -> {error, invalid_absolute_uri}
    catch
        _:_ -> {error, invalid_absolute_uri}
    end;
validate_file_uri(_) ->
    {error, invalid_absolute_uri}.

reject_uri_secrets_and_fragments(Parsed) ->
    case {maps:is_key(userinfo, Parsed), maps:is_key(fragment, Parsed)} of
        {false, false} -> ok;
        {true, _} -> {error, uri_userinfo_not_allowed};
        {_, true} -> {error, uri_fragment_not_allowed}
    end.

decode_canonical_base64(Data) when is_binary(Data), byte_size(Data) rem 4 =:= 0 ->
    case re:run(Data, <<"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$">>,
                [{capture, none}]) of
        match ->
            try base64:decode(Data) of
                Bytes ->
                    case base64:encode(Bytes) =:= Data of
                        true -> {ok, Bytes};
                        false -> {error, non_canonical_base64}
                    end
            catch
                _:_ -> {error, invalid_base64}
            end;
        nomatch -> {error, invalid_base64}
    end;
decode_canonical_base64(_) ->
    {error, invalid_base64}.

encoded_size(Value) when is_binary(Value) -> byte_size(Value);
encoded_size(_) -> invalid.

strict_json(Value, Path) ->
    case adk_json:normalize(Value, Path) of
        {ok, Value} -> ok;
        {ok, _Normalized} -> {error, not_canonical_json};
        {error, Reason} -> {error, Reason}
    end.

exact_keys(Map, Allowed) ->
    exact_keys(Map, Allowed, Allowed).

exact_keys(Map, Allowed, Required) ->
    Keys = maps:keys(Map),
    Missing = [Key || Key <- Required, not maps:is_key(Key, Map)],
    Unknown = [Key || Key <- Keys, not lists:member(Key, Allowed)],
    case {Missing, Unknown} of
        {[], []} -> ok;
        {[_ | _], _} -> {error, {invalid_content_part, [],
                                  {missing_keys, lists:sort(Missing)}}};
        {[], [_ | _]} -> {error, {invalid_content_part, [],
                                   {unknown_keys, lists:sort(Unknown)}}}
    end.

prefix_part_error({error, {invalid_content_part, [], Reason}}, Path) ->
    {error, {invalid_content_part, Path, Reason}}.

valid_identifier(Name) ->
    valid_utf8_binary(Name) andalso byte_size(Name) > 0 andalso
        byte_size(Name) =< 256 andalso
        re:run(Name, <<"^[A-Za-z_][A-Za-z0-9_.:-]*$">>,
               [{capture, none}]) =:= match.

unicode_binary(Value) when is_binary(Value) ->
    case valid_utf8_binary(Value) of
        true -> {ok, Value};
        false -> {error, {invalid_content_part, [<<"text">>], invalid_utf8}}
    end;
unicode_binary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> {error, {invalid_content_part, [<<"text">>], invalid_unicode}}
    catch
        _:_ -> {error, {invalid_content_part, [<<"text">>], invalid_unicode}}
    end;
unicode_binary(Value) ->
    {error, {invalid_content_part, [<<"text">>],
             {expected_text, term_type(Value)}}}.

valid_utf8_binary(Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end;
valid_utf8_binary(_) -> false.

term_type(Value) when is_binary(Value) -> binary;
term_type(Value) when is_list(Value) -> list;
term_type(Value) when is_map(Value) -> map;
term_type(Value) when is_tuple(Value) -> tuple;
term_type(Value) when is_atom(Value) -> atom;
term_type(Value) when is_integer(Value) -> integer;
term_type(Value) when is_float(Value) -> float;
term_type(Value) when is_pid(Value) -> pid;
term_type(Value) when is_reference(Value) -> reference;
term_type(Value) when is_function(Value) -> function;
term_type(Value) when is_port(Value) -> port;
term_type(_) -> other.
