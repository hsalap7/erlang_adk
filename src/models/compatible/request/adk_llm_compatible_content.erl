%% @doc Checked ADK content translation for OpenAI-compatible Chat Completions.
%%
%% The module is a pure JSON boundary. Emitted wire maps have binary keys;
%% provider input is bounded and treated as untrusted; errors never retain
%% prompts, model text, function arguments, tool results, or schema values.
-module(adk_llm_compatible_content).

-export([encode/3, encode_history/2, encode_tools/1,
         decode_message/2, outcome/1, tool_calls/1, text_parts/1]).

-define(MAX_HISTORY_MESSAGES, 2048).
-define(MAX_TOOLS, 128).
-define(MAX_TOOL_NAME_BYTES, 64).
-define(MAX_CALL_ID_BYTES, 256).
-define(MAX_DESCRIPTION_BYTES, 8192).
-define(MAX_TOOL_SCHEMA_BYTES, 1048576).
-define(MAX_ALL_TOOL_BYTES, 4194304).

-spec encode(system | user | assistant | agent | tool, term(), map()) ->
    {ok, [map()]} | {error, term()}.
encode(Role, Content, LimitOverrides) ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} -> encode_role(Role, Content, Limits);
        {error, _} = Error -> Error
    end.

-spec encode_history(term(), map()) ->
    {ok, [map()]} | {error, term()}.
encode_history(History, LimitOverrides) ->
    case {adk_content:normalize_limits(LimitOverrides),
          bounded_list_length(History, ?MAX_HISTORY_MESSAGES)} of
        {{ok, Limits}, {ok, _Count}} ->
            encode_history(History, Limits, []);
        {{error, _} = Error, _} -> Error;
        {_, too_many} ->
            {error, {compatible_history_limit_exceeded,
                     ?MAX_HISTORY_MESSAGES}};
        {_, improper} -> {error, invalid_compatible_history}
    end.

%% @doc Encode ordinary ADK function declarations into the Chat Completions
%% nested `{type:function,function:{...}}' shape.
-spec encode_tools(term()) -> {ok, [map()]} | {error, term()}.
encode_tools(Tools) ->
    case bounded_list_length(Tools, ?MAX_TOOLS) of
        {ok, _} -> encode_tools(Tools, 0, #{}, [], 0);
        too_many ->
            {error, {compatible_tool_limit_exceeded, ?MAX_TOOLS}};
        improper -> {error, invalid_compatible_tools}
    end.

%% @doc Decode one assistant message from a completed choice. Text and
%% parallel tool calls may coexist. Every call preserves its provider id.
-spec decode_message(term(), map()) ->
    {ok, adk_content:content(), list()} | {error, term()}.
decode_message(#{<<"role">> := <<"assistant">>} = Message,
               LimitOverrides) ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} -> decode_assistant_message(Message, Limits);
        {error, _} = Error -> Error
    end;
decode_message(_Message, _LimitOverrides) ->
    {error, invalid_compatible_assistant_message}.

-spec outcome(adk_content:content()) ->
    {ok, binary() | adk_content:content()} | {tool_calls, list()} |
    {error, term()}.
outcome(Content) ->
    case tool_calls(Content) of
        [_ | _] = Calls -> {tool_calls, Calls};
        [] ->
            Parts = adk_content:parts(Content),
            case lists:all(
                   fun(#{<<"type">> := <<"text">>}) -> true;
                      (_) -> false
                   end, Parts) of
                true ->
                    Text = iolist_to_binary(text_parts(Content)),
                    case Text of
                        <<>> -> {error, empty_compatible_response};
                        _ -> {ok, Text}
                    end;
                false -> {ok, Content}
            end
    end.

-spec tool_calls(adk_content:content()) -> list().
tool_calls(Content) ->
    lists:filtermap(
      fun(#{<<"type">> := <<"function_call">>,
            <<"name">> := Name, <<"args">> := Args,
            <<"id">> := CallId}) ->
              {true, {Name, Args, undefined, CallId}};
         (_) -> false
      end, adk_content:parts(Content)).

-spec text_parts(adk_content:content()) -> [binary()].
text_parts(Content) ->
    [Text || #{<<"type">> := <<"text">>, <<"text">> := Text}
                 <- adk_content:parts(Content)].

encode_history([], _Limits, Acc) -> {ok, lists:reverse(Acc)};
encode_history([#{role := Role, content := Content} | Rest], Limits, Acc) ->
    case encode_role(Role, Content, Limits) of
        {ok, Messages} ->
            encode_history(Rest, Limits, lists:reverse(Messages, Acc));
        {error, _} = Error -> Error
    end;
encode_history([_ | _], _Limits, _Acc) ->
    {error, invalid_compatible_history_message}.

encode_role(system, Content, Limits) ->
    case text_only(Content, Limits) of
        {ok, Text} ->
            {ok, [#{<<"role">> => <<"system">>,
                    <<"content">> => Text}]};
        {error, _} = Error -> Error
    end;
encode_role(user, Content, Limits) ->
    encode_user(Content, Limits);
encode_role(agent, Content, Limits) ->
    encode_assistant(Content, Limits);
encode_role(assistant, Content, Limits) ->
    encode_assistant(Content, Limits);
encode_role(tool, Content, Limits) ->
    encode_tool_results(Content, Limits);
encode_role(_Role, _Content, _Limits) ->
    {error, invalid_compatible_history_role}.

text_only(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            Parts = adk_content:parts(Canonical),
            case lists:all(
                   fun(#{<<"type">> := <<"text">>}) -> true;
                      (_) -> false
                   end, Parts) of
                true -> {ok, iolist_to_binary(text_parts(Canonical))};
                false -> {error, unsupported_compatible_system_content}
            end;
        {error, _} = Error -> Error
    end;
text_only(Content, Limits) ->
    bounded_text(Content, maps:get(max_text_bytes, Limits)).

encode_user(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            case encode_user_parts(adk_content:parts(Canonical), []) of
                {ok, Parts} ->
                    {ok, [#{<<"role">> => <<"user">>,
                            <<"content">> => lists:reverse(Parts)}]};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_user(Content, Limits) ->
    case bounded_text(Content, maps:get(max_text_bytes, Limits)) of
        {ok, Text} ->
            {ok, [#{<<"role">> => <<"user">>,
                    <<"content">> => Text}]};
        {error, _} = Error -> Error
    end.

encode_user_parts([], Acc) -> {ok, Acc};
encode_user_parts([#{<<"type">> := <<"text">>,
                     <<"text">> := Text} | Rest], Acc) ->
    encode_user_parts(
      Rest, [#{<<"type">> => <<"text">>, <<"text">> => Text} | Acc]);
encode_user_parts([#{<<"type">> := <<"inline_data">>,
                     <<"mime_type">> := Mime,
                     <<"data">> := Data} | Rest], Acc) ->
    case image_mime(Mime) of
        true ->
            Url = <<"data:", Mime/binary, ";base64,", Data/binary>>,
            Part = #{<<"type">> => <<"image_url">>,
                     <<"image_url">> => #{<<"url">> => Url}},
            encode_user_parts(Rest, [Part | Acc]);
        false -> {error, unsupported_compatible_inline_media}
    end;
encode_user_parts([#{<<"type">> := <<"file_data">>,
                     <<"mime_type">> := Mime,
                     <<"uri">> := Uri} | Rest], Acc) ->
    case image_mime(Mime) andalso https_uri(Uri) of
        true ->
            Part = #{<<"type">> => <<"image_url">>,
                     <<"image_url">> => #{<<"url">> => Uri}},
            encode_user_parts(Rest, [Part | Acc]);
        false -> {error, unsupported_compatible_file_media}
    end;
encode_user_parts([_ | _], _Acc) ->
    {error, unsupported_compatible_user_content}.

encode_assistant({tool_calls, Calls}, Limits) ->
    encode_legacy_assistant_calls(Calls, Limits);
encode_assistant(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            encode_assistant_parts(adk_content:parts(Canonical), [], []);
        {error, _} = Error -> Error
    end;
encode_assistant(Content, Limits) ->
    case bounded_text(Content, maps:get(max_text_bytes, Limits)) of
        {ok, Text} ->
            {ok, [#{<<"role">> => <<"assistant">>,
                    <<"content">> => Text}]};
        {error, _} = Error -> Error
    end.

encode_assistant_parts([], Text, Calls) ->
    Content = case Text of
        [] when Calls =/= [] -> null;
        _ -> iolist_to_binary(lists:reverse(Text))
    end,
    Base = #{<<"role">> => <<"assistant">>, <<"content">> => Content},
    Message = case Calls of
        [] -> Base;
        _ -> Base#{<<"tool_calls">> => lists:reverse(Calls)}
    end,
    {ok, [Message]};
encode_assistant_parts([#{<<"type">> := <<"text">>,
                          <<"text">> := Text} | Rest], TextAcc, Calls) ->
    encode_assistant_parts(Rest, [Text | TextAcc], Calls);
encode_assistant_parts([#{<<"type">> := <<"function_call">>} = Part |
                        Rest], TextAcc, Calls) ->
    case encode_call(Part) of
        {ok, Call} ->
            encode_assistant_parts(Rest, TextAcc, [Call | Calls]);
        {error, _} = Error -> Error
    end;
encode_assistant_parts([_ | _], _TextAcc, _Calls) ->
    {error, unsupported_compatible_assistant_content}.

encode_legacy_assistant_calls(Calls, Limits) ->
    case adk_tool_call:validate_list(Calls) of
        ok -> encode_legacy_assistant_calls(Calls, Limits, []);
        {error, _} -> {error, invalid_compatible_tool_calls}
    end.

encode_legacy_assistant_calls([], _Limits, Acc) ->
    {ok, [#{<<"role">> => <<"assistant">>,
            <<"content">> => null,
            <<"tool_calls">> => lists:reverse(Acc)}]};
encode_legacy_assistant_calls(
  [{Name, Args, _Signature, CallId} | Rest], Limits, Acc) ->
    Part = #{<<"type">> => <<"function_call">>,
             <<"name">> => Name, <<"args">> => Args,
             <<"id">> => CallId},
    case adk_content:new([Part], Limits) of
        {ok, _} ->
            case encode_call(Part) of
                {ok, Call} ->
                    encode_legacy_assistant_calls(
                      Rest, Limits, [Call | Acc]);
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, invalid_compatible_tool_calls}
    end;
encode_legacy_assistant_calls([_ | _], _Limits, _Acc) ->
    {error, compatible_tool_call_id_required}.

encode_call(#{<<"name">> := Name, <<"args">> := Args} = Part) ->
    CallId = maps:get(<<"id">>, Part, undefined),
    case {valid_tool_name(Name), valid_call_id(CallId), json_binary(Args)} of
        {true, true, {ok, Arguments}} ->
            {ok, #{<<"id">> => CallId,
                   <<"type">> => <<"function">>,
                   <<"function">> =>
                       #{<<"name">> => Name,
                         <<"arguments">> => Arguments}}};
        {false, _, _} -> {error, invalid_compatible_tool_name};
        {_, false, _} -> {error, compatible_tool_call_id_required};
        {_, _, {error, _}} ->
            {error, invalid_compatible_tool_arguments}
    end.

encode_tool_results(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            encode_tool_result_parts(adk_content:parts(Canonical), []);
        {error, _} = Error -> Error
    end;
encode_tool_results(Content, Limits) ->
    case legacy_tool_response(Content) of
        {ok, Part} ->
            case adk_content:new([Part], Limits) of
                {ok, Canonical} ->
                    encode_tool_result_parts(
                      adk_content:parts(Canonical), []);
                {error, _} -> {error, invalid_compatible_tool_response}
            end;
        {error, _} = Error -> Error
    end.

legacy_tool_response(
  {tool_response, Name, Response, _Signature, CallId}) ->
    {ok, #{<<"type">> => <<"function_response">>,
           <<"name">> => Name, <<"response">> => Response,
           <<"id">> => CallId}};
legacy_tool_response(_) ->
    {error, compatible_tool_call_id_required}.

encode_tool_result_parts([], Acc) -> {ok, lists:reverse(Acc)};
encode_tool_result_parts(
  [#{<<"type">> := <<"function_response">>,
     <<"name">> := Name, <<"response">> := Response} = Part | Rest], Acc) ->
    CallId = maps:get(<<"id">>, Part, undefined),
    case {valid_tool_name(Name), valid_call_id(CallId),
          json_binary(Response)} of
        {true, true, {ok, Output}} ->
            Message = #{<<"role">> => <<"tool">>,
                        <<"tool_call_id">> => CallId,
                        <<"name">> => Name,
                        <<"content">> => Output},
            encode_tool_result_parts(Rest, [Message | Acc]);
        {false, _, _} -> {error, invalid_compatible_tool_name};
        {_, false, _} -> {error, compatible_tool_call_id_required};
        {_, _, {error, _}} ->
            {error, invalid_compatible_tool_output}
    end;
encode_tool_result_parts([_ | _], _Acc) ->
    {error, unsupported_compatible_tool_content}.

encode_tools([], _Index, _Names, Acc, _Total) ->
    {ok, lists:reverse(Acc)};
encode_tools([Tool | Rest], Index, Names, Acc, Total) ->
    case load_tool_schema(Tool) of
        {ok, Schema} ->
            case encode_tool_schema(Schema) of
                {ok, Name, Encoded, Size} ->
                    NewTotal = Total + Size,
                    case {maps:is_key(Name, Names),
                          NewTotal =< ?MAX_ALL_TOOL_BYTES} of
                        {true, _} ->
                            {error, {duplicate_compatible_tool, Index}};
                        {false, false} ->
                            {error, compatible_tool_schemas_too_large};
                        {false, true} ->
                            encode_tools(Rest, Index + 1,
                                         Names#{Name => true},
                                         [Encoded | Acc], NewTotal)
                    end;
                {error, Reason} ->
                    {error, {invalid_compatible_tool, Index, Reason}}
            end;
        {error, Reason} ->
            {error, {invalid_compatible_tool, Index, Reason}}
    end.

load_tool_schema(Schema) when is_map(Schema) -> {ok, Schema};
load_tool_schema(Module) when is_atom(Module), Module =/= undefined ->
    try Module:schema() of
        Schema when is_map(Schema) -> {ok, Schema};
        _ -> {error, invalid_schema}
    catch
        _:_ -> {error, schema_callback_failed}
    end;
load_tool_schema(_) -> {error, invalid_descriptor}.

encode_tool_schema(Schema) ->
    Allowed = [<<"name">>, <<"description">>, <<"parameters">>,
               <<"strict">>],
    case bounded_term(Schema, ?MAX_TOOL_SCHEMA_BYTES) of
        false -> {error, schema_too_large};
        true ->
            case maps:keys(maps:without(Allowed, Schema)) of
                [] -> encode_tool_schema_fields(Schema);
                _ -> {error, unknown_schema_keys}
            end
    end.

encode_tool_schema_fields(Schema) ->
    Name = maps:get(<<"name">>, Schema, undefined),
    Description = maps:get(<<"description">>, Schema, undefined),
    Parameters0 = maps:get(
                    <<"parameters">>, Schema,
                    #{<<"type">> => <<"object">>,
                      <<"properties">> => #{}}),
    Strict = maps:get(<<"strict">>, Schema, undefined),
    case {valid_tool_name(Name), valid_description(Description),
          strict_json_map(Parameters0),
          adk_json_schema:compile(Parameters0),
          valid_optional_boolean(Strict)} of
        {true, true, ok, {ok, Parameters}, true} ->
            Function0 = #{<<"name">> => Name,
                          <<"parameters">> => Parameters},
            Function1 = put_optional(
                          <<"description">>, Description, Function0),
            Function = put_optional(<<"strict">>, Strict, Function1),
            Encoded = #{<<"type">> => <<"function">>,
                        <<"function">> => Function},
            try iolist_size(jsx:encode(Encoded)) of
                Size when Size =< ?MAX_TOOL_SCHEMA_BYTES ->
                    {ok, Name, Encoded, Size};
                _ -> {error, schema_too_large}
            catch
                _:_ -> {error, invalid_schema}
            end;
        {false, _, _, _, _} -> {error, invalid_name};
        {_, false, _, _, _} -> {error, invalid_description};
        {_, _, _, {error, _}, _} -> {error, invalid_parameters};
        {_, _, {error, _}, _, _} -> {error, invalid_parameters};
        {_, _, _, _, false} -> {error, invalid_strict}
    end.

decode_assistant_message(Message, Limits) ->
    Content0 = maps:get(<<"content">>, Message, null),
    Calls0 = maps:get(<<"tool_calls">>, Message, []),
    case {decode_output_text(Content0, Limits),
          decode_wire_calls(Calls0, Limits)} of
        {{ok, TextParts}, {ok, CallParts, Calls}} ->
            Parts = TextParts ++ CallParts,
            case Parts of
                [] -> {error, empty_compatible_response};
                _ ->
                    case adk_content:new(Parts, Limits) of
                        {ok, Content} ->
                            case adk_tool_call:validate_list(Calls) of
                                ok -> {ok, Content, Calls};
                                {error, _} ->
                                    {error, invalid_compatible_tool_calls}
                            end;
                        {error, _} ->
                            {error, invalid_compatible_response_content}
                    end
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

decode_output_text(null, _Limits) -> {ok, []};
decode_output_text(Text, Limits) when is_binary(Text) ->
    case bounded_text(Text, maps:get(max_text_bytes, Limits)) of
        {ok, <<>>} -> {ok, []};
        {ok, Canonical} ->
            {ok, [#{<<"type">> => <<"text">>,
                    <<"text">> => Canonical}]};
        {error, _} -> {error, invalid_compatible_response_text}
    end;
decode_output_text(_Text, _Limits) ->
    {error, invalid_compatible_response_text}.

decode_wire_calls(Calls, Limits) ->
    case bounded_list_length(Calls, maps:get(max_parts, Limits)) of
        {ok, _} -> decode_wire_calls(Calls, Limits, 0, #{}, [], []);
        too_many -> {error, compatible_response_part_limit_exceeded};
        improper -> {error, invalid_compatible_tool_calls}
    end.

decode_wire_calls([], _Limits, _Index, _Ids, Parts, Calls) ->
    {ok, lists:reverse(Parts), lists:reverse(Calls)};
decode_wire_calls([Wire | Rest], Limits, Index, Ids, Parts, Calls) ->
    case decode_wire_call(Wire, Limits) of
        {ok, Part, CallId, Call} ->
            case maps:is_key(CallId, Ids) of
                true -> {error, duplicate_compatible_tool_call_id};
                false ->
                    decode_wire_calls(Rest, Limits, Index + 1,
                                      Ids#{CallId => true},
                                      [Part | Parts], [Call | Calls])
            end;
        {error, Reason} ->
            {error, {invalid_compatible_tool_call, Index, Reason}}
    end.

decode_wire_call(
  #{<<"id">> := CallId, <<"type">> := <<"function">>,
    <<"function">> :=
        #{<<"name">> := Name, <<"arguments">> := Arguments}}, Limits) ->
    Max = maps:get(max_function_payload_bytes, Limits),
    case {valid_call_id(CallId), valid_tool_name(Name),
          bounded_utf8_binary(Arguments, Max)} of
        {true, true, true} ->
            case decode_json_object(Arguments) of
                {ok, Args} ->
                    Part = #{<<"type">> => <<"function_call">>,
                             <<"name">> => Name, <<"args">> => Args,
                             <<"id">> => CallId},
                    Call = {Name, Args, undefined, CallId},
                    {ok, Part, CallId, Call};
                {error, _} -> {error, invalid_arguments}
            end;
        {false, _, _} -> {error, invalid_call_id};
        {_, false, _} -> {error, invalid_name};
        {_, _, false} -> {error, invalid_arguments}
    end;
decode_wire_call(_Wire, _Limits) ->
    {error, invalid_shape}.

decode_json_object(Json) ->
    try jsx:decode(Json, [return_maps]) of
        Value when is_map(Value) ->
            case strict_json_map(Value) of
                ok -> {ok, Value};
                {error, _} -> {error, invalid_json}
            end;
        _ -> {error, expected_object}
    catch
        _:_ -> {error, invalid_json}
    end.

json_binary(Value) ->
    case adk_json:normalize(Value) of
        {ok, Value} ->
            try jsx:encode(Value) of
                Encoded -> {ok, Encoded}
            catch
                _:_ -> {error, invalid_json}
            end;
        _ -> {error, invalid_json}
    end.

strict_json_map(Value) when is_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Value} -> ok;
        _ -> {error, invalid_json}
    end;
strict_json_map(_Value) -> {error, invalid_json}.

bounded_text(Value, Max) ->
    case unicode_binary(Value) of
        {ok, Text} when byte_size(Text) =< Max -> {ok, Text};
        {ok, _} -> {error, compatible_text_limit_exceeded};
        {error, _} = Error -> Error
    end.

unicode_binary(Value) when is_binary(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> {ok, Value};
        _ -> {error, invalid_compatible_utf8}
    catch
        _:_ -> {error, invalid_compatible_utf8}
    end;
unicode_binary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> {error, invalid_compatible_utf8}
    catch
        _:_ -> {error, invalid_compatible_utf8}
    end;
unicode_binary(_) -> {error, invalid_compatible_text}.

bounded_utf8_binary(Value, Max) when is_binary(Value),
                                     byte_size(Value) =< Max ->
    valid_utf8(Value);
bounded_utf8_binary(_Value, _Max) -> false.

valid_tool_name(Name) when is_binary(Name), byte_size(Name) > 0,
                           byte_size(Name) =< ?MAX_TOOL_NAME_BYTES ->
    re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

valid_call_id(CallId) when is_binary(CallId), byte_size(CallId) > 0,
                           byte_size(CallId) =< ?MAX_CALL_ID_BYTES ->
    valid_utf8(CallId);
valid_call_id(_) -> false.

valid_description(undefined) -> true;
valid_description(Value) when is_binary(Value), byte_size(Value) =<
                                              ?MAX_DESCRIPTION_BYTES ->
    valid_utf8(Value);
valid_description(_) -> false.

valid_optional_boolean(undefined) -> true;
valid_optional_boolean(Value) -> is_boolean(Value).

valid_utf8(Value) when is_binary(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end.

image_mime(<<"image/", Rest/binary>>) -> byte_size(Rest) > 0;
image_mime(_) -> false.

https_uri(Uri) when is_binary(Uri) ->
    try uri_string:parse(Uri) of
        #{scheme := <<"https">>, host := Host} = Parsed
          when is_binary(Host), byte_size(Host) > 0 ->
            not maps:is_key(userinfo, Parsed) andalso
                not maps:is_key(fragment, Parsed);
        _ -> false
    catch _:_ -> false
    end;
https_uri(_) -> false.

bounded_list_length(Value, Max) ->
    bounded_list_length(Value, Max, 0).

bounded_list_length([], _Max, Count) -> {ok, Count};
bounded_list_length([_ | _], Max, Count) when Count >= Max -> too_many;
bounded_list_length([_ | Rest], Max, Count) ->
    bounded_list_length(Rest, Max, Count + 1);
bounded_list_length(_, _Max, _Count) -> improper.

put_optional(_Key, undefined, Map) -> Map;
put_optional(Key, Value, Map) -> Map#{Key => Value}.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.
