%% @doc Security boundary and bounded webhook transport for A2A 1.0 push.
%%
%% Registration validates the immutable destination policy before a config is
%% accepted. Delivery resolves the hostname again and connects to the vetted
%% address, preventing redirects and DNS results for loopback/private ranges
%% from bypassing the policy. Credentials are carried only in the private
%% delivery job and are never included in public configs or returned errors.
-module(adk_a2a_v1_push).

-export([normalize_policy/1,
         prepare_config/5,
         deliver/2]).

-ifdef(TEST).
-export([test_resolve_addresses/2]).
-endif.

-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_CONNECT_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_ATTEMPTS, 3).
-define(DEFAULT_RETRY_BASE_MS, 100).
-define(DEFAULT_MAX_RESPONSE_BYTES, 65536).
-define(MAX_URL_BYTES, 2048).
-define(MAX_ID_BYTES, 512).
-define(MAX_TOKEN_BYTES, 4096).
-define(MAX_CREDENTIAL_BYTES, 8192).
-define(MAX_AUTH_SCHEME_BYTES, 128).
-define(MAX_DNS_ADDRESSES, 64).

-spec normalize_policy(map()) -> {ok, map()} | {error, term()}.
normalize_policy(Options) when is_map(Options) ->
    Timeout = maps:get(timeout_ms, Options, ?DEFAULT_TIMEOUT_MS),
    ConnectTimeout = maps:get(connect_timeout_ms, Options,
                              ?DEFAULT_CONNECT_TIMEOUT_MS),
    Attempts = maps:get(max_attempts, Options, ?DEFAULT_MAX_ATTEMPTS),
    RetryBase = maps:get(retry_base_ms, Options, ?DEFAULT_RETRY_BASE_MS),
    MaxResponse = maps:get(max_response_bytes, Options,
                           ?DEFAULT_MAX_RESPONSE_BYTES),
    AllowLoopback = maps:get(allow_http_loopback, Options, false),
    AllowedHosts0 = maps:get(allowed_hosts, Options, any),
    AllowedPrivate0 = maps:get(allowed_private_hosts, Options, []),
    Resolver = maps:get(resolver, Options, fun resolved_addresses/1),
    Transport = maps:get(transport, Options, fun deliver_http/2),
    case positive(Timeout) andalso Timeout =< 120000
         andalso positive(ConnectTimeout) andalso ConnectTimeout =< Timeout
         andalso positive(Attempts) andalso Attempts =< 5
         andalso is_integer(RetryBase) andalso RetryBase >= 0
         andalso RetryBase =< 5000
         andalso positive(MaxResponse)
         andalso MaxResponse =< ?DEFAULT_MAX_RESPONSE_BYTES
         andalso is_boolean(AllowLoopback)
         andalso valid_host_policy(AllowedHosts0)
         andalso valid_host_list(AllowedPrivate0)
         andalso is_function(Resolver, 1)
         andalso is_function(Transport, 2) of
        true ->
            {ok, #{timeout_ms => Timeout,
                   connect_timeout_ms => ConnectTimeout,
                   max_attempts => Attempts,
                   retry_base_ms => RetryBase,
                   max_response_bytes => MaxResponse,
                   allow_http_loopback => AllowLoopback,
                   allowed_hosts => normalize_host_policy(AllowedHosts0),
                   allowed_private_hosts => normalize_hosts(AllowedPrivate0),
                   resolver => Resolver,
                   transport => Transport}};
        false -> {error, invalid_a2a_push_policy}
    end;
normalize_policy(_) -> {error, invalid_a2a_push_policy}.

%% @doc Validate and split a protocol config into public and secret halves.
%% The caller supplies the server-assigned config id and expected tenant.
-spec prepare_config(binary(), binary(), binary() | undefined, map(), map()) ->
    {ok, map(), map()} | {error, term()}.
prepare_config(TaskId, ConfigId, Tenant, Config0, Policy)
  when is_binary(TaskId), is_binary(ConfigId), is_map(Config0),
       is_map(Policy) ->
    TaskValue = maps:get(<<"taskId">>, Config0, TaskId),
    TenantValue = maps:get(<<"tenant">>, Config0, Tenant),
    Url = maps:get(<<"url">>, Config0, undefined),
    Token = maps:get(<<"token">>, Config0, undefined),
    Authentication = maps:get(<<"authentication">>, Config0, undefined),
    case valid_id(TaskId) andalso valid_id(ConfigId)
         andalso valid_task_value(TaskValue, TaskId)
         andalso valid_tenant_value(TenantValue, Tenant)
         andalso valid_url_shape(Url)
         andalso valid_optional_secret(Token, ?MAX_TOKEN_BYTES)
         andalso valid_authentication(Authentication) of
        false -> {error, invalid_push_notification_config};
        true ->
            case endpoint(Url, Policy) of
                {ok, _} ->
                    Public0 = #{<<"id">> => ConfigId,
                                <<"taskId">> => TaskId,
                                <<"url">> => Url},
                    Public1 = maybe_put_tenant(Tenant, Public0),
                    Public = maybe_put_public_auth(Authentication, Public1),
                    Secret = #{token => Token,
                               authentication => Authentication},
                    {ok, Public, Secret};
                {error, _} = Error -> Error
            end
    end;
prepare_config(_, _, _, _, _) ->
    {error, invalid_push_notification_config}.

-spec deliver(map(), map()) -> ok | {error, term()}.
deliver(Job, Policy) when is_map(Job), is_map(Policy) ->
    Payload = maps:get(payload, Job, undefined),
    Public = maps:get(config, Job, #{}),
    Url = maps:get(<<"url">>, Public, undefined),
    case adk_a2a_v1_codec:validate_stream_response(Payload) of
        {ok, SafePayload} ->
            case endpoint(Url, Policy) of
                {ok, Target} ->
                    Deadline = erlang:monotonic_time(millisecond) +
                               maps:get(timeout_ms, Policy),
                    Delivery = Job#{payload => SafePayload,
                                    target => Target,
                                    deadline => Deadline},
                    deliver_attempt(Delivery, Policy, 1);
                {error, _} = Error -> Error
            end;
        {error, _} -> {error, invalid_a2a_push_payload}
    end;
deliver(_, _) -> {error, invalid_a2a_push_delivery}.

deliver_attempt(Job, Policy, Attempt) ->
    case remaining(maps:get(deadline, Job)) of
        0 -> {error, a2a_push_timeout};
        _ ->
            Transport = maps:get(transport, Policy),
            Result = safe_transport(Transport, Job, Policy),
            case retryable(Result) andalso
                 Attempt < maps:get(max_attempts, Policy) of
                true ->
                    Delay0 = maps:get(retry_base_ms, Policy) bsl
                             (Attempt - 1),
                    Delay = erlang:min(Delay0,
                                       remaining(maps:get(deadline, Job))),
                    receive after Delay -> ok end,
                    deliver_attempt(Job, Policy, Attempt + 1);
                false -> public_delivery_result(Result)
            end
    end.

safe_transport(Transport, Job, Policy) ->
    try Transport(Job, Policy) of
        ok -> ok;
        {error, _} = Error -> Error;
        _ -> {error, a2a_push_transport_failed}
    catch
        _:_ -> {error, a2a_push_transport_failed}
    end.

retryable({error, a2a_push_timeout}) -> true;
retryable({error, a2a_push_connect_failed}) -> true;
retryable({error, a2a_push_transport_failed}) -> true;
retryable({error, {a2a_push_http_status, Status}})
  when Status =:= 408; Status =:= 429; Status >= 500 -> true;
retryable(_) -> false.

public_delivery_result(ok) -> ok;
public_delivery_result({error, a2a_push_destination_not_allowed}) ->
    {error, a2a_push_destination_not_allowed};
public_delivery_result({error, a2a_push_private_destination_rejected}) ->
    {error, a2a_push_private_destination_rejected};
public_delivery_result({error, insecure_a2a_push_destination}) ->
    {error, insecure_a2a_push_destination};
public_delivery_result({error, a2a_push_timeout}) ->
    {error, a2a_push_timeout};
public_delivery_result({error, {a2a_push_http_status, Status}}) ->
    {error, {a2a_push_http_status, Status}};
public_delivery_result({error, _}) ->
    {error, a2a_push_delivery_failed}.

deliver_http(Job, Policy) ->
    Target0 = maps:get(target, Job),
    case resolve_target(Target0, Policy) of
        {ok, Target} ->
            open_and_post(Target, Job, Policy);
        {error, _} = Error -> Error
    end.

resolve_target(Target, Policy) ->
    Host = maps:get(host, Target),
    Resolver = maps:get(resolver, Policy),
    case safe_resolve(Resolver, Host) of
        {ok, Addresses} -> validate_addresses(Target, Addresses, Policy);
        error -> {error, a2a_push_connect_failed}
    end.

safe_resolve(Resolver, Host) ->
    try normalize_addresses(Resolver(Host), ?MAX_DNS_ADDRESSES, []) of
        {ok, []} -> error;
        {ok, Addresses} -> {ok, Addresses};
        error -> error
    catch _:_ -> error
    end.

normalize_addresses([], _Remaining, Acc) -> {ok, lists:usort(Acc)};
normalize_addresses(_Addresses, 0, _Acc) -> error;
normalize_addresses([Address | Rest], Remaining, Acc) ->
    case valid_ip_address(Address) of
        true -> normalize_addresses(Rest, Remaining - 1,
                                    [Address | Acc]);
        false -> error
    end;
normalize_addresses(_, _, _) -> error.

validate_addresses(Target, Addresses, Policy) ->
    Host = maps:get(host, Target),
    Scheme = maps:get(scheme, Target),
    AllLoopback = lists:all(fun is_loopback_address/1, Addresses),
    AllPublic = lists:all(fun is_public_address/1, Addresses),
    PrivateAllowed = lists:member(
                       Host, maps:get(allowed_private_hosts, Policy)),
    Allowed = case Scheme of
        <<"https">> -> AllPublic orelse PrivateAllowed;
        <<"http">> -> maps:get(allow_http_loopback, Policy)
                      andalso AllLoopback andalso PrivateAllowed
    end,
    case Allowed of
        true -> {ok, Target#{address => hd(Addresses)}};
        false when Scheme =:= <<"http">> ->
            {error, insecure_a2a_push_destination};
        false -> {error, a2a_push_private_destination_rejected}
    end.

open_and_post(Target, Job, Policy) ->
    Deadline = maps:get(deadline, Job),
    Options = gun_options(Target, Policy, Deadline),
    case gun:open(maps:get(address, Target), maps:get(port, Target), Options) of
        {ok, Conn} ->
            try await_up_and_post(Conn, Target, Job, Policy, Deadline)
            after _ = catch gun:close(Conn) end;
        {error, _} -> {error, a2a_push_connect_failed}
    end.

await_up_and_post(Conn, Target, Job, Policy, Deadline) ->
    case gun:await_up(Conn, connect_remaining(Policy, Deadline)) of
        {ok, _} ->
            Headers = delivery_headers(Target, Job),
            Body = jsx:encode(maps:get(payload, Job)),
            Ref = gun:request(Conn, <<"POST">>, maps:get(path, Target),
                              Headers, Body, #{flow => 1}),
            await_delivery_response(Conn, Ref, Policy, Deadline, 0);
        {error, timeout} -> {error, a2a_push_timeout};
        {error, _} -> {error, a2a_push_connect_failed}
    end.

await_delivery_response(Conn, Ref, Policy, Deadline, Bytes) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {inform, _Status, _Headers} ->
            await_delivery_response(Conn, Ref, Policy, Deadline, Bytes);
        {response, fin, Status, _Headers} -> status_result(Status);
        {response, nofin, Status, _Headers} ->
            consume_delivery_body(Conn, Ref, Status, Policy, Deadline,
                                  Bytes);
        {error, timeout} -> {error, a2a_push_timeout};
        {error, _} -> {error, a2a_push_transport_failed};
        _ -> {error, a2a_push_transport_failed}
    end.

consume_delivery_body(Conn, Ref, Status, Policy, Deadline, Bytes) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {data, Fin, Chunk} when is_binary(Chunk) ->
            Total = Bytes + byte_size(Chunk),
            case Total =< maps:get(max_response_bytes, Policy) of
                false ->
                    _ = catch gun:cancel(Conn, Ref),
                    {error, a2a_push_response_too_large};
                true when Fin =:= fin -> status_result(Status);
                true ->
                    ok = gun:update_flow(Conn, Ref, 1),
                    consume_delivery_body(Conn, Ref, Status, Policy,
                                          Deadline, Total)
            end;
        {trailers, _} -> status_result(Status);
        {error, timeout} -> {error, a2a_push_timeout};
        {error, _} -> {error, a2a_push_transport_failed};
        _ -> {error, a2a_push_transport_failed}
    end.

status_result(Status) when Status >= 200, Status < 300 -> ok;
status_result(Status) -> {error, {a2a_push_http_status, Status}}.

delivery_headers(Target, Job) ->
    Secret = maps:get(secret, Job, #{}),
    Base = [{<<"host">>, host_header(Target)},
            {<<"content-type">>, <<"application/a2a+json">>},
            {<<"a2a-version">>, <<"1.0">>},
            {<<"idempotency-key">>, maps:get(delivery_id, Job)},
            {<<"a2a-delivery-id">>, maps:get(delivery_id, Job)}],
    Auth = case maps:get(authentication, Secret, undefined) of
        #{<<"scheme">> := Scheme,
          <<"credentials">> := Credentials}
          when Credentials =/= <<>> ->
            [{<<"authorization">>, <<Scheme/binary, " ",
                                      Credentials/binary>>}];
        _ -> []
    end,
    Token = case maps:get(token, Secret, undefined) of
        Value when is_binary(Value), Value =/= <<>> ->
            [{<<"x-a2a-notification-token">>, Value}];
        _ -> []
    end,
    Base ++ Auth ++ Token.

endpoint(Url, Policy) ->
    case parse_url(Url) of
        {ok, Target} ->
            case exact_host_allowed(maps:get(host, Target),
                                    maps:get(allowed_hosts, Policy)) of
                true -> registration_address_allowed(Target, Policy);
                false -> {error, a2a_push_destination_not_allowed}
            end;
        Error -> Error
    end.

registration_address_allowed(Target, Policy) ->
    case inet:parse_address(binary_to_list(maps:get(host, Target))) of
        {ok, Address} -> validate_addresses(Target, [Address], Policy);
        {error, _} -> {ok, Target}
    end.

parse_url(Url) when is_binary(Url), byte_size(Url) > 0,
                             byte_size(Url) =< ?MAX_URL_BYTES ->
    try uri_string:parse(Url) of
        Parsed when is_map(Parsed) ->
            Scheme = lower(to_binary(maps:get(scheme, Parsed, <<>>))),
            Host = canonical_host(to_binary(maps:get(host, Parsed, <<>>))),
            Port = maps:get(port, Parsed, default_port(Scheme)),
            UserInfo = maps:get(userinfo, Parsed, undefined),
            Fragment = maps:get(fragment, Parsed, undefined),
            Path0 = to_binary(maps:get(path, Parsed, <<"/">>)),
            Path1 = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
            Path = case maps:find(query, Parsed) of
                {ok, Query} -> <<Path1/binary, "?",
                                 (to_binary(Query))/binary>>;
                error -> Path1
            end,
            case lists:member(Scheme, [<<"http">>, <<"https">>])
                 andalso byte_size(Host) > 0
                 andalso valid_port(Port)
                 andalso UserInfo =:= undefined
                 andalso Fragment =:= undefined of
                true -> {ok, #{scheme => Scheme, host => Host,
                               port => Port, path => Path}};
                false -> {error, invalid_a2a_push_url}
            end;
        _ -> {error, invalid_a2a_push_url}
    catch _:_ -> {error, invalid_a2a_push_url}
    end;
parse_url(_) -> {error, invalid_a2a_push_url}.

valid_url_shape(Url) ->
    case parse_url(Url) of {ok, _} -> true; _ -> false end.

valid_task_value(<<>>, _Expected) -> true;
valid_task_value(Expected, Expected) -> true;
valid_task_value(_, _) -> false.

valid_tenant_value(undefined, undefined) -> true;
valid_tenant_value(<<>>, undefined) -> true;
valid_tenant_value(Expected, Expected) -> true;
valid_tenant_value(_, _) -> false.

valid_authentication(undefined) -> true;
valid_authentication(Authentication) when is_map(Authentication) ->
    Scheme = maps:get(<<"scheme">>, Authentication, undefined),
    Credentials = maps:get(<<"credentials">>, Authentication, <<>>),
    valid_nonempty_secret(Scheme, ?MAX_AUTH_SCHEME_BYTES)
    andalso valid_optional_secret(Credentials, ?MAX_CREDENTIAL_BYTES);
valid_authentication(_) -> false.

valid_optional_secret(undefined, _Max) -> true;
valid_optional_secret(Value, Max) when is_binary(Value),
                                      byte_size(Value) =< Max ->
    no_controls(Value);
valid_optional_secret(_, _) -> false.

valid_nonempty_secret(Value, Max) when is_binary(Value),
                                       byte_size(Value) > 0,
                                       byte_size(Value) =< Max ->
    no_controls(Value);
valid_nonempty_secret(_, _) -> false.

maybe_put_tenant(undefined, Public) -> Public;
maybe_put_tenant(Tenant, Public) -> Public#{<<"tenant">> => Tenant}.

maybe_put_public_auth(undefined, Public) -> Public;
maybe_put_public_auth(Authentication, Public) ->
    Public#{<<"authentication">> =>
                maps:with([<<"scheme">>], Authentication)}.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< ?MAX_ID_BYTES ->
    unicode:characters_to_binary(Value, utf8, utf8) =:= Value;
valid_id(_) -> false.

gun_options(#{scheme := <<"http">>}, Policy, Deadline) ->
    #{transport => tcp, protocols => [http], retry => 0,
      connect_timeout => connect_remaining(Policy, Deadline),
      http_opts => #{max_header_block_size => 16384,
                     max_trailer_block_size => 16384}};
gun_options(#{scheme := <<"https">>, host := Host}, Policy, Deadline) ->
    #{transport => tls, protocols => [http], retry => 0,
      connect_timeout => connect_remaining(Policy, Deadline),
      tls_handshake_timeout => connect_remaining(Policy, Deadline),
      http_opts => #{max_header_block_size => 16384,
                     max_trailer_block_size => 16384},
      tls_opts => [{verify, verify_peer},
                   {cacerts, public_key:cacerts_get()},
                   {server_name_indication, binary_to_list(Host)},
                   {customize_hostname_check,
                    [{match_fun,
                      public_key:pkix_verify_hostname_match_fun(https)}]}]}.

connect_remaining(Policy, Deadline) ->
    erlang:min(maps:get(connect_timeout_ms, Policy), remaining(Deadline)).

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

resolved_addresses(Host) ->
    HostString = binary_to_list(Host),
    resolve_family(HostString, inet) ++ resolve_family(HostString, inet6).

resolve_family(Host, Family) ->
    case inet:getaddrs(Host, Family) of
        {ok, Addresses} -> Addresses;
        {error, _} -> []
    end.

valid_host_policy(any) -> true;
valid_host_policy(Hosts) -> valid_host_list(Hosts).

valid_host_list(Hosts) when is_list(Hosts) ->
    lists:all(
      fun(Host0) ->
          Host = canonical_host(to_binary(Host0)),
          byte_size(Host) > 0 andalso no_controls(Host)
      end, Hosts);
valid_host_list(_) -> false.

normalize_host_policy(any) -> any;
normalize_host_policy(Hosts) -> normalize_hosts(Hosts).

normalize_hosts(Hosts) ->
    lists:usort([canonical_host(to_binary(Host)) || Host <- Hosts]).

exact_host_allowed(_Host, any) -> true;
exact_host_allowed(Host, Hosts) -> lists:member(Host, Hosts).

host_header(#{scheme := <<"https">>, host := Host, port := 443}) ->
    authority_host(Host);
host_header(#{scheme := <<"http">>, host := Host, port := 80}) ->
    authority_host(Host);
host_header(#{host := Host, port := Port}) ->
    Authority = authority_host(Host),
    <<Authority/binary, ":", (integer_to_binary(Port))/binary>>.

authority_host(Host) ->
    case binary:match(Host, <<":">>) of
        nomatch -> Host;
        _ -> <<"[", Host/binary, "]">>
    end.

canonical_host(Host0) ->
    Host1 = lower(Host0),
    case Host1 of
        <<>> -> <<>>;
        _ -> case binary:last(Host1) of
            $. -> binary:part(Host1, 0, byte_size(Host1) - 1);
            _ -> Host1
        end
    end.

default_port(<<"https">>) -> 443;
default_port(<<"http">>) -> 80;
default_port(_) -> 0.

valid_port(Value) -> is_integer(Value) andalso Value > 0
                     andalso Value =< 65535.

valid_ip_address(Address) when is_tuple(Address), tuple_size(Address) =:= 4 ->
    lists:all(fun(Value) -> is_integer(Value) andalso Value >= 0
                            andalso Value =< 16#ff end,
              tuple_to_list(Address));
valid_ip_address(Address) when is_tuple(Address), tuple_size(Address) =:= 8 ->
    lists:all(fun(Value) -> is_integer(Value) andalso Value >= 0
                            andalso Value =< 16#ffff end,
              tuple_to_list(Address));
valid_ip_address(_) -> false.

is_loopback_address({127, _B, _C, _D}) -> true;
is_loopback_address({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback_address({0, 0, 0, 0, 0, 16#ffff, C, D}) ->
    is_loopback_address({C bsr 8, C band 16#ff,
                         D bsr 8, D band 16#ff});
is_loopback_address(_) -> false.

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
is_public_address({0, 0, 0, 0, 0, 16#ffff, C, D}) ->
    is_public_address({C bsr 8, C band 16#ff,
                       D bsr 8, D band 16#ff});
is_public_address({0, _B, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#0100, 0, 0, 0, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 0, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 2, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 16#0db8, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, A, _C, _D, _E, _F, _G, _H})
  when A >= 16#0010, A =< 16#002f -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#fe00) =:= 16#fc00 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fe80 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fec0 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ff00) =:= 16#ff00 -> false;
is_public_address({_A, _B, _C, _D, _E, _F, _G, _H}) -> true;
is_public_address(_) -> false.

no_controls(Binary) ->
    lists:all(fun(C) -> C >= 16#20 andalso C =/= 16#7f end,
              binary_to_list(Binary)).

positive(Value) -> is_integer(Value) andalso Value > 0.

lower(Value) -> list_to_binary(string:lowercase(binary_to_list(Value))).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.

-ifdef(TEST).
test_resolve_addresses(Host, Resolver)
  when is_binary(Host), is_function(Resolver, 1) ->
    safe_resolve(Resolver, Host).
-endif.
