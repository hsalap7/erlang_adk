%% @doc OpenAI-compatible Chat Completions provider.
%%
%% This adapter is intentionally narrower than "arbitrary HTTP".  The
%% operator selects a trusted HTTPS `base_url' (normally through a provider
%% profile), while the adapter owns the fixed `/chat/completions' path and a
%% small allow-list of authentication header shapes.  Callers cannot inject
%% header names, request paths, redirects, or transport authority.
-module(adk_llm_compatible).

-behaviour(adk_llm).

-export([generate/3, stream/4, stream_content/4,
         capabilities/0, capabilities/1,
         validate_config/1, public_config/1]).

-define(SSE_ENVELOPE_BYTES, 9437184).
-define(SSE_EVENTS_PER_FEED, 4096).

-spec generate(map(), list(), list()) -> term().
generate(Config, Memory, Tools) ->
    case {validate_config(Config), resolve_auth_headers(Config),
          adk_llm_compatible_request:build(Config, Memory, Tools, false)} of
        {ok, {ok, AuthHeaders}, {ok, Payload}} ->
            perform_generate(Config, AuthHeaders, Payload);
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

-spec capabilities() -> map().
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
      api => chat_completions,
      live => false}.

%% @doc Config-sensitive capability projection for direct adapter inspection.
%% A vendor profile remains the authoritative place to narrow capabilities;
%% `response_format => unsupported' is reflected for both locked profile
%% policy and trusted legacy configuration.
-spec capabilities(map()) -> map().
capabilities(Config) when is_map(Config) ->
    (capabilities())#{structured_output =>
                          maps:get(response_format, Config, auto) =/=
                              unsupported};
capabilities(_Config) ->
    capabilities().

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case unknown_config_keys(Config) of
        [] ->
            case first_error(
                   [validate_https_base_url(Config),
                    validate_auth_scheme(Config),
                    validate_optional_api_key(Config),
                    validate_auth_credential(Config),
                    adk_model_http_client:validate_options(Config)]) of
                ok -> validate_codec_options(Config);
                {error, _} = Error -> Error
            end;
        Unknown -> {error, {unknown_compatible_options, Unknown}}
    end;
validate_config(_Config) ->
    {error, invalid_compatible_config}.

%% @doc Secret- and injected-handle-free projection for developer tooling.
-spec public_config(map()) -> map().
public_config(Config) when is_map(Config) ->
    adk_secret_redactor:redact(maps:without([http_transport], Config));
public_config(_Config) -> #{}.

perform_generate(Config, AuthHeaders, Payload) ->
    case adk_model_http_client:request(
           Config, <<"/chat/completions">>,
           headers(AuthHeaders), Payload) of
        {ok, #{status := Status, body := Body}}
          when Status >= 200, Status < 300 ->
            case adk_llm_compatible_request:decode_response(Body, Config) of
                {ok, ProviderResult} -> ProviderResult;
                {error, _} = Error -> Error
            end;
        {ok, #{status := Status, body := Body}} ->
            compatible_http_error(Status, Body);
        {error, _} = Error -> Error
    end.

stream_mode(Config, Memory, Tools, Callback, Mode) ->
    case {validate_config(Config), resolve_auth_headers(Config),
          adk_llm_compatible_request:build(Config, Memory, Tools, true)} of
        {ok, {ok, AuthHeaders}, {ok, Payload}} ->
            perform_stream(Config, AuthHeaders, Payload, Callback,
                           emission_mode(Mode, Config));
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

perform_stream(Config, AuthHeaders, Payload, Callback, Mode) ->
    case adk_llm_compatible_stream:new(stream_codec_options(Config)) of
        {ok, Provider0} ->
            Key = {?MODULE, make_ref()},
            put(Key, #{provider => Provider0, result => undefined}),
            RawCallback = fun(Chunk) ->
                consume_stream_chunk(Key, Chunk, Callback, Mode)
            end,
            try adk_model_http_client:stream(
                  Config, <<"/chat/completions">>,
                  headers(AuthHeaders), Payload, RawCallback) of
                {ok, #{status := Status}}
                  when Status >= 200, Status < 300 ->
                    finish_stream(Key);
                {ok, #{status := Status, body := Body}} ->
                    compatible_http_error(Status, Body);
                {error, _} = Error -> Error
            after
                erase(Key)
            end;
        {error, _} = Error -> Error
    end.

consume_stream_chunk(Key, Chunk, Callback, Mode) ->
    case get(Key) of
        #{provider := Provider0, result := undefined} = State0 ->
            case adk_llm_compatible_stream:feed(Provider0, Chunk) of
                {ok, Provider1, Emissions} ->
                    case emit(Emissions, Callback, Mode) of
                        ok -> put(Key, State0#{provider => Provider1}), ok;
                        {error, _} = Error -> Error
                    end;
                {done, Result, Provider1, Emissions} ->
                    case emit(Emissions, Callback, Mode) of
                        ok ->
                            put(Key, State0#{provider => Provider1,
                                            result => Result}),
                            ok;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        #{result := _Result} when Chunk =:= <<>> -> ok;
        #{result := _Result} ->
            {error, compatible_stream_data_after_completion};
        _ -> {error, invalid_compatible_stream_state}
    end.

finish_stream(Key) ->
    case get(Key) of
        #{result := Result} when Result =/= undefined -> Result;
        #{provider := Provider, result := undefined} ->
            case adk_llm_compatible_stream:finish(Provider) of
                {ok, Result} -> Result;
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_compatible_stream_state}
    end.

emit([], _Callback, _Mode) -> ok;
emit([{text, <<>>} | Rest], Callback, Mode) ->
    emit(Rest, Callback, Mode);
emit([{text, Text} | Rest], Callback, text) ->
    case invoke_user_callback(Callback, Text) of
        ok -> emit(Rest, Callback, text);
        {error, _} = Error -> Error
    end;
emit([{text, Text} | Rest], Callback, {content, Limits} = Mode) ->
    Part = #{<<"type">> => <<"text">>, <<"text">> => Text},
    case adk_content:new([Part], Limits) of
        {ok, Content} ->
            case invoke_user_callback(Callback, Content) of
                ok -> emit(Rest, Callback, Mode);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

emission_mode(text, _Config) -> text;
emission_mode(content, Config) ->
    {content, maps:get(content_limits, Config, #{})}.

invoke_user_callback(Callback, Value) ->
    try Callback(Value) of
        ok -> ok;
        _ -> {error, invalid_stream_callback_result}
    catch
        Class:_Reason -> {error, {stream_callback_failed, Class}}
    end.

headers(AuthHeaders) ->
    [{<<"content-type">>, <<"application/json">>},
     {<<"accept">>, <<"application/json">>} | AuthHeaders].

resolve_auth_headers(Config) ->
    case maps:get(auth_scheme, Config, bearer) of
        none -> {ok, []};
        bearer ->
            case adk_model_http_client:resolve_explicit_api_key(Config) of
                {ok, ApiKey} ->
                    {ok, [{<<"authorization">>,
                           <<"Bearer ", ApiKey/binary>>}]};
                {error, _} = Error -> Error
            end;
        x_api_key ->
            case adk_model_http_client:resolve_explicit_api_key(Config) of
                {ok, ApiKey} -> {ok, [{<<"x-api-key">>, ApiKey}]};
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_compatible_auth_scheme}
    end.

compatible_http_error(Status, Body) ->
    case adk_llm_compatible_request:decode_error(Body) of
        {error, Reason} -> {error, {http_status, Status, Reason}}
    end.

%% The compatible stream codec accepts raw SSE bytes.  Its event limit is
%% deliberately one MiB above the maximum canonical text/function payload so
%% JSON/SSE framing does not make a valid maximum-sized logical delta fail at
%% the transport boundary.
stream_codec_options(Config) ->
    Config#{sse_options =>
                #{max_buffer_bytes => ?SSE_ENVELOPE_BYTES,
                  max_event_bytes => ?SSE_ENVELOPE_BYTES,
                  max_events_per_feed => ?SSE_EVENTS_PER_FEED}}.

validate_codec_options(Config) ->
    ValidationHistory = [#{role => user, content => <<"validation">>}],
    case adk_llm_compatible_request:build(
           Config, ValidationHistory, [], true) of
        {ok, _} ->
            case adk_llm_compatible_stream:new(stream_codec_options(Config)) of
                {ok, _} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_https_base_url(Config) ->
    case maps:get(base_url, Config, undefined) of
        Base when is_binary(Base), byte_size(Base) > 0 ->
            try uri_string:parse(Base) of
                #{scheme := Scheme} when is_binary(Scheme) ->
                    case unicode:characters_to_binary(
                           string:lowercase(Scheme)) of
                        <<"https">> -> ok;
                        _ -> {error, compatible_https_base_url_required}
                    end;
                _ -> {error, invalid_compatible_base_url}
            catch
                _:_ -> {error, invalid_compatible_base_url}
            end;
        _ -> {error, invalid_compatible_base_url}
    end.

validate_auth_scheme(Config) ->
    Scheme = maps:get(auth_scheme, Config, bearer),
    case lists:member(Scheme, [bearer, x_api_key, none]) of
        true -> ok;
        false -> {error, invalid_compatible_auth_scheme}
    end.

validate_optional_api_key(Config) ->
    case maps:find(api_key, Config) of
        error -> ok;
        {ok, Value} ->
            case adk_model_http_client:resolve_api_key(
                   #{api_key => Value}, "OPENAI_COMPATIBLE_API_KEY") of
                {ok, _} -> ok;
                {error, _} ->
                    {error, {invalid_compatible_option,
                             api_key, redacted}}
            end
    end.

validate_auth_credential(Config) ->
    case maps:get(auth_scheme, Config, bearer) of
        none -> ok;
        Scheme when Scheme =:= bearer; Scheme =:= x_api_key ->
            case maps:is_key(api_key, Config) of
                true -> ok;
                false -> {error, compatible_api_key_required}
            end;
        _ -> ok
    end.

first_error([]) -> ok;
first_error([ok | Rest]) -> first_error(Rest);
first_error([{error, _} = Error | _]) -> Error.

unknown_config_keys(Config) ->
    lists:sort(maps:keys(maps:without(known_config_keys(), Config))).

known_config_keys() ->
    [provider, model, base_url, api_key, auth_scheme,
     temperature, top_p, max_tokens, max_completion_tokens,
     stop_sequences, parallel_tool_calls, tool_choice,
     response_format, response_mime_type, response_schema,
     response_schema_name, stream_include_usage,
     content_limits, max_stream_events,
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
