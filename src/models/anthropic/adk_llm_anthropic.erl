%% @doc Native Anthropic Messages API provider.
%%
%% Request/response translation is delegated to the pure bounded codecs under
%% `models/anthropic/request'. This module owns credential/header handling,
%% HTTP status classification, and incremental SSE delivery through the shared
%% flow-controlled model transport.
-module(adk_llm_anthropic).

-behaviour(adk_llm).

-export([generate/3, stream/4, stream_content/4,
         capabilities/0, validate_config/1, public_config/1]).

-define(DEFAULT_BASE_URL, <<"https://api.anthropic.com/v1">>).
-define(DEFAULT_VERSION, <<"2023-06-01">>).
-define(MAX_SSE_EVENT_BYTES, 9437184).

-spec generate(map(), list(), list()) -> term().
generate(Config0, Memory, Tools) ->
    Config = with_defaults(Config0),
    case {validate_config(Config0),
          resolve_api_key(Config),
          adk_llm_anthropic_request:build(Config, Memory, Tools, false)} of
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
      structured_output => true,
      multimodal => true,
      content_schema_version => adk_content:codec_version(),
      input_content_parts => [text, inline_data, file_data,
                              function_call, function_response],
      output_content_parts => [text, function_call],
      supported_inline_mime_types =>
          [<<"image/jpeg">>, <<"image/png">>,
           <<"image/gif">>, <<"image/webp">>],
      live => false}.

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config0) when is_map(Config0) ->
    Config = with_defaults(Config0),
    case unknown_config_keys(Config0) of
        [] ->
            first_error(
              [validate_nonempty_binary(model, Config),
               validate_nonempty_binary(anthropic_version, Config),
               validate_optional_api_key(Config),
               adk_model_http_client:validate_https_base_url(Config),
               validate_credential_origin(Config),
               adk_model_http_client:validate_options(Config)]);
        Unknown -> {error, {unknown_anthropic_options, Unknown}}
    end;
validate_config(_Config) ->
    {error, invalid_anthropic_config}.

%% @doc Secret- and handle-free projection for developer tooling.
-spec public_config(map()) -> map().
public_config(Config) when is_map(Config) ->
    adk_secret_redactor:redact(
      maps:without([http_transport], Config));
public_config(_Config) -> #{}.

perform_generate(Config, ApiKey, Payload) ->
    case adk_model_http_client:request(
           Config, <<"/messages">>, headers(Config, ApiKey), Payload) of
        {ok, #{status := Status, body := Body}}
          when Status >= 200, Status < 300 ->
            adk_llm_anthropic_content:decode_response(
              Body, content_limits(Config));
        {ok, #{status := Status, body := Body}} ->
            adk_llm_anthropic_content:decode_error(Status, Body);
        {error, _} = Error -> Error
    end.

stream_mode(Config0, Memory, Tools, Callback, Mode) ->
    Config = with_defaults(Config0),
    case {validate_config(Config0),
          resolve_api_key(Config),
          adk_llm_anthropic_request:build(Config, Memory, Tools, true)} of
        {ok, {ok, ApiKey}, {ok, Payload}} ->
            perform_stream(Config, ApiKey, Payload, Callback, Mode);
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

perform_stream(Config, ApiKey, Payload, Callback, Mode) ->
    Key = {?MODULE, make_ref()},
    State = #{sse => new_sse_decoder(),
              provider => adk_llm_anthropic_stream:new(
                            content_limits(Config)),
              result => undefined},
    put(Key, State),
    RawCallback = fun(Chunk) ->
        consume_stream_chunk(Key, Chunk, Callback, Mode)
    end,
    try adk_model_http_client:stream(
          Config, <<"/messages">>, headers(Config, ApiKey), Payload,
          RawCallback) of
        {ok, #{status := Status}} when Status >= 200, Status < 300 ->
            finish_stream(Key, Callback, Mode);
        {ok, #{status := Status, body := Body}} ->
            adk_llm_anthropic_content:decode_error(Status, Body);
        {error, _} = Error -> Error
    after
        erase(Key)
    end.

consume_stream_chunk(Key, Chunk, Callback, Mode) ->
    #{sse := Sse0} = State0 = get(Key),
    case adk_model_sse_decoder:feed(Sse0, Chunk) of
        {ok, Events, Sse1} ->
            case consume_provider_events(Events, State0#{sse => Sse1},
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
            case consume_provider_events(Events, State0, Callback, Mode) of
                {ok, #{result := undefined}} ->
                    {error, anthropic_stream_not_complete};
                {ok, #{result := Result}} -> Result;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

consume_provider_events([], State, _Callback, _Mode) -> {ok, State};
consume_provider_events([Event | Rest],
                        #{provider := Provider0,
                          result := undefined} = State,
                        Callback, Mode) ->
    case adk_llm_anthropic_stream:feed(Provider0, Event) of
        {ok, Provider1, Emissions} ->
            case emit(Emissions, Callback, Mode) of
                ok -> consume_provider_events(
                        Rest, State#{provider => Provider1}, Callback, Mode);
                {error, _} = Error -> Error
            end;
        {done, Result, Provider1} ->
            consume_provider_events(
              Rest, State#{provider => Provider1, result => Result},
              Callback, Mode);
        {error, _} = Error -> Error
    end;
consume_provider_events([_Event | _Rest],
                        #{result := _Result}, _Callback, _Mode) ->
    {error, anthropic_stream_data_after_completion}.

emit([], _Callback, _Mode) -> ok;
emit([{text, <<>>} | Rest], Callback, Mode) ->
    emit(Rest, Callback, Mode);
emit([{text, Text} | Rest], Callback, text) ->
    case invoke_user_callback(Callback, Text) of
        ok -> emit(Rest, Callback, text);
        {error, _} = Error -> Error
    end;
emit([{text, Text} | Rest], Callback, content) ->
    case adk_content:text(Text) of
        {ok, Part} ->
            {ok, Content} = adk_content:new([Part]),
            case invoke_user_callback(Callback, Content) of
                ok -> emit(Rest, Callback, content);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

invoke_user_callback(Callback, Value) ->
    try Callback(Value) of
        ok -> ok;
        _ -> {error, invalid_stream_callback_result}
    catch
        Class:_Reason -> {error, {stream_callback_failed, Class}}
    end.

headers(Config, ApiKey) ->
    [{<<"content-type">>, <<"application/json">>},
     {<<"accept">>, <<"application/json">>},
     {<<"x-api-key">>, ApiKey},
     {<<"anthropic-version">>, maps:get(anthropic_version, Config)}].

with_defaults(Config) when is_map(Config) ->
    Config#{base_url => maps:get(base_url, Config, ?DEFAULT_BASE_URL),
            anthropic_version => maps:get(
                                   anthropic_version, Config,
                                   ?DEFAULT_VERSION)};
with_defaults(Config) -> Config.

content_limits(Config) -> maps:get(content_limits, Config, #{}).

%% Anthropic content deltas and terminal blocks are bounded at 8 MiB by the
%% logical codec. The shared SSE envelope therefore needs explicit headroom;
%% its conservative 1 MiB generic default would reject valid configured
%% streams before the provider validator saw them.
new_sse_decoder() ->
    adk_model_sse_decoder:new(
      #{max_buffer_bytes => ?MAX_SSE_EVENT_BYTES,
        max_event_bytes => ?MAX_SSE_EVENT_BYTES,
        max_events_per_feed => 4096}).

validate_nonempty_binary(Key, Config) ->
    case maps:get(Key, Config, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 ->
            case has_control(Value) of
                false -> ok;
                true -> {error, {invalid_anthropic_option, Key}}
            end;
        _ -> {error, {invalid_anthropic_option, Key}}
    end.

validate_optional_api_key(Config) ->
    case maps:find(api_key, Config) of
        error -> ok;
        {ok, Value} ->
            case adk_model_http_client:resolve_api_key(
                   #{api_key => Value}, "ANTHROPIC_API_KEY") of
                {ok, _} -> ok;
                {error, _} ->
                    {error, {invalid_anthropic_option, api_key, redacted}}
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
      Config, "ANTHROPIC_API_KEY", ?DEFAULT_BASE_URL).

first_error([]) -> ok;
first_error([ok | Rest]) -> first_error(Rest);
first_error([{error, _} = Error | _]) -> Error.

unknown_config_keys(Config) ->
    lists:sort(maps:keys(maps:without(known_config_keys(), Config))).

known_config_keys() ->
    [provider, model, base_url, api_key, anthropic_version,
     max_tokens, temperature, top_p, top_k, stop_sequences, tool_choice,
     content_limits, request_timeout, max_response_bytes,
     allow_private_hosts, http_transport,
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
