%% @doc Bounded OAuth discovery and PKCE helper for MCP clients.
%%
%% Discovery follows RFC 9728 protected-resource metadata, then RFC 8414
%% authorization-server metadata with the OpenID Connect well-known location
%% as a 404-only fallback.  The caller supplies a fetch function so connection
%% pinning and trust roots remain owned by the application.  Requests emitted
%% to that function never contain credentials and redirects are never followed.
-module(adk_mcp_oauth).

-export([discover/2, resource_metadata_url/1,
         authorization_metadata_urls/1, pkce/0,
         authorization_request/2, token_parameters/4,
         describe/1]).

-define(MAX_DOCUMENT_BYTES, 1048576).
-define(MAX_SCOPES, 256).
-define(MAX_URL_BYTES, 8192).
-define(MAX_TIMEOUT, 120000).
-define(DEFAULT_CALLBACK_MAX_HEAP_WORDS, 262144).
-define(MIN_VERIFIER_BYTES, 43).
-define(MAX_VERIFIER_BYTES, 128).

-spec discover(binary(), map()) -> {ok, map()} | {error, term()}.
discover(Resource0, Options) when is_binary(Resource0), is_map(Options) ->
    case normalize_options(Resource0, Options) of
        {ok, Resource, Config} ->
            case resource_metadata_url(Resource) of
                {ok, MetadataUrl} ->
                    case fetch_json(MetadataUrl, protected_resource, Config) of
                        {ok, Document} ->
                            discover_authorization(Resource, MetadataUrl,
                                                   Document, Config);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
discover(_Resource, _Options) -> {error, invalid_mcp_oauth_options}.

-spec resource_metadata_url(binary()) ->
    {ok, binary()} | {error, invalid_mcp_oauth_resource}.
resource_metadata_url(Resource) ->
    case parse_https_uri(Resource, false) of
        {ok, Parsed} ->
            Path = maps:get(path, Parsed, <<>>),
            WellKnown = case Path of
                <<>> -> <<"/.well-known/oauth-protected-resource">>;
                <<"/">> -> <<"/.well-known/oauth-protected-resource">>;
                <<"/", Rest/binary>> ->
                    <<"/.well-known/oauth-protected-resource/", Rest/binary>>
            end,
            compose(Parsed#{path => WellKnown});
        {error, _} -> {error, invalid_mcp_oauth_resource}
    end.

-spec authorization_metadata_urls(binary()) ->
    {ok, [binary()]} | {error, invalid_mcp_authorization_server}.
authorization_metadata_urls(Issuer) ->
    case parse_https_uri(Issuer, false) of
        {ok, Parsed} ->
            Path = maps:get(path, Parsed, <<>>),
            Suffix = trim_leading_slash(Path),
            RfcPath = case Suffix of
                <<>> -> <<"/.well-known/oauth-authorization-server">>;
                _ -> <<"/.well-known/oauth-authorization-server/",
                       Suffix/binary>>
            end,
            OidcPath = case Path of
                <<>> -> <<"/.well-known/openid-configuration">>;
                <<"/">> -> <<"/.well-known/openid-configuration">>;
                _ -> <<Path/binary, "/.well-known/openid-configuration">>
            end,
            case {compose(Parsed#{path => RfcPath}),
                  compose(Parsed#{path => OidcPath})} of
                {{ok, Rfc}, {ok, Oidc}} -> {ok, [Rfc, Oidc]};
                _ -> {error, invalid_mcp_authorization_server}
            end;
        {error, _} -> {error, invalid_mcp_authorization_server}
    end.

-spec pkce() -> #{verifier := binary(), challenge := binary(),
                  method := <<_:32>>}.
pkce() ->
    Verifier = base64url(crypto:strong_rand_bytes(32)),
    #{verifier => Verifier,
      challenge => base64url(crypto:hash(sha256, Verifier)),
      method => <<"S256">>}.

-spec authorization_request(map(), map()) ->
    {ok, map()} | {error, term()}.
authorization_request(Discovery, Params) when is_map(Discovery),
                                               is_map(Params) ->
    ClientId = maps:get(client_id, Params, undefined),
    RedirectUri = maps:get(redirect_uri, Params, undefined),
    State = maps:get(state, Params, undefined),
    Scopes = maps:get(scopes, Params,
                      maps:get(scopes_supported, Discovery, [])),
    Pkce = maps:get(pkce, Params, pkce()),
    case {discovery_fields(Discovery), valid_text(ClientId, 1024),
          safe_redirect_uri(RedirectUri), valid_text(State, 1024),
          valid_scopes(Scopes), valid_pkce(Pkce)} of
        {{ok, AuthorizationEndpoint, _TokenEndpoint, Resource}, true,
         true, true, true, true} ->
            Scope = iolist_to_binary(lists:join(<<" ">>, Scopes)),
            Query = uri_string:compose_query(
                      [{<<"response_type">>, <<"code">>},
                       {<<"client_id">>, ClientId},
                       {<<"redirect_uri">>, RedirectUri},
                       {<<"state">>, State},
                       {<<"scope">>, Scope},
                       {<<"code_challenge">>, maps:get(challenge, Pkce)},
                       {<<"code_challenge_method">>, <<"S256">>},
                       {<<"resource">>, Resource}]),
            case parse_https_uri(AuthorizationEndpoint, false) of
                {ok, Parsed} ->
                    case compose(Parsed#{query => Query}) of
                        {ok, Url} ->
                            {ok, #{url => Url,
                                   code_verifier => maps:get(verifier, Pkce),
                                   code_challenge => maps:get(challenge, Pkce),
                                   resource => Resource}};
                        {error, _} = Error -> Error
                    end;
                {error, _} -> {error, invalid_mcp_authorization_endpoint}
            end;
        {{error, _} = Error, _, _, _, _, _} -> Error;
        _ -> {error, invalid_mcp_authorization_request}
    end;
authorization_request(_Discovery, _Params) ->
    {error, invalid_mcp_authorization_request}.

-spec token_parameters(map(), binary(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
token_parameters(Discovery, Code, RedirectUri, Verifier) ->
    case {discovery_fields(Discovery), valid_text(Code, 8192),
          safe_redirect_uri(RedirectUri), valid_verifier(Verifier)} of
        {{ok, _AuthorizationEndpoint, _TokenEndpoint, Resource}, true,
         true, true} ->
            {ok, #{<<"grant_type">> => <<"authorization_code">>,
                   <<"code">> => Code,
                   <<"redirect_uri">> => RedirectUri,
                   <<"code_verifier">> => Verifier,
                   <<"resource">> => Resource}};
        {{error, _} = Error, _, _, _} -> Error;
        _ -> {error, invalid_mcp_token_request}
    end.

%% Content-free summary for diagnostics.  Endpoints and tenant paths may be
%% sensitive, so only origins and advertised support are retained.
-spec describe(map()) -> map().
describe(Discovery) when is_map(Discovery) ->
    #{resource_origin => origin(maps:get(resource, Discovery, <<>>)),
      authorization_server_origin =>
          origin(maps:get(authorization_server, Discovery, <<>>)),
      scope_count => length(maps:get(scopes_supported, Discovery, [])),
      pkce_s256 => maps:get(pkce_s256, Discovery, false)};
describe(_) -> #{status => invalid}.

discover_authorization(Resource, MetadataUrl, Document, Config) ->
    case validate_protected_resource(Resource, Document, Config) of
        {ok, AuthorizationServer, Scopes} ->
            case authorization_metadata_urls(AuthorizationServer) of
                {ok, [RfcUrl, OidcUrl]} ->
                    case fetch_json(RfcUrl, authorization_server, Config) of
                        {ok, AuthorizationDocument} ->
                            assemble_discovery(Resource, MetadataUrl,
                                               AuthorizationServer, Scopes,
                                               RfcUrl, AuthorizationDocument,
                                               Config);
                        {error, {http_status, 404}} ->
                            case fetch_json(OidcUrl, authorization_server,
                                            Config) of
                                {ok, AuthorizationDocument} ->
                                    assemble_discovery(
                                      Resource, MetadataUrl,
                                      AuthorizationServer, Scopes, OidcUrl,
                                      AuthorizationDocument, Config);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

assemble_discovery(Resource, MetadataUrl, AuthorizationServer, Scopes,
                   AuthorizationMetadataUrl, Document, Config) ->
    case validate_authorization_document(AuthorizationServer, Document,
                                         Config) of
        {ok, AuthorizationEndpoint, TokenEndpoint} ->
            {ok, #{resource => Resource,
                   resource_metadata_url => MetadataUrl,
                   authorization_server => AuthorizationServer,
                   authorization_metadata_url => AuthorizationMetadataUrl,
                   authorization_endpoint => AuthorizationEndpoint,
                   token_endpoint => TokenEndpoint,
                   scopes_supported => Scopes,
                   pkce_s256 => true}};
        {error, _} = Error -> Error
    end.

validate_protected_resource(Resource, Document, Config)
  when is_map(Document) ->
    DocumentResource = maps:get(<<"resource">>, Document, undefined),
    Servers = maps:get(<<"authorization_servers">>, Document, undefined),
    Scopes = maps:get(<<"scopes_supported">>, Document, []),
    case DocumentResource =:= Resource andalso is_list(Servers) andalso
         Servers =/= [] andalso length(Servers) =< 16 andalso
         valid_scopes(Scopes) of
        false -> {error, invalid_mcp_protected_resource_metadata};
        true -> choose_authorization_server(Servers, Config, Scopes)
    end;
validate_protected_resource(_Resource, _Document, _Config) ->
    {error, invalid_mcp_protected_resource_metadata}.

choose_authorization_server([], _Config, _Scopes) ->
    {error, mcp_authorization_server_not_allowed};
choose_authorization_server([Server | Rest], Config, Scopes) ->
    Allowed = maps:get(allowed_authorization_servers, Config),
    case safe_destination(Server, Config) andalso
         lists:member(origin(Server), Allowed) of
        true -> {ok, Server, Scopes};
        false -> choose_authorization_server(Rest, Config, Scopes)
    end.

validate_authorization_document(ExpectedIssuer, Document, Config)
  when is_map(Document) ->
    Issuer = maps:get(<<"issuer">>, Document, undefined),
    AuthorizationEndpoint = maps:get(<<"authorization_endpoint">>, Document,
                                     undefined),
    TokenEndpoint = maps:get(<<"token_endpoint">>, Document, undefined),
    Methods = maps:get(<<"code_challenge_methods_supported">>, Document, []),
    ExpectedOrigin = origin(ExpectedIssuer),
    case Issuer =:= ExpectedIssuer andalso lists:member(<<"S256">>, Methods)
         andalso endpoint_at_origin(AuthorizationEndpoint, ExpectedOrigin,
                                    Config)
         andalso endpoint_at_origin(TokenEndpoint, ExpectedOrigin, Config) of
        true -> {ok, AuthorizationEndpoint, TokenEndpoint};
        false -> {error, invalid_mcp_authorization_metadata}
    end;
validate_authorization_document(_Issuer, _Document, _Config) ->
    {error, invalid_mcp_authorization_metadata}.

endpoint_at_origin(Url, ExpectedOrigin, Config) ->
    safe_destination(Url, Config) andalso origin(Url) =:= ExpectedOrigin.

fetch_json(Url, Kind, Config) ->
    case safe_destination(Url, Config) of
        false -> {error, mcp_oauth_destination_not_allowed};
        true ->
            Fetch = maps:get(fetch_fun, Config),
            Request = #{method => get,
                        headers => [{<<"accept">>, <<"application/json">>}],
                        timeout => remaining(maps:get(deadline, Config)),
                        max_bytes => maps:get(max_document_bytes, Config),
                        redirect => reject,
                        credentials => none,
                        kind => Kind},
            case run_fetch(fun() -> Fetch(Url, Request) end, Config) of
                {ok, Result} -> normalize_fetch_result(Result, Config);
                timeout -> {error, mcp_oauth_discovery_timeout};
                failed -> {error, mcp_oauth_fetch_failed}
            end
    end.

normalize_fetch_result({ok, Status, _Headers, _Body}, _Config)
  when Status >= 300, Status =< 399 ->
    {error, {redirect_rejected, Status}};
normalize_fetch_result({ok, 200, Headers, Body}, Config)
  when is_list(Headers), is_binary(Body) ->
    Max = maps:get(max_document_bytes, Config),
    case byte_size(Body) =< Max andalso json_content_type(Headers) of
        true -> decode_json(Body);
        false when byte_size(Body) > Max ->
            {error, mcp_oauth_document_too_large};
        false -> {error, invalid_mcp_oauth_content_type}
    end;
normalize_fetch_result({ok, Status, _Headers, _Body}, _Config)
  when is_integer(Status) -> {error, {http_status, Status}};
normalize_fetch_result({'EXIT', _}, _Config) ->
    {error, mcp_oauth_fetch_failed};
normalize_fetch_result({error, mcp_oauth_document_too_large}, _Config) ->
    {error, mcp_oauth_document_too_large};
normalize_fetch_result(_Other, _Config) ->
    {error, mcp_oauth_fetch_failed}.

decode_json(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Document when is_map(Document), map_size(Document) =< 256 ->
            case adk_mcp_protocol_limits:validate_json(
                   Document, #{max_bytes => ?MAX_DOCUMENT_BYTES,
                               max_depth => 32, max_nodes => 10000,
                               max_binary_bytes => 262144,
                               max_total_binary_bytes => ?MAX_DOCUMENT_BYTES,
                               max_list_length => 1024, max_map_size => 256,
                               max_external_bytes => 2097152}) of
                {ok, Safe} -> {ok, Safe};
                {error, _} -> {error, invalid_mcp_oauth_document}
            end;
        _ -> {error, invalid_mcp_oauth_document}
    catch _:_ -> {error, invalid_mcp_oauth_document}
    end.

normalize_options(Resource, Options) ->
    Allowed = [fetch_fun, timeout, max_document_bytes,
               allowed_authorization_servers, allow_http_loopback,
               allowed_hosts, callback_max_heap_words],
    Fetch = maps:get(fetch_fun, Options, undefined),
    Timeout = maps:get(timeout, Options, 10000),
    MaxBytes = maps:get(max_document_bytes, Options, ?MAX_DOCUMENT_BYTES),
    AllowLoopback = maps:get(allow_http_loopback, Options, false),
    AllowedHosts = maps:get(allowed_hosts, Options, any),
    CallbackMaxHeap = maps:get(callback_max_heap_words, Options,
                               ?DEFAULT_CALLBACK_MAX_HEAP_WORDS),
    case maps:keys(maps:without(Allowed, Options)) =:= [] andalso
         is_function(Fetch, 2) andalso valid_positive(Timeout, ?MAX_TIMEOUT)
         andalso valid_positive(MaxBytes, 16777216) andalso
         is_boolean(AllowLoopback) andalso valid_host_policy(AllowedHosts)
         andalso is_integer(CallbackMaxHeap) andalso
         CallbackMaxHeap >= 1024 andalso
         CallbackMaxHeap =< 4194304
         andalso safe_destination(Resource,
                                  #{allow_http_loopback => AllowLoopback,
                                    allowed_hosts => AllowedHosts}) of
        false -> {error, invalid_mcp_oauth_options};
        true ->
            ResourceOrigin = origin(Resource),
            Allowed0 = maps:get(allowed_authorization_servers, Options,
                                [ResourceOrigin]),
            case valid_origin_list(Allowed0) of
                true ->
                    {ok, Resource,
                     #{fetch_fun => Fetch, timeout => Timeout,
                       max_document_bytes => MaxBytes,
                       deadline => erlang:monotonic_time(millisecond) + Timeout,
                       callback_max_heap_words => CallbackMaxHeap,
                       allow_http_loopback => AllowLoopback,
                       allowed_hosts => AllowedHosts,
                       allowed_authorization_servers => Allowed0}};
                false -> {error, invalid_mcp_oauth_options}
            end
    end.

discovery_fields(Discovery) ->
    Authorization = maps:get(authorization_endpoint, Discovery, undefined),
    Token = maps:get(token_endpoint, Discovery, undefined),
    Resource = maps:get(resource, Discovery, undefined),
    case valid_text(Authorization, ?MAX_URL_BYTES) andalso
         valid_text(Token, ?MAX_URL_BYTES) andalso
         valid_text(Resource, ?MAX_URL_BYTES) of
        true -> {ok, Authorization, Token, Resource};
        false -> {error, invalid_mcp_oauth_discovery}
    end.

safe_destination(Url, Config) when is_binary(Url),
                                   byte_size(Url) =< ?MAX_URL_BYTES ->
    AllowLoopback = maps:get(allow_http_loopback, Config, false),
    AllowedHosts = maps:get(allowed_hosts, Config, any),
    case parse_https_uri(Url, AllowLoopback) of
        {ok, #{host := Host}} ->
            host_allowed(Host, AllowedHosts) andalso
                not private_literal(Host, AllowLoopback);
        {error, _} -> false
    end;
safe_destination(_Url, _Config) -> false.

parse_https_uri(Url, AllowLoopback) when is_binary(Url),
                                         byte_size(Url) =< ?MAX_URL_BYTES ->
    try uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Parsed0 ->
            Scheme = lower(to_binary(Scheme0)),
            Host = lower(to_binary(Host0)),
            Path = to_binary(maps:get(path, Parsed0, <<>>)),
            AllowedScheme = Scheme =:= <<"https">> orelse
                (AllowLoopback andalso Scheme =:= <<"http">> andalso
                 loopback_host(Host)),
            case AllowedScheme andalso byte_size(Host) > 0 andalso
                 not maps:is_key(userinfo, Parsed0) andalso
                 not maps:is_key(fragment, Parsed0) andalso
                 not maps:is_key(query, Parsed0) andalso
                 valid_uri_path(Path) of
                true -> {ok, Parsed0#{scheme => Scheme, host => Host,
                                     path => Path}};
                false -> {error, invalid_uri}
            end;
        _ -> {error, invalid_uri}
    catch _:_ -> {error, invalid_uri}
    end;
parse_https_uri(_Url, _AllowLoopback) -> {error, invalid_uri}.

compose(Parsed) ->
    try unicode:characters_to_binary(uri_string:recompose(Parsed)) of
        Url when byte_size(Url) =< ?MAX_URL_BYTES -> {ok, Url};
        _ -> {error, invalid_mcp_oauth_url}
    catch _:_ -> {error, invalid_mcp_oauth_url}
    end.

origin(Url) when is_binary(Url) ->
    try uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Parsed ->
            Scheme = lower(to_binary(Scheme0)),
            Host = lower(to_binary(Host0)),
            Default = case Scheme of <<"https">> -> 443; <<"http">> -> 80;
                         _ -> invalid end,
            Port = maps:get(port, Parsed, Default),
            case {Scheme, Port} of
                {<<"https">>, 443} -> <<"https://", Host/binary>>;
                {<<"http">>, 80} -> <<"http://", Host/binary>>;
                {<<"https">>, P} when is_integer(P) ->
                    <<"https://", Host/binary, ":", (integer_to_binary(P))/binary>>;
                {<<"http">>, P} when is_integer(P) ->
                    <<"http://", Host/binary, ":", (integer_to_binary(P))/binary>>;
                _ -> invalid
            end;
        _ -> invalid
    catch _:_ -> invalid
    end;
origin(_) -> invalid.

json_content_type(Headers) ->
    case [Value || {Name, Value} <- Headers,
                   lower(Name) =:= <<"content-type">>] of
        [Value | _] ->
            Main = lower(hd(binary:split(Value, <<";">>))),
            Main =:= <<"application/json">> orelse
                (binary:match(Main, <<"+json">>) =/= nomatch);
        [] -> false
    end.

safe_redirect_uri(Uri) ->
    case parse_https_uri(Uri, true) of {ok, _} -> true; _ -> false end.

valid_pkce(#{verifier := Verifier, challenge := Challenge,
             method := <<"S256">>}) ->
    valid_verifier(Verifier) andalso
        Challenge =:= base64url(crypto:hash(sha256, Verifier));
valid_pkce(_) -> false.

valid_verifier(Value) when is_binary(Value),
                           byte_size(Value) >= ?MIN_VERIFIER_BYTES,
                           byte_size(Value) =< ?MAX_VERIFIER_BYTES ->
    lists:all(fun pkce_char/1, binary_to_list(Value));
valid_verifier(_) -> false.

pkce_char(C) when C >= $a, C =< $z -> true;
pkce_char(C) when C >= $A, C =< $Z -> true;
pkce_char(C) when C >= $0, C =< $9 -> true;
pkce_char($-) -> true;
pkce_char($.) -> true;
pkce_char($_) -> true;
pkce_char($~) -> true;
pkce_char(_) -> false.

valid_scopes(Scopes) when is_list(Scopes), length(Scopes) =< ?MAX_SCOPES ->
    length(Scopes) =:= length(lists:usort(Scopes)) andalso
        lists:all(fun(Scope) -> valid_text(Scope, 256) andalso
                     binary:match(Scope, <<" ">>) =:= nomatch end, Scopes);
valid_scopes(_) -> false.

valid_origin_list(Origins) when is_list(Origins), Origins =/= [],
                                length(Origins) =< 32 ->
    lists:all(fun(Origin) -> origin(Origin) =:= Origin end, Origins);
valid_origin_list(_) -> false.

valid_host_policy(any) -> true;
valid_host_policy(Hosts) when is_list(Hosts), length(Hosts) =< 256 ->
    lists:all(fun(Host) -> valid_text(Host, 253) end, Hosts);
valid_host_policy(_) -> false.

host_allowed(_Host, any) -> true;
host_allowed(Host, Hosts) -> lists:member(Host, [lower(H) || H <- Hosts]).

private_literal(Host, AllowLoopback) ->
    case loopback_host(Host) of
        true -> not AllowLoopback;
        false ->
            case inet:parse_address(binary_to_list(Host)) of
                {ok, Address} -> not is_public(Address);
                {error, _} -> false
            end
    end.

is_public({A, _, _, _}) when A =:= 0; A =:= 10; A =:= 127 -> false;
is_public({100, B, _, _}) when B >= 64, B =< 127 -> false;
is_public({169, 254, _, _}) -> false;
is_public({172, B, _, _}) when B >= 16, B =< 31 -> false;
is_public({192, 168, _, _}) -> false;
is_public({A, _, _, _}) when A >= 224 -> false;
is_public({_A, _B, _C, _D}) -> true;
is_public({A, _, _, _, _, _, _, _}) when (A band 16#fe00) =:= 16#fc00 -> false;
is_public({A, _, _, _, _, _, _, _}) when (A band 16#ffc0) =:= 16#fe80 -> false;
is_public({A, _, _, _, _, _, _, _}) when (A band 16#ff00) =:= 16#ff00 -> false;
is_public({_A, _B, _C, _D, _E, _F, _G, _H}) -> true.

loopback_host(<<"localhost">>) -> true;
loopback_host(<<"127.0.0.1">>) -> true;
loopback_host(<<"::1">>) -> true;
loopback_host(_) -> false.

trim_leading_slash(<<"/", Rest/binary>>) -> Rest;
trim_leading_slash(Value) -> Value.

valid_text(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                            byte_size(Value) =< Max ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end;
valid_text(_, _) -> false.

valid_uri_path(<<>>) -> true;
valid_uri_path(Path) -> valid_text(Path, ?MAX_URL_BYTES).

valid_positive(Value, Ceiling) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Ceiling.

run_fetch(Work, Config) ->
    Deadline = maps:get(deadline, Config),
    case remaining(Deadline) of
        0 -> timeout;
        _ -> start_fetch_worker(Work, Config, Deadline)
    end.

start_fetch_worker(Work, Config, Deadline) ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Ref = make_ref(),
    MaxBytes = maps:get(max_document_bytes, Config),
    Worker = fun() ->
        start_owner_watchdog(Owner, self()),
        Result = bounded_fetch_result(catch Work(), MaxBytes),
        CompletedAt = erlang:monotonic_time(millisecond),
        _ = erlang:send(ReplyAlias,
                        {mcp_oauth_fetch_result, Ref, self(), CompletedAt,
                         Result},
                        [noconnect, nosuspend]),
        ok
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => maps:get(callback_max_heap_words, Config), kill => true,
            error_logger => false, include_shared_binaries => true}}],
    try spawn_opt(Worker, SpawnOptions) of
        {Pid, Monitor} ->
            await_fetch_worker(Pid, Monitor, ReplyAlias, Ref, Deadline)
    catch _:_ ->
        _ = erlang:unalias(ReplyAlias),
        failed
    end.

await_fetch_worker(Pid, Monitor, ReplyAlias, Ref, Deadline) ->
    receive
        {mcp_oauth_fetch_result, Ref, Pid, CompletedAt, Result}
          when CompletedAt =< Deadline ->
            _ = erlang:unalias(ReplyAlias),
            _ = erlang:demonitor(Monitor, [flush]),
            {ok, Result};
        {mcp_oauth_fetch_result, Ref, Pid, _CompletedAt, _Result} ->
            _ = erlang:unalias(ReplyAlias),
            exit(Pid, kill),
            await_worker_down(Pid, Monitor),
            timeout;
        {'DOWN', Monitor, process, Pid, _Reason} ->
            _ = erlang:unalias(ReplyAlias),
            flush_fetch_result(Ref, Pid),
            failed
    after remaining(Deadline) ->
        _ = erlang:unalias(ReplyAlias),
        exit(Pid, kill),
        await_worker_down(Pid, Monitor),
        flush_fetch_result(Ref, Pid),
        timeout
    end.

bounded_fetch_result({ok, Status, Headers, Body} = Result, MaxBytes)
  when is_integer(Status), is_list(Headers), is_binary(Body) ->
    try erlang:external_size(Result) of
        Size when byte_size(Body) =< MaxBytes,
                  Size =< MaxBytes + 65536 -> Result;
        _ -> {error, mcp_oauth_document_too_large}
    catch _:_ -> {error, mcp_oauth_fetch_failed}
    end;
bounded_fetch_result(Result, MaxBytes) ->
    try erlang:external_size(Result) of
        Size when Size =< MaxBytes + 65536 -> Result;
        _ -> {error, mcp_oauth_document_too_large}
    catch _:_ -> {error, mcp_oauth_fetch_failed}
    end.

start_owner_watchdog(Owner, Worker) ->
    _ = spawn_opt(
          fun() -> owner_watchdog(Owner, Worker) end,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]),
    ok.

owner_watchdog(Owner, Worker) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, Worker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            exit(Worker, kill),
            erlang:demonitor(WorkerMonitor, [flush]);
        {'DOWN', WorkerMonitor, process, Worker, _Reason} ->
            erlang:demonitor(OwnerMonitor, [flush])
    end.

await_worker_down(Pid, Monitor) ->
    receive {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 100 -> erlang:demonitor(Monitor, [flush]), ok
    end.

flush_fetch_result(Ref, Pid) ->
    receive {mcp_oauth_fetch_result, Ref, Pid, _At, _Result} -> ok
    after 0 -> ok
    end.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

base64url(Value) ->
    base64:encode(Value, #{mode => urlsafe, padding => false}).

lower(Value) when is_binary(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value).
