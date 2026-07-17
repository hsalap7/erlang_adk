%% @doc Native OpenAI Responses API provider.
%%
%% Uses the Responses API rather than translating through Chat Completions.
%% Pure codecs own canonical content/tool translation; this module owns
%% credentials, fixed headers, bounded HTTP and incremental SSE delivery.
-module(adk_llm_openai).

-behaviour(adk_llm).

-export([generate/3, stream/4, stream_content/4,
         capabilities/0, validate_config/1, public_config/1]).

-define(DEFAULT_BASE_URL, <<"https://api.openai.com/v1">>).
-define(MAX_SSE_EVENT_BYTES, 9437184).

-spec generate(map(), list(), list()) -> term().
generate(Config0, Memory, Tools) ->
    Config = with_defaults(Config0),
    case {validate_config(Config0),
          resolve_api_key(Config),
          adk_openai_responses_codec:encode_request(
            Config, Memory, Tools, false)} of
        {ok, {ok, ApiKey}, {ok, Payload}} ->
            perform_generate(Config, ApiKey, Payload);
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

-spec stream(map(), list(), list(), fun((binary()) -> ok)) -> term().
stream(Config, Memory, Tools, Callback) when is_function(Callback, 1) ->
    stream_mode(Config, Memory, Tools, Callback, text);
stream(_Config, _Memory, _Tools, _Callback) ->
    {error, invalid_stream_callback}.

-spec stream_content(map(), list(), list(),
                     fun((adk_content:content()) -> ok)) -> term().
stream_content(Config, Memory, Tools, Callback)
  when is_function(Callback, 1) ->
    stream_mode(Config, Memory, Tools, Callback, content);
stream_content(_Config, _Memory, _Tools, _Callback) ->
    {error, invalid_stream_callback}.

capabilities() ->
    #{generate => true,
      streaming => true,
      content_streaming => true,
      function_calling => true,
      parallel_function_calling => true,
      function_call_ids => true,
      structured_output => true,
      multimodal => true,
      content_schema_version => adk_content:codec_version(),
      input_content_parts => [text, inline_data, file_data,
                              function_call, function_response],
      output_content_parts => [text, function_call],
      api => responses,
      live => false}.

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config0) when is_map(Config0) ->
    Config = with_defaults(Config0),
    case unknown_config_keys(Config0) of
        [] ->
            case first_error(
                   [validate_nonempty_binary(model, Config),
                    validate_optional_header(organization, Config),
                    validate_optional_header(project, Config),
                    validate_optional_api_key(Config),
                    adk_model_http_client:validate_https_base_url(Config),
                    validate_credential_origin(Config),
                    adk_model_http_client:validate_options(Config)]) of
                ok -> validate_codec_options(Config);
                {error, _} = Error -> Error
            end;
        Unknown -> {error, {unknown_openai_options, Unknown}}
    end;
validate_config(_Config) ->
    {error, invalid_openai_config}.

-spec public_config(map()) -> map().
public_config(Config) when is_map(Config) ->
    adk_secret_redactor:redact(maps:without([http_transport], Config));
public_config(_Config) -> #{}.

perform_generate(Config, ApiKey, Payload) ->
    case adk_model_http_client:request(
           Config, <<"/responses">>, headers(Config, ApiKey), Payload) of
        {ok, #{status := Status, body := Body}}
          when Status >= 200, Status < 300 ->
            case decode_json(Body) of
                {ok, Response} ->
                    case adk_openai_responses_codec:decode_response(
                           Response, Config) of
                        {ok, ProviderResult} -> ProviderResult;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {ok, #{status := Status, body := Body}} ->
            openai_http_error(Status, Body);
        {error, _} = Error -> Error
    end.

stream_mode(Config0, Memory, Tools, Callback, Mode) ->
    Config = with_defaults(Config0),
    case {validate_config(Config0),
          resolve_api_key(Config),
          adk_openai_responses_codec:encode_request(
            Config, Memory, Tools, true)} of
        {ok, {ok, ApiKey}, {ok, Payload}} ->
            perform_stream(Config, ApiKey, Payload, Callback, Mode);
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

perform_stream(Config, ApiKey, Payload, Callback, Mode) ->
    {ok, Provider0} = adk_openai_responses_stream:new(Config),
    Key = {?MODULE, make_ref()},
    put(Key, #{sse => new_sse_decoder(),
               provider => Provider0}),
    RawCallback = fun(Chunk) ->
        consume_stream_chunk(Key, Chunk, Callback, Mode)
    end,
    try adk_model_http_client:stream(
          Config, <<"/responses">>, headers(Config, ApiKey), Payload,
          RawCallback) of
        {ok, #{status := Status}} when Status >= 200, Status < 300 ->
            finish_stream(Key, Callback, Mode);
        {ok, #{status := Status, body := Body}} ->
            openai_http_error(Status, Body);
        {error, _} = Error -> Error
    after
        erase(Key)
    end.

consume_stream_chunk(Key, Chunk, Callback, Mode) ->
    #{sse := Sse0} = State0 = get(Key),
    case adk_model_sse_decoder:feed(Sse0, Chunk) of
        {ok, Events, Sse1} ->
            case consume_sse_events(Events, State0#{sse => Sse1},
                                    Callback, Mode) of
                {ok, State1} -> put(Key, State1), ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

finish_stream(Key, Callback, Mode) ->
    #{sse := Sse0} = State0 = get(Key),
    case adk_model_sse_decoder:finish(Sse0) of
        {ok, Events} ->
            case consume_sse_events(Events, State0, Callback, Mode) of
                {ok, #{provider := Provider1}} ->
                    case adk_openai_responses_stream:finish(Provider1) of
                        {ok, ProviderResult} -> ProviderResult;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

consume_sse_events([], State, _Callback, _Mode) -> {ok, State};
consume_sse_events([#{data := <<"[DONE]">>} | Rest],
                   State, Callback, Mode) ->
    consume_sse_events(Rest, State, Callback, Mode);
consume_sse_events([#{data := Data} | Rest],
                   #{provider := Provider0} = State, Callback, Mode) ->
    case decode_json(Data) of
        {ok, Event} ->
            case adk_openai_responses_stream:decode_event(Event, Provider0) of
                {ok, LogicalEvents, Provider1} ->
                    case emit(LogicalEvents, Callback, Mode) of
                        ok -> consume_sse_events(
                                Rest, State#{provider => Provider1},
                                Callback, Mode);
                        {error, _} = Error -> Error
                    end;
                {error, Reason, _FailedState} -> {error, Reason}
            end;
        {error, _} = Error -> Error
    end;
consume_sse_events([_Invalid | _Rest], _State, _Callback, _Mode) ->
    {error, invalid_openai_sse_event}.

emit([], _Callback, _Mode) -> ok;
emit([{text_delta, <<>>} | Rest], Callback, Mode) ->
    emit(Rest, Callback, Mode);
emit([{text_delta, Text} | Rest], Callback, text) ->
    case invoke_user_callback(Callback, Text) of
        ok -> emit(Rest, Callback, text);
        {error, _} = Error -> Error
    end;
emit([{text_delta, Text} | Rest], Callback, content) ->
    case adk_content:text(Text) of
        {ok, Part} ->
            {ok, Content} = adk_content:new([Part]),
            case invoke_user_callback(Callback, Content) of
                ok -> emit(Rest, Callback, content);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
emit([_ToolOrCompletionEvent | Rest], Callback, Mode) ->
    emit(Rest, Callback, Mode).

invoke_user_callback(Callback, Value) ->
    try Callback(Value) of
        ok -> ok;
        _ -> {error, invalid_stream_callback_result}
    catch
        Class:_Reason -> {error, {stream_callback_failed, Class}}
    end.

openai_http_error(Status, Body) ->
    Reason = case decode_json(Body) of
        {ok, ErrorBody} ->
            {error, Decoded} =
                adk_openai_responses_codec:decode_api_error(ErrorBody),
            Decoded;
        {error, _} -> {openai_api_error, <<"unknown">>}
    end,
    {error, {http_status, Status, Reason}}.

decode_json(Body) when is_binary(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Map when is_map(Map) -> {ok, Map};
        _ -> {error, invalid_openai_response_json}
    catch
        _:_ -> {error, invalid_openai_response_json}
    end.

headers(Config, ApiKey) ->
    Base = [{<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json">>},
            {<<"authorization">>, <<"Bearer ", ApiKey/binary>>}],
    WithOrganization = put_header(
                         <<"openai-organization">>, organization,
                         Config, Base),
    put_header(<<"openai-project">>, project, Config, WithOrganization).

put_header(Name, Key, Config, Headers) ->
    case maps:find(Key, Config) of
        {ok, Value} -> [{Name, Value} | Headers];
        error -> Headers
    end.

with_defaults(Config) when is_map(Config) ->
    Config#{base_url => maps:get(base_url, Config, ?DEFAULT_BASE_URL)};
with_defaults(Config) -> Config.

%% A terminal Responses event can contain the complete bounded text or
%% function payload in addition to its JSON envelope. Keep this aligned with
%% the provider codec's 8 MiB content ceiling plus bounded wire headroom.
new_sse_decoder() ->
    adk_model_sse_decoder:new(
      #{max_buffer_bytes => ?MAX_SSE_EVENT_BYTES,
        max_event_bytes => ?MAX_SSE_EVENT_BYTES,
        max_events_per_feed => 4096}).

validate_codec_options(Config) ->
    ValidationHistory = [#{role => user, content => <<"validation">>}],
    case adk_openai_responses_codec:encode_request(
           Config, ValidationHistory, [], false) of
        {ok, _} ->
            case adk_openai_responses_stream:new(Config) of
                {ok, _} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_nonempty_binary(Key, Config) ->
    case maps:get(Key, Config, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 ->
            case has_control(Value) of
                false -> ok;
                true -> {error, {invalid_openai_option, Key}}
            end;
        _ -> {error, {invalid_openai_option, Key}}
    end.

validate_optional_header(Key, Config) ->
    case maps:find(Key, Config) of
        error -> ok;
        {ok, Value} when is_binary(Value), byte_size(Value) > 0,
                         byte_size(Value) =< 1024 ->
            case has_control(Value) of
                false -> ok;
                true -> {error, {invalid_openai_option, Key}}
            end;
        {ok, _} -> {error, {invalid_openai_option, Key}}
    end.

validate_optional_api_key(Config) ->
    case maps:find(api_key, Config) of
        error -> ok;
        {ok, Value} ->
            case adk_model_http_client:resolve_api_key(
                   #{api_key => Value}, "OPENAI_API_KEY") of
                {ok, _} -> ok;
                {error, _} ->
                    {error, {invalid_openai_option, api_key, redacted}}
            end
    end.

validate_credential_origin(Config) ->
    case adk_model_http_client:base_url_matches(
           Config, ?DEFAULT_BASE_URL) orelse maps:is_key(api_key, Config) of
        true -> ok;
        false -> {error, custom_endpoint_requires_explicit_api_key}
    end.

resolve_api_key(Config) ->
    adk_model_http_client:resolve_bound_api_key(
      Config, "OPENAI_API_KEY", ?DEFAULT_BASE_URL).

first_error([]) -> ok;
first_error([ok | Rest]) -> first_error(Rest);
first_error([{error, _} = Error | _]) -> Error.

unknown_config_keys(Config) ->
    lists:sort(maps:keys(maps:without(known_config_keys(), Config))).

known_config_keys() ->
    [provider, model, base_url, api_key, organization, project,
     temperature, top_p, max_tokens, max_output_tokens,
     parallel_tool_calls, store, response_mime_type, response_schema,
     response_schema_name, content_limits, max_stream_events,
     request_timeout, max_response_bytes, allow_private_hosts,
     http_transport,
     instructions, global_instruction, input_schema, output_schema,
     generation_config, history_policy, include_history, include_contents,
     output_key, required_capabilities, instruction_timeout_ms,
     artifact_timeout_ms, max_instruction_bytes,
     session_id, session_store, sub_agents, callbacks, callback_config,
     callback_pid, max_tool_rounds, app_name, user_id, artifact_svc,
     artifact_service, agent_turn_timeout, max_concurrent_invocations,
     '$adk_invocation_context_api', '$adk_inherited_global_instruction'].

has_control(Binary) ->
    lists:any(fun(Byte) -> Byte < 32 orelse Byte =:= 127 end,
              binary_to_list(Binary)).
