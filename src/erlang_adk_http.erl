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
    TransportOptions =
        #{socket_opts => [{ip, maps:get(ip, Config)},
                          {port, maps:get(port, Config)}],
          num_acceptors => maps:get(num_acceptors, Config),
          max_connections => maps:get(max_connections, Config)},
    ProtocolOptions =
        #{env => #{dispatch => Dispatch},
          idle_timeout => maps:get(idle_timeout, Config),
          request_timeout => maps:get(request_timeout, Config),
          max_keepalive => maps:get(max_keepalive, Config)},
    case cowboy:start_clear(?LISTENER, TransportOptions, ProtocolOptions) of
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
         fun non_negative_integer/1}
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
                    case DevEnabled of
                        false -> {ok, Config2};
                        true -> add_dev_config(Config2)
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
    case valid_a2a_v1_auth(Auth) andalso positive_integer(MaxBody)
         andalso positive_integer(Heartbeat) of
        true ->
            {ok, Config#{a2a_v1_config =>
                             #{server => adk_a2a_v1_server,
                               auth => Auth,
                               max_body_bytes => MaxBody,
                               sse_heartbeat_ms => Heartbeat}}};
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
