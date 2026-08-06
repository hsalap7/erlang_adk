%% @doc Native Vertex AI GenerateContent request adapter.
%%
%% This adapter intentionally supports one narrow Google publisher-model REST
%% contract. A complete resource name determines both HTTPS origin and fixed
%% v1 method paths. OAuth tokens are resolved immediately before a request;
%% callers cannot supply URLs, headers, redirects, private-host policy, or ADC
%% provider handles through a provider profile.
-module(adk_llm_vertex).

-behaviour(adk_llm).

-export([generate/3, stream/4, stream_content/4,
         capabilities/0, validate_config/1, public_config/1]).

-define(MAX_SSE_EVENT_BYTES, 9437184).
-define(DEFAULT_MAX_STREAM_EVENTS, 4096).
-define(HARD_MAX_STREAM_EVENTS, 65536).

-spec generate(map(), list(), list()) -> term().
generate(Config, Memory, Tools) ->
    case validate_config(Config) of
        ok ->
            case prepare_request(Config, Memory, Tools) of
                {ok, Target, Token, Payload} ->
                    perform_generate(Config, Target, Token, Payload);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
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
      thought_signatures => true,
      generation_config => true,
      safety_settings => true,
      structured_output => true,
      multimodal => true,
      content_schema_version => adk_content:codec_version(),
      input_content_parts => [text, inline_data, file_data,
                              function_call, function_response],
      output_content_parts => [text, inline_data, file_data,
                               function_call, function_response],
      supported_file_uri_schemes => [https, gs],
      api => vertex_generate_content,
      auth => oauth2_adc,
      builtin_tools => [],
      context_caching => false,
      thinking => false,
      live => false}.

-spec validate_config(term()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case unknown_config_keys(Config) of
        [] -> validate_known_config(Config);
        Unknown -> {error, {unknown_vertex_options, Unknown}}
    end;
validate_config(_Config) ->
    {error, invalid_vertex_config}.

validate_known_config(Config) ->
    case adk_vertex_model_resource:parse(
           maps:get(model, Config, undefined)) of
        {ok, Target} ->
            first_error(
              [adk_google_adc:validate_config(Config),
               validate_nested_generation_config(Config),
               validate_stream_event_limit(Config),
               validate_shared_config(Config),
               validate_http_config(Config, Target)]);
        {error, _} = Error -> Error
    end.

%% @doc Secret- and handle-free configuration projection.
-spec public_config(term()) -> map().
public_config(Config) when is_map(Config) ->
    adk_secret_redactor:redact(
      maps:without([adc_token_provider, http_transport], Config));
public_config(_Config) -> #{}.

prepare_request(Config, Memory, Tools) ->
    %% Establish the complete request shape before touching ADC. Invalid
    %% caller content must not launch gcloud or invoke an injected token
    %% provider when no HTTPS request can be made.
    case {adk_vertex_model_resource:parse(maps:get(model, Config)),
          adk_llm_gemini:encode_generate_content(
            shared_config(Config), Memory, Tools)} of
        {{ok, Target}, {ok, Payload}} ->
            case adk_google_adc:access_token(Config) of
                {ok, Token} -> {ok, Target, Token, Payload};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

perform_generate(Config, Target, Token, Payload) ->
    HttpConfig = http_config(Config, Target),
    Path = adk_vertex_model_resource:generate_path(Target),
    case adk_model_http_client:request(
           HttpConfig, Path, headers(Token, json), Payload) of
        {ok, #{status := Status, body := Body}}
          when is_integer(Status), Status >= 200, Status < 300 ->
            decode_vertex_generate_response(Body, Config);
        {ok, #{status := Status, body := Body}}
          when is_integer(Status), Status >= 100, Status =< 599 ->
            vertex_http_error(Status, Body);
        {ok, _InvalidResponse} ->
            {error, invalid_vertex_http_response};
        {error, _} = Error -> Error
    end.

stream_mode(Config, Memory, Tools, Callback, Mode) ->
    case validate_config(Config) of
        ok ->
            case prepare_request(Config, Memory, Tools) of
                {ok, Target, Token, Payload} ->
                    perform_stream(
                      Config, Target, Token, Payload, Callback, Mode);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

perform_stream(Config, Target, Token, Payload, Callback, Mode) ->
    MaxEvents = maps:get(max_stream_events, Config,
                         ?DEFAULT_MAX_STREAM_EVENTS),
    Key = {?MODULE, make_ref()},
    put(Key, #{sse => new_sse_decoder(MaxEvents),
               event_count => 0,
               max_events => MaxEvents,
               tool_calls => [],
               done => false}),
    RawCallback = fun(Chunk) ->
        consume_stream_chunk(Key, Chunk, Config, Callback, Mode)
    end,
    HttpConfig = http_config(Config, Target),
    Path = adk_vertex_model_resource:stream_path(Target),
    try adk_model_http_client:stream_sse(
          HttpConfig, Path, headers(Token, sse), Payload, RawCallback) of
        {ok, #{status := Status}}
          when is_integer(Status), Status >= 200, Status < 300 ->
            finish_stream(Key, Config, Callback, Mode);
        {ok, #{status := Status, body := Body}}
          when is_integer(Status), Status >= 100, Status =< 599 ->
            vertex_http_error(Status, Body);
        {ok, _InvalidResponse} ->
            {error, invalid_vertex_http_response};
        {error, _} = Error -> Error
    after
        erase(Key)
    end.

consume_stream_chunk(Key, Chunk, Config, Callback, Mode) ->
    case get(Key) of
        #{sse := Sse0} = State0 when is_binary(Chunk) ->
            case adk_model_sse_decoder:feed(Sse0, Chunk) of
                {ok, Events, Sse1} ->
                    State1 = State0#{sse => Sse1},
                    case consume_sse_events(
                           Events, State1, Config, Callback, Mode) of
                        {ok, State2} -> put(Key, State2), ok;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_vertex_stream_state}
    end.

finish_stream(Key, Config, Callback, Mode) ->
    case get(Key) of
        #{sse := Sse0} = State0 ->
            case adk_model_sse_decoder:finish(Sse0) of
                {ok, Events} ->
                    case consume_sse_events(
                           Events, State0, Config, Callback, Mode) of
                        {ok, #{tool_calls := ReversedCalls}} ->
                            case lists:reverse(ReversedCalls) of
                                [] -> ok;
                                Calls -> {tool_calls, Calls}
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_vertex_stream_state}
    end.

consume_sse_events([], State, _Config, _Callback, _Mode) ->
    {ok, State};
consume_sse_events([#{data := Data} | Rest], State0,
                   Config, Callback, Mode) ->
    case count_stream_event(State0) of
        {ok, State1} ->
            case consume_sse_data(Data, State1, Config, Callback, Mode) of
                {ok, State2} ->
                    consume_sse_events(
                      Rest, State2, Config, Callback, Mode);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

count_stream_event(#{event_count := Count, max_events := Maximum} = State)
  when Count < Maximum ->
    {ok, State#{event_count => Count + 1}};
count_stream_event(_State) ->
    {error, vertex_stream_event_limit_exceeded}.

consume_sse_data(<<"[DONE]">>, State, _Config, _Callback, _Mode) ->
    {ok, State#{done => true}};
consume_sse_data(_Data, #{done := true}, _Config, _Callback, _Mode) ->
    {error, vertex_stream_data_after_completion};
consume_sse_data(Data, State, Config, Callback, Mode) ->
    case decode_vertex_stream_response(Data, Config) of
        {ok, none} -> {ok, State};
        {ok, Content} ->
            case emit_content(Content, Callback, Mode) of
                ok ->
                    Calls = adk_llm_gemini_content:tool_calls(Content),
                    Existing = maps:get(tool_calls, State),
                    {ok, State#{tool_calls =>
                                   lists:reverse(Calls, Existing)}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

%% Successful HTTP response bytes remain untrusted. The shared Gemini codec
%% deliberately returns detailed structural errors for its native adapter;
%% those errors can contain provider-controlled map keys. Collapse them at the
%% Vertex boundary so a malformed response cannot be reflected into logs or
%% caller-visible error terms.
decode_vertex_generate_response(Body, Config) ->
    try adk_llm_gemini:decode_generate_content(
          Body, shared_config(Config)) of
        {error, _} -> {error, invalid_vertex_response};
        Result ->
            case vertex_result(Result) of
                {error, _} -> {error, invalid_vertex_response};
                VertexResult -> VertexResult
            end
    catch
        _:_ -> {error, invalid_vertex_response}
    end.

decode_vertex_stream_response(Data, Config) ->
    try adk_llm_gemini:decode_stream_generate_content(
          Data, shared_config(Config)) of
        {ok, none} = None -> None;
        {ok, Content} -> {ok, Content};
        {error, _} -> {error, invalid_vertex_stream_response}
    catch
        _:_ -> {error, invalid_vertex_stream_response}
    end.

emit_content(Content, Callback, text) ->
    Types = adk_llm_gemini_content:part_types(Content),
    Unsupported = [Type || Type <- Types,
                            Type =/= <<"text">>,
                            Type =/= <<"function_call">>],
    case Unsupported of
        [] -> emit_text_parts(
                visible_text_parts(Content), Callback);
        [Type | _] -> {error, {unsupported_text_stream_part, Type}}
    end;
emit_content(Content, Callback, content) ->
    invoke_user_callback(Callback, Content).

emit_text_parts([], _Callback) -> ok;
emit_text_parts([<<>> | Rest], Callback) ->
    emit_text_parts(Rest, Callback);
emit_text_parts([Text | Rest], Callback) ->
    case invoke_user_callback(Callback, Text) of
        ok -> emit_text_parts(Rest, Callback);
        {error, _} = Error -> Error
    end.

visible_text_parts(Content) ->
    [Text || #{<<"type">> := <<"text">>, <<"text">> := Text} = Part
                 <- adk_content:parts(Content),
             maps:get(<<"thought">>, Part, false) =/= true].

invoke_user_callback(Callback, Value) ->
    try Callback(Value) of
        ok -> ok;
        _ -> {error, invalid_stream_callback_result}
    catch
        Class:_Reason -> {error, {stream_callback_failed, Class}}
    end.

new_sse_decoder(MaxEvents) ->
    adk_model_sse_decoder:new(
      #{max_buffer_bytes => ?MAX_SSE_EVENT_BYTES,
        max_event_bytes => ?MAX_SSE_EVENT_BYTES,
        max_events_per_feed => MaxEvents}).

headers(Token, Accept) ->
    [{<<"content-type">>, <<"application/json">>},
     {<<"accept">>, accept_header(Accept)},
     {<<"authorization">>, <<"Bearer ", Token/binary>>}].

accept_header(json) -> <<"application/json">>;
accept_header(sse) -> <<"text/event-stream">>.

vertex_result({provider_result, _Envelope} = Result) ->
    case adk_provider_result:decode(Result) of
        {ok, Outcome, ProviderMetadata} ->
            case adk_provider_result:new(
                   <<"vertex_ai">>, maps:get(<<"type">>, ProviderMetadata),
                   Outcome, maps:get(<<"metadata">>, ProviderMetadata)) of
                {ok, VertexResult} -> VertexResult;
                {error, Reason} ->
                    {error, {invalid_vertex_response_metadata, Reason}}
            end;
        {error, _} = Error -> Error;
        not_provider_result -> {error, invalid_vertex_provider_result}
    end;
vertex_result(Result) -> Result.

vertex_http_error(Status, Body) ->
    {error, {http_status, Status,
             {vertex_api_error, vertex_error_code(Body)}}}.

vertex_error_code(Body) when is_binary(Body) ->
    try jsx:decode(Body, [return_maps]) of
        #{<<"error">> := #{<<"status">> := Code}}
          when is_binary(Code), byte_size(Code) > 0,
               byte_size(Code) =< 128 ->
            case valid_error_code(Code) of
                true -> Code;
                false -> unknown
            end;
        _ -> unknown
    catch
        _:_ -> unknown
    end.

validate_shared_config(Config) ->
    adk_llm_gemini:validate_config(shared_config(Config)).

validate_http_config(Config, Target) ->
    HttpConfig = http_config(Config, Target),
    first_error([adk_model_http_client:validate_https_base_url(HttpConfig),
                 adk_model_http_client:validate_options(HttpConfig)]).

validate_nested_generation_config(Config) ->
    case maps:find(generation_config, Config) of
        error -> ok;
        {ok, Generation} when is_map(Generation) ->
            Allowed = [temperature, top_p, top_k, max_tokens,
                       max_output_tokens, stop_sequences,
                       response_mime_type, safety_settings],
            case maps:keys(Generation) -- Allowed of
                [] -> ok;
                Unknown ->
                    {error, {unknown_vertex_generation_options,
                             lists:sort(Unknown)}}
            end;
        {ok, _} -> {error, invalid_vertex_generation_config}
    end.

validate_stream_event_limit(Config) ->
    Value = maps:get(max_stream_events, Config,
                     ?DEFAULT_MAX_STREAM_EVENTS),
    case is_integer(Value) andalso Value > 0 andalso
         Value =< ?HARD_MAX_STREAM_EVENTS of
        true -> ok;
        false -> {error, invalid_vertex_stream_event_limit}
    end.

shared_config(Config) ->
    maps:without([credential_source, adc_token_provider,
                  max_stream_events, max_response_bytes,
                  http_transport], Config).

http_config(Config, Target) ->
    (maps:with([request_timeout, max_response_bytes, http_transport],
               Config))#{base_url => maps:get(base_url, Target)}.

first_error([]) -> ok;
first_error([ok | Rest]) -> first_error(Rest);
first_error([{error, _} = Error | _]) -> Error.

unknown_config_keys(Config) ->
    lists:sort(maps:keys(maps:without(known_config_keys(), Config))).

known_config_keys() ->
    [provider, model, api_key, credential_source, adc_token_provider,
     temperature, top_p, top_k, max_tokens, max_output_tokens,
     stop_sequences, response_mime_type, response_schema, safety_settings,
     content_limits, max_stream_events,
     request_timeout, max_response_bytes, http_transport,
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

valid_error_code(Code) ->
    not has_control(Code) andalso
        lists:all(
          fun(Char) ->
              (Char >= $A andalso Char =< $Z) orelse
              (Char >= $0 andalso Char =< $9) orelse Char =:= $_
          end, binary_to_list(Code)).
