-module(adk_llm_gemini).
-behaviour(adk_llm).

-export([generate/3, stream/4, stream_content/4,
         capabilities/0, validate_config/1]).

-define(DEFAULT_MODEL, <<"gemini-3.1-flash-lite">>).

generate(Config, Memory, Tools) ->
    case {validate_config(Config), get_api_key(Config)} of
        {ok, {ok, ApiKey}} ->
            generate_with_key(Config, Memory, Tools, ApiKey);
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

capabilities() ->
    #{generate => true,
      streaming => true,
      function_calling => true,
      parallel_function_calling => true,
      thought_signatures => true,
      thinking => true,
      thought_summaries => true,
      function_call_ids => true,
      google_search_grounding => true,
      builtin_tools => [google_search],
      generation_config => true,
      safety_settings => true,
      structured_output => true,
      multimodal => true,
      content_schema_version => adk_content:codec_version(),
      input_content_parts => [text, inline_data, file_data,
                              function_call, function_response],
      output_content_parts => [text, inline_data, file_data,
                               function_call, function_response],
      content_streaming => true,
      supported_file_uri_schemes => [https, gs],
      live => false}.

validate_config(Config) when is_map(Config) ->
    Validators = [validate_known_config_keys(Config)] ++
      generation_validators(Config) ++ [
        validate_nested_generation_config(Config),
        validate_optional_binary(model, Config),
        validate_optional_binary(base_url, Config),
        validate_optional_secret(api_key, Config),
        validate_builtin_tools(Config),
        validate_response_schema(Config),
        validate_content_limits(Config),
        request_timeout_validation(Config)
    ],
    first_error(Validators);
validate_config(Value) ->
    {error, {invalid_gemini_config, Value}}.

first_error([]) -> ok;
first_error([ok | Rest]) -> first_error(Rest);
first_error([{error, _} = Error | _]) -> Error.

generation_validators(Config) ->
    [validate_optional_number(temperature, Config),
     validate_optional_number(top_p, Config),
     validate_optional_integer(top_k, Config, 0),
     validate_optional_integer(max_tokens, Config, 1),
     validate_optional_integer(max_output_tokens, Config, 1),
     validate_token_aliases(Config),
     validate_optional_integer(candidate_count, Config, 1),
     validate_optional_integer(seed, Config, 0),
     validate_optional_number(presence_penalty, Config),
     validate_optional_number(frequency_penalty, Config),
     validate_optional_binary(response_mime_type, Config),
     validate_stop_sequences(Config),
     validate_thinking_config(Config),
     validate_safety_settings(Config)].

validate_known_config_keys(Config) ->
    Unknown = maps:without(known_config_keys(), Config),
    case map_size(Unknown) of
        0 -> ok;
        _ -> {error, {unknown_gemini_options,
                      lists:sort(maps:keys(Unknown))}}
    end.

%% Agent configs intentionally reach the provider with their runtime contract
%% fields intact.  Keep this finite list synchronized with the documented
%% agent surface; arbitrary keys must live under callback_config.
known_config_keys() ->
    [provider, model, base_url, api_key,
     temperature, top_p, top_k, max_tokens, max_output_tokens,
     candidate_count, seed, presence_penalty, frequency_penalty,
     stop_sequences, response_mime_type, response_schema,
     thinking_config, safety_settings, builtin_tools,
     content_limits, request_timeout,
     instructions, global_instruction, input_schema, output_schema,
     generation_config, history_policy, include_history, include_contents,
     output_key, required_capabilities, instruction_timeout_ms,
     artifact_timeout_ms, max_instruction_bytes,
     session_id, session_store, sub_agents, callbacks, callback_config,
     callback_pid, max_tool_rounds, app_name, user_id, artifact_svc,
     artifact_service, agent_turn_timeout, max_concurrent_invocations,
     '$adk_invocation_context_api',
     '$adk_inherited_global_instruction'].

generation_config_keys() ->
    [temperature, top_p, top_k, max_tokens, max_output_tokens,
     candidate_count, seed, presence_penalty, frequency_penalty,
     stop_sequences, response_mime_type, thinking_config, safety_settings].

validate_nested_generation_config(Config) ->
    case maps:find(generation_config, Config) of
        error -> ok;
        {ok, Nested} when is_map(Nested) ->
            Unknown = maps:without(generation_config_keys(), Nested),
            case map_size(Unknown) of
                0 -> first_error(generation_validators(Nested));
                _ -> {error, {unknown_gemini_generation_options,
                              lists:sort(maps:keys(Unknown))}}
            end;
        {ok, Value} ->
            {error, {invalid_gemini_option, generation_config, Value}}
    end.

validate_token_aliases(Config) ->
    case {maps:is_key(max_tokens, Config),
          maps:is_key(max_output_tokens, Config)} of
        {true, true} ->
            {error, {conflicting_gemini_options,
                     [max_output_tokens, max_tokens]}};
        _ -> ok
    end.

validate_optional_binary(Key, Config) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_binary(Value), byte_size(Value) > 0 -> ok;
        {ok, Value} -> {error, {invalid_gemini_option, Key, Value}}
    end.

validate_optional_secret(Key, Config) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_binary(Value), byte_size(Value) > 0 -> ok;
        {ok, Value} when is_list(Value), Value =/= [] ->
            case unicode:characters_to_binary(Value) of
                Bin when is_binary(Bin), byte_size(Bin) > 0 -> ok;
                _ -> {error, {invalid_gemini_option, Key, redacted}}
            end;
        {ok, _Value} -> {error, {invalid_gemini_option, Key, redacted}}
    end.

validate_optional_number(Key, Config) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_integer(Value); is_float(Value) -> ok;
        {ok, Value} -> {error, {invalid_gemini_option, Key, Value}}
    end.

validate_optional_integer(Key, Config, Minimum) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_integer(Value), Value >= Minimum -> ok;
        {ok, Value} -> {error, {invalid_gemini_option, Key, Value}}
    end.

validate_builtin_tools(Config) ->
    case maps:find(builtin_tools, Config) of
        error -> ok;
        {ok, []} -> ok;
        {ok, [google_search]} -> ok;
        {ok, Value} ->
            {error, {invalid_gemini_option, builtin_tools, Value}}
    end.

validate_response_schema(Config) ->
    case maps:find(response_schema, Config) of
        error -> ok;
        {ok, Schema} when is_map(Schema) ->
            case json_safe(Schema) of
                true -> ok;
                false -> {error, {invalid_gemini_option,
                                  response_schema, not_json_safe}}
            end;
        {ok, Value} ->
            {error, {invalid_gemini_option, response_schema, Value}}
    end.

validate_stop_sequences(Config) ->
    case maps:find(stop_sequences, Config) of
        error -> ok;
        {ok, Values} when is_list(Values) ->
            case lists:all(fun(Value) ->
                               is_binary(Value) andalso byte_size(Value) > 0
                           end, Values) of
                true -> ok;
                false -> {error, {invalid_gemini_option,
                                  stop_sequences, Values}}
            end;
        {ok, Value} ->
            {error, {invalid_gemini_option, stop_sequences, Value}}
    end.

validate_thinking_config(Config) ->
    case maps:find(thinking_config, Config) of
        error -> ok;
        {ok, Thinking} when is_map(Thinking), map_size(Thinking) > 0 ->
            Allowed = [thinking_level, thinking_budget, include_thoughts],
            Unknown = maps:without(Allowed, Thinking),
            Level = maps:get(thinking_level, Thinking, undefined),
            Budget = maps:get(thinking_budget, Thinking, undefined),
            Include = maps:get(include_thoughts, Thinking, undefined),
            case map_size(Unknown) =:= 0 andalso
                 not (Level =/= undefined andalso Budget =/= undefined) andalso
                 valid_thinking_level(Level) andalso
                 valid_thinking_budget(Budget) andalso
                 (Include =:= undefined orelse is_boolean(Include)) of
                true -> ok;
                false -> {error, {invalid_gemini_option,
                                  thinking_config, Thinking}}
            end;
        {ok, Value} ->
            {error, {invalid_gemini_option, thinking_config, Value}}
    end.

validate_safety_settings(Config) ->
    case maps:find(safety_settings, Config) of
        error -> ok;
        {ok, Settings} ->
            case adk_gemini_safety:normalize(Settings) of
                {ok, _} -> ok;
                {error, Reason} ->
                    {error, {invalid_gemini_option,
                             safety_settings, Reason}}
            end
    end.

valid_thinking_level(undefined) -> true;
valid_thinking_level(minimal) -> true;
valid_thinking_level(low) -> true;
valid_thinking_level(medium) -> true;
valid_thinking_level(high) -> true;
valid_thinking_level(<<"minimal">>) -> true;
valid_thinking_level(<<"low">>) -> true;
valid_thinking_level(<<"medium">>) -> true;
valid_thinking_level(<<"high">>) -> true;
valid_thinking_level(_) -> false.

valid_thinking_budget(undefined) -> true;
valid_thinking_budget(-1) -> true;
valid_thinking_budget(Value) -> is_integer(Value) andalso Value >= 0.

validate_content_limits(Config) ->
    case maps:find(content_limits, Config) of
        error -> ok;
        {ok, Limits} ->
            case adk_content:normalize_limits(Limits) of
                {ok, _} -> ok;
                {error, Reason} ->
                    {error, {invalid_gemini_option, content_limits, Reason}}
            end
    end.

request_timeout_validation(Config) ->
    case request_timeout(Config) of
        {ok, _} -> ok;
        {error, _} = Error ->
            Error
    end.

generate_with_key(Config, Memory, Tools, ApiKey) ->
    case build_payload(Config, Memory, Tools) of
        {ok, Payload} ->
            generate_payload(Config, ApiKey, Payload);
        {error, _} = Error -> Error
    end.

generate_payload(Config, ApiKey, Payload) ->
    Model = maps:get(model, Config, ?DEFAULT_MODEL),
    BaseUrl = maps:get(base_url, Config,
                       <<"https://generativelanguage.googleapis.com">>),
    Url = binary_to_list(BaseUrl) ++ "/v1beta/models/" ++
          binary_to_list(Model) ++ ":generateContent",
    JsonBody = jsx:encode(Payload),
    Headers = [{"Content-Type", "application/json"},
               {"x-goog-api-key", binary_to_list(ApiKey)}],
    Request = {Url, Headers, "application/json", JsonBody},
    Options = [{body_format, binary}],
    case {ssl_options(BaseUrl), request_timeout(Config)} of
        {{ok, SslOptions}, {ok, RequestTimeout}} ->
            HttpOptions = add_request_timeout(
                            [{ssl, SslOptions}], RequestTimeout),
            case httpc:request(post, Request, HttpOptions, Options) of
                {ok, {{_Version, StatusCode, _ReasonPhrase}, _Headers, Body}}
                        when StatusCode >= 200, StatusCode < 300 ->
                    decode_response(Body, content_limits(Config));
                {ok, {{_Version, StatusCode, _ReasonPhrase}, _Headers, Body}} ->
                    {error, {http_status, StatusCode, Body}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

stream(Config, Memory, Tools, Callback) when is_function(Callback, 1) ->
    stream_mode(Config, Memory, Tools, Callback, text);
stream(_Config, _Memory, _Tools, Callback) ->
    {error, {invalid_stream_callback, Callback}}.

%% @doc Stream one canonical versioned content value per decoded Gemini SSE
%% frame. `stream/4' remains the backwards-compatible text-delta API.
stream_content(Config, Memory, Tools, Callback) when is_function(Callback, 1) ->
    stream_mode(Config, Memory, Tools, Callback, content);
stream_content(_Config, _Memory, _Tools, Callback) ->
    {error, {invalid_stream_callback, Callback}}.

stream_mode(Config, Memory, Tools, Callback, Mode) ->
    case {validate_config(Config), get_api_key(Config)} of
        {ok, {ok, ApiKey}} ->
            stream_with_key(Config, Memory, Tools, Callback, ApiKey, Mode);
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

stream_with_key(Config, Memory, Tools, Callback, ApiKey, Mode) ->
    Model = maps:get(model, Config, ?DEFAULT_MODEL),
    BaseUrl = maps:get(base_url, Config, <<"https://generativelanguage.googleapis.com">>),
    case {build_payload(Config, Memory, Tools),
          stream_destination(BaseUrl, Model), request_timeout(Config)} of
        {{ok, Payload}, {ok, Scheme, Host, Port, Path},
         {ok, RequestTimeout}} ->
            case open_connection(Scheme, Host, Port) of
                {ok, ConnPid} ->
                    try
                        perform_stream_request(
                            ConnPid,
                            Path,
                            jsx:encode(Payload),
                            Callback,
                            ApiKey,
                            gun_request_timeout(RequestTimeout),
                            Mode,
                            content_limits(Config)
                        )
                    catch
                        Class:Reason ->
                            {error, {stream_failed, Class, Reason}}
                    after
                        _ = catch gun:close(ConnPid)
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

stream_destination(BaseUrl, Model) ->
    try uri_string:parse(BaseUrl) of
        #{host := Host, scheme := Scheme} = Uri
                when Scheme =:= <<"http">>; Scheme =:= <<"https">> ->
            BasePath = maps:get(path, Uri, <<>>),
            Port = case maps:get(port, Uri, undefined) of
                undefined when Scheme =:= <<"https">> -> 443;
                undefined -> 80;
                Value -> Value
            end,
            Path = binary_to_list(BasePath) ++ "/v1beta/models/" ++
                binary_to_list(Model) ++ ":streamGenerateContent?alt=sse",
            {ok, Scheme, Host, Port, Path};
        _ ->
            {error, invalid_base_url}
    catch
        _:_ -> {error, invalid_base_url}
    end.

%% Keep the transports' existing defaults when request_timeout is omitted:
%% httpc currently uses 60 seconds, while Gun awaits use 5 seconds. An
%% explicit value is useful when the caller has a tighter outer deadline.
request_timeout(Config) ->
    case maps:find(request_timeout, Config) of
        error ->
            {ok, default};
        {ok, infinity} ->
            {ok, infinity};
        {ok, Timeout} when is_integer(Timeout), Timeout >= 0 ->
            {ok, Timeout};
        {ok, Timeout} ->
            {error, {invalid_request_timeout, Timeout}}
    end.

add_request_timeout(HttpOptions, default) ->
    HttpOptions;
add_request_timeout(HttpOptions, RequestTimeout) ->
    [{timeout, RequestTimeout} | HttpOptions].

gun_request_timeout(default) -> 5000;
gun_request_timeout(RequestTimeout) -> RequestTimeout.

open_connection(<<"https">>, Host, Port) ->
    HostString = binary_to_list(Host),
    case tls_options(HostString) of
        {ok, TlsOptions} ->
            gun:open(HostString, Port,
                     #{transport => tls, tls_opts => TlsOptions});
        {error, _} = Error ->
            Error
    end;
open_connection(<<"http">>, Host, Port) ->
    gun:open(binary_to_list(Host), Port, #{transport => tcp}).

perform_stream_request(ConnPid, Path, JsonBody, Callback, ApiKey,
                       RequestTimeout, Mode, Limits) ->
    case gun:await_up(ConnPid, RequestTimeout) of
        {ok, _Protocol} ->
            Headers = [{<<"content-type">>, <<"application/json">>},
                       {<<"x-goog-api-key">>, ApiKey}],
            StreamRef = gun:post(ConnPid, Path, Headers, JsonBody),
            await_stream_response(
              ConnPid, StreamRef, Callback, RequestTimeout, Mode, Limits);
        {error, Reason} ->
            {error, Reason}
    end.

await_stream_response(ConnPid, StreamRef, Callback, RequestTimeout,
                      Mode, Limits) ->
    case gun:await(ConnPid, StreamRef, RequestTimeout) of
        {inform, _Status, _Headers} ->
            await_stream_response(
              ConnPid, StreamRef, Callback, RequestTimeout, Mode, Limits);
        {response, fin, Status, _Headers} when Status >= 200, Status < 300 ->
            ok;
        {response, fin, Status, _Headers} ->
            {error, {http_status, Status, <<>>}};
        {response, nofin, Status, _Headers} when Status >= 200, Status < 300 ->
            consume_stream_data(
              ConnPid, StreamRef, Callback, <<>>, new_stream_result_acc(),
              RequestTimeout,
              Mode, Limits);
        {response, nofin, Status, _Headers} ->
            read_error_response(
              ConnPid, StreamRef, Status, RequestTimeout);
        {error, Reason} ->
            {error, Reason}
    end.

read_error_response(ConnPid, StreamRef, Status, RequestTimeout) ->
    case gun:await_body(ConnPid, StreamRef, RequestTimeout) of
        {ok, Body} -> {error, {http_status, Status, Body}};
        {ok, Body, _Trailers} -> {error, {http_status, Status, Body}};
        {error, Reason} -> {error, {http_status, Status, {body_error, Reason}}}
    end.

consume_stream_data(ConnPid, StreamRef, Callback, Buffer, ResultAcc,
                    RequestTimeout, Mode, Limits) ->
    case gun:await(ConnPid, StreamRef, RequestTimeout) of
        {data, IsFin, Data} ->
            case consume_sse_bytes(<<Buffer/binary, Data/binary>>, Callback,
                                   ResultAcc, Mode, Limits) of
                {ok, Rest, NewResultAcc} when IsFin =:= nofin ->
                    consume_stream_data(
                      ConnPid, StreamRef, Callback, Rest, NewResultAcc,
                      RequestTimeout, Mode, Limits);
                {ok, Rest, NewResultAcc} ->
                    finish_sse(Rest, Callback, NewResultAcc,
                               Mode, Limits);
                {error, _} = Error ->
                    Error
            end;
        {trailers, _Trailers} ->
            finish_sse(Buffer, Callback, ResultAcc, Mode, Limits);
        {error, Reason} ->
            {error, Reason}
    end.

new_stream_result_acc() ->
    #{tool_calls => [], grounding_metadata => undefined}.

consume_sse_bytes(Bytes, Callback, ResultAcc, Mode, Limits) ->
    Normalized = binary:replace(Bytes, <<"\r\n">>, <<"\n">>, [global]),
    Parts = binary:split(Normalized, <<"\n\n">>, [global]),
    {Frames, [Rest]} = lists:split(length(Parts) - 1, Parts),
    case consume_sse_frames(Frames, Callback, ResultAcc, Mode, Limits) of
        {ok, NewResultAcc} -> {ok, Rest, NewResultAcc};
        {error, _} = Error -> Error
    end.

consume_sse_frames([], _Callback, ResultAcc, _Mode, _Limits) ->
    {ok, ResultAcc};
consume_sse_frames([Frame | Rest], Callback, ResultAcc, Mode, Limits) ->
    case consume_sse_frame(Frame, Callback, Mode, Limits) of
        {ok, ToolCalls, GroundingMetadata} ->
            case merge_stream_result(
                   ToolCalls, GroundingMetadata, ResultAcc) of
                {ok, NewAcc} ->
                    consume_sse_frames(
                      Rest, Callback, NewAcc, Mode, Limits);
                {error, _} = Error -> Error
            end;
        done ->
            consume_sse_frames(Rest, Callback, ResultAcc, Mode, Limits);
        {error, _} = Error ->
            Error
    end.

finish_sse(Buffer, Callback, ResultAcc, Mode, Limits) ->
    case string:trim(Buffer) of
        <<>> -> final_stream_result(ResultAcc);
        FinalFrame ->
            case consume_sse_frame(FinalFrame, Callback, Mode, Limits) of
                {ok, ToolCalls, GroundingMetadata} ->
                    case merge_stream_result(
                           ToolCalls, GroundingMetadata, ResultAcc) of
                        {ok, NewAcc} -> final_stream_result(NewAcc);
                        {error, _} = Error -> Error
                    end;
                done ->
                    final_stream_result(ResultAcc);
                {error, _} = Error ->
                    Error
            end
    end.

final_stream_result(#{tool_calls := ReversedToolCalls,
                      grounding_metadata := GroundingMetadata}) ->
    Outcome = case ReversedToolCalls of
        [] -> streamed;
        _ ->
            {tool_calls,
             normalize_tool_call_signatures(
               lists:reverse(ReversedToolCalls))}
    end,
    case GroundingMetadata of
        undefined ->
            case Outcome of
                streamed -> ok;
                ToolCalls -> ToolCalls
            end;
        _ ->
            case adk_provider_result:new(
                   <<"gemini">>, <<"google_search_grounding">>,
                   Outcome, GroundingMetadata) of
                {ok, ProviderResult} -> ProviderResult;
                {error, Reason} ->
                    {error, {invalid_grounding_metadata, Reason}}
            end
    end.

merge_stream_result(ToolCalls, GroundingMetadata,
                    Acc = #{tool_calls := ReversedToolCalls,
                            grounding_metadata := Existing}) ->
    NewToolCalls = lists:reverse(ToolCalls, ReversedToolCalls),
    case merge_grounding_metadata(Existing, GroundingMetadata) of
        {ok, NewGrounding} ->
            {ok, Acc#{tool_calls => NewToolCalls,
                      grounding_metadata => NewGrounding}};
        {error, _} = Error -> Error
    end.

merge_grounding_metadata(Existing, undefined) ->
    {ok, Existing};
merge_grounding_metadata(undefined, New) ->
    validate_stream_grounding(New);
merge_grounding_metadata(Existing, New)
  when is_map(Existing), is_map(New) ->
    Merged = maps:fold(fun merge_grounding_field/3, Existing, New),
    validate_stream_grounding(Merged);
merge_grounding_metadata(_Existing, New) ->
    {error, {invalid_grounding_metadata,
             {metadata_must_be_map, New}}}.

merge_grounding_field(Key, NewValue, Acc) ->
    case {accumulated_grounding_field(Key),
          maps:find(Key, Acc), NewValue} of
        {true, {ok, ExistingValue}, Value}
          when is_list(ExistingValue), is_list(Value) ->
            Acc#{Key => ExistingValue ++ Value};
        _ ->
            Acc#{Key => NewValue}
    end.

accumulated_grounding_field(<<"groundingChunks">>) -> true;
accumulated_grounding_field(<<"groundingSupports">>) -> true;
accumulated_grounding_field(<<"webSearchQueries">>) -> true;
accumulated_grounding_field(<<"imageSearchQueries">>) -> true;
accumulated_grounding_field(_) -> false.

validate_stream_grounding(Metadata) ->
    case adk_provider_result:new(
           <<"gemini">>, <<"google_search_grounding">>,
           streamed, Metadata) of
        {ok, _} -> {ok, Metadata};
        {error, Reason} ->
            {error, {invalid_grounding_metadata, Reason}}
    end.

consume_sse_frame(Frame, Callback, Mode, Limits) ->
    case sse_data(Frame) of
        none ->
            {ok, [], undefined};
        <<"[DONE]">> ->
            done;
        Data ->
            try jsx:decode(Data, [return_maps]) of
                Response -> consume_stream_response(
                              Response, Callback, Mode, Limits)
            catch
                error:Reason -> {error, {invalid_sse_data, Reason, Data}}
            end
    end.

sse_data(Frame) ->
    Lines = binary:split(Frame, <<"\n">>, [global]),
    DataLines = lists:filtermap(
        fun
            (<<"data:", Rest/binary>>) -> {true, strip_optional_space(Rest)};
            (<<"data">>) -> {true, <<>>};
            (_) -> false
        end,
        Lines
    ),
    case DataLines of
        [] -> none;
        _ -> iolist_to_binary(lists:join(<<"\n">>, DataLines))
    end.

strip_optional_space(<<" ", Rest/binary>>) -> Rest;
strip_optional_space(Value) -> Value.

consume_stream_response(Response, Callback, Mode, Limits) ->
    GroundingMetadata = stream_grounding_metadata(Response),
    case stream_response_parts(Response) of
        {ok, []} -> {ok, [], GroundingMetadata};
        {ok, Parts} ->
            case adk_llm_gemini_content:decode(Parts, Limits) of
                {ok, Content} ->
                    case emit_stream_content(Mode, Content, Callback) of
                        {ok, ToolCalls} ->
                            {ok, ToolCalls, GroundingMetadata};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

stream_grounding_metadata(#{<<"candidates">> := [Candidate | _]})
  when is_map(Candidate) ->
    maps:get(<<"groundingMetadata">>, Candidate, undefined);
stream_grounding_metadata(_) ->
    undefined.

emit_stream_content(text, Content, Callback) ->
    Types = adk_llm_gemini_content:part_types(Content),
    Unsupported = [Type || Type <- Types,
                            Type =/= <<"text">>,
                            Type =/= <<"function_call">>],
    case Unsupported of
        [] ->
            lists:foreach(Callback,
                          [Text || Text <- visible_text_parts(Content),
                                   Text =/= <<>>]),
            {ok, adk_llm_gemini_content:tool_calls(Content)};
        [Type | _] ->
            {error, {unsupported_text_stream_part, Type}}
    end;
emit_stream_content(content, Content, Callback) ->
    Callback(Content),
    {ok, adk_llm_gemini_content:tool_calls(Content)}.

stream_response_parts(#{<<"candidates">> := Candidates})
  when is_list(Candidates) ->
    {ok, lists:append([
        Parts
        || #{<<"content">> := #{<<"parts">> := Parts}} <- Candidates,
           is_list(Parts)
    ])};
stream_response_parts(#{<<"usageMetadata">> := _}) ->
    %% Gemini may emit a final accounting-only SSE frame. It contains no model
    %% content and therefore must not create an empty or duplicate delta.
    {ok, []};
stream_response_parts(_) ->
    {error, invalid_stream_response}.

decode_response(Body, Limits) ->
    try jsx:decode(Body, [return_maps]) of
        ResponseMap -> parse_response(ResponseMap, Limits)
    catch
        error:Reason -> {error, {invalid_json, Reason}}
    end.

ssl_options(<<"http://", _/binary>>) ->
    {ok, []};
ssl_options(BaseUrl) ->
    case uri_string:parse(BaseUrl) of
        #{scheme := <<"https">>, host := Host} ->
            tls_options(binary_to_list(Host));
        _ ->
            {error, invalid_base_url}
    end.

tls_options(HostString) ->
    case ca_options() of
        {ok, CaOptions} ->
            %% OTP's default hostname matcher is deliberately strict and does
            %% not accept DNS wildcards. HTTPS certificates commonly use
            %% wildcard SANs (Google serves *.googleapis.com), so select the
            %% RFC-compatible HTTPS matcher explicitly for both httpc and gun.
            HostnameCheck = apply(public_key,
                                  pkix_verify_hostname_match_fun, [https]),
            {ok, [{server_name_indication, HostString},
                  {customize_hostname_check,
                   [{match_fun, HostnameCheck}]} | CaOptions]};
        {error, _} = Error ->
            Error
    end.

ca_options() ->
    %% Never silently downgrade certificate verification. If the host has no
    %% CA store, return a provider error rather than crashing or using
    %% verify_none.
    try apply(public_key, cacerts_get, []) of
        Certs -> {ok, [{verify, verify_peer}, {cacerts, Certs}]}
    catch
        Class:Reason -> {error, {ca_certificates_unavailable, Class, Reason}}
    end.

build_payload(Config, Memory, Tools) ->
    Limits = content_limits(Config),
    case build_contents(Memory, <<>>, [], Limits) of
        {ok, SystemInstruction, Contents} ->
            Payload0 = #{<<"contents">> => Contents},
            Payload1 = case SystemInstruction of
                <<>> -> Payload0;
                Sys -> Payload0#{
                    <<"system_instruction">> =>
                        #{<<"parts">> => [#{<<"text">> => Sys}]}
                }
            end,
            GenConfig = build_gen_config(Config),
            Payload2 = case maps:size(GenConfig) of
                0 -> Payload1;
                _ -> Payload1#{<<"generationConfig">> => GenConfig}
            end,
            case add_safety_settings(Payload2, Config) of
                {ok, Payload3} ->
                    add_provider_tools(Payload3, Config, Tools);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

tool_schema(Schema) when is_map(Schema) -> Schema;
tool_schema(Module) when is_atom(Module) -> Module:schema().

add_provider_tools(Payload, Config, Tools) ->
    Builtins = case maps:get(builtin_tools, Config, []) of
        [google_search] -> [#{<<"googleSearch">> => #{}}];
        [] -> []
    end,
    FunctionTools = case Tools of
        [] -> [];
        _ ->
            Declarations = [tool_schema(Tool) || Tool <- Tools],
            [#{<<"functionDeclarations">> => Declarations}]
    end,
    case Builtins ++ FunctionTools of
        [] -> {ok, Payload};
        ProviderTools -> {ok, Payload#{<<"tools">> => ProviderTools}}
    end.

add_safety_settings(Payload, Config) ->
    case maps:find(safety_settings, Config) of
        error -> {ok, Payload};
        {ok, []} -> {ok, Payload};
        {ok, Settings} ->
            case adk_gemini_safety:encode(Settings) of
                {ok, Encoded} ->
                    {ok, Payload#{<<"safetySettings">> => Encoded}};
                {error, Reason} ->
                    {error, {invalid_gemini_option,
                             safety_settings, Reason}}
            end
    end.

get_api_key(Config) ->
    case maps:find(api_key, Config) of
        {ok, Key} ->
            {ok, to_binary(Key)};
        error ->
            case os:getenv("GEMINI_API_KEY") of
                false -> {error, missing_api_key};
                KeyStr -> {ok, list_to_binary(KeyStr)}
            end
    end.

build_contents([], SysAcc, ContentsAcc, _Limits) ->
    {ok, SysAcc, lists:reverse(ContentsAcc)};
build_contents([#{role := system, content := Content} | Rest],
               SysAcc, ContentsAcc, Limits) ->
    case system_text(Content, Limits) of
        {ok, ContentBin} ->
            NewSys = case SysAcc of
                <<>> -> ContentBin;
                _ -> <<SysAcc/binary, "\n", ContentBin/binary>>
            end,
            build_contents(Rest, NewSys, ContentsAcc, Limits);
        {error, _} = Error -> Error
    end;
build_contents([#{role := tool} | _] = History, SysAcc, ContentsAcc,
               Limits) ->
    %% Group consecutive tool responses into a single 'user' message
    case consume_tool_responses(History, [], Limits) of
        {ok, ToolParts, Rest} ->
            Msg = #{<<"role">> => <<"user">>, <<"parts">> => ToolParts},
            build_contents(Rest, SysAcc, [Msg | ContentsAcc], Limits);
        {error, _} = Error -> Error
    end;
build_contents([#{role := agent, content := {tool_calls, Calls}} | Rest],
               SysAcc, ContentsAcc, Limits) ->
    case encode_legacy_tool_calls(Calls, Limits) of
        {ok, Parts} ->
            Msg = #{<<"role">> => <<"model">>, <<"parts">> => Parts},
            build_contents(Rest, SysAcc, [Msg | ContentsAcc], Limits);
        {error, _} = Error -> Error
    end;
build_contents([#{role := Role, content := Content} | Rest],
               SysAcc, ContentsAcc, Limits)
  when Role =:= user; Role =:= agent ->
    case encode_message_content(Role, Content, Limits) of
        {ok, Parts} ->
            GeminiRole = case Role of
                user -> <<"user">>;
                agent -> <<"model">>
            end,
            Msg = #{<<"role">> => GeminiRole, <<"parts">> => Parts},
            build_contents(Rest, SysAcc, [Msg | ContentsAcc], Limits);
        {error, _} = Error -> Error
    end;
build_contents([Message | _], _SysAcc, _ContentsAcc, _Limits) ->
    {error, {invalid_gemini_history_message, Message}};
build_contents(Value, _SysAcc, _ContentsAcc, _Limits) ->
    {error, {invalid_gemini_history, Value}}.

system_text(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            Types = adk_llm_gemini_content:part_types(Canonical),
            case lists:all(fun(Type) -> Type =:= <<"text">> end, Types) of
                true ->
                    {ok, iolist_to_binary(lists:join(
                           <<"\n">>,
                           adk_llm_gemini_content:text_parts(Canonical)))};
                false ->
                    {error, {unsupported_system_content_parts, Types}}
            end;
        {error, _} = Error -> Error
    end;
system_text(Content, _Limits) ->
    text_binary(Content).

encode_message_content(Role, Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            case validate_role_parts(Role,
                                     adk_llm_gemini_content:part_types(
                                       Canonical)) of
                ok -> adk_llm_gemini_content:encode(Canonical, Limits);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_message_content(_Role, Content, _Limits) ->
    case text_binary(Content) of
        {ok, Text} -> {ok, [#{<<"text">> => Text}]};
        {error, _} = Error -> Error
    end.

validate_role_parts(user, Types) ->
    validate_allowed_types(user, Types,
                           [<<"text">>, <<"inline_data">>,
                            <<"file_data">>, <<"function_response">>]);
validate_role_parts(agent, Types) ->
    validate_allowed_types(agent, Types,
                           [<<"text">>, <<"inline_data">>,
                            <<"file_data">>, <<"function_call">>]).

validate_allowed_types(_Role, [], _Allowed) -> ok;
validate_allowed_types(Role, [Type | Rest], Allowed) ->
    case lists:member(Type, Allowed) of
        true -> validate_allowed_types(Role, Rest, Allowed);
        false -> {error, {unsupported_content_part_for_role, Role, Type}}
    end.

encode_legacy_tool_calls(Calls, Limits) when is_list(Calls) ->
    encode_legacy_tool_calls(Calls, Limits, []);
encode_legacy_tool_calls(Value, _Limits) ->
    {error, {invalid_tool_calls, Value}}.

encode_legacy_tool_calls([], _Limits, Acc) ->
    {ok, lists:reverse(Acc)};
encode_legacy_tool_calls([Call | Rest], Limits, Acc) ->
    case legacy_call_content(Call, Limits) of
        {ok, Part} ->
            {ok, [GeminiPart]} = adk_llm_gemini_content:encode(
                                  content_with_part(Part), Limits),
            encode_legacy_tool_calls(Rest, Limits, [GeminiPart | Acc]);
        {error, _} = Error -> Error
    end.

legacy_call_content(Call, Limits) ->
    case Call of
        {Name, Args} -> make_function_call(Name, Args, undefined,
                                           undefined, Limits);
        {Name, Args, Signature} ->
            make_function_call(Name, Args, Signature, undefined, Limits);
        {Name, Args, Signature, Id} ->
            make_function_call(Name, Args, Signature, Id, Limits);
        _ -> {error, {invalid_tool_call, Call}}
    end.

make_function_call(Name, Args, Signature, Id, Limits) ->
    Options0 = optional_binary(<<"thought_signature">>, Signature, #{}),
    Options = optional_binary(<<"id">>, Id, Options0),
    Part = maps:merge(#{<<"type">> => <<"function_call">>,
                        <<"name">> => to_binary(Name),
                        <<"args">> => Args}, Options),
    validate_single_part(Part, Limits).

consume_tool_responses([#{role := tool, content := Content} | Rest],
                       Acc, Limits) ->
    case encode_tool_response_content(Content, Limits) of
        {ok, Parts} ->
            consume_tool_responses(Rest, lists:reverse(Parts, Acc), Limits);
        {error, _} = Error -> Error
    end;
consume_tool_responses(Rest, Acc, _Limits) ->
    {ok, lists:reverse(Acc), Rest}.

encode_tool_response_content(Content, Limits) when is_map(Content) ->
    case adk_content:validate(Content, Limits) of
        {ok, Canonical} ->
            Types = adk_llm_gemini_content:part_types(Canonical),
            case lists:all(
                   fun(Type) -> Type =:= <<"function_response">> end,
                   Types) of
                true -> adk_llm_gemini_content:encode(Canonical, Limits);
                false -> {error, {unsupported_tool_content_parts, Types}}
            end;
        {error, _} = Error -> Error
    end;
encode_tool_response_content(Content, Limits) ->
    case Content of
        {tool_response, Name, Response} ->
            make_function_response(Name, Response, undefined,
                                   undefined, Limits);
        {tool_response, Name, Response, Signature} ->
            make_function_response(Name, Response, Signature,
                                   undefined, Limits);
        {tool_response, Name, Response, Signature, Id} ->
            make_function_response(Name, Response, Signature, Id, Limits);
        _ -> {error, {invalid_tool_response, Content}}
    end.

make_function_response(Name, Response, Signature, Id, Limits) ->
    Options0 = optional_binary(<<"thought_signature">>, Signature, #{}),
    Options = optional_binary(<<"id">>, Id, Options0),
    Part = maps:merge(#{<<"type">> => <<"function_response">>,
                        <<"name">> => to_binary(Name),
                        <<"response">> => Response}, Options),
    case validate_single_part(Part, Limits) of
        {ok, CanonicalPart} ->
            adk_llm_gemini_content:encode(
              content_with_part(CanonicalPart), Limits);
        {error, _} = Error -> Error
    end.

validate_single_part(Part, Limits) ->
    case adk_content:new([Part], Limits) of
        {ok, Canonical} -> {ok, hd(adk_content:parts(Canonical))};
        {error, _} = Error -> Error
    end.

content_with_part(Part) ->
    #{<<"schema_version">> => adk_content:codec_version(),
      <<"parts">> => [Part]}.

optional_binary(_Key, undefined, Acc) -> Acc;
optional_binary(Key, Value, Acc) -> Acc#{Key => Value}.

text_binary(Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> {ok, Value};
        _ -> {error, {invalid_text_content, invalid_utf8}}
    end;
text_binary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> {error, {invalid_text_content, invalid_unicode}}
    catch
        _:_ -> {error, {invalid_text_content, invalid_unicode}}
    end;
text_binary(Value) ->
    {error, {unsupported_gemini_content, Value}}.

build_gen_config(Config) ->
    Keys = [
        {temperature, <<"temperature">>},
        {max_tokens, <<"maxOutputTokens">>},
        {max_output_tokens, <<"maxOutputTokens">>},
        {top_p, <<"topP">>},
        {top_k, <<"topK">>},
        {candidate_count, <<"candidateCount">>},
        {seed, <<"seed">>},
        {presence_penalty, <<"presencePenalty">>},
        {frequency_penalty, <<"frequencyPenalty">>},
        {stop_sequences, <<"stopSequences">>},
        {response_mime_type, <<"responseMimeType">>},
        {response_schema, <<"responseSchema">>}
    ],
    Basic = lists:foldl(
        fun({K, GeminiK}, Acc) ->
            case maps:find(K, Config) of
                {ok, V} -> Acc#{GeminiK => V};
                error -> Acc
            end
        end,
        #{},
        Keys
    ),
    case maps:find(thinking_config, Config) of
        {ok, ThinkingConfig} ->
            Basic#{<<"thinkingConfig">> =>
                       encode_thinking_config(ThinkingConfig)};
        error -> Basic
    end.

encode_thinking_config(Config) ->
    lists:foldl(
      fun({ErlangKey, GeminiKey, Transform}, Acc) ->
              case maps:find(ErlangKey, Config) of
                  {ok, Value} -> Acc#{GeminiKey => Transform(Value)};
                  error -> Acc
              end
      end,
      #{},
      [{thinking_level, <<"thinkingLevel">>, fun thinking_level_json/1},
       {thinking_budget, <<"thinkingBudget">>, fun identity/1},
       {include_thoughts, <<"includeThoughts">>, fun identity/1}]).

thinking_level_json(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
thinking_level_json(Value) -> Value.

identity(Value) -> Value.

parse_response(#{<<"candidates">> :=
                   [#{<<"content">> := #{<<"parts">> := Parts}} = Candidate
                    | _]},
               Limits) ->
    case adk_llm_gemini_content:decode(Parts, Limits) of
        {ok, Content} ->
            ToolCalls = normalize_tool_call_signatures(
                          adk_llm_gemini_content:tool_calls(Content)),
            Result = case ToolCalls of
                [_ | _] -> {tool_calls, ToolCalls};
                [] ->
                    Types = adk_llm_gemini_content:part_types(Content),
                    TextParts = visible_text_parts(Content),
                    HasThoughtSummary = lists:any(
                      fun(Part) -> maps:get(<<"thought">>, Part, false) =:= true
                      end, adk_content:parts(Content)),
                    case {HasThoughtSummary,
                          lists:all(
                            fun(Type) -> Type =:= <<"text">> end, Types)} of
                        {true, _} ->
                            %% Thought summaries are optional structured model
                            %% content. Never concatenate them into the public
                            %% answer binary or mistake them for an executable
                            %% plan.
                            {ok, Content};
                        {false, true} when TextParts =/= [] ->
                            {ok, iolist_to_binary(TextParts)};
                        {false, true} -> {error, empty_response};
                        {false, false} -> {ok, Content}
                    end
            end,
            add_candidate_grounding(Result, Candidate);
        {error, _} = Error -> Error
    end;
parse_response(_, _Limits) ->
    {error, invalid_response}.

add_candidate_grounding({error, _} = Error, _Candidate) ->
    Error;
add_candidate_grounding(Result, Candidate) ->
    case maps:find(<<"groundingMetadata">>, Candidate) of
        error -> Result;
        {ok, GroundingMetadata} ->
            Outcome = case Result of
                {ok, Output} -> {ok, Output};
                {tool_calls, Calls} -> {tool_calls, Calls}
            end,
            case adk_provider_result:new(
                   <<"gemini">>, <<"google_search_grounding">>,
                   Outcome, GroundingMetadata) of
                {ok, ProviderResult} -> ProviderResult;
                {error, Reason} ->
                    {error, {invalid_grounding_metadata, Reason}}
            end
    end.

%% Thought signatures belong to their original content parts. Keeping each
%% signature on its own call allows build_contents/3 to replay the model turn
%% exactly instead of copying one signature onto unrelated parallel calls.
normalize_tool_call_signatures(ToolCalls) ->
    ToolCalls.

visible_text_parts(Content) ->
    [Text || #{<<"type">> := <<"text">>, <<"text">> := Text} = Part
                 <- adk_content:parts(Content),
             maps:get(<<"thought">>, Part, false) =/= true].

content_limits(Config) ->
    {ok, Limits} = adk_content:normalize_limits(
                     maps:get(content_limits, Config, #{})),
    Limits.

to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(Str) when is_list(Str) -> unicode:characters_to_binary(Str);
to_binary(Bin) when is_binary(Bin) -> Bin.

json_safe(Value) when is_binary(Value); is_integer(Value); is_float(Value) ->
    true;
json_safe(true) -> true;
json_safe(false) -> true;
json_safe(null) -> true;
json_safe(Value) when is_list(Value) ->
    lists:all(fun json_safe/1, Value);
json_safe(Value) when is_map(Value) ->
    lists:all(
      fun({Key, Item}) -> is_binary(Key) andalso json_safe(Item) end,
      maps:to_list(Value));
json_safe(_) -> false.
