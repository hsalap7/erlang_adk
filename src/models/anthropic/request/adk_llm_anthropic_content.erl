%% @doc Checked translation between provider-neutral ADK content/history and
%% Anthropic Messages API content blocks.
%%
%% Anthropic tool results refer to a previous tool call by `tool_use_id'.  The
%% provider-neutral function response therefore must carry its original `id';
%% refusing an id-less replay is safer than manufacturing an uncorrelated id.
-module(adk_llm_anthropic_content).

-export([encode/3, encode_history/2,
         decode/2, decode_response/2,
         decode_error/1, decode_error/2,
         metadata/1, outcome/1,
         tool_calls/1, text_parts/1, part_types/1]).

-define(MAX_HISTORY_MESSAGES, 1024).
-define(MAX_RESPONSE_BYTES, 33554432).
-define(MAX_ERROR_BYTES, 1048576).
-define(MAX_ERROR_MESSAGE_BYTES, 16384).
-define(MAX_METADATA_VALUE_BYTES, 131072).
-define(MAX_CALL_ID_BYTES, 256).
-define(MAX_TOOL_NAME_BYTES, 128).
-define(MAX_BASE64_IMAGE_BYTES, 10485760).

-spec encode(user | assistant | tool, term(), map()) ->
    {ok, [map()]} | {error, term()}.
encode(Role, Content, LimitOverrides)
  when Role =:= user; Role =:= assistant; Role =:= tool ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} -> encode_content(Role, Content, Limits);
        {error, _} = Error -> Error
    end;
encode(Role, _Content, _LimitOverrides) ->
    {error, {invalid_anthropic_role, Role}}.

%% @doc Return the top-level system prompt (or `undefined') and chronological
%% Anthropic user/assistant messages. Consecutive ADK tool messages are grouped
%% into one Anthropic user turn containing only tool_result blocks.
-spec encode_history(term(), map()) ->
    {ok, undefined | binary(), [map()]} | {error, term()}.
encode_history(History, LimitOverrides) ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} ->
            case bounded_list_length(History, ?MAX_HISTORY_MESSAGES) of
                {ok, _} -> encode_history(History, Limits, <<>>, []);
                too_many ->
                    {error, {anthropic_history_limit_exceeded,
                             ?MAX_HISTORY_MESSAGES}};
                improper -> {error, invalid_anthropic_history}
            end;
        {error, _} = Error -> Error
    end.

-spec decode(term(), map()) ->
    {ok, adk_content:content()} | {error, term()}.
decode(Blocks, LimitOverrides) ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} -> decode_blocks(Blocks, Limits);
        {error, _} = Error -> Error
    end.

%% @doc Decode a successful Messages response. Generation accounting is kept
%% in the ordinary checked provider-result envelope; prompt/response content is
%% never copied into metadata.
-spec decode_response(binary() | map(), map()) -> term().
decode_response(Body, LimitOverrides) when is_binary(Body) ->
    case byte_size(Body) =< ?MAX_RESPONSE_BYTES of
        false ->
            {error, {anthropic_response_too_large,
                     byte_size(Body), ?MAX_RESPONSE_BYTES}};
        true ->
            try jsx:decode(Body, [return_maps]) of
                Response -> decode_response(Response, LimitOverrides)
            catch
                _:_ -> {error, invalid_anthropic_response_json}
            end
    end;
decode_response(#{<<"type">> := <<"message">>,
                  <<"role">> := <<"assistant">>,
                  <<"content">> := Blocks} = Response,
                LimitOverrides) ->
    case {decode(Blocks, LimitOverrides), metadata(Response)} of
        {{ok, Content}, {ok, Metadata}} ->
            case outcome(Content) of
                {error, _} = Error -> Error;
                Outcome ->
                    case adk_provider_result:new(
                           <<"anthropic">>, <<"generation_metadata">>,
                           Outcome, Metadata) of
                        {ok, ProviderResult} -> ProviderResult;
                        {error, Reason} ->
                            {error, {invalid_anthropic_metadata, Reason}}
                    end
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
decode_response(_Response, _LimitOverrides) ->
    {error, invalid_anthropic_response}.

-spec decode_error(binary() | map()) -> {error, term()}.
decode_error(Response) ->
    decode_error(undefined, Response).

%% @doc Decode an API error without retaining the remote message. Validation
%% errors can quote request values, so only status, bounded type and request id
%% cross this boundary.
-spec decode_error(undefined | non_neg_integer(), binary() | map()) ->
    {error, term()}.
decode_error(Status, Body) when is_binary(Body) ->
    case byte_size(Body) =< ?MAX_ERROR_BYTES of
        false -> {error, anthropic_error_response_too_large};
        true ->
            try jsx:decode(Body, [return_maps]) of
                Response -> decode_error(Status, Response)
            catch
                _:_ -> {error, invalid_anthropic_error_json}
            end
    end;
decode_error(Status,
             #{<<"type">> := <<"error">>,
               <<"error">> := #{<<"type">> := Type,
                                  <<"message">> := Message}} = Response)
  when (Status =:= undefined orelse
        (is_integer(Status) andalso Status >= 0)) ->
    RequestId = maps:get(<<"request_id">>, Response, undefined),
    case {bounded_utf8(Type, 128),
          bounded_utf8(Message, ?MAX_ERROR_MESSAGE_BYTES),
          optional_bounded_utf8(RequestId, ?MAX_CALL_ID_BYTES)} of
        {true, true, true} ->
            {error, {anthropic_api_error, Status, Type, RequestId}};
        _ -> {error, invalid_anthropic_error_response}
    end;
decode_error(_Status, _Response) ->
    {error, invalid_anthropic_error_response}.

%% @doc Project bounded non-content response metadata.
-spec metadata(map()) -> {ok, map()} | {error, term()}.
metadata(#{<<"id">> := Id, <<"model">> := Model,
           <<"usage">> := Usage} = Response) ->
    StopReason = maps:get(<<"stop_reason">>, Response, null),
    StopSequence = maps:get(<<"stop_sequence">>, Response, null),
    case {bounded_utf8(Id, 512), bounded_utf8(Model, 512),
          valid_optional_wire_binary(StopReason, 128),
          valid_optional_wire_binary(StopSequence, 4096),
          validate_usage(Usage)} of
        {true, true, true, true, {ok, CanonicalUsage}} ->
            {ok, #{<<"message_id">> => Id,
                   <<"model">> => Model,
                   <<"stop_reason">> => StopReason,
                   <<"stop_sequence">> => StopSequence,
                   <<"usage_metadata">> => CanonicalUsage}};
        _ -> {error, invalid_anthropic_response_metadata}
    end;
metadata(_Response) ->
    {error, invalid_anthropic_response_metadata}.

-spec outcome(adk_content:content()) ->
    {ok, binary() | adk_content:content()} | {tool_calls, list()} |
    {error, term()}.
outcome(Content) ->
    Calls = tool_calls(Content),
    case Calls of
        [_ | _] -> {tool_calls, Calls};
        [] ->
            case part_types(Content) of
                Types when Types =/= [] ->
                    case lists:all(fun(Type) -> Type =:= <<"text">> end,
                                   Types) of
                        true ->
                            case text_parts(Content) of
                                [] -> {error, empty_anthropic_response};
                                Text -> {ok, iolist_to_binary(Text)}
                            end;
                        false -> {ok, Content}
                    end;
                [] -> {error, empty_anthropic_response}
            end
    end.

-spec tool_calls(adk_content:content()) -> list().
tool_calls(Content) ->
    [
      {Name, Args, undefined, Id}
      || #{<<"type">> := <<"function_call">>,
           <<"name">> := Name, <<"args">> := Args,
           <<"id">> := Id} <- adk_content:parts(Content)
    ].

-spec text_parts(adk_content:content()) -> [binary()].
text_parts(Content) ->
    [Text || #{<<"type">> := <<"text">>, <<"text">> := Text}
                 <- adk_content:parts(Content)].

-spec part_types(adk_content:content()) -> [binary()].
part_types(Content) ->
    adk_content:part_types(Content).

encode_history([], _Limits, System, Messages) ->
    SystemValue = case System of <<>> -> undefined; _ -> System end,
    {ok, SystemValue, lists:reverse(Messages)};
encode_history([#{role := system, content := Content} | Rest],
               Limits, System, Messages) ->
    case system_text(Content, Limits) of
        {ok, Text} ->
            case append_system(System, Text, Limits) of
                {ok, NewSystem} ->
                    encode_history(Rest, Limits, NewSystem, Messages);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_history([#{role := tool} | _] = History,
               Limits, System, Messages) ->
    case consume_tool_messages(History, Limits, []) of
        {ok, Blocks, Rest} ->
            Message = #{<<"role">> => <<"user">>,
                        <<"content">> => Blocks},
            encode_history(Rest, Limits, System, [Message | Messages]);
        {error, _} = Error -> Error
    end;
encode_history([#{role := agent, content := {tool_calls, Calls}} | Rest],
               Limits, System, Messages) ->
    case encode_tool_calls(Calls, Limits) of
        {ok, Blocks} ->
            Message = #{<<"role">> => <<"assistant">>,
                        <<"content">> => Blocks},
            encode_history(Rest, Limits, System, [Message | Messages]);
        {error, _} = Error -> Error
    end;
encode_history([#{role := Role, content := Content} | Rest],
               Limits, System, Messages)
  when Role =:= user; Role =:= agent ->
    WireRole = case Role of user -> user; agent -> assistant end,
    case encode_content(WireRole, Content, Limits) of
        {ok, Blocks} ->
            Message = #{<<"role">> => role_binary(WireRole),
                        <<"content">> => Blocks},
            encode_history(Rest, Limits, System, [Message | Messages]);
        {error, _} = Error -> Error
    end;
encode_history([Message | _], _Limits, _System, _Messages) ->
    {error, {invalid_anthropic_history_message, term_type(Message)}}.

consume_tool_messages([#{role := tool, content := Content} | Rest],
                      Limits, Acc) ->
    case encode_tool_content(Content, Limits) of
        {ok, Blocks} ->
            consume_tool_messages(Rest, Limits,
                                  lists:reverse(Blocks, Acc));
        {error, _} = Error -> Error
    end;
consume_tool_messages(Rest, _Limits, Acc) ->
    {ok, lists:reverse(Acc), Rest}.

system_text(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            Parts = adk_content:parts(Canonical),
            case lists:all(
                   fun(#{<<"type">> := <<"text">>} = Part) ->
                           no_provider_metadata(Part);
                      (_) -> false
                   end, Parts) of
                true -> {ok, iolist_to_binary(
                               lists:join(<<"\n">>, text_parts(Canonical)))};
                false -> {error, unsupported_anthropic_system_content}
            end;
        {error, _} = Error -> Error
    end;
system_text(Content, Limits) ->
    text_binary(Content, Limits).

append_system(<<>>, Text, Limits) ->
    bounded_system(Text, Limits);
append_system(System, Text, Limits) ->
    bounded_system(<<System/binary, "\n", Text/binary>>, Limits).

bounded_system(System, Limits) ->
    Max = maps:get(max_text_bytes, Limits),
    case byte_size(System) =< Max of
        true -> {ok, System};
        false ->
            {error, {anthropic_system_limit_exceeded,
                     byte_size(System), Max}}
    end.

encode_content(Role, Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            encode_parts(Role, adk_content:parts(Canonical), Limits, 0, []);
        {error, _} = Error -> Error
    end;
encode_content(Role, Content, Limits)
  when Role =:= user; Role =:= assistant ->
    case text_binary(Content, Limits) of
        {ok, Text} ->
            {ok, [#{<<"type">> => <<"text">>, <<"text">> => Text}]};
        {error, _} = Error -> Error
    end;
encode_content(tool, Content, Limits) ->
    encode_tool_content(Content, Limits).

encode_tool_content(Content, Limits) when is_map(Content) ->
    encode_content_map_as_tool(Content, Limits);
encode_tool_content({tool_response, Name, _Response}, _Limits) ->
    {error, {missing_anthropic_tool_use_id, printable_name(Name)}};
encode_tool_content({tool_response, Name, _Response, _Signature}, _Limits) ->
    {error, {missing_anthropic_tool_use_id, printable_name(Name)}};
encode_tool_content({tool_response, Name, Response, undefined, Id}, Limits) ->
    case encode_function_response(Name, Response, Id, Limits) of
        {ok, Block} -> {ok, [Block]};
        {error, _} = Error -> Error
    end;
encode_tool_content({tool_response, _Name, _Response, _Signature, _Id},
                    _Limits) ->
    {error, unsupported_anthropic_thought_signature};
encode_tool_content(_Content, _Limits) ->
    {error, invalid_anthropic_tool_response}.

encode_content_map_as_tool(Content, Limits) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            encode_parts(tool, adk_content:parts(Canonical), Limits, 0, []);
        {error, _} = Error -> Error
    end.

encode_tool_calls(Calls, Limits) ->
    case adk_tool_call:validate_list(Calls) of
        ok -> encode_tool_calls(Calls, Limits, 0, []);
        {error, Reason} -> {error, {invalid_anthropic_tool_calls, Reason}}
    end.

encode_tool_calls([], _Limits, _Index, Acc) ->
    {ok, lists:reverse(Acc)};
encode_tool_calls([{Name, _Args} | _], _Limits, Index, _Acc) ->
    {error, {missing_anthropic_tool_use_id, Index, Name}};
encode_tool_calls([{Name, _Args, _Signature} | _],
                  _Limits, Index, _Acc) ->
    {error, {missing_anthropic_tool_use_id, Index, Name}};
encode_tool_calls([{_Name, _Args, Signature, _Id} | _],
                  _Limits, Index, _Acc)
  when Signature =/= undefined ->
    {error, {unsupported_anthropic_thought_signature, Index}};
encode_tool_calls([{Name, Args, undefined, Id} | Rest],
                  Limits, Index, Acc) ->
    case encode_function_call(Name, Args, Id, Limits) of
        {ok, Block} ->
            encode_tool_calls(Rest, Limits, Index + 1, [Block | Acc]);
        {error, Reason} ->
            {error, {invalid_anthropic_tool_call, Index, Reason}}
    end.

encode_parts(_Role, [], _Limits, _Index, Acc) ->
    {ok, lists:reverse(Acc)};
encode_parts(Role, [Part | Rest], Limits, Index, Acc) ->
    case encode_part(Role, Part, Limits) of
        {ok, Block} ->
            encode_parts(Role, Rest, Limits, Index + 1, [Block | Acc]);
        {error, Reason} ->
            {error, {invalid_anthropic_content_part, Index, Reason}}
    end.

encode_part(Role, #{<<"type">> := <<"text">>,
                    <<"text">> := Text} = Part, _Limits)
  when Role =:= user; Role =:= assistant ->
    case no_provider_metadata(Part) of
        true -> {ok, #{<<"type">> => <<"text">>, <<"text">> => Text}};
        false -> {error, unsupported_provider_metadata}
    end;
encode_part(user, #{<<"type">> := <<"inline_data">>,
                    <<"mime_type">> := Mime,
                    <<"data">> := Data} = Part, _Limits) ->
    case {supported_image_mime(Mime), no_provider_metadata(Part)} of
        {true, true} when byte_size(Data) =< ?MAX_BASE64_IMAGE_BYTES ->
            {ok, #{<<"type">> => <<"image">>,
                   <<"source">> => #{<<"type">> => <<"base64">>,
                                      <<"media_type">> => Mime,
                                      <<"data">> => Data}}};
        {true, true} ->
            {error, {anthropic_base64_image_too_large,
                     byte_size(Data), ?MAX_BASE64_IMAGE_BYTES}};
        {false, _} ->
            {error, {unsupported_anthropic_image_mime, Mime}};
        {true, false} -> {error, unsupported_provider_metadata}
    end;
encode_part(user, #{<<"type">> := <<"file_data">>,
                    <<"mime_type">> := Mime,
                    <<"uri">> := Uri} = Part, _Limits) ->
    case {supported_image_mime(Mime), Uri,
          no_provider_metadata(Part)} of
        {true, <<"https://", _/binary>>, true} ->
            {ok, #{<<"type">> => <<"image">>,
                   <<"source">> => #{<<"type">> => <<"url">>,
                                      <<"url">> => Uri}}};
        {false, _, _} ->
            {error, {unsupported_anthropic_image_mime, Mime}};
        {true, _, _} when not is_binary(Uri) ->
            {error, invalid_anthropic_image_url};
        {true, _, false} -> {error, unsupported_provider_metadata};
        _ -> {error, unsupported_anthropic_image_url}
    end;
encode_part(assistant, #{<<"type">> := <<"function_call">>,
                         <<"name">> := Name,
                         <<"args">> := Args} = Part, Limits) ->
    case no_provider_metadata(Part) of
        true ->
            case maps:find(<<"id">>, Part) of
                {ok, Id} -> encode_function_call(Name, Args, Id, Limits);
                error -> {error, missing_anthropic_tool_use_id}
            end;
        false -> {error, unsupported_anthropic_thought_metadata}
    end;
encode_part(tool, #{<<"type">> := <<"function_response">>,
                    <<"name">> := Name,
                    <<"response">> := Response} = Part, Limits) ->
    case no_provider_metadata(Part) of
        true ->
            case maps:find(<<"id">>, Part) of
                {ok, Id} -> encode_function_response(
                              Name, Response, Id, Limits);
                error -> {error, missing_anthropic_tool_use_id}
            end;
        false -> {error, unsupported_anthropic_thought_metadata}
    end;
encode_part(Role, #{<<"type">> := Type}, _Limits) ->
    {error, {unsupported_anthropic_part_for_role, Role, Type}}.

encode_function_call(Name, Args, Id, Limits) ->
    case validate_function_fields(Name, Args, Id, Limits) of
        ok ->
            {ok, #{<<"type">> => <<"tool_use">>,
                   <<"id">> => Id, <<"name">> => Name,
                   <<"input">> => Args}};
        {error, _} = Error -> Error
    end.

encode_function_response(Name, Response, Id, Limits) ->
    case validate_function_fields(Name, Response, Id, Limits) of
        ok ->
            {ok, #{<<"type">> => <<"tool_result">>,
                   <<"tool_use_id">> => Id,
                   <<"content">> => jsx:encode(Response)}};
        {error, _} = Error -> Error
    end.

validate_function_fields(Name, Payload, Id, Limits) ->
    Max = maps:get(max_function_payload_bytes, Limits),
    case {valid_tool_name(Name), bounded_utf8(Id, ?MAX_CALL_ID_BYTES),
          strict_json_map(Payload, Max)} of
        {true, true, ok} -> ok;
        {false, _, _} -> {error, invalid_anthropic_tool_name};
        {_, false, _} -> {error, invalid_anthropic_tool_use_id};
        {_, _, {error, _} = Error} -> Error
    end.

decode_blocks(Blocks, Limits) when is_list(Blocks) ->
    Max = maps:get(max_parts, Limits),
    case bounded_list_length(Blocks, Max) of
        {ok, Count} when Count > 0 ->
            decode_blocks(Blocks, Limits, 0, []);
        {ok, 0} -> {error, empty_anthropic_response};
        too_many -> {error, {anthropic_part_limit_exceeded, Max}};
        improper -> {error, invalid_anthropic_content_blocks}
    end;
decode_blocks(_Blocks, _Limits) ->
    {error, invalid_anthropic_content_blocks}.

decode_blocks([], Limits, _Index, Acc) ->
    adk_content:new(lists:reverse(Acc), Limits);
decode_blocks([Block | Rest], Limits, Index, Acc) ->
    case decode_block(Block, Limits) of
        {ok, Part} ->
            decode_blocks(Rest, Limits, Index + 1, [Part | Acc]);
        {error, Reason} ->
            {error, {invalid_anthropic_response_block, Index, Reason}}
    end.

decode_block(#{<<"type">> := <<"text">>, <<"text">> := Text}, Limits) ->
    case text_binary(Text, Limits) of
        {ok, Canonical} -> {ok, #{<<"type">> => <<"text">>,
                                  <<"text">> => Canonical}};
        {error, _} = Error -> Error
    end;
decode_block(#{<<"type">> := <<"tool_use">>,
               <<"id">> := Id, <<"name">> := Name,
               <<"input">> := Input}, Limits) ->
    case validate_function_fields(Name, Input, Id, Limits) of
        ok -> {ok, #{<<"type">> => <<"function_call">>,
                    <<"id">> => Id, <<"name">> => Name,
                    <<"args">> => Input}};
        {error, _} = Error -> Error
    end;
decode_block(#{<<"type">> := Type}, _Limits) when is_binary(Type) ->
    {error, unsupported_anthropic_content_block};
decode_block(_Block, _Limits) ->
    {error, malformed_anthropic_content_block}.

validate_usage(Usage) when is_map(Usage) ->
    case {maps:find(<<"input_tokens">>, Usage),
          maps:find(<<"output_tokens">>, Usage),
          strict_json_value(Usage, ?MAX_METADATA_VALUE_BYTES)} of
        {{ok, Input}, {ok, Output}, ok}
          when is_integer(Input), Input >= 0,
               is_integer(Output), Output >= 0 ->
            {ok, Usage};
        _ -> {error, invalid_anthropic_usage}
    end;
validate_usage(_Usage) ->
    {error, invalid_anthropic_usage}.

strict_json_map(Value, Max) when is_map(Value) ->
    strict_json_value(Value, Max);
strict_json_map(_Value, _Max) ->
    {error, invalid_anthropic_json_object}.

strict_json_value(Value, Max) ->
    case adk_json:normalize(Value) of
        {ok, Value} ->
            try jsx:encode(Value) of
                Encoded when byte_size(Encoded) =< Max -> ok;
                Encoded ->
                    {error, {anthropic_json_limit_exceeded,
                             byte_size(Encoded), Max}}
            catch
                _:_ -> {error, invalid_anthropic_json}
            end;
        {ok, _Coerced} -> {error, anthropic_json_must_be_canonical};
        {error, Reason} -> {error, {invalid_anthropic_json, Reason}}
    end.

text_binary(Value, Limits) when is_binary(Value) ->
    Max = maps:get(max_text_bytes, Limits),
    case bounded_utf8_allow_empty(Value, Max) of
        true -> {ok, Value};
        false -> {error, invalid_or_oversized_anthropic_text}
    end;
text_binary(Value, Limits) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> text_binary(Binary, Limits);
        _ -> {error, invalid_anthropic_text}
    catch
        _:_ -> {error, invalid_anthropic_text}
    end;
text_binary(_Value, _Limits) ->
    {error, invalid_anthropic_text}.

no_provider_metadata(Part) ->
    not maps:is_key(<<"thought">>, Part) andalso
        not maps:is_key(<<"thought_signature">>, Part).

supported_image_mime(<<"image/jpeg">>) -> true;
supported_image_mime(<<"image/png">>) -> true;
supported_image_mime(<<"image/gif">>) -> true;
supported_image_mime(<<"image/webp">>) -> true;
supported_image_mime(_) -> false.

valid_tool_name(Name) when is_binary(Name),
                           byte_size(Name) > 0,
                           byte_size(Name) =< ?MAX_TOOL_NAME_BYTES ->
    valid_utf8(Name) andalso
        re:run(Name, <<"^[A-Za-z0-9_-]{1,128}$">>,
               [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

valid_optional_wire_binary(null, _Max) -> true;
valid_optional_wire_binary(Value, Max) -> bounded_utf8(Value, Max).

optional_bounded_utf8(undefined, _Max) -> true;
optional_bounded_utf8(Value, Max) -> bounded_utf8(Value, Max).

bounded_utf8(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                              byte_size(Value) =< Max ->
    valid_utf8(Value);
bounded_utf8(_, _) -> false.

bounded_utf8_allow_empty(Value, Max)
  when is_binary(Value), byte_size(Value) =< Max ->
    valid_utf8(Value);
bounded_utf8_allow_empty(_, _) -> false.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

role_binary(user) -> <<"user">>;
role_binary(assistant) -> <<"assistant">>.

bounded_list_length(Value, Max) ->
    bounded_list_length(Value, Max, 0).

bounded_list_length([], _Max, Count) -> {ok, Count};
bounded_list_length([_ | _], Max, Count) when Count >= Max -> too_many;
bounded_list_length([_ | Rest], Max, Count) ->
    bounded_list_length(Rest, Max, Count + 1);
bounded_list_length(_, _Max, _Count) -> improper.

printable_name(Name) when is_binary(Name) -> Name;
printable_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
printable_name(_) -> invalid.

term_type(Value) when is_map(Value) -> map;
term_type(Value) when is_list(Value) -> list;
term_type(Value) when is_tuple(Value) -> tuple;
term_type(Value) when is_binary(Value) -> binary;
term_type(Value) when is_atom(Value) -> atom;
term_type(_) -> other.
