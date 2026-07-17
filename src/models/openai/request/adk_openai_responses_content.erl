%% @doc Checked translation between ADK's provider-neutral content/history
%% representation and OpenAI Responses API input/output items.
%%
%% This module is deliberately a JSON boundary: emitted maps use binary keys,
%% provider output is treated as untrusted, and error terms never retain model
%% text, tool arguments, tool results, or other request content.
-module(adk_openai_responses_content).

-export([encode_history/2, encode_tools/1, decode_output/2,
         text_parts/1, tool_calls/1]).

-define(MAX_HISTORY_ITEMS, 2048).
-define(MAX_TOOLS, 128).
-define(MAX_OUTPUT_ITEMS, 256).
-define(MAX_TOOL_NAME_BYTES, 64).
-define(MAX_CALL_ID_BYTES, 64).
-define(MAX_DESCRIPTION_BYTES, 8192).

-spec encode_history(term(), map()) ->
    {ok, binary(), [map()]} | {error, term()}.
encode_history(History, LimitOverrides) ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} ->
            encode_history_items(History, Limits, 0, <<>>, []);
        {error, _} = Error -> Error
    end.

-spec encode_tools(term()) -> {ok, [map()]} | {error, term()}.
encode_tools(Tools) ->
    encode_tools(Tools, 0, #{}, []).

%% @doc Decode a complete Responses `output' array. The returned content is
%% canonical `adk_content'; calls preserve the OpenAI `call_id' in the fourth
%% ADK tuple element and have no provider thought signature.
-spec decode_output(term(), map()) ->
    {ok, adk_content:content(), list()} | {error, term()}.
decode_output(Output, LimitOverrides) ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} ->
            case decode_output_items(Output, Limits, 0, [], []) of
                {ok, [], _Calls} ->
                    {error, empty_openai_output};
                {ok, Parts, Calls} ->
                    case adk_content:new(lists:reverse(Parts), Limits) of
                        {ok, Content} ->
                            OrderedCalls = lists:reverse(Calls),
                            case adk_tool_call:validate_list(OrderedCalls) of
                                ok -> {ok, Content, OrderedCalls};
                                {error, _} -> {error, invalid_openai_tool_calls}
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

-spec text_parts(adk_content:content()) -> [binary()].
text_parts(Content) ->
    [Text || #{<<"type">> := <<"text">>, <<"text">> := Text}
                 <- adk_content:parts(Content)].

-spec tool_calls(adk_content:content()) -> list().
tool_calls(Content) ->
    lists:filtermap(
      fun(#{<<"type">> := <<"function_call">>,
            <<"name">> := Name, <<"args">> := Args,
            <<"id">> := CallId}) ->
              {true, {Name, Args, undefined, CallId}};
         (_) -> false
      end, adk_content:parts(Content)).

encode_history_items([], _Limits, _Count, Instructions, Acc) ->
    {ok, Instructions, lists:reverse(Acc)};
encode_history_items(_History, _Limits, Count, _Instructions, _Acc)
  when Count >= ?MAX_HISTORY_ITEMS ->
    {error, {openai_history_limit_exceeded, ?MAX_HISTORY_ITEMS}};
encode_history_items([Message | Rest], Limits, Count,
                     Instructions0, Acc0) when is_map(Message) ->
    case encode_history_message(Message, Limits) of
        {system, Text} ->
            case append_instruction(Instructions0, Text, Limits) of
                {ok, Instructions} ->
                    encode_history_items(Rest, Limits, Count + 1,
                                         Instructions, Acc0);
                {error, _} = Error -> Error
            end;
        {items, Items} ->
            encode_history_items(Rest, Limits, Count + 1, Instructions0,
                                 lists:reverse(Items, Acc0));
        {error, _} = Error -> Error
    end;
encode_history_items([_ | _], _Limits, _Count, _Instructions, _Acc) ->
    {error, invalid_openai_history_message};
encode_history_items(_, _Limits, _Count, _Instructions, _Acc) ->
    {error, invalid_openai_history}.

encode_history_message(#{role := system, content := Content}, Limits) ->
    case system_text(Content, Limits) of
        {ok, Text} -> {system, Text};
        {error, _} = Error -> Error
    end;
encode_history_message(#{role := user, content := Content}, Limits) ->
    encode_user_message(Content, Limits);
encode_history_message(#{role := agent, content := {tool_calls, Calls}},
                       Limits) ->
    encode_legacy_calls(Calls, Limits);
encode_history_message(#{role := agent, content := Content}, Limits) ->
    encode_agent_message(Content, Limits);
encode_history_message(#{role := tool, content := Content}, Limits) ->
    encode_tool_message(Content, Limits);
encode_history_message(_, _Limits) ->
    {error, invalid_openai_history_message}.

system_text(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            Parts = adk_content:parts(Canonical),
            case lists:all(
                   fun(#{<<"type">> := <<"text">>}) -> true;
                      (_) -> false
                   end, Parts) of
                true ->
                    {ok, iolist_to_binary(
                           lists:join(<<"\n">>,
                                      [maps:get(<<"text">>, Part)
                                       || Part <- Parts]))};
                false -> {error, unsupported_openai_system_content}
            end;
        {error, _} = Error -> Error
    end;
system_text(Content, Limits) ->
    bounded_text(Content, maps:get(max_text_bytes, Limits)).

append_instruction(<<>>, Text, _Limits) -> {ok, Text};
append_instruction(Instructions, Text, Limits) ->
    Combined = <<Instructions/binary, "\n", Text/binary>>,
    Max = maps:get(max_text_bytes, Limits),
    case byte_size(Combined) =< Max of
        true -> {ok, Combined};
        false -> {error, {openai_instructions_limit_exceeded, Max}}
    end.

encode_user_message(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            case encode_user_parts(adk_content:parts(Canonical), []) of
                {ok, Parts} ->
                    {items, [message_item(<<"user">>,
                                          lists:reverse(Parts))]};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_user_message(Content, Limits) ->
    case bounded_text(Content, maps:get(max_text_bytes, Limits)) of
        {ok, Text} ->
            {items, [message_item(
                       <<"user">>,
                       [#{<<"type">> => <<"input_text">>,
                          <<"text">> => Text}])]};
        {error, _} = Error -> Error
    end.

encode_user_parts([], Acc) -> {ok, Acc};
encode_user_parts([#{<<"type">> := <<"text">>,
                     <<"text">> := Text} | Rest], Acc) ->
    encode_user_parts(
      Rest, [#{<<"type">> => <<"input_text">>,
              <<"text">> => Text} | Acc]);
encode_user_parts([#{<<"type">> := <<"inline_data">>,
                     <<"mime_type">> := Mime,
                     <<"data">> := Data} | Rest], Acc) ->
    case image_mime(Mime) of
        true ->
            Url = <<"data:", Mime/binary, ";base64,", Data/binary>>,
            encode_user_parts(
              Rest, [#{<<"type">> => <<"input_image">>,
                       <<"image_url">> => Url} | Acc]);
        false -> {error, unsupported_openai_inline_media}
    end;
encode_user_parts([#{<<"type">> := <<"file_data">>,
                     <<"mime_type">> := Mime,
                     <<"uri">> := Uri} | Rest], Acc) ->
    case image_mime(Mime) andalso https_uri(Uri) of
        true ->
            encode_user_parts(
              Rest, [#{<<"type">> => <<"input_image">>,
                       <<"image_url">> => Uri} | Acc]);
        false -> {error, unsupported_openai_file_media}
    end;
encode_user_parts([_ | _], _Acc) ->
    {error, unsupported_openai_user_content}.

encode_agent_message(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            encode_agent_parts(adk_content:parts(Canonical), []);
        {error, _} = Error -> Error
    end;
encode_agent_message(Content, Limits) ->
    case bounded_text(Content, maps:get(max_text_bytes, Limits)) of
        {ok, Text} ->
            {items, [message_item(
                       <<"assistant">>,
                       [#{<<"type">> => <<"input_text">>,
                          <<"text">> => Text}])]};
        {error, _} = Error -> Error
    end.

encode_agent_parts([], Acc) -> {items, lists:reverse(Acc)};
encode_agent_parts([#{<<"type">> := <<"text">>,
                      <<"text">> := Text} | Rest], Acc) ->
    Item = message_item(
             <<"assistant">>,
             [#{<<"type">> => <<"input_text">>, <<"text">> => Text}]),
    encode_agent_parts(Rest, [Item | Acc]);
encode_agent_parts([#{<<"type">> := <<"function_call">>} = Part | Rest],
                   Acc) ->
    case encode_call_part(Part) of
        {ok, Item} -> encode_agent_parts(Rest, [Item | Acc]);
        {error, _} = Error -> Error
    end;
encode_agent_parts([_ | _], _Acc) ->
    {error, unsupported_openai_agent_content}.

encode_legacy_calls(Calls, Limits) ->
    case adk_tool_call:validate_list(Calls) of
        ok -> encode_legacy_calls(Calls, Limits, []);
        {error, _} -> {error, invalid_openai_tool_calls}
    end.

encode_legacy_calls([], _Limits, Acc) ->
    {items, lists:reverse(Acc)};
encode_legacy_calls([{Name, Args, _Signature, CallId} | Rest],
                    Limits, Acc) ->
    Part = #{<<"type">> => <<"function_call">>,
             <<"name">> => Name, <<"args">> => Args,
             <<"id">> => CallId},
    case adk_content:new([Part], Limits) of
        {ok, _} ->
            case encode_call_part(Part) of
                {ok, Item} ->
                    encode_legacy_calls(Rest, Limits, [Item | Acc]);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_legacy_calls([_ | _], _Limits, _Acc) ->
    {error, openai_tool_call_id_required}.

encode_call_part(#{<<"name">> := Name, <<"args">> := Args} = Part) ->
    CallId = maps:get(<<"id">>, Part, undefined),
    case {valid_tool_name(Name), valid_call_id(CallId), json_binary(Args)} of
        {true, true, {ok, Arguments}} ->
            {ok, #{<<"type">> => <<"function_call">>,
                   <<"call_id">> => CallId,
                   <<"name">> => Name,
                   <<"arguments">> => Arguments}};
        {false, _, _} -> {error, invalid_openai_tool_name};
        {_, false, _} -> {error, openai_tool_call_id_required};
        {_, _, {error, _}} -> {error, invalid_openai_tool_arguments}
    end.

encode_tool_message(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            encode_tool_parts(adk_content:parts(Canonical), []);
        {error, _} = Error -> Error
    end;
encode_tool_message(Content, Limits) ->
    case legacy_tool_response_part(Content) of
        {ok, Part} ->
            case adk_content:new([Part], Limits) of
                {ok, _} -> encode_tool_parts([Part], []);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

legacy_tool_response_part(
  {tool_response, Name, Response, _Signature, CallId}) ->
    {ok, #{<<"type">> => <<"function_response">>,
           <<"name">> => Name, <<"response">> => Response,
           <<"id">> => CallId}};
legacy_tool_response_part(_) ->
    {error, openai_tool_call_id_required}.

encode_tool_parts([], Acc) -> {items, lists:reverse(Acc)};
encode_tool_parts([#{<<"type">> := <<"function_response">>,
                     <<"response">> := Response} = Part | Rest], Acc) ->
    CallId = maps:get(<<"id">>, Part, undefined),
    case {valid_call_id(CallId), json_binary(Response)} of
        {true, {ok, Output}} ->
            Item = #{<<"type">> => <<"function_call_output">>,
                     <<"call_id">> => CallId,
                     <<"output">> => Output},
            encode_tool_parts(Rest, [Item | Acc]);
        {false, _} -> {error, openai_tool_call_id_required};
        {_, {error, _}} -> {error, invalid_openai_tool_output}
    end;
encode_tool_parts([_ | _], _Acc) ->
    {error, unsupported_openai_tool_content}.

message_item(Role, Parts) ->
    #{<<"type">> => <<"message">>,
      <<"role">> => Role,
      <<"content">> => Parts}.

encode_tools([], _Count, _Names, Acc) ->
    {ok, lists:reverse(Acc)};
encode_tools(_Tools, Count, _Names, _Acc) when Count >= ?MAX_TOOLS ->
    {error, {openai_tool_limit_exceeded, ?MAX_TOOLS}};
encode_tools([Tool | Rest], Count, Names, Acc) ->
    case load_tool_schema(Tool) of
        {ok, Schema} ->
            case encode_tool_schema(Schema) of
                {ok, Name, Encoded} ->
                    case maps:is_key(Name, Names) of
                        true -> {error, duplicate_openai_tool_name};
                        false ->
                            encode_tools(Rest, Count + 1,
                                         Names#{Name => true},
                                         [Encoded | Acc])
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_tools(_, _Count, _Names, _Acc) ->
    {error, invalid_openai_tools}.

load_tool_schema(Schema) when is_map(Schema) -> {ok, Schema};
load_tool_schema(Module) when is_atom(Module), Module =/= undefined ->
    try Module:schema() of
        Schema when is_map(Schema) -> {ok, Schema};
        _ -> {error, invalid_openai_tool_schema}
    catch
        _:_ -> {error, openai_tool_schema_unavailable}
    end;
load_tool_schema(_) -> {error, invalid_openai_tool_schema}.

encode_tool_schema(Schema0) ->
    case normalize_json_map(Schema0) of
        {ok, Schema} ->
            Name = maps:get(<<"name">>, Schema, undefined),
            Description = maps:get(<<"description">>, Schema, undefined),
            Parameters0 = maps:get(
                            <<"parameters">>, Schema,
                            #{<<"type">> => <<"object">>,
                              <<"properties">> => #{}}),
            Strict = maps:get(<<"strict">>, Schema, undefined),
            case {valid_tool_name(Name), valid_description(Description),
                  validate_parameter_schema(Parameters0),
                  valid_optional_boolean(Strict)} of
                {true, true, {ok, Parameters}, true} ->
                    Base = #{<<"type">> => <<"function">>,
                             <<"name">> => Name,
                             <<"parameters">> => Parameters},
                    WithDescription = optional_put(
                                        <<"description">>, Description,
                                        Base),
                    Encoded = optional_put(<<"strict">>, Strict,
                                           WithDescription),
                    {ok, Name, Encoded};
                {false, _, _, _} -> {error, invalid_openai_tool_name};
                {_, false, _, _} ->
                    {error, invalid_openai_tool_description};
                {_, _, {error, _}, _} ->
                    {error, invalid_openai_tool_parameters};
                {_, _, _, false} -> {error, invalid_openai_tool_strict}
            end;
        {error, _} -> {error, invalid_openai_tool_schema}
    end.

validate_parameter_schema(Parameters) when is_map(Parameters) ->
    case adk_json_schema:compile(Parameters) of
        {ok, Compiled} -> {ok, Compiled};
        {error, _} -> {error, invalid_schema}
    end;
validate_parameter_schema(_) -> {error, invalid_schema}.

decode_output_items([], _Limits, _Count, Parts, Calls) ->
    {ok, Parts, Calls};
decode_output_items(_Output, _Limits, Count, _Parts, _Calls)
  when Count >= ?MAX_OUTPUT_ITEMS ->
    {error, {openai_output_item_limit_exceeded, ?MAX_OUTPUT_ITEMS}};
decode_output_items([Item | Rest], Limits, Count, Parts0, Calls0)
  when is_map(Item) ->
    case decode_output_item(Item, Limits) of
        {ok, Parts, Calls} ->
            decode_output_items(Rest, Limits, Count + 1,
                                lists:reverse(Parts, Parts0),
                                lists:reverse(Calls, Calls0));
        skip ->
            decode_output_items(Rest, Limits, Count + 1, Parts0, Calls0);
        {error, _} = Error -> Error
    end;
decode_output_items([_ | _], _Limits, _Count, _Parts, _Calls) ->
    {error, invalid_openai_output_item};
decode_output_items(_, _Limits, _Count, _Parts, _Calls) ->
    {error, invalid_openai_output}.

decode_output_item(#{<<"type">> := <<"reasoning">>}, _Limits) -> skip;
decode_output_item(#{<<"type">> := <<"message">>,
                     <<"role">> := <<"assistant">>,
                     <<"content">> := Content}, Limits) ->
    case decode_message_content(Content, Limits, 0, []) of
        {ok, Parts} -> {ok, Parts, []};
        {error, _} = Error -> Error
    end;
decode_output_item(#{<<"type">> := <<"function_call">>,
                     <<"name">> := Name,
                     <<"call_id">> := CallId,
                     <<"arguments">> := Arguments}, Limits) ->
    decode_function_call(Name, CallId, Arguments, Limits);
decode_output_item(_, _Limits) ->
    {error, unsupported_openai_output_item}.

decode_message_content([], _Limits, _Count, Acc) ->
    {ok, lists:reverse(Acc)};
decode_message_content(Content, Limits, Count, Acc) ->
    case Count >= maps:get(max_parts, Limits) of
        true -> {error, openai_output_part_limit_exceeded};
        false -> decode_message_content_part(Content, Limits, Count, Acc)
    end.

decode_message_content_part([#{<<"type">> := <<"output_text">>,
                               <<"text">> := Text} | Rest], Limits,
                            Count, Acc) ->
    Max = maps:get(max_text_bytes, Limits),
    case bounded_text(Text, Max) of
        {ok, CanonicalText} ->
            Part = #{<<"type">> => <<"text">>,
                     <<"text">> => CanonicalText},
            decode_message_content(Rest, Limits, Count + 1, [Part | Acc]);
        {error, _} = Error -> Error
    end;
decode_message_content_part([#{<<"type">> := <<"refusal">>} | _],
                            _Limits, _Count, _Acc) ->
    {error, openai_model_refusal};
decode_message_content_part([_ | _], _Limits, _Count, _Acc) ->
    {error, unsupported_openai_output_content};
decode_message_content_part(_, _Limits, _Count, _Acc) ->
    {error, invalid_openai_output_content}.

decode_function_call(Name, CallId, Arguments, Limits) ->
    Max = maps:get(max_function_payload_bytes, Limits),
    case {valid_tool_name(Name), valid_call_id(CallId),
          bounded_binary(Arguments, Max)} of
        {true, true, {ok, ArgsJson}} ->
            case decode_json_object(ArgsJson) of
                {ok, Args} ->
                    Part = #{<<"type">> => <<"function_call">>,
                             <<"name">> => Name,
                             <<"args">> => Args,
                             <<"id">> => CallId},
                    case adk_content:new([Part], Limits) of
                        {ok, _} ->
                            Call = {Name, Args, undefined, CallId},
                            case adk_tool_call:validate(Call) of
                                ok -> {ok, [Part], [Call]};
                                {error, _} ->
                                    {error, invalid_openai_function_call}
                            end;
                        {error, _} ->
                            {error, invalid_openai_function_call}
                    end;
                {error, _} ->
                    {error, invalid_openai_function_arguments}
            end;
        {false, _, _} -> {error, invalid_openai_tool_name};
        {_, false, _} -> {error, invalid_openai_call_id};
        {_, _, {error, _}} ->
            {error, openai_function_arguments_limit_exceeded}
    end.

decode_json_object(Json) ->
    try jsx:decode(Json, [return_maps]) of
        Value when is_map(Value) ->
            case strict_json_value(Value) of
                ok -> {ok, Value};
                {error, _} -> {error, invalid_json_object}
            end;
        _ -> {error, expected_json_object}
    catch
        _:_ -> {error, invalid_json}
    end.

json_binary(Value) ->
    case strict_json_value(Value) of
        ok ->
            try jsx:encode(Value) of
                Encoded -> {ok, Encoded}
            catch
                _:_ -> {error, invalid_json}
            end;
        {error, _} = Error -> Error
    end.

strict_json_value(Value) ->
    case adk_json:normalize(Value) of
        {ok, Value} -> ok;
        {ok, _Coerced} -> {error, json_must_use_binary_keys};
        {error, _} -> {error, invalid_json}
    end.

normalize_json_map(Value) when is_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Normalized} when is_map(Normalized) -> {ok, Normalized};
        _ -> {error, invalid_json_map}
    end.

bounded_text(Value, Max) ->
    case unicode_binary(Value) of
        {ok, Text} when byte_size(Text) =< Max -> {ok, Text};
        {ok, _} -> {error, openai_text_limit_exceeded};
        {error, _} = Error -> Error
    end.

unicode_binary(Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> {ok, Value};
        _ -> {error, invalid_openai_utf8}
    end;
unicode_binary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> {error, invalid_openai_utf8}
    catch
        _:_ -> {error, invalid_openai_utf8}
    end;
unicode_binary(_) -> {error, invalid_openai_text}.

bounded_binary(Value, Max) when is_binary(Value),
                                byte_size(Value) =< Max ->
    {ok, Value};
bounded_binary(_, _Max) -> {error, invalid_or_oversized_binary}.

valid_tool_name(Name) when is_binary(Name), byte_size(Name) > 0,
                           byte_size(Name) =< ?MAX_TOOL_NAME_BYTES ->
    re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

valid_call_id(CallId) when is_binary(CallId), byte_size(CallId) > 0,
                           byte_size(CallId) =< ?MAX_CALL_ID_BYTES ->
    valid_utf8(CallId);
valid_call_id(_) -> false.

valid_description(undefined) -> true;
valid_description(Description) when is_binary(Description),
                                    byte_size(Description) =<
                                        ?MAX_DESCRIPTION_BYTES ->
    valid_utf8(Description);
valid_description(_) -> false.

valid_optional_boolean(undefined) -> true;
valid_optional_boolean(Value) -> is_boolean(Value).

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

%% OpenAI's vision guide documents PNG, JPEG, WEBP and non-animated GIF.
%% The codec can verify the media type, but animation/content validation
%% remains the server's responsibility.
image_mime(<<"image/png">>) -> true;
image_mime(<<"image/jpeg">>) -> true;
image_mime(<<"image/webp">>) -> true;
image_mime(<<"image/gif">>) -> true;
image_mime(_) -> false.

https_uri(Uri) when is_binary(Uri) ->
    try uri_string:parse(Uri) of
        #{scheme := <<"https">>, host := Host}
          when is_binary(Host), byte_size(Host) > 0 -> true;
        _ -> false
    catch
        _:_ -> false
    end;
https_uri(_) -> false.

optional_put(_Key, undefined, Map) -> Map;
optional_put(Key, Value, Map) -> Map#{Key => Value}.
