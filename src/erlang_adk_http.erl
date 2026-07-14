%%%-------------------------------------------------------------------
%% @doc Supervised lifecycle owner for the optional project HTTP endpoint.
%% @end
%%%-------------------------------------------------------------------

-module(erlang_adk_http).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(LISTENER, erlang_adk_a2a_http).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    case listener_config() of
        {ok, Config} -> start_listener(Config);
        {error, Reason} -> {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', MonitorRef, process, ListenerPid, Reason},
            #{listener_pid := ListenerPid,
              monitor_ref := MonitorRef} = State) ->
    {stop, {http_listener_terminated, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{monitor_ref := MonitorRef}) ->
    erlang:demonitor(MonitorRef, [flush]),
    _ = cowboy:stop_listener(?LISTENER),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% internal functions

start_listener(Config) ->
    MaxBodyBytes = maps:get(max_body_bytes, Config),
    Routes = legacy_a2a_routes(Config, MaxBodyBytes) ++
             a2a_v1_routes(Config) ++ dev_routes(Config),
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    SocketOptions = [{ip, maps:get(ip, Config)},
                     {port, maps:get(port, Config)}] ++
                    tls_socket_options(Config),
    TransportOptions =
        #{socket_opts => SocketOptions,
          num_acceptors => maps:get(num_acceptors, Config),
          max_connections => maps:get(max_connections, Config)},
    ProtocolOptions =
        #{env => #{dispatch => Dispatch},
          idle_timeout => maps:get(idle_timeout, Config),
          request_timeout => maps:get(request_timeout, Config),
          max_keepalive => maps:get(max_keepalive, Config)},
    case start_cowboy(Config, TransportOptions, ProtocolOptions) of
        {ok, ListenerPid} ->
            MonitorRef = erlang:monitor(process, ListenerPid),
            {ok, #{listener_pid => ListenerPid,
                   monitor_ref => MonitorRef}};
        {error, Reason} ->
            {stop, {http_listener_start_failed, Reason}}
    end.

listener_config() ->
    Specs = [
        {port, a2a_port, 8080, fun valid_port/1},
        {ip, a2a_ip, {127, 0, 0, 1}, fun valid_ip/1},
        {num_acceptors, a2a_num_acceptors, 10, fun positive_integer/1},
        {max_connections, a2a_max_connections, 1024,
         fun positive_integer/1},
        {max_body_bytes, a2a_max_body_bytes, 1048576,
         fun positive_integer/1},
        {request_timeout, a2a_request_timeout, 10000,
         fun positive_integer/1},
        {idle_timeout, a2a_idle_timeout, 60000,
         fun positive_integer/1},
        {max_keepalive, a2a_max_keepalive, 100,
         fun non_negative_integer/1},
        {allow_non_loopback, a2a_allow_non_loopback, false,
         fun erlang:is_boolean/1},
        {trusted_tls_proxy, a2a_trusted_tls_proxy, false,
         fun erlang:is_boolean/1},
        {tls_options, a2a_tls_options, undefined,
         fun valid_tls_options/1}
    ],
    case read_config(Specs, #{}) of
        {ok, Config} -> add_endpoint_config(Config);
        {error, _} = Error -> Error
    end.

add_endpoint_config(Config) ->
    A2AEnabled = application:get_env(erlang_adk, a2a_enabled, false),
    A2AV1Enabled = application:get_env(erlang_adk, a2a_v1_enabled, false),
    DevEnabled = application:get_env(erlang_adk, dev_enabled, false),
    case is_boolean(A2AEnabled) andalso is_boolean(A2AV1Enabled)
         andalso is_boolean(DevEnabled) of
        false -> {error, invalid_http_endpoint_config};
        true ->
            Config1 = Config#{a2a_enabled => A2AEnabled,
                              a2a_v1_enabled => A2AV1Enabled,
                              dev_enabled => DevEnabled},
            case add_a2a_v1_config(Config1) of
                {ok, Config2} ->
                    case validate_public_route_mix(Config2) of
                        ok ->
                            case validate_dev_exposure(Config2) of
                                ok ->
                                    ConfigResult = case DevEnabled of
                                        false -> {ok, Config2};
                                        true -> add_dev_config(Config2)
                                    end,
                                    case ConfigResult of
                                        {ok, Config3} ->
                                            validate_exposure(Config3);
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

add_a2a_v1_config(#{a2a_v1_enabled := false} = Config) ->
    {ok, Config};
add_a2a_v1_config(Config) ->
    Auth = application:get_env(erlang_adk, a2a_v1_auth, none),
    MaxBody = application:get_env(
                erlang_adk, a2a_v1_max_body_bytes,
                maps:get(max_body_bytes, Config)),
    Heartbeat = application:get_env(
                  erlang_adk, a2a_v1_sse_heartbeat_ms, 15000),
    MaxExtensions = application:get_env(
                      erlang_adk, a2a_v1_max_extensions, 32),
    MaxExtensionHeaderBytes = application:get_env(
                                erlang_adk,
                                a2a_v1_max_extension_header_bytes, 8192),
    AuthTimeout = application:get_env(
                    erlang_adk, a2a_v1_auth_timeout_ms, 5000),
    AuthMaxHeap = application:get_env(
                    erlang_adk, a2a_v1_auth_max_heap_words, 300000),
    case valid_a2a_v1_auth(Auth) andalso positive_integer(MaxBody)
         andalso positive_integer(Heartbeat)
         andalso positive_integer(MaxExtensions)
         andalso MaxExtensions =< 128
         andalso positive_integer(MaxExtensionHeaderBytes)
         andalso MaxExtensionHeaderBytes =< 65536
         andalso positive_integer(AuthTimeout)
         andalso AuthTimeout =< 30000
         andalso is_integer(AuthMaxHeap)
         andalso AuthMaxHeap >= 1000
         andalso AuthMaxHeap =< 2000000 of
        true ->
            {ok, Config#{a2a_v1_config =>
                             #{server => adk_a2a_v1_server,
                               auth => Auth,
                               max_body_bytes => MaxBody,
                               sse_heartbeat_ms => Heartbeat,
                               max_extensions => MaxExtensions,
                               max_extension_header_bytes =>
                                   MaxExtensionHeaderBytes,
                               auth_timeout_ms => AuthTimeout,
                               auth_max_heap_words => AuthMaxHeap}}};
        false -> {error, invalid_a2a_v1_endpoint_config}
    end.

add_dev_config(Config) ->
    case developer_token() of
        {ok, Token} ->
            DevConfig = #{auth_token => Token,
                          session_service => application:get_env(
                                               erlang_adk,
                                               dev_session_service,
                                               erlang_adk_session),
                          runner_options => application:get_env(
                                              erlang_adk,
                                              dev_runner_options, #{}),
                          run_options => application:get_env(
                                           erlang_adk, dev_run_options, #{}),
                          resource_provider => application:get_env(
                                                 erlang_adk,
                                                 dev_resource_provider,
                                                 undefined),
                          max_resource_results => application:get_env(
                                                    erlang_adk,
                                                    dev_max_resource_results,
                                                    100),
                          diagnostic_timeout_ms => application:get_env(
                                                     erlang_adk,
                                                     dev_diagnostic_timeout_ms,
                                                     5000),
                          diagnostic_context_policy => application:get_env(
                                                         erlang_adk,
                                                         dev_diagnostic_context_policy,
                                                         #{max_bytes => 1048576,
                                                           max_tokens => 262144,
                                                           overflow => truncate}),
                          max_body_bytes => application:get_env(
                                              erlang_adk,
                                              dev_max_body_bytes, 65536),
                          max_field_bytes => application:get_env(
                                               erlang_adk,
                                               dev_max_field_bytes, 4096),
                          sse_heartbeat_ms => application:get_env(
                                                erlang_adk,
                                                dev_sse_heartbeat_ms, 15000),
                          sse_max_events => application:get_env(
                                              erlang_adk,
                                              dev_sse_max_events, 128),
                          sse_max_bytes => application:get_env(
                                             erlang_adk,
                                             dev_sse_max_bytes, 1048576),
                          sse_max_duration_ms => application:get_env(
                                                   erlang_adk,
                                                   dev_sse_max_duration_ms,
                                                   300000),
                          max_session_results => application:get_env(
                                                   erlang_adk,
                                                   dev_max_session_results,
                                                   100)},
            case adk_dev_router:validate_config(DevConfig) of
                {ok, SafeDevConfig} ->
                    {ok, Config#{dev_config => SafeDevConfig}};
                {error, Reason} ->
                    {error, {invalid_dev_platform_config, Reason}}
            end;
        {error, _} = Error -> Error
    end.

developer_token() ->
    case application:get_env(erlang_adk, dev_auth_token) of
        {ok, Token} when is_binary(Token), byte_size(Token) >= 16 ->
            {ok, Token};
        {ok, _Invalid} ->
            {error, invalid_dev_auth_token};
        undefined ->
            EnvName = application:get_env(
                        erlang_adk, dev_auth_token_env,
                        "ERLANG_ADK_DEV_TOKEN"),
            case is_list(EnvName) andalso os:getenv(EnvName) of
                TokenString when is_list(TokenString),
                                 length(TokenString) >= 16 ->
                    {ok, unicode:characters_to_binary(TokenString)};
                _ ->
                    {error, missing_dev_auth_token}
            end
    end.

legacy_a2a_routes(#{a2a_enabled := true}, MaxBodyBytes) ->
    [{"/a2a/prompt", erlang_adk_a2a_handler,
      #{max_body_bytes => MaxBodyBytes}}];
legacy_a2a_routes(_Config, _MaxBodyBytes) ->
    [].

a2a_v1_routes(#{a2a_v1_enabled := true, a2a_v1_config := Config}) ->
    [{"/.well-known/agent-card.json", adk_a2a_v1_handler,
      Config#{endpoint => card}},
     {"/a2a/v1", adk_a2a_v1_handler,
      Config#{endpoint => jsonrpc}}];
a2a_v1_routes(_Config) -> [].

dev_routes(#{dev_enabled := true, dev_config := Config}) ->
    %% validate_config/1 has already replaced the raw token with a digest.
    adk_dev_router:routes_validated(Config);
dev_routes(_Config) ->
    [].

read_config([], Config) ->
    {ok, Config};
read_config([{Name, EnvKey, Default, Validator} | Rest], Config) ->
    Value = application:get_env(erlang_adk, EnvKey, Default),
    case Validator(Value) of
        true -> read_config(Rest, Config#{Name => Value});
        false -> {error, {invalid_application_env, EnvKey, Value}}
    end.

valid_port(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< 65535.

valid_ip({A, B, C, D}) ->
    lists:all(fun valid_ipv4_octet/1, [A, B, C, D]);
valid_ip({A, B, C, D, E, F, G, H}) ->
    lists:all(fun valid_ipv6_segment/1, [A, B, C, D, E, F, G, H]);
valid_ip(_) ->
    false.

valid_ipv4_octet(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 255.

valid_ipv6_segment(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffff.

positive_integer(Value) ->
    is_integer(Value) andalso Value > 0.

non_negative_integer(Value) ->
    is_integer(Value) andalso Value >= 0.

valid_a2a_v1_auth(none) -> true;
valid_a2a_v1_auth(Module) when is_atom(Module) -> true;
valid_a2a_v1_auth(Fun) when is_function(Fun, 3) -> true;
valid_a2a_v1_auth(_) -> false.

start_cowboy(#{tls_options := undefined}, Transport, Protocol) ->
    cowboy:start_clear(?LISTENER, Transport, Protocol);
start_cowboy(_Config, Transport, Protocol) ->
    cowboy:start_tls(?LISTENER, Transport, Protocol).

tls_socket_options(#{tls_options := undefined}) -> [];
tls_socket_options(#{tls_options := Options}) -> Options.

valid_tls_options(undefined) -> true;
valid_tls_options(Options) when is_list(Options), Options =/= [] ->
    lists:all(fun(Option) -> is_tuple(Option) andalso tuple_size(Option) =:= 2
              end, Options)
    andalso not lists:keymember(ip, 1, Options)
    andalso not lists:keymember(port, 1, Options)
    andalso has_tls_identity(Options);
valid_tls_options(_) -> false.

has_tls_identity(Options) ->
    (lists:keymember(certfile, 1, Options)
     andalso lists:keymember(keyfile, 1, Options))
    orelse (lists:keymember(cert, 1, Options)
            andalso lists:keymember(key, 1, Options)).

validate_public_route_mix(#{a2a_v1_enabled := true,
                            ip := Ip,
                            a2a_enabled := Legacy,
                            dev_enabled := Dev}) ->
    case is_loopback(Ip) orelse (Legacy =:= false andalso Dev =:= false) of
        true -> ok;
        false -> {error, public_a2a_v1_requires_dedicated_listener}
    end;
validate_public_route_mix(_Config) -> ok.

%% The bundled developer console uses one shared administrator bearer and is
%% deliberately single-operator tooling.  Enforce the loopback boundary in
%% the listener owner, not only in the CLI parser, so application startup and
%% direct erlang_adk_http:start_link/0 calls cannot expose /dev or co-host it
%% on a public legacy A2A socket.
validate_dev_exposure(#{dev_enabled := true, ip := Ip}) ->
    case is_loopback(Ip) of
        true -> ok;
        false -> {error, developer_server_must_bind_loopback}
    end;
validate_dev_exposure(_Config) -> ok.

validate_exposure(#{a2a_v1_enabled := false} = Config) -> {ok, Config};
validate_exposure(Config) ->
    Auth = maps:get(auth, maps:get(a2a_v1_config, Config)),
    Card0 = application:get_env(erlang_adk, a2a_v1_card, undefined),
    case adk_a2a_v1_card:validate(Card0) of
        {ok, Card} -> validate_card_and_transport(Config, Auth, Card);
        {error, Reason} -> {error, {invalid_a2a_v1_card, Reason}}
    end.

validate_card_and_transport(Config, none, Card) ->
    case has_security_requirements(Card) of
        true -> {error, a2a_v1_auth_card_mismatch};
        false -> validate_anonymous_transport(Config)
    end;
validate_card_and_transport(Config, _Auth, Card) ->
    case is_loopback(maps:get(ip, Config)) of
        true -> {ok, Config};
        false ->
            case has_security_declarations(Card) of
                false -> {error, a2a_v1_auth_card_mismatch};
                true -> validate_public_transport(Config, Card)
            end
    end.

validate_anonymous_transport(Config) ->
    case is_loopback(maps:get(ip, Config)) of
        true -> {ok, Config};
        false -> {error, non_loopback_a2a_v1_requires_authentication}
    end.

validate_public_transport(Config, Card) ->
    Allow = maps:get(allow_non_loopback, Config),
    HasTlsBoundary = maps:get(tls_options, Config) =/= undefined
                     orelse maps:get(trusted_tls_proxy, Config),
    case {Allow, HasTlsBoundary, card_uses_https(Card)} of
        {false, _, _} ->
            {error, non_loopback_a2a_v1_requires_explicit_opt_in};
        {true, false, _} ->
            {error, non_loopback_a2a_v1_requires_tls};
        {true, true, false} ->
            {error, non_loopback_a2a_v1_requires_https_card};
        {true, true, true} -> {ok, Config}
    end.

has_security_requirements(Card) ->
    case maps:get(<<"securityRequirements">>, Card, []) of
        [_ | _] -> true;
        _ -> false
    end.

has_security_declarations(Card) ->
    Schemes = maps:get(<<"securitySchemes">>, Card, #{}),
    is_map(Schemes) andalso map_size(Schemes) > 0
    andalso has_security_requirements(Card).

card_uses_https(Card) ->
    case adk_a2a_v1_card:jsonrpc_interface(Card) of
        {ok, Interface} ->
            try uri_string:parse(maps:get(<<"url">>, Interface)) of
                Parsed ->
                    to_binary(maps:get(scheme, Parsed, <<>>)) =:= <<"https">>
            catch _:_ -> false
            end;
        _ -> false
    end.

is_loopback({A, _, _, _}) when A =:= 127 -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback(_) -> false.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.
