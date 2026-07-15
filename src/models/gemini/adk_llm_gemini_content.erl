%% @doc Checked translation between the provider-neutral `adk_content' schema
%% and Gemini Content/Part JSON objects.
-module(adk_llm_gemini_content).

-export([encode/2, decode/2, tool_calls/1, text_parts/1,
         part_types/1]).

-spec encode(adk_content:content(), map()) ->
    {ok, [map()]} | {error, term()}.
encode(Content, Limits) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            {ok, [encode_part(Part) || Part <- adk_content:parts(Canonical)]};
        {error, _} = Error -> Error
    end.

-spec decode([map()], map()) ->
    {ok, adk_content:content()} | {error, term()}.
decode(Parts, Limits) when is_list(Parts) ->
    case decode_parts(Parts, 0, []) of
        {ok, CanonicalParts} -> adk_content:new(CanonicalParts, Limits);
        {error, _} = Error -> Error
    end;
decode(Value, _Limits) ->
    {error, {invalid_gemini_parts, {expected_list, term_type(Value)}}}.

-spec tool_calls(adk_content:content()) -> list().
tool_calls(Content) ->
    lists:filtermap(
      fun(#{<<"type">> := <<"function_call">>,
            <<"name">> := Name, <<"args">> := Args} = Part) ->
              Signature = maps:get(<<"thought_signature">>, Part, undefined),
              case maps:find(<<"id">>, Part) of
                  {ok, Id} -> {true, {Name, Args, Signature, Id}};
                  error -> {true, {Name, Args, Signature}}
              end;
         (_) -> false
      end, adk_content:parts(Content)).

-spec text_parts(adk_content:content()) -> [binary()].
text_parts(Content) ->
    [Text || #{<<"type">> := <<"text">>, <<"text">> := Text}
                 <- adk_content:parts(Content)].

-spec part_types(adk_content:content()) -> [binary()].
part_types(Content) ->
    adk_content:part_types(Content).

encode_part(#{<<"type">> := <<"text">>, <<"text">> := Text} = Part) ->
    with_metadata(Part, #{<<"text">> => Text});
encode_part(#{<<"type">> := <<"inline_data">>,
              <<"mime_type">> := MimeType, <<"data">> := Data} = Part) ->
    with_metadata(Part,
                  #{<<"inlineData">> => #{<<"mimeType">> => MimeType,
                                            <<"data">> => Data}});
encode_part(#{<<"type">> := <<"file_data">>,
              <<"mime_type">> := MimeType, <<"uri">> := Uri} = Part) ->
    with_metadata(Part,
                  #{<<"fileData">> => #{<<"mimeType">> => MimeType,
                                          <<"fileUri">> => Uri}});
encode_part(#{<<"type">> := <<"function_call">>,
              <<"name">> := Name, <<"args">> := Args} = Part) ->
    Function0 = #{<<"name">> => Name, <<"args">> => Args},
    Function = copy_optional(<<"id">>, Part, Function0),
    with_metadata(Part, #{<<"functionCall">> => Function});
encode_part(#{<<"type">> := <<"function_response">>,
              <<"name">> := Name, <<"response">> := Response} = Part) ->
    Function0 = #{<<"name">> => Name, <<"response">> => Response},
    Function = copy_optional(<<"id">>, Part, Function0),
    with_metadata(Part, #{<<"functionResponse">> => Function}).

with_metadata(Part, GeminiPart0) ->
    GeminiPart1 = case maps:find(<<"thought_signature">>, Part) of
        {ok, Signature} ->
            GeminiPart0#{<<"thoughtSignature">> => Signature};
        error -> GeminiPart0
    end,
    case maps:find(<<"thought">>, Part) of
        {ok, Thought} -> GeminiPart1#{<<"thought">> => Thought};
        error -> GeminiPart1
    end.

copy_optional(Key, Source, Destination) ->
    case maps:find(Key, Source) of
        {ok, Value} -> Destination#{Key => Value};
        error -> Destination
    end.

decode_parts([], _Index, Acc) ->
    {ok, lists:reverse(Acc)};
decode_parts([Part | Rest], Index, Acc) when is_map(Part) ->
    case decode_part(Part, Index) of
        {ok, Canonical} ->
            decode_parts(Rest, Index + 1, [Canonical | Acc]);
        {error, _} = Error -> Error
    end;
decode_parts([Value | _], Index, _Acc) ->
    {error, {invalid_gemini_part, Index,
             {expected_map, term_type(Value)}}}.

decode_part(#{<<"text">> := Text} = Part, Index) ->
    case allowed_keys(Part, [<<"text">>, <<"thought">>,
                             <<"thoughtSignature">>]) of
        ok -> {ok, copy_metadata(
                     Part, #{<<"type">> => <<"text">>,
                             <<"text">> => Text})};
        {error, Keys} -> unsupported_part(Index, Keys)
    end;
decode_part(#{<<"inlineData">> := Data} = Part, Index) ->
    case {allowed_keys(Part, [<<"inlineData">>, <<"thought">>,
                              <<"thoughtSignature">>]), Data} of
        {ok, #{<<"mimeType">> := MimeType, <<"data">> := Bytes} = Nested} ->
            case allowed_keys(Nested, [<<"mimeType">>, <<"data">>]) of
                ok -> {ok, copy_metadata(
                             Part,
                             #{<<"type">> => <<"inline_data">>,
                               <<"mime_type">> => MimeType,
                               <<"data">> => Bytes})};
                {error, Keys} -> unsupported_part(Index, Keys)
            end;
        {{error, Keys}, _} -> unsupported_part(Index, Keys);
        {ok, _} -> {error, {invalid_gemini_part, Index,
                            invalid_inline_data}}
    end;
decode_part(#{<<"fileData">> := Data} = Part, Index) ->
    case {allowed_keys(Part, [<<"fileData">>, <<"thought">>,
                              <<"thoughtSignature">>]), Data} of
        {ok, #{<<"mimeType">> := MimeType, <<"fileUri">> := Uri} = Nested} ->
            case allowed_keys(Nested, [<<"mimeType">>, <<"fileUri">>]) of
                ok -> {ok, copy_metadata(
                             Part,
                             #{<<"type">> => <<"file_data">>,
                               <<"mime_type">> => MimeType,
                               <<"uri">> => Uri})};
                {error, Keys} -> unsupported_part(Index, Keys)
            end;
        {{error, Keys}, _} -> unsupported_part(Index, Keys);
        {ok, _} -> {error, {invalid_gemini_part, Index,
                            invalid_file_data}}
    end;
decode_part(#{<<"functionCall">> := Function} = Part, Index) ->
    decode_function_part(call, Function, Part, Index);
decode_part(#{<<"functionResponse">> := Function} = Part, Index) ->
    decode_function_part(response, Function, Part, Index);
decode_part(Part, Index) ->
    unsupported_part(Index, maps:keys(Part)).

decode_function_part(Kind, Function, Part, Index) when is_map(Function) ->
    {PayloadKey, CanonicalPayloadKey, AllowedFunctionKeys} = case Kind of
        call -> {<<"args">>, <<"args">>,
                 [<<"name">>, <<"args">>, <<"id">>]};
        response -> {<<"response">>, <<"response">>,
                     [<<"name">>, <<"response">>, <<"id">>]}
    end,
    GeminiKey = case Kind of
        call -> <<"functionCall">>;
        response -> <<"functionResponse">>
    end,
    case {allowed_keys(Part, [GeminiKey, <<"thought">>,
                              <<"thoughtSignature">>]),
          allowed_keys(Function, AllowedFunctionKeys),
          maps:find(<<"name">>, Function),
          function_payload(Kind, PayloadKey, Function)} of
        {ok, ok, {ok, Name}, {ok, Payload}} ->
            Type = case Kind of
                call -> <<"function_call">>;
                response -> <<"function_response">>
            end,
            Canonical0 = #{<<"type">> => Type,
                           <<"name">> => Name,
                           CanonicalPayloadKey => Payload},
            Canonical1 = copy_optional(<<"id">>, Function, Canonical0),
            Canonical = copy_metadata(Part, Canonical1),
            {ok, Canonical};
        {{error, Keys}, _, _, _} -> unsupported_part(Index, Keys);
        {_, {error, Keys}, _, _} -> unsupported_part(Index, Keys);
        _ -> {error, {invalid_gemini_part, Index,
                      {invalid_function_part, Kind}}}
    end;
decode_function_part(Kind, _Function, _Part, Index) ->
    {error, {invalid_gemini_part, Index,
             {invalid_function_part, Kind}}}.

function_payload(call, PayloadKey, Function) ->
    {ok, maps:get(PayloadKey, Function, #{})};
function_payload(response, PayloadKey, Function) ->
    maps:find(PayloadKey, Function).

copy_metadata(Source, Destination0) ->
    Destination1 = case maps:find(<<"thoughtSignature">>, Source) of
        {ok, Signature} ->
            Destination0#{<<"thought_signature">> => Signature};
        error -> Destination0
    end,
    case maps:find(<<"thought">>, Source) of
        {ok, Thought} -> Destination1#{<<"thought">> => Thought};
        error -> Destination1
    end.

allowed_keys(Map, Allowed) ->
    Unknown = [Key || Key <- maps:keys(Map),
                      not lists:member(Key, Allowed)],
    case Unknown of
        [] -> ok;
        _ -> {error, lists:sort(Unknown)}
    end.

unsupported_part(Index, Keys) ->
    {error, {unsupported_gemini_part, Index, Keys}}.

term_type(Value) when is_map(Value) -> map;
term_type(Value) when is_list(Value) -> list;
term_type(Value) when is_binary(Value) -> binary;
term_type(Value) when is_tuple(Value) -> tuple;
term_type(Value) when is_atom(Value) -> atom;
term_type(_) -> other.
