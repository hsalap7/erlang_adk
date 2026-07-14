%% @doc Production bounded OpenAPI HTTP transport backed by Gun.
%%
%% The hostname is allow-listed before lookup, every resolved address is
%% checked against the private/link-local policy, and Gun connects to the
%% selected IP address directly. HTTPS keeps the original DNS name for SNI,
%% hostname verification, and the Host header, avoiding a DNS-rebinding window
%% between validation and connect. Responses are accumulated only up to the
%% caller-supplied limit and redirects are never followed.
-module(adk_openapi_gun_transport).

-behaviour(adk_openapi_http_transport).

-export([request/2]).

-spec request(adk_openapi_http_transport:handle(),
              adk_openapi_http_transport:request()) ->
    {ok, adk_openapi_http_transport:response()} | {error, term()}.
request(_Handle, Request) when is_map(Request) ->
    case normalize_request(Request) of
        {ok, Parsed} -> perform(Parsed);
        {error, _} = Error -> Error
    end;
request(_Handle, _Request) ->
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
       is_list(Headers), is_binary(Body),
       is_integer(Timeout), Timeout > 0,
       is_integer(MaxBytes), MaxBytes > 0,
       is_list(AllowedSchemes), is_list(AllowedHosts),
       is_boolean(AllowPrivate) ->
    case valid_headers(Headers) of
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
          when is_binary(Scheme0), is_binary(Host0),
               byte_size(Host0) > 0 ->
            Scheme = lower(Scheme0),
            Host = lower(Host0),
            AllowedSchemeSet = [lower(Value) || Value <- AllowedSchemes,
                                                is_binary(Value)],
            AllowedHostSet = [lower(Value) || Value <- AllowedHosts,
                                              is_binary(Value)],
            case safe_uri(Uri) andalso
                 lists:member(Scheme, [<<"http">>, <<"https">>]) andalso
                 lists:member(Scheme, AllowedSchemeSet) andalso
                 lists:member(Host, AllowedHostSet) of
                false -> {error, target_not_allowed};
                true ->
                    case target_port(Uri, Scheme) of
                        {ok, Port} ->
                            Path = request_target(Uri),
                            {ok, #{method => Method, scheme => Scheme,
                                   host => Host, port => Port,
                                   path => Path, headers => Headers,
                                   body => Body, timeout => Timeout,
                                   max_bytes => MaxBytes,
                                   allow_private => AllowPrivate}};
                        error -> {error, invalid_url}
                    end
            end;
        _ -> {error, invalid_url}
    catch
        _:_ -> {error, invalid_url}
    end.

safe_uri(Uri) ->
    not maps:is_key(userinfo, Uri) andalso
    not maps:is_key(fragment, Uri).

target_port(Uri, <<"https">>) -> valid_port(maps:get(port, Uri, 443));
target_port(Uri, <<"http">>) -> valid_port(maps:get(port, Uri, 80)).

valid_port(Port) when is_integer(Port), Port > 0, Port =< 65535 ->
    {ok, Port};
valid_port(_Port) -> error.

request_target(Uri) ->
    Path0 = maps:get(path, Uri, <<>>),
    Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
    case maps:get(query, Uri, undefined) of
        undefined -> Path;
        <<>> -> Path;
        Query -> <<Path/binary, "?", Query/binary>>
    end.

perform(Target) ->
    Deadline = erlang:monotonic_time(millisecond) + maps:get(timeout, Target),
    case resolve_target(maps:get(host, Target),
                        maps:get(allow_private, Target)) of
        {ok, Address} -> open_and_request(Address, Target, Deadline);
        {error, _} = Error -> Error
    end.

resolve_target(Host, AllowPrivate) ->
    HostString = binary_to_list(Host),
    Addresses = resolve_family(HostString, inet) ++
                resolve_family(HostString, inet6),
    Unique = lists:usort(Addresses),
    case Unique of
        [] -> {error, dns_resolution_failed};
        _ when AllowPrivate -> {ok, hd(Unique)};
        _ ->
            case lists:all(fun is_public_address/1, Unique) of
                true -> {ok, hd(Unique)};
                false -> {error, private_address_rejected}
            end
    end.

resolve_family(Host, Family) ->
    case inet:getaddrs(Host, Family) of
        {ok, Values} -> Values;
        {error, _} -> []
    end.

open_and_request(Address, Target, Deadline) ->
    OpenOpts = connection_options(Target, Deadline),
    case remaining(Deadline) of
        0 -> {error, timeout};
        _ ->
            case gun:open(Address, maps:get(port, Target), OpenOpts) of
                {ok, Connection} ->
                    try await_connection(Connection, Target, Deadline)
                    after
                        _ = catch gun:close(Connection)
                    end;
                {error, _} -> {error, connect_failed}
            end
    end.

connection_options(#{scheme := <<"https">>, host := Host}, Deadline) ->
    HostString = binary_to_list(Host),
    #{transport => tls,
      protocols => [http],
      retry => 0,
      connect_timeout => remaining(Deadline),
      tls_handshake_timeout => remaining(Deadline),
      tls_opts => [{verify, verify_peer},
                   {cacerts, public_key:cacerts_get()},
                   {server_name_indication, HostString},
                   {customize_hostname_check,
                    [{match_fun,
                      public_key:pkix_verify_hostname_match_fun(https)}]}]};
connection_options(#{scheme := <<"http">>}, Deadline) ->
    #{transport => tcp, protocols => [http], retry => 0,
      connect_timeout => remaining(Deadline)}.

await_connection(Connection, Target, Deadline) ->
    case gun:await_up(Connection, remaining(Deadline)) of
        {ok, http} -> send_request(Connection, Target, Deadline);
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, connect_failed};
        _ -> {error, unsupported_protocol}
    end.

send_request(Connection, Target, Deadline) ->
    Headers0 = maps:get(headers, Target),
    Headers = [{<<"host">>, host_header(Target)} | Headers0],
    Stream = gun:request(Connection, maps:get(method, Target),
                         maps:get(path, Target), Headers,
                         maps:get(body, Target)),
    await_response(Connection, Stream, Target, Deadline).

host_header(#{scheme := <<"https">>, host := Host, port := 443}) -> Host;
host_header(#{scheme := <<"http">>, host := Host, port := 80}) -> Host;
host_header(#{host := Host, port := Port}) ->
    <<Host/binary, ":", (integer_to_binary(Port))/binary>>.

await_response(Connection, Stream, Target, Deadline) ->
    case gun:await(Connection, Stream, remaining(Deadline)) of
        {inform, _Status, _Headers} ->
            await_response(Connection, Stream, Target, Deadline);
        {response, fin, Status, Headers} ->
            {ok, #{status => Status, headers => Headers, body => <<>>}};
        {response, nofin, Status, Headers} ->
            collect_body(Connection, Stream, Status, Headers,
                         maps:get(max_bytes, Target), Deadline, <<>>);
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, transport_failed};
        _ -> {error, invalid_response}
    end.

collect_body(Connection, Stream, Status, Headers, MaxBytes, Deadline, Acc) ->
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
                    collect_body(Connection, Stream, Status, Headers,
                                 MaxBytes, Deadline,
                                 <<Acc/binary, Chunk/binary>>)
            end;
        {trailers, _Trailers} ->
            {ok, #{status => Status, headers => Headers, body => Acc}};
        {error, timeout} -> {error, timeout};
        {error, _} -> {error, transport_failed};
        _ -> {error, invalid_response}
    end.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

valid_headers([]) -> true;
valid_headers([{Name, Value} | Rest])
  when is_binary(Name), byte_size(Name) > 0,
       is_binary(Value) ->
    not has_control(Name) andalso not has_control(Value) andalso
    valid_headers(Rest);
valid_headers(_) -> false.

has_control(Binary) ->
    lists:any(fun(Byte) -> Byte < 32 orelse Byte =:= 127 end,
              binary_to_list(Binary)).

lower(Binary) ->
    unicode:characters_to_binary(string:lowercase(Binary)).

%% Reject loopback, link-local, private, carrier-grade NAT, documentation,
%% benchmarking, multicast, and otherwise non-global IPv4 ranges.
is_public_address({A, _B, _C, _D}) when A =:= 0; A =:= 10; A =:= 127 -> false;
is_public_address({100, B, _C, _D}) when B >= 64, B =< 127 -> false;
is_public_address({169, 254, _C, _D}) -> false;
is_public_address({172, B, _C, _D}) when B >= 16, B =< 31 -> false;
is_public_address({192, 0, 0, _D}) -> false;
is_public_address({192, 0, 2, _D}) -> false;
is_public_address({192, 168, _C, _D}) -> false;
is_public_address({198, B, _C, _D}) when B =:= 18; B =:= 19 -> false;
is_public_address({198, 51, 100, _D}) -> false;
is_public_address({203, 0, 113, _D}) -> false;
is_public_address({A, _B, _C, _D}) when A >= 224 -> false;
is_public_address({_A, _B, _C, _D}) -> true;
is_public_address({0, 0, 0, 0, 0, 0, 0, 0}) -> false;
is_public_address({0, 0, 0, 0, 0, 0, 0, 1}) -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#fe00) =:= 16#fc00 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fe80 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ff00) =:= 16#ff00 -> false;
is_public_address({16#2001, 16#0db8, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({0, 0, 0, 0, 0, 16#ffff, C, D}) ->
    is_public_address({C bsr 8, C band 16#ff,
                       D bsr 8, D band 16#ff});
is_public_address({_A, _B, _C, _D, _E, _F, _G, _H}) -> true;
is_public_address(_) -> false.
