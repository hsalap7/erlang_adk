%% @doc Bounded local-reference resolver and JSON Schema compiler for OpenAPI.
-module(adk_openapi_schema).

-export([validate_json/2, reject_remote_refs/2, resolve_object/3,
         compile/3]).

-define(DEFAULT_MAX_DEPTH, 32).

-spec validate_json(term(), pos_integer()) -> ok | {error, term()}.
validate_json(Value, MaxDepth) when is_integer(MaxDepth), MaxDepth > 0 ->
    validate_json(Value, 0, MaxDepth);
validate_json(_Value, _MaxDepth) ->
    {error, invalid_json_limit}.

-spec reject_remote_refs(term(), pos_integer()) -> ok | {error, term()}.
reject_remote_refs(Value, MaxDepth)
  when is_integer(MaxDepth), MaxDepth > 0 ->
    scan_refs(Value, 0, MaxDepth);
reject_remote_refs(_Value, _MaxDepth) ->
    {error, invalid_reference_limit}.

%% @doc Resolve an object which is either inline or a single local `$ref'.
-spec resolve_object(map(), term(), map()) ->
    {ok, map()} | {error, term()}.
resolve_object(Root, Value, Opts) when is_map(Root), is_map(Opts) ->
    MaxDepth = maps:get(max_schema_depth, Opts, ?DEFAULT_MAX_DEPTH),
    resolve_object(Root, Value, MaxDepth, [], 0);
resolve_object(_Root, _Value, _Opts) ->
    {error, invalid_reference_object}.

%% @doc Resolve and compile the provider-neutral JSON Schema subset supported
%% by `adk_json_schema'. Unsupported assertion keywords are rejected rather
%% than silently weakening the API contract.
-spec compile(map(), term(), map()) ->
    {ok, adk_json_schema:schema()} | {error, term()}.
compile(Root, Schema, Opts) when is_map(Root), is_map(Opts) ->
    MaxDepth = maps:get(max_schema_depth, Opts, ?DEFAULT_MAX_DEPTH),
    case compile_schema(Root, Schema, MaxDepth, [], 0) of
        {ok, Compiled} ->
            case adk_json_schema:compile(Compiled) of
                {ok, Checked} -> {ok, Checked};
                {error, _} -> {error, invalid_openapi_schema}
            end;
        {error, _} = Error -> Error
    end;
compile(_Root, _Schema, _Opts) ->
    {error, invalid_openapi_schema}.

validate_json(_Value, Depth, MaxDepth) when Depth > MaxDepth ->
    {error, json_too_deep};
validate_json(Map, Depth, MaxDepth) when is_map(Map) ->
    validate_json_pairs(lists:sort(maps:to_list(Map)), Depth, MaxDepth);
validate_json(List, Depth, MaxDepth) when is_list(List) ->
    validate_json_list(List, Depth, MaxDepth);
validate_json(Binary, _Depth, _MaxDepth) when is_binary(Binary) ->
    case unicode:characters_to_binary(Binary, utf8, utf8) of
        Binary -> ok;
        _ -> {error, invalid_utf8}
    end;
validate_json(Value, _Depth, _MaxDepth)
  when is_integer(Value); is_float(Value); is_boolean(Value);
       Value =:= null ->
    ok;
validate_json(_Value, _Depth, _MaxDepth) ->
    {error, non_json_value}.

validate_json_pairs([], _Depth, _MaxDepth) -> ok;
validate_json_pairs([{Key, Value} | Rest], Depth, MaxDepth)
  when is_binary(Key) ->
    case validate_json(Key, Depth + 1, MaxDepth) of
        ok ->
            case validate_json(Value, Depth + 1, MaxDepth) of
                ok -> validate_json_pairs(Rest, Depth, MaxDepth);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
validate_json_pairs(_Pairs, _Depth, _MaxDepth) ->
    {error, non_binary_json_key}.

validate_json_list([], _Depth, _MaxDepth) -> ok;
validate_json_list([Value | Rest], Depth, MaxDepth) ->
    case validate_json(Value, Depth + 1, MaxDepth) of
        ok -> validate_json_list(Rest, Depth, MaxDepth);
        {error, _} = Error -> Error
    end;
validate_json_list(_Improper, _Depth, _MaxDepth) ->
    {error, improper_json_list}.

scan_refs(_Value, Depth, MaxDepth) when Depth > MaxDepth ->
    {error, reference_scan_too_deep};
scan_refs(Map, Depth, MaxDepth) when is_map(Map) ->
    case maps:find(<<"$ref">>, Map) of
        {ok, Ref} ->
            case valid_local_ref(Ref) of
                true -> scan_ref_pairs(maps:to_list(Map), Depth, MaxDepth);
                false -> {error, remote_reference_not_allowed}
            end;
        error -> scan_ref_pairs(maps:to_list(Map), Depth, MaxDepth)
    end;
scan_refs(List, Depth, MaxDepth) when is_list(List) ->
    scan_ref_list(List, Depth, MaxDepth);
scan_refs(_Scalar, _Depth, _MaxDepth) -> ok.

scan_ref_pairs([], _Depth, _MaxDepth) -> ok;
scan_ref_pairs([{_Key, Value} | Rest], Depth, MaxDepth) ->
    case scan_refs(Value, Depth + 1, MaxDepth) of
        ok -> scan_ref_pairs(Rest, Depth, MaxDepth);
        {error, _} = Error -> Error
    end.

scan_ref_list([], _Depth, _MaxDepth) -> ok;
scan_ref_list([Value | Rest], Depth, MaxDepth) ->
    case scan_refs(Value, Depth + 1, MaxDepth) of
        ok -> scan_ref_list(Rest, Depth, MaxDepth);
        {error, _} = Error -> Error
    end;
scan_ref_list(_Improper, _Depth, _MaxDepth) ->
    {error, improper_json_list}.

resolve_object(_Root, _Value, MaxDepth, _Seen, Depth)
  when Depth > MaxDepth ->
    {error, reference_depth_exceeded};
resolve_object(Root, #{<<"$ref">> := Ref} = Object,
               MaxDepth, Seen, Depth) ->
    case map_size(Object) =:= 1 andalso valid_local_ref(Ref) of
        false -> {error, invalid_reference_object};
        true ->
            case lists:member(Ref, Seen) of
                true -> {error, cyclic_reference};
                false ->
                    case resolve_pointer(Root, Ref) of
                        {ok, Target} ->
                            resolve_object(Root, Target, MaxDepth,
                                           [Ref | Seen], Depth + 1);
                        {error, _} = Error -> Error
                    end
            end
    end;
resolve_object(_Root, Object, _MaxDepth, _Seen, _Depth)
  when is_map(Object) ->
    {ok, Object};
resolve_object(_Root, _Object, _MaxDepth, _Seen, _Depth) ->
    {error, invalid_reference_object}.

compile_schema(_Root, _Schema, MaxDepth, _Seen, Depth)
  when Depth > MaxDepth ->
    {error, schema_depth_exceeded};
compile_schema(_Root, Schema, _MaxDepth, _Seen, _Depth)
  when is_boolean(Schema) ->
    {ok, Schema};
compile_schema(Root, #{<<"$ref">> := Ref} = Schema,
               MaxDepth, Seen, Depth) ->
    case map_size(Schema) =:= 1 andalso valid_local_ref(Ref) of
        false -> {error, invalid_schema_reference};
        true ->
            case lists:member(Ref, Seen) of
                true -> {error, cyclic_schema_reference};
                false ->
                    case resolve_pointer(Root, Ref) of
                        {ok, Target} ->
                            compile_schema(Root, Target, MaxDepth,
                                           [Ref | Seen], Depth + 1);
                        {error, _} = Error -> Error
                    end
            end
    end;
compile_schema(Root, Schema, MaxDepth, Seen, Depth) when is_map(Schema) ->
    case unsupported_schema_keys(Schema) of
        [] -> compile_schema_pairs(lists:sort(maps:to_list(Schema)),
                                   Root, MaxDepth, Seen, Depth, #{});
        [Key | _] -> {error, {unsupported_schema_keyword, Key}}
    end;
compile_schema(_Root, _Schema, _MaxDepth, _Seen, _Depth) ->
    {error, invalid_openapi_schema}.

compile_schema_pairs([], _Root, _MaxDepth, _Seen, _Depth, Acc) ->
    {ok, Acc};
compile_schema_pairs([{Key, Value} | Rest], Root, MaxDepth,
                     Seen, Depth, Acc) ->
    case lists:member(Key, ignored_annotation_keys()) of
        true ->
            compile_schema_pairs(Rest, Root, MaxDepth, Seen, Depth, Acc);
        false ->
            case compile_schema_keyword(Key, Value, Root,
                                        MaxDepth, Seen, Depth) of
                {ok, CompiledValue} ->
                    compile_schema_pairs(Rest, Root, MaxDepth, Seen, Depth,
                                         Acc#{Key => CompiledValue});
                {error, _} = Error -> Error
            end
    end.

compile_schema_keyword(<<"properties">>, Properties, Root,
                       MaxDepth, Seen, Depth) when is_map(Properties) ->
    compile_property_pairs(lists:sort(maps:to_list(Properties)), Root,
                           MaxDepth, Seen, Depth + 1, #{});
compile_schema_keyword(<<"items">>, Items, Root, MaxDepth, Seen, Depth) ->
    compile_schema(Root, Items, MaxDepth, Seen, Depth + 1);
compile_schema_keyword(<<"additionalProperties">>, Value, _Root,
                       _MaxDepth, _Seen, _Depth) when is_boolean(Value) ->
    {ok, Value};
compile_schema_keyword(<<"additionalProperties">>, Value, Root,
                       MaxDepth, Seen, Depth) ->
    compile_schema(Root, Value, MaxDepth, Seen, Depth + 1);
compile_schema_keyword(Key, Schemas, Root, MaxDepth, Seen, Depth)
  when (Key =:= <<"allOf">> orelse Key =:= <<"anyOf">> orelse
        Key =:= <<"oneOf">>), is_list(Schemas) ->
    compile_schema_list(Schemas, Root, MaxDepth, Seen, Depth + 1, []);
compile_schema_keyword(_Key, Value, _Root, _MaxDepth, _Seen, _Depth) ->
    {ok, Value}.

compile_property_pairs([], _Root, _MaxDepth, _Seen, _Depth, Acc) ->
    {ok, Acc};
compile_property_pairs([{Name, Schema} | Rest], Root,
                       MaxDepth, Seen, Depth, Acc) ->
    case compile_schema(Root, Schema, MaxDepth, Seen, Depth) of
        {ok, Compiled} ->
            compile_property_pairs(Rest, Root, MaxDepth, Seen, Depth,
                                   Acc#{Name => Compiled});
        {error, _} = Error -> Error
    end.

compile_schema_list([], _Root, _MaxDepth, _Seen, _Depth, Acc) ->
    {ok, lists:reverse(Acc)};
compile_schema_list([Schema | Rest], Root, MaxDepth, Seen, Depth, Acc) ->
    case compile_schema(Root, Schema, MaxDepth, Seen, Depth) of
        {ok, Compiled} ->
            compile_schema_list(Rest, Root, MaxDepth, Seen, Depth,
                                [Compiled | Acc]);
        {error, _} = Error -> Error
    end;
compile_schema_list(_Improper, _Root, _MaxDepth, _Seen, _Depth, _Acc) ->
    {error, invalid_schema_list}.

unsupported_schema_keys(Schema) ->
    Allowed = supported_schema_keys() ++ ignored_annotation_keys(),
    [Key || Key <- maps:keys(Schema), not lists:member(Key, Allowed)].

supported_schema_keys() ->
    [<<"type">>, <<"properties">>, <<"required">>,
     <<"additionalProperties">>, <<"items">>, <<"enum">>, <<"const">>,
     <<"allOf">>, <<"anyOf">>, <<"oneOf">>, <<"nullable">>,
     <<"minLength">>, <<"maxLength">>, <<"minimum">>, <<"maximum">>,
     <<"exclusiveMinimum">>, <<"exclusiveMaximum">>, <<"minItems">>,
     <<"maxItems">>, <<"minProperties">>, <<"maxProperties">>,
     <<"pattern">>, <<"format">>, <<"title">>, <<"description">>,
     <<"default">>, <<"examples">>, <<"$id">>, <<"$schema">>].

ignored_annotation_keys() ->
    [<<"example">>, <<"deprecated">>, <<"readOnly">>, <<"writeOnly">>,
     <<"externalDocs">>, <<"xml">>, <<"discriminator">>].

valid_local_ref(<<"#/", _/binary>>) -> true;
valid_local_ref(_) -> false.

resolve_pointer(Root, <<"#/", Pointer/binary>>) ->
    case binary:match(Pointer, <<"%">>) of
        nomatch ->
            Segments0 = binary:split(Pointer, <<"/">>, [global]),
            case unescape_segments(Segments0, []) of
                {ok, Segments} -> pointer_get(Root, Segments);
                error -> {error, invalid_json_pointer}
            end;
        _ -> {error, encoded_json_pointer_not_supported}
    end;
resolve_pointer(_Root, _Ref) ->
    {error, remote_reference_not_allowed}.

unescape_segments([], Acc) -> {ok, lists:reverse(Acc)};
unescape_segments([Segment | Rest], Acc) ->
    case unescape_segment(Segment, <<>>) of
        {ok, Value} -> unescape_segments(Rest, [Value | Acc]);
        error -> error
    end.

unescape_segment(<<>>, Acc) -> {ok, Acc};
unescape_segment(<<"~0", Rest/binary>>, Acc) ->
    unescape_segment(Rest, <<Acc/binary, "~">>);
unescape_segment(<<"~1", Rest/binary>>, Acc) ->
    unescape_segment(Rest, <<Acc/binary, "/">>);
unescape_segment(<<"~", _/binary>>, _Acc) -> error;
unescape_segment(<<Byte, Rest/binary>>, Acc) ->
    unescape_segment(Rest, <<Acc/binary, Byte>>).

pointer_get(Value, []) -> {ok, Value};
pointer_get(Map, [Key | Rest]) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> pointer_get(Value, Rest);
        error -> {error, reference_not_found}
    end;
pointer_get(List, [IndexBin | Rest]) when is_list(List) ->
    case parse_index(IndexBin) of
        {ok, Index} when Index < length(List) ->
            pointer_get(lists:nth(Index + 1, List), Rest);
        _ -> {error, reference_not_found}
    end;
pointer_get(_Value, _Segments) ->
    {error, reference_not_found}.

parse_index(<<"0">>) -> {ok, 0};
parse_index(<<First, _/binary>>) when First =:= $0 -> error;
parse_index(Binary) ->
    try binary_to_integer(Binary) of
        Value when Value >= 0 -> {ok, Value};
        _ -> error
    catch
        _:_ -> error
    end.
