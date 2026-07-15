%% @doc Bounded OTLP/HTTP JSON exporter for Erlang ADK observability signals.
%%
%% This module performs one HTTP request per accepted envelope and never
%% retries by itself.  Transient/permanent classification is returned in a
%% redacted structural error; the supervised observability bus owns retry and
%% backoff policy.  Redirects are disabled and neither response bodies,
%% endpoints nor configured header values appear in returned errors.
-module(adk_otlp_http_json_exporter).
-behaviour(adk_observability_exporter).

-export([export/2, validate_config/1]).

-define(DEFAULT_ENDPOINT, <<"http://localhost:4318">>).
-define(DEFAULT_TRACES_PATH, <<"/v1/traces">>).
-define(DEFAULT_LOGS_PATH, <<"/v1/logs">>).
-define(DEFAULT_TIMEOUT_MS, 10000).
-define(DEFAULT_MAX_REQUEST_BYTES, 1048576).
-define(DEFAULT_MAX_RESPONSE_BYTES, 65536).
-define(MAX_ENDPOINT_BYTES, 2048).
-define(MAX_PATH_BYTES, 2048).
-define(MAX_HEADERS, 32).
-define(MAX_HEADER_NAME_BYTES, 128).
-define(MAX_HEADER_VALUE_BYTES, 8192).
-define(MAX_HEADER_BYTES, 32768).
-define(MAX_RETRY_AFTER_SECONDS, 86400).

-spec validate_config(map()) -> {ok, map()} | {error, term()}.
validate_config(Config0) when is_map(Config0) ->
    Defaults = #{endpoint => ?DEFAULT_ENDPOINT,
                 path => ?DEFAULT_TRACES_PATH,
                 logs_path => ?DEFAULT_LOGS_PATH,
                 headers => #{},
                 timeout_ms => ?DEFAULT_TIMEOUT_MS,
                 max_request_bytes => ?DEFAULT_MAX_REQUEST_BYTES,
                 max_response_bytes => ?DEFAULT_MAX_RESPONSE_BYTES,
                 transport => adk_openapi_gun_transport,
                 transport_handle => undefined,
                 allow_private_hosts => true},
    Allowed = maps:keys(Defaults),
    case maps:keys(Config0) -- Allowed of
        [] -> validate_values(maps:merge(Defaults, Config0));
        _ -> {error, invalid_otlp_exporter_config}
    end;
validate_config(_) ->
    {error, invalid_otlp_exporter_config}.

-spec export(map(), map()) -> ok | {error, term()}.
export(Envelope, Config0) when is_map(Envelope), is_map(Config0) ->
    case validate_config(Config0) of
        {ok, Config} -> export_checked(Envelope, Config);
        {error, _} = Error -> Error
    end;
export(_, _) ->
    {error, invalid_otlp_export_arguments}.

validate_values(Config) ->
    case {parse_origin(maps:get(endpoint, Config)),
          validate_path(maps:get(path, Config)),
          validate_path(maps:get(logs_path, Config)),
          validate_headers(maps:get(headers, Config)),
          validate_transport(maps:get(transport, Config)),
          valid_limit(maps:get(timeout_ms, Config), 50, 120000),
          valid_limit(maps:get(max_request_bytes, Config), 1024, 16777216),
          valid_limit(maps:get(max_response_bytes, Config), 2, 1048576),
          is_boolean(maps:get(allow_private_hosts, Config))} of
        {{ok, Origin}, {ok, TracesPath}, {ok, LogsPath},
         {ok, Headers}, ok, true, true, true, true} ->
            {ok, Config#{origin => Origin,
                         path => TracesPath,
                         logs_path => LogsPath,
                         headers => Headers}};
        _ -> {error, invalid_otlp_exporter_config}
    end.

export_checked(Envelope, Config) ->
    case adk_otlp_json:to_request(Envelope) of
        {skip, incomplete_span} -> ok;
        {ok, Signal, Payload} ->
            encode_and_send(Signal, Payload, Config);
        {error, Reason} -> permanent(mapping_reason(Reason), #{})
    end.

encode_and_send(Signal, Payload, Config) ->
    try jsx:encode(Payload) of
        Body when is_binary(Body) ->
            case byte_size(Body) =< maps:get(max_request_bytes, Config) of
                true -> send_request(Signal, Body, Config);
                false -> permanent(request_too_large, #{})
            end
    catch
        _:_ -> permanent(json_encoding_failed, #{})
    end.

send_request(Signal, Body, Config) ->
    Origin = maps:get(origin, Config),
    Path = case Signal of
        traces -> maps:get(path, Config);
        logs -> maps:get(logs_path, Config)
    end,
    Url = endpoint_url(Origin, Path),
    Headers = fixed_headers() ++ maps:get(headers, Config),
    Request = #{method => <<"POST">>, url => Url, headers => Headers,
                body => Body,
                timeout_ms => maps:get(timeout_ms, Config),
                max_response_bytes => maps:get(max_response_bytes, Config),
                follow_redirects => false,
                allowed_schemes => [maps:get(scheme, Origin)],
                allowed_hosts => [maps:get(host, Origin)],
                allow_private_hosts =>
                    maps:get(allow_private_hosts, Config)},
    call_transport(Request, Config).

call_transport(Request, Config) ->
    Module = maps:get(transport, Config),
    Handle = maps:get(transport_handle, Config),
    try Module:request(Handle, Request) of
        {ok, Response} -> handle_response(Response, Config);
        {error, Reason} ->
            transient(transport_reason(Reason), #{});
        _ -> transient(invalid_transport_result, #{})
    catch
        _:_ -> transient(transport_exception, #{})
    end.

handle_response(#{status := Status, headers := Headers, body := Body}, Config)
  when is_integer(Status), Status >= 100, Status =< 599,
       is_binary(Body) ->
    case byte_size(Body) =< maps:get(max_response_bytes, Config) of
        false -> transient(response_too_large, #{});
        true when Status =:= 200 -> successful_response(Headers, Body);
        true -> failed_status(Status, Headers)
    end;
handle_response(_, _Config) ->
    transient(invalid_transport_response, #{}).

successful_response(Headers, Body) ->
    case bounded_response_headers(Headers) of
        {ok, CheckedHeaders} ->
            case content_type(CheckedHeaders) of
                <<"application/json">> -> decode_success_body(Body);
                _ -> permanent(invalid_response_content_type, #{})
            end;
        error -> transient(invalid_response_headers, #{})
    end.

decode_success_body(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Map when is_map(Map) -> partial_success(Map);
        _ -> permanent(invalid_success_response, #{})
    catch
        _:_ -> permanent(invalid_success_response, #{})
    end.

partial_success(#{<<"partialSuccess">> := Partial})
  when is_map(Partial) ->
    case parse_non_negative_int64(
           maps:get(<<"rejectedSpans">>, Partial,
                    maps:get(<<"rejectedLogRecords">>, Partial, 0))) of
        {ok, 0} -> ok;
        {ok, Count} -> permanent(partial_success_rejected,
                                 #{rejected_items => Count});
        error -> permanent(invalid_success_response, #{})
    end;
partial_success(_Map) -> ok.

failed_status(Status, Headers) ->
    Fields0 = #{status => Status},
    Fields = case retry_after_ms(Headers) of
        undefined -> Fields0;
        RetryAfter -> Fields0#{retry_after_ms => RetryAfter}
    end,
    case lists:member(Status, [429, 502, 503, 504]) of
        true -> transient(http_status, Fields);
        false -> permanent(http_status, Fields)
    end.

transient(Reason, Fields) ->
    failure(transient, true, Reason, Fields).

permanent(Reason, Fields) ->
    failure(permanent, false, Reason, Fields).

failure(Classification, Retryable, Reason, Fields) ->
    Public = Fields#{classification => Classification,
                     retryable => Retryable,
                     reason => Reason},
    {error, {otlp_export_failed, Public}}.

parse_origin(Endpoint)
  when is_binary(Endpoint), byte_size(Endpoint) > 0,
       byte_size(Endpoint) =< ?MAX_ENDPOINT_BYTES ->
    try uri_string:parse(Endpoint) of
        #{scheme := Scheme0, host := Host0} = Uri
          when is_binary(Scheme0), is_binary(Host0),
               byte_size(Host0) > 0, byte_size(Host0) =< 253 ->
            Scheme = ascii_lower(Scheme0),
            Host = ascii_lower(Host0),
            Port = maps:get(port, Uri, default_port(Scheme)),
            Path = maps:get(path, Uri, <<>>),
            Safe = not maps:is_key(userinfo, Uri) andalso
                   not maps:is_key(query, Uri) andalso
                   not maps:is_key(fragment, Uri) andalso
                   (Path =:= <<>> orelse Path =:= <<"/">>) andalso
                   valid_host(Host) andalso valid_port(Port),
            case lists:member(Scheme, [<<"http">>, <<"https">>]) andalso
                 Safe of
                true -> {ok, #{scheme => Scheme, host => Host, port => Port}};
                false -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end;
parse_origin(_) -> error.

validate_path(Path)
  when is_binary(Path), byte_size(Path) > 0,
       byte_size(Path) =< ?MAX_PATH_BYTES ->
    case Path of
        <<"/">> -> {ok, Path};
        <<"/", Next, _/binary>> when Next =/= $/ ->
            case valid_path_bytes(Path) of
                true -> {ok, Path};
                false -> error
            end;
        _ -> error
    end;
validate_path(_) -> error.

validate_headers(Headers) when is_map(Headers),
                               map_size(Headers) =< ?MAX_HEADERS ->
    validate_header_list(lists:sort(maps:to_list(Headers)), [], 0, #{});
validate_headers(Headers) when is_list(Headers),
                               length(Headers) =< ?MAX_HEADERS ->
    validate_header_list(Headers, [], 0, #{});
validate_headers(_) -> error.

validate_header_list([], Acc, _Bytes, _Seen) -> {ok, lists:reverse(Acc)};
validate_header_list([{Name0, Value} | Rest], Acc, Bytes, Seen)
  when is_binary(Name0), is_binary(Value),
       byte_size(Name0) > 0,
       byte_size(Name0) =< ?MAX_HEADER_NAME_BYTES,
       byte_size(Value) =< ?MAX_HEADER_VALUE_BYTES ->
    Name = ascii_lower(Name0),
    NewBytes = Bytes + byte_size(Name) + byte_size(Value),
    case header_name(Name) andalso header_value(Value) andalso
         not reserved_header(Name) andalso NewBytes =< ?MAX_HEADER_BYTES andalso
         not maps:is_key(Name, Seen) of
        true -> validate_header_list(Rest, [{Name, Value} | Acc], NewBytes,
                                     Seen#{Name => true});
        false -> error
    end;
validate_header_list(_, _, _, _) -> error.

validate_transport(Module) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, request, 2) of
                true -> ok;
                false -> error
            end;
        _ -> error
    end;
validate_transport(_) -> error.

endpoint_url(#{scheme := Scheme, host := Host, port := Port}, Path) ->
    Uri = #{scheme => Scheme, host => Host, port => Port, path => Path},
    unicode:characters_to_binary(uri_string:recompose(Uri)).

fixed_headers() ->
    [{<<"content-type">>, <<"application/json">>},
     {<<"accept">>, <<"application/json">>},
     {<<"user-agent">>, <<"erlang-adk-otlp-http-json/0.7.0">>}].

bounded_response_headers(Headers) when is_list(Headers), length(Headers) =< 128 ->
    bounded_response_headers(Headers, [], 0);
bounded_response_headers(_) -> error.

bounded_response_headers([], Acc, _Bytes) -> {ok, lists:reverse(Acc)};
bounded_response_headers([{Name0, Value} | Rest], Acc, Bytes)
  when is_binary(Name0), is_binary(Value),
       byte_size(Name0) =< ?MAX_HEADER_NAME_BYTES,
       byte_size(Value) =< ?MAX_HEADER_VALUE_BYTES ->
    Name = ascii_lower(Name0),
    NewBytes = Bytes + byte_size(Name) + byte_size(Value),
    case header_name(Name) andalso header_value(Value) andalso
         NewBytes =< 65536 of
        true -> bounded_response_headers(Rest,
                                         [{Name, Value} | Acc], NewBytes);
        false -> error
    end;
bounded_response_headers(_, _, _) -> error.

content_type(Headers) ->
    case [Value || {<<"content-type">>, Value} <- Headers] of
        [Value] ->
            [MediaType | _] = binary:split(ascii_lower(Value), <<";">>),
            trim_ascii(MediaType);
        _ -> undefined
    end.

retry_after_ms(Headers) ->
    case bounded_response_headers(Headers) of
        {ok, Checked} ->
            case [Value || {<<"retry-after">>, Value} <- Checked] of
                [Value] -> retry_after_delta(Value);
                _ -> undefined
            end;
        error -> undefined
    end.

retry_after_delta(Value) ->
    try binary_to_integer(trim_ascii(Value)) of
        Seconds when Seconds >= 0, Seconds =< ?MAX_RETRY_AFTER_SECONDS ->
            Seconds * 1000;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

parse_non_negative_int64(Value) when is_integer(Value), Value >= 0,
                                     Value =< 9223372036854775807 ->
    {ok, Value};
parse_non_negative_int64(Value) when is_binary(Value), byte_size(Value) > 0,
                                     byte_size(Value) =< 19 ->
    try binary_to_integer(Value) of
        Number when Number >= 0, Number =< 9223372036854775807 ->
            {ok, Number};
        _ -> error
    catch
        _:_ -> error
    end;
parse_non_negative_int64(_) -> error.

mapping_reason(content_bearing_envelope_not_exportable) ->
    content_capture_not_exportable;
mapping_reason(invalid_otlp_span_signal) -> invalid_span;
mapping_reason(invalid_otlp_log_envelope) -> invalid_log_envelope;
mapping_reason(forbidden_otlp_attribute) -> forbidden_attribute;
mapping_reason(invalid_otlp_attributes) -> invalid_attributes;
mapping_reason(otlp_attribute_depth_exceeded) -> attribute_limit;
mapping_reason(invalid_otlp_attribute_value) -> invalid_attribute_value;
mapping_reason({unsupported_otlp_source_schema, _}) -> unsupported_schema;
mapping_reason(_) -> mapping_failed.

transport_reason(timeout) -> timeout;
transport_reason(connect_failed) -> connect_failed;
transport_reason(dns_resolution_failed) -> dns_resolution_failed;
transport_reason(response_too_large) -> response_too_large;
transport_reason(transport_failed) -> transport_failed;
transport_reason(invalid_response) -> invalid_transport_response;
transport_reason(_) -> transport_failed.

reserved_header(Name) ->
    lists:member(Name,
                 [<<"content-type">>, <<"content-length">>,
                  <<"transfer-encoding">>, <<"host">>, <<"connection">>,
                  <<"user-agent">>, <<"accept">>, <<"accept-encoding">>]).

header_name(Name) ->
    lists:all(fun header_name_char/1, binary_to_list(Name)).

header_name_char(Char) when Char >= $a, Char =< $z -> true;
header_name_char(Char) when Char >= $0, Char =< $9 -> true;
header_name_char($!) -> true;
header_name_char($#) -> true;
header_name_char($$) -> true;
header_name_char($%) -> true;
header_name_char($&) -> true;
header_name_char($') -> true;
header_name_char($*) -> true;
header_name_char($+) -> true;
header_name_char($-) -> true;
header_name_char($.) -> true;
header_name_char($^) -> true;
header_name_char($_) -> true;
header_name_char($`) -> true;
header_name_char($|) -> true;
header_name_char($~) -> true;
header_name_char(_) -> false.

header_value(Value) ->
    lists:all(fun(Byte) -> Byte >= 32 andalso Byte =/= 127 end,
              binary_to_list(Value)).

valid_path_bytes(Path) ->
    valid_path_bytes(Path, normal).

valid_path_bytes(<<>>, normal) -> true;
valid_path_bytes(<<$%, High, Low, Rest/binary>>, normal) ->
    hex_char(High) andalso hex_char(Low) andalso
    valid_path_bytes(Rest, normal);
valid_path_bytes(<<Byte, Rest/binary>>, normal)
  when Byte >= 16#21, Byte =< 16#7e,
       Byte =/= $?, Byte =/= $#, Byte =/= $\ ->
    valid_path_bytes(Rest, normal);
valid_path_bytes(_, normal) -> false.

valid_host(Host) ->
    not has_control(Host) andalso
    lists:all(fun host_char/1, binary_to_list(Host)) andalso
    (valid_ip_text(Host) orelse valid_dns_host(Host)).

host_char(Char) when Char >= $a, Char =< $z -> true;
host_char(Char) when Char >= $0, Char =< $9 -> true;
host_char($.) -> true;
host_char($-) -> true;
host_char($:) -> true;
host_char(_) -> false.

valid_ip_text(Host) ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _Address} -> true;
        {error, _} -> false
    end.

valid_dns_host(Host) ->
    Labels0 = binary:split(Host, <<".">>, [global]),
    Labels = case lists:reverse(Labels0) of
        [<<>> | Rest] -> lists:reverse(Rest);
        _ -> Labels0
    end,
    Labels =/= [] andalso lists:all(fun valid_dns_label/1, Labels).

valid_dns_label(Label) when byte_size(Label) >= 1,
                            byte_size(Label) =< 63 ->
    dns_alnum(binary:first(Label)) andalso
    dns_alnum(binary:last(Label)) andalso
    lists:all(fun(Char) -> dns_alnum(Char) orelse Char =:= $- end,
              binary_to_list(Label));
valid_dns_label(_) -> false.

dns_alnum(Char) when Char >= $a, Char =< $z -> true;
dns_alnum(Char) when Char >= $0, Char =< $9 -> true;
dns_alnum(_) -> false.

hex_char(Char) when Char >= $0, Char =< $9 -> true;
hex_char(Char) when Char >= $a, Char =< $f -> true;
hex_char(Char) when Char >= $A, Char =< $F -> true;
hex_char(_) -> false.

has_control(Binary) ->
    lists:any(fun(Byte) -> Byte < 32 orelse Byte =:= 127 end,
              binary_to_list(Binary)).

valid_port(Port) -> is_integer(Port) andalso Port > 0 andalso Port =< 65535.

default_port(<<"http">>) -> 80;
default_port(<<"https">>) -> 443;
default_port(_) -> invalid.

valid_limit(Value, Min, Max) ->
    is_integer(Value) andalso Value >= Min andalso Value =< Max.

ascii_lower(Value) ->
    << <<(ascii_lower_byte(Byte))>> || <<Byte>> <= Value >>.

ascii_lower_byte(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
ascii_lower_byte(Byte) -> Byte.

trim_ascii(Value) ->
    trim_ascii_right(trim_ascii_left(Value)).

trim_ascii_left(<<Byte, Rest/binary>>) when Byte =:= $\s; Byte =:= $\t ->
    trim_ascii_left(Rest);
trim_ascii_left(Value) -> Value.

trim_ascii_right(<<>>) -> <<>>;
trim_ascii_right(Value) ->
    case binary:last(Value) of
        Byte when Byte =:= $\s; Byte =:= $\t ->
            trim_ascii_right(binary:part(Value, 0, byte_size(Value) - 1));
        _ -> Value
    end.
