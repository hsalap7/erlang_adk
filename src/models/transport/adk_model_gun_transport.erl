%% @doc Bounded model HTTP/SSE transport backed by Gun.
%%
%% Ordinary requests reuse the hardened OpenAPI implementation. Streaming
%% requests resolve first, reject non-global addresses by default, connect to
%% the selected address directly, retain the original host for TLS/Host, use
%% Gun flow control, and execute the chunk callback inline for backpressure.
-module(adk_model_gun_transport).

-behaviour(adk_model_http_transport).

-export([request/2, stream/3]).

-define(MAX_BODY_BYTES, 33554432).
-define(MAX_URL_BYTES, 16384).
-define(MAX_HEADER_BYTES, 65536).

-spec request(adk_model_http_transport:handle(),
              adk_model_http_transport:request()) ->
    {ok, adk_model_http_transport:response()} | {error, term()}.
request(Handle, #{headers := Headers} = Request) ->
    case adk_model_http_headers:validate(Headers) of
        ok -> adk_openapi_gun_transport:request(Handle, Request);
        {error, _} -> {error, invalid_request}
    end;
request(_Handle, _Request) ->
    {error, invalid_request}.

-spec stream(adk_model_http_transport:handle(),
             adk_model_http_transport:request(),
             adk_model_http_transport:chunk_callback()) ->
    {ok, adk_model_http_transport:response()} | {error, term()}.
stream(_Handle, Request, Callback)
  when is_map(Request), is_function(Callback, 1) ->
    case normalize_request(Request) of
        {ok, Target} -> perform(Target, Callback);
        {error, _} = Error -> Error
    end;
stream(_Handle, _Request, _Callback) ->
    {error, invalid_request}.

normalize_request(Request) ->
    Required = [method, url, headers, body, timeout_ms,
                max_response_bytes, follow_redirects, allowed_schemes,
                allowed_hosts, allow_private_hosts],
    case lists:all(fun(Key) -> maps:is_key(Key, Request) end, Required) of
        false -> {error, invalid_request};
        true -> normalize_required(Request)
    end.

normalize_required(#{method := Method, url := Url, headers := Headers,
                     body := Body, timeout_ms := Timeout,
                     max_response_bytes := MaxBytes,
                     follow_redirects := false,
                     allowed_schemes := AllowedSchemes,
                     allowed_hosts := AllowedHosts,
                     allow_private_hosts := AllowPrivate})
  when is_binary(Method), byte_size(Method) > 0,
       is_binary(Url), byte_size(Url) > 0,
       byte_size(Url) =< ?MAX_URL_BYTES,
       is_list(Headers), is_binary(Body),
       byte_size(Body) =< ?MAX_BODY_BYTES,
       is_integer(Timeout), Timeout > 0,
       is_integer(MaxBytes), MaxBytes > 0,
       is_list(AllowedSchemes), is_list(AllowedHosts),
       is_boolean(AllowPrivate) ->
    case valid_method(Method) andalso
         adk_model_http_headers:validate(Headers) =:= ok of
        false -> {error, invalid_request};
        true -> parse_target(Method, Url, Headers, Body, Timeout, MaxBytes,
                             AllowedSchemes, AllowedHosts, AllowPrivate)
    end;
normalize_required(_Request) ->
    {error, invalid_request}.

parse_target(Method, Url, Headers, Body, Timeout, MaxBytes,
             AllowedSchemes, AllowedHosts, AllowPrivate) ->
    try uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Uri
          when is_binary(Scheme0), is_binary(Host0), byte_size(Host0) > 0 ->
            Scheme = lower(Scheme0),
            Host = lower(Host0),
            AllowedSchemeSet = normalized_binary_set(AllowedSchemes),
            AllowedHostSet = normalized_binary_set(AllowedHosts),
            case safe_uri(Uri) andalso
                 lists:member(Scheme, [<<"http">>, <<"https">>]) andalso
                 lists:member(Scheme, AllowedSchemeSet) andalso
                 lists:member(Host, AllowedHostSet) of
                false -> {error, target_not_allowed};
                true ->
                    case target_port(Uri, Scheme) of
                        {ok, Port} ->
                            {ok, #{method => Method, scheme => Scheme,
                                   host => Host, port => Port,
                                   path => request_target(Uri),
                                   headers => Headers, body => Body,
                                   timeout => Timeout, max_bytes => MaxBytes,
                                   allow_private => AllowPrivate}};
                        error -> {error, invalid_url}
                    end
            end;
        _ -> {error, invalid_url}
    catch
        _:_ -> {error, invalid_url}
    end.

perform(Target, Callback) ->
    Deadline = erlang:monotonic_time(millisecond) + maps:get(timeout, Target),
    case remaining(Deadline) of
        0 -> {error, timeout};
        Remaining ->
            case adk_openapi_gun_transport:resolve_host(
                   maps:get(host, Target), maps:get(allow_private, Target),
                   Remaining) of
                {ok, Address} ->
                    open_and_stream(Address, Target, Deadline, Callback);
                {error, _} = Error -> Error
            end
    end.

open_and_stream(Address, Target, Deadline, Callback) ->
    case remaining(Deadline) of
        0 -> {error, timeout};
        _ ->
            case gun:open(Address, maps:get(port, Target),
                          connection_options(Target, Deadline)) of
                {ok, Connection} ->
                    try await_connection(Connection, Target, Deadline,
                                         Callback)
                    after
                        _ = catch gun:close(Connection)
                    end;
                {error, _} -> {error, connect_failed}
            end
    end.

connection_options(#{scheme := <<"https">>, host := Host}, Deadline) ->
    HostString = binary_to_list(Host),
    #{transport => tls, protocols => [http], retry => 0,
      connect_timeout => remaining(Deadline),
      tls_handshake_timeout => remaining(Deadline),
      http_opts => #{max_header_block_size => ?MAX_HEADER_BYTES,
                     max_trailer_block_size => ?MAX_HEADER_BYTES},
      tls_opts => [{verify, verify_peer},
                   {cacerts, public_key:cacerts_get()},
                   {server_name_indication, HostString},
                   {customize_hostname_check,
                    [{match_fun,
                      public_key:pkix_verify_hostname_match_fun(https)}]}]};
connection_options(#{scheme := <<"http">>}, Deadline) ->
    #{transport => tcp, protocols => [http], retry => 0,
      connect_timeout => remaining(Deadline),
      http_opts => #{max_header_block_size => ?MAX_HEADER_BYTES,
                     max_trailer_block_size => ?MAX_HEADER_BYTES}}.

await_connection(Connection, Target, Deadline, Callback) ->
    case gun:await_up(Connection, remaining(Deadline)) of
        {ok, http} -> send_request(Connection, Target, Deadline, Callback);
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, connect_failed};
        _ -> {error, unsupported_protocol}
    end.

send_request(Connection, Target, Deadline, Callback) ->
    Headers = [{<<"host">>, host_header(Target)} |
               maps:get(headers, Target)],
    Stream = gun:request(Connection, maps:get(method, Target),
                         maps:get(path, Target), Headers,
                         maps:get(body, Target), #{flow => 1}),
    await_response(Connection, Stream, Target, Deadline, Callback).

await_response(Connection, Stream, Target, Deadline, Callback) ->
    case gun:await(Connection, Stream, remaining(Deadline)) of
        {inform, _Status, _Headers} ->
            await_response(Connection, Stream, Target, Deadline, Callback);
        {response, fin, Status, Headers} ->
            {ok, #{status => Status, headers => Headers, body => <<>>}};
        {response, nofin, Status, Headers}
          when Status >= 200, Status < 300 ->
            consume_success(Connection, Stream, Status, Headers,
                            maps:get(max_bytes, Target), Deadline,
                            Callback, 0);
        {response, nofin, Status, Headers} ->
            collect_error(Connection, Stream, Status, Headers,
                          maps:get(max_bytes, Target), Deadline, <<>>);
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, transport_failed};
        _ -> {error, invalid_response}
    end.

consume_success(Connection, Stream, Status, Headers, MaxBytes, Deadline,
                Callback, BytesRead) ->
    case gun:await(Connection, Stream, remaining(Deadline)) of
        {data, IsFin, Chunk} when is_binary(Chunk) ->
            NewBytesRead = BytesRead + byte_size(Chunk),
            case NewBytesRead =< MaxBytes of
                false ->
                    _ = catch gun:cancel(Connection, Stream),
                    {error, response_too_large};
                true ->
                    case invoke_callback(Callback, Chunk) of
                        ok when IsFin =:= fin ->
                            {ok, #{status => Status, headers => Headers,
                                   body => <<>>}};
                        ok ->
                            ok = gun:update_flow(Connection, Stream, 1),
                            consume_success(Connection, Stream, Status,
                                            Headers, MaxBytes, Deadline,
                                            Callback, NewBytesRead);
                        {error, _} = Error ->
                            _ = catch gun:cancel(Connection, Stream),
                            Error
                    end
            end;
        {trailers, _Trailers} ->
            {ok, #{status => Status, headers => Headers, body => <<>>}};
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, transport_failed};
        _ -> {error, invalid_response}
    end.

collect_error(Connection, Stream, Status, Headers, MaxBytes, Deadline, Acc) ->
    case gun:await(Connection, Stream, remaining(Deadline)) of
        {data, IsFin, Chunk} when is_binary(Chunk) ->
            NewSize = byte_size(Acc) + byte_size(Chunk),
            case NewSize =< MaxBytes of
                false ->
                    _ = catch gun:cancel(Connection, Stream),
                    {error, response_too_large};
                true when IsFin =:= fin ->
                    {ok, #{status => Status, headers => Headers,
                           body => <<Acc/binary, Chunk/binary>>}};
                true ->
                    ok = gun:update_flow(Connection, Stream, 1),
                    collect_error(Connection, Stream, Status, Headers,
                                  MaxBytes, Deadline,
                                  <<Acc/binary, Chunk/binary>>)
            end;
        {trailers, _Trailers} ->
            {ok, #{status => Status, headers => Headers, body => Acc}};
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, transport_failed};
        _ -> {error, invalid_response}
    end.

invoke_callback(Callback, Chunk) ->
    try Callback(Chunk) of
        ok -> ok;
        {error, _} = Error -> Error;
        _ -> {error, invalid_stream_callback_result}
    catch
        Class:_Reason -> {error, {stream_callback_failed, Class}}
    end.

safe_uri(Uri) ->
    not maps:is_key(userinfo, Uri) andalso not maps:is_key(fragment, Uri).

target_port(Uri, <<"https">>) -> valid_port(maps:get(port, Uri, 443));
target_port(Uri, <<"http">>) -> valid_port(maps:get(port, Uri, 80)).

valid_port(Port) when is_integer(Port), Port > 0, Port =< 65535 -> {ok, Port};
valid_port(_) -> error.

request_target(Uri) ->
    Path0 = maps:get(path, Uri, <<>>),
    Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
    case maps:get(query, Uri, undefined) of
        undefined -> Path;
        <<>> -> Path;
        Query -> <<Path/binary, "?", Query/binary>>
    end.

host_header(#{scheme := <<"https">>, host := Host, port := 443}) ->
    authority_host(Host);
host_header(#{scheme := <<"http">>, host := Host, port := 80}) ->
    authority_host(Host);
host_header(#{host := Host, port := Port}) ->
    Authority = authority_host(Host),
    <<Authority/binary, ":", (integer_to_binary(Port))/binary>>.

authority_host(Host) ->
    case inet:parse_ipv6_address(binary_to_list(Host)) of
        {ok, _} -> <<"[", Host/binary, "]">>;
        {error, _} -> Host
    end.

valid_method(<<"GET">>) -> true;
valid_method(<<"POST">>) -> true;
valid_method(<<"PUT">>) -> true;
valid_method(<<"PATCH">>) -> true;
valid_method(<<"DELETE">>) -> true;
valid_method(_) -> false.

normalized_binary_set(Values) ->
    [lower(Value) || Value <- Values, is_binary(Value)].

lower(Binary) ->
    unicode:characters_to_binary(string:lowercase(Binary)).

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
