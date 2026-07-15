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

-ifdef(TEST).
-export([test_is_public_address/1, test_resolve_target/4]).
-endif.

-define(DNS_MAX_HEAP_WORDS, 262144).
-define(DNS_WATCHDOG_MAX_HEAP_WORDS, 8192).
-define(MAX_DNS_ADDRESSES, 64).

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
                        maps:get(allow_private, Target), Deadline) of
        {ok, Address} -> open_and_request(Address, Target, Deadline);
        {error, _} = Error -> Error
    end.

resolve_target(Host, AllowPrivate, Deadline) ->
    resolve_target(Host, AllowPrivate, Deadline, fun system_resolver/1).

resolve_target(Host, AllowPrivate, Deadline, Resolver) ->
    case resolve_addresses(Host, Resolver, Deadline) of
        {ok, Addresses} -> select_address(Addresses, AllowPrivate);
        {error, _} = Error -> Error
    end.

resolve_addresses(Host, Resolver, Deadline) ->
    case remaining(Deadline) of
        0 -> {error, timeout};
        _ -> start_resolver(Host, Resolver, Deadline)
    end.

start_resolver(Host, Resolver, Deadline) ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Ref = make_ref(),
    Worker = fun() ->
        ok = start_owner_watchdog(Owner, self()),
        Result = resolver_result(Host, Resolver),
        CompletedAt = erlang:monotonic_time(millisecond),
        _ = erlang:send(
              ReplyAlias,
              {openapi_dns_result, Ref, self(), CompletedAt, Result},
              [noconnect, nosuspend]),
        ok
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?DNS_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try erlang:spawn_opt(Worker, SpawnOptions) of
        {Pid, Monitor} ->
            await_resolver(Pid, Monitor, ReplyAlias, Ref, Deadline)
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            {error, dns_resolution_failed}
    end.

start_owner_watchdog(Owner, ResolverWorker) ->
    Watchdog = fun() -> owner_watchdog(Owner, ResolverWorker) end,
    SpawnOptions =
        [{message_queue_data, off_heap},
         {max_heap_size,
          #{size => ?DNS_WATCHDOG_MAX_HEAP_WORDS, kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try erlang:spawn_opt(Watchdog, SpawnOptions) of
        WatchdogPid when is_pid(WatchdogPid) -> ok
    catch
        _:_ -> error
    end.

owner_watchdog(Owner, ResolverWorker) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, ResolverWorker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(ResolverWorker, kill),
            _ = erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', WorkerMonitor, process, ResolverWorker, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

await_resolver(Pid, Monitor, ReplyAlias, Ref, Deadline) ->
    receive
        {openapi_dns_result, Ref, Pid, CompletedAt, Result} ->
            resolver_complete(ReplyAlias, Monitor),
            completed_resolver_result(CompletedAt, Deadline, Result);
        {'DOWN', Monitor, process, Pid, _OpaqueReason} ->
            _ = erlang:unalias(ReplyAlias),
            {error, dns_resolution_failed}
    after remaining(Deadline) ->
        _ = erlang:unalias(ReplyAlias),
        exit(Pid, kill),
        _ = erlang:demonitor(Monitor, [flush]),
        {error, timeout}
    end.

completed_resolver_result(CompletedAt, Deadline, _Result)
  when CompletedAt > Deadline ->
    {error, timeout};
completed_resolver_result(_CompletedAt, _Deadline, {ok, []}) ->
    {error, dns_resolution_failed};
completed_resolver_result(_CompletedAt, _Deadline, {ok, Addresses}) ->
    {ok, Addresses};
completed_resolver_result(_CompletedAt, _Deadline, error) ->
    {error, dns_resolution_failed}.

resolver_complete(ReplyAlias, Monitor) ->
    _ = erlang:unalias(ReplyAlias),
    _ = erlang:demonitor(Monitor, [flush]),
    ok.

resolver_result(Host, Resolver) ->
    %% `apply/2' keeps the isolation boundary generic: production uses the
    %% system resolver while tests can exercise malformed or hostile results.
    try normalize_addresses(erlang:apply(Resolver, [Host])) of
        {ok, _Addresses} = Result -> Result;
        error -> error
    catch
        _:_ -> error
    end.

-ifdef(TEST).
normalize_addresses(Addresses) when is_list(Addresses) ->
    bounded_addresses(Addresses, ?MAX_DNS_ADDRESSES, []);
normalize_addresses(_Addresses) ->
    error.

bounded_addresses([], _Remaining, Acc) ->
    {ok, lists:usort(Acc)};
bounded_addresses(_Addresses, 0, _Acc) ->
    error;
bounded_addresses([Address | Rest], Remaining, Acc) ->
    case valid_ip_address(Address) of
        true -> bounded_addresses(Rest, Remaining - 1, [Address | Acc]);
        false -> error
    end;
bounded_addresses(_Improper, _Remaining, _Acc) ->
    error.
-else.
normalize_addresses(Addresses) ->
    bounded_addresses(Addresses, ?MAX_DNS_ADDRESSES, []).

bounded_addresses([], _Remaining, Acc) ->
    {ok, lists:usort(Acc)};
bounded_addresses(_Addresses, 0, _Acc) ->
    error;
bounded_addresses([Address | Rest], Remaining, Acc) ->
    case valid_ip_address(Address) of
        true -> bounded_addresses(Rest, Remaining - 1, [Address | Acc]);
        false -> error
    end.
-endif.

select_address([], _AllowPrivate) ->
    {error, dns_resolution_failed};
select_address(Addresses, true) ->
    {ok, hd(Addresses)};
select_address(Addresses, false) ->
    case lists:all(fun is_public_address/1, Addresses) of
        true -> {ok, hd(Addresses)};
        false -> {error, private_address_rejected}
    end.

system_resolver(Host) ->
    HostString = binary_to_list(Host),
    resolve_family(HostString, inet) ++
    resolve_family(HostString, inet6).

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

host_header(#{scheme := <<"https">>, host := Host, port := 443}) ->
    authority_host(Host);
host_header(#{scheme := <<"http">>, host := Host, port := 80}) ->
    authority_host(Host);
host_header(#{host := Host, port := Port}) ->
    AuthorityHost = authority_host(Host),
    <<AuthorityHost/binary, ":", (integer_to_binary(Port))/binary>>.

authority_host(Host) ->
    case inet:parse_ipv6_address(binary_to_list(Host)) of
        {ok, _Address} -> <<"[", Host/binary, "]">>;
        {error, _} -> Host
    end.

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

-ifdef(TEST).
valid_ip_address({A, B, C, D}) ->
    lists:all(fun valid_ipv4_part/1, [A, B, C, D]);
valid_ip_address({A, B, C, D, E, F, G, H}) ->
    lists:all(fun valid_ipv6_part/1, [A, B, C, D, E, F, G, H]);
valid_ip_address(_Address) -> false.
-else.
valid_ip_address({A, B, C, D}) ->
    lists:all(fun valid_ipv4_part/1, [A, B, C, D]);
valid_ip_address({A, B, C, D, E, F, G, H}) ->
    lists:all(fun valid_ipv6_part/1, [A, B, C, D, E, F, G, H]).
-endif.

valid_ipv4_part(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 255.

valid_ipv6_part(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffff.

%% Reject loopback, link-local, private, carrier-grade NAT, documentation,
%% benchmarking, multicast, and otherwise non-global IPv4 ranges.
is_public_address({A, _B, _C, _D}) when A =:= 0; A =:= 10; A =:= 127 -> false;
is_public_address({100, B, _C, _D}) when B >= 64, B =< 127 -> false;
is_public_address({169, 254, _C, _D}) -> false;
is_public_address({172, B, _C, _D}) when B >= 16, B =< 31 -> false;
is_public_address({192, 0, 0, _D}) -> false;
is_public_address({192, 0, 2, _D}) -> false;
is_public_address({192, 31, 196, _D}) -> false;
is_public_address({192, 52, 193, _D}) -> false;
is_public_address({192, 88, 99, _D}) -> false;
is_public_address({192, 168, _C, _D}) -> false;
is_public_address({198, B, _C, _D}) when B =:= 18; B =:= 19 -> false;
is_public_address({198, 51, 100, _D}) -> false;
is_public_address({203, 0, 113, _D}) -> false;
is_public_address({A, _B, _C, _D}) when A >= 224 -> false;
is_public_address({_A, _B, _C, _D}) -> true;
%% Reject IPv4-compatible and IPv4-mapped forms rather than recursively
%% classifying their embedded address.  This prevents address-text and socket
%% family differences from bypassing the IPv4 policy.
is_public_address({0, _B, _C, _D, _E, _F, _G, _H}) -> false;
%% IPv4/IPv6 translation prefixes (RFC 6052 and RFC 8215).
is_public_address({16#0064, 16#ff9b, 0, 0, 0, 0, _G, _H}) -> false;
is_public_address({16#0064, 16#ff9b, 1, _D, _E, _F, _G, _H}) -> false;
%% Discard-only, protocol-assignment, benchmarking, documentation, ORCHID,
%% deprecated 6to4/6bone, and other non-global special-purpose ranges.
is_public_address({16#0100, 0, 0, 0, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 0, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 2, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 16#0db8, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, A, _C, _D, _E, _F, _G, _H})
  when A >= 16#0010, A =< 16#002f -> false;
is_public_address({16#2002, _B, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#3ffe, _B, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#3fff, B, _C, _D, _E, _F, _G, _H})
  when (B band 16#f000) =:= 0 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#fe00) =:= 16#fc00 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fe80 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ff00) =:= 16#ff00 -> false;
%% Current global unicast space is 2000::/3.  Fail closed on unallocated
%% address space so a future special-purpose range is not silently trusted.
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#e000) =:= 16#2000 -> true;
is_public_address(_) -> false.

-ifdef(TEST).
test_is_public_address(Address) ->
    is_public_address(Address).

test_resolve_target(Host, AllowPrivate, Timeout, Resolver)
  when is_binary(Host), is_boolean(AllowPrivate),
       is_integer(Timeout), Timeout > 0, is_function(Resolver, 1) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    resolve_target(Host, AllowPrivate, Deadline, Resolver).
-endif.
