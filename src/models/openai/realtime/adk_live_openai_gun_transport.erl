%% @doc Production OpenAI Realtime WebSocket transport backed by Gun.
%%
%% The OpenAI origin and Realtime path are fixed. TLS peer and hostname
%% verification are mandatory, redirects and reconnect retries are not
%% followed, WebSocket compression is disabled, and inbound socket credit is
%% replenished only after the Live session reports consumption.
%%
%% Credentials are transferred after process start through the opaque Live
%% credential broker. The API key is resolved only while constructing the
%% upgrade request and is never retained in transport state or diagnostics.
-module(adk_live_openai_gun_transport).
-behaviour(adk_live_transport).
-behaviour(gen_server).

-export([open/2, send/2, close/2, consumed/2]).
%% Internal transport policy. These release-build functions are exported so
%% deterministic tests inspect the exact validation, endpoint and TLS options
%% used by the connection state machine.
-export([validate_options/1, endpoint_path/1, gun_options/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(HOST, "api.openai.com").
-define(PORT, 443).
-define(PATH, <<"/v1/realtime">>).
-define(HANDOFF_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_FRAME_BYTES, 8388608).
-define(MAX_FRAME_BYTES, 16777216).

-spec open(pid(), map()) -> {ok, pid()} | {error, term()}.
open(Owner, Options) when is_pid(Owner), is_map(Options) ->
    HandoffRef = make_ref(),
    case gen_server:start_link(?MODULE, HandoffRef, []) of
        {ok, Pid} ->
            case safe_handoff(Pid, HandoffRef, Owner, Options) of
                ok -> {ok, Pid};
                {error, _} = Error ->
                    unlink(Pid),
                    exit(Pid, shutdown),
                    Error
            end;
        {error, _} -> {error, transport_start_failed}
    end;
open(_Owner, _Options) ->
    {error, invalid_transport_options}.

-spec send(pid(), binary()) -> {ok, reference()} | {error, term()}.
send(Handle, Frame) when is_pid(Handle), is_binary(Frame) ->
    try gen_server:call(Handle, {send, Frame}, 5000) of
        Reply -> Reply
    catch
        exit:_ -> {error, transport_unavailable}
    end;
send(_Handle, _Frame) ->
    {error, invalid_frame}.

-spec close(pid(), term()) -> ok.
close(Handle, _Reason) when is_pid(Handle) ->
    try gen_server:call(Handle, close, 5000) of
        ok -> ok
    catch
        exit:_ -> ok
    end;
close(_Handle, _Reason) -> ok.

-spec consumed(pid(), pos_integer()) -> ok.
consumed(Handle, Count)
  when is_pid(Handle), is_integer(Count), Count > 0 ->
    gen_server:cast(Handle, {consumed, Count}),
    ok;
consumed(_Handle, _Count) -> ok.

init(HandoffRef) when is_reference(HandoffRef) ->
    process_flag(trap_exit, true),
    process_flag(message_queue_data, off_heap),
    Timer = erlang:send_after(
              ?HANDOFF_TIMEOUT_MS, self(), handoff_timeout),
    {ok, #{phase => awaiting_handoff,
           handoff_ref => HandoffRef,
           timer => Timer,
           send_timer => undefined,
           owner => undefined,
           owner_monitor => undefined,
           connection => undefined,
           stream_ref => undefined,
           credential_ref => undefined,
           credential_owned => false,
           outbound_pending => undefined,
           notified_closed => false}}.

handle_call({handoff, HandoffRef, Owner, Options}, _From,
            #{phase := awaiting_handoff,
              handoff_ref := Expected} = State) ->
    case HandoffRef =:= Expected of
        false -> {reply, {error, invalid_transport_handoff}, State};
        true ->
            case validate_options(Options) of
                {ok, Checked0} ->
                    case install_credential(Checked0) of
                        {error, _} = Error ->
                            {reply, Error, State};
                        {ok, Checked} ->
                            cancel_timer(maps:get(timer, State)),
                            OwnerMonitor = erlang:monitor(process, Owner),
                            ConnectTimer = phase_timer(
                                             maps:get(connect_timeout_ms,
                                                      Checked),
                                             connecting),
                            self() ! connect,
                            {reply, ok,
                             maps:merge(
                               State,
                               Checked#{phase => connecting,
                                        owner => Owner,
                                        owner_monitor => OwnerMonitor,
                                        timer => ConnectTimer})}
                    end;
                {error, _} = Error -> {reply, Error, State}
            end
    end;
handle_call({handoff, _Ref, _Owner, _Options}, _From, State) ->
    {reply, {error, transport_handoff_already_completed}, State};
handle_call({send, Frame}, _From,
            #{phase := active,
              outbound_pending := undefined,
              max_client_frame_bytes := Maximum} = State)
  when is_binary(Frame), byte_size(Frame) > Maximum ->
    {reply, {error, client_frame_too_large}, State};
handle_call({send, Frame}, _From,
            #{phase := active, connection := Connection,
              stream_ref := StreamRef,
              outbound_pending := undefined} = State)
  when is_binary(Frame) ->
    SendRef = make_ref(),
    try gun:ws_send(Connection, StreamRef, {text, Frame}) of
        ok ->
            SendTimer = erlang:send_after(
                          maps:get(send_timeout_ms, State), self(),
                          {send_timeout, SendRef}),
            {reply, {ok, SendRef},
             State#{outbound_pending => SendRef,
                    send_timer => SendTimer}}
    catch
        _:_ -> {reply, {error, transport_send_failed}, State}
    end;
handle_call({send, _Frame}, _From, State) ->
    {reply, {error, busy}, State};
handle_call(close, _From, State) ->
    close_gun(State),
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast({consumed, Count},
            #{phase := active, connection := Connection,
              stream_ref := StreamRef} = State) ->
    _ = catch gun:update_flow(Connection, StreamRef, Count),
    {noreply, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(connect, #{phase := connecting} = State) ->
    case gun_options(State) of
        {ok, Options} ->
            case gun:open(?HOST, ?PORT, Options) of
                {ok, Connection} ->
                    {noreply, State#{connection => Connection}};
                {error, _} ->
                    stop_closed(connect_failed, State)
            end;
        {error, _} ->
            %% Never downgrade to verify_none if a trust store is absent.
            stop_closed(ca_certificates_unavailable, State)
    end;
handle_info({gun_up, Connection, http},
            #{phase := connecting, connection := Connection,
              credential_ref := CredentialRef} = State) ->
    case adk_live_credential_broker:resolve(CredentialRef) of
        {ok, ApiKey} ->
            case valid_api_key(ApiKey) of
                true -> start_upgrade(Connection, ApiKey, State);
                false -> stop_closed(credential_unavailable, State)
            end;
        {error, _} ->
            stop_closed(credential_unavailable, State)
    end;
handle_info({gun_up, Connection, _OtherProtocol},
            #{phase := connecting, connection := Connection} = State) ->
    stop_closed(protocol_not_allowed, State);
handle_info({gun_upgrade, Connection, StreamRef, Protocols, _Headers},
            #{phase := upgrading, connection := Connection,
              stream_ref := StreamRef} = State) ->
    case lists:member(<<"websocket">>, Protocols) of
        true ->
            cancel_timer(maps:get(timer, State)),
            notify(State, connected),
            {noreply, State#{phase => active, timer => undefined}};
        false -> stop_closed(upgrade_failed, State)
    end;
handle_info({gun_response, Connection, StreamRef, _Fin, _Status, _Headers},
            #{phase := upgrading, connection := Connection,
              stream_ref := StreamRef} = State) ->
    %% Gun does not follow redirects. Every non-upgrade HTTP response is a
    %% stable upgrade failure and response details are intentionally dropped.
    stop_closed(upgrade_failed, State);
handle_info({gun_ws, Connection, StreamRef, {Type, Frame}},
            #{phase := active, connection := Connection,
              stream_ref := StreamRef} = State)
  when (Type =:= text orelse Type =:= binary), is_binary(Frame) ->
    case byte_size(Frame) =< maps:get(max_server_frame_bytes, State) of
        true ->
            notify(State, {frame, Frame}),
            %% The owner replenishes flow only after strict decode/admission.
            {noreply, State};
        false -> stop_closed(server_frame_too_large, State)
    end;
handle_info({gun_ws, Connection, StreamRef, close},
            #{connection := Connection, stream_ref := StreamRef} = State) ->
    stop_closed(remote_closed, State);
handle_info({gun_ws, Connection, StreamRef, {close, _Code, _Reason}},
            #{connection := Connection, stream_ref := StreamRef} = State) ->
    stop_closed(remote_closed, State);
handle_info({gun_ws, Connection, StreamRef, _Control},
            #{phase := active, connection := Connection,
              stream_ref := StreamRef} = State) ->
    _ = catch gun:update_flow(Connection, StreamRef, 1),
    {noreply, State};
handle_info({adk_live_gun_event, Connection,
             {ws_send_frame_end, StreamRef}},
            #{phase := active, connection := Connection,
              stream_ref := StreamRef,
              outbound_pending := SendRef} = State)
  when is_reference(SendRef) ->
    cancel_timer(maps:get(send_timer, State, undefined)),
    notify(State, {sent, SendRef}),
    notify(State, writable),
    {noreply, State#{outbound_pending => undefined,
                     send_timer => undefined}};
handle_info({send_timeout, SendRef},
            #{outbound_pending := SendRef} = State)
  when is_reference(SendRef) ->
    stop_closed(send_timeout, State);
handle_info({gun_error, Connection, _Opaque},
            #{connection := Connection} = State) ->
    stop_closed(transport_error, State);
handle_info({gun_error, Connection, _StreamRef, _Opaque},
            #{connection := Connection} = State) ->
    stop_closed(transport_error, State);
handle_info({gun_down, Connection, _Protocol, _Opaque, _KilledStreams},
            #{connection := Connection} = State) ->
    stop_closed(transport_closed, State);
handle_info({phase_timeout, Phase}, #{phase := Phase} = State) ->
    stop_closed(timeout_reason(Phase), State);
handle_info(handoff_timeout, #{phase := awaiting_handoff} = State) ->
    {stop, normal, State};
handle_info({'DOWN', Ref, process, _Owner, _Opaque},
            #{owner_monitor := Ref} = State) ->
    {stop, normal, State};
handle_info({'EXIT', Connection, _Opaque},
            #{connection := Connection} = State)
  when is_pid(Connection) ->
    stop_closed(transport_closed, State);
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(maps:get(timer, State, undefined)),
    cancel_timer(maps:get(send_timer, State, undefined)),
    close_gun(State),
    revoke_owned_credential(State),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

safe_handoff(Pid, HandoffRef, Owner, Options) ->
    try gen_server:call(
          Pid, {handoff, HandoffRef, Owner, Options}, 5000) of
        Reply -> Reply
    catch
        exit:_ -> {error, transport_handoff_failed}
    end.

start_upgrade(Connection, ApiKey, State) ->
    cancel_timer(maps:get(timer, State)),
    Path = endpoint_path(maps:get(model, State)),
    Headers = upgrade_headers(ApiKey, State),
    Flow = maps:get(ws_flow, State),
    WsOptions = #{flow => Flow, compress => false,
                  silence_pings => true},
    StreamRef = gun:ws_upgrade(Connection, Path, Headers, WsOptions),
    UpgradeTimer = phase_timer(
                     maps:get(upgrade_timeout_ms, State), upgrading),
    {noreply, State#{phase => upgrading,
                     stream_ref => StreamRef,
                     timer => UpgradeTimer}}.

upgrade_headers(ApiKey, State) ->
    Headers0 = [{<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
                {<<"user-agent">>, <<"erlang-adk/0.8">>}],
    Headers1 = optional_header(
                 safety_identifier, <<"openai-safety-identifier">>,
                 State, Headers0),
    Headers2 = optional_header(
                 organization, <<"openai-organization">>, State, Headers1),
    optional_header(project, <<"openai-project">>, State, Headers2).

optional_header(Key, Name, State, Headers) ->
    case maps:get(Key, State, undefined) of
        undefined -> Headers;
        Value -> Headers ++ [{Name, Value}]
    end.

validate_options(Options) ->
    Allowed = [api_key, credential_ref, model,
               safety_identifier, organization, project,
               connect_timeout_ms, tls_handshake_timeout_ms,
               upgrade_timeout_ms, send_timeout_ms, ws_flow,
               max_client_frame_bytes, max_server_frame_bytes,
               cacertfile],
    case maps:keys(Options) -- Allowed of
        [] -> validate_option_values(Options);
        [_ | _] -> {error, invalid_transport_options}
    end.

validate_option_values(Options) ->
    ApiKey = maps:get(api_key, Options, undefined),
    CredentialRef = maps:get(credential_ref, Options, undefined),
    CredentialSource = case {ApiKey, CredentialRef} of
        {undefined, undefined} -> invalid;
        {undefined, Ref} -> {reference, Ref};
        {Key, undefined} -> {raw, Key};
        _ -> invalid
    end,
    Checked =
        #{credential_source => CredentialSource,
          model => maps:get(model, Options, undefined),
          safety_identifier => maps:get(safety_identifier, Options,
                                        undefined),
          organization => maps:get(organization, Options, undefined),
          project => maps:get(project, Options, undefined),
          connect_timeout_ms =>
              maps:get(connect_timeout_ms, Options, 10000),
          tls_handshake_timeout_ms =>
              maps:get(tls_handshake_timeout_ms, Options, 10000),
          upgrade_timeout_ms =>
              maps:get(upgrade_timeout_ms, Options, 10000),
          send_timeout_ms => maps:get(send_timeout_ms, Options, 5000),
          ws_flow => maps:get(ws_flow, Options, 1),
          cacertfile => maps:get(cacertfile, Options, undefined),
          max_client_frame_bytes =>
              maps:get(max_client_frame_bytes, Options,
                       ?DEFAULT_MAX_FRAME_BYTES),
          max_server_frame_bytes =>
              maps:get(max_server_frame_bytes, Options,
                       ?DEFAULT_MAX_FRAME_BYTES)},
    case valid_credential_source(CredentialSource)
         andalso valid_model(maps:get(model, Checked))
         andalso valid_optional_header(
                   maps:get(safety_identifier, Checked), 512)
         andalso valid_optional_header(
                   maps:get(organization, Checked), 256)
         andalso valid_optional_header(maps:get(project, Checked), 256)
         andalso bounded(maps:get(connect_timeout_ms, Checked),
                         100, 120000)
         andalso bounded(maps:get(tls_handshake_timeout_ms, Checked),
                         100, 120000)
         andalso bounded(maps:get(upgrade_timeout_ms, Checked),
                         100, 120000)
         andalso bounded(maps:get(send_timeout_ms, Checked), 100, 120000)
         andalso bounded(maps:get(ws_flow, Checked), 1, 64)
         andalso valid_cacertfile(maps:get(cacertfile, Checked))
         andalso bounded(maps:get(max_client_frame_bytes, Checked),
                         1024, ?MAX_FRAME_BYTES)
         andalso bounded(maps:get(max_server_frame_bytes, Checked),
                         1024, ?MAX_FRAME_BYTES) of
        true -> {ok, Checked};
        false -> {error, invalid_transport_options}
    end.

valid_credential_source({raw, ApiKey}) -> valid_api_key(ApiKey);
valid_credential_source({reference, CredentialRef}) ->
    adk_live_credential_broker:valid_ref(CredentialRef);
valid_credential_source(_) -> false.

install_credential(#{credential_source := {raw, ApiKey}} = Checked) ->
    case adk_live_credential_broker:start(self(), ApiKey) of
        {ok, CredentialRef} ->
            {ok, maps:remove(
                   credential_source,
                   Checked#{credential_ref => CredentialRef,
                            credential_owned => true})};
        {error, _} -> {error, invalid_transport_options}
    end;
install_credential(#{credential_source :=
                         {reference, CredentialRef}} = Checked) ->
    {ok, maps:remove(
           credential_source,
           Checked#{credential_ref => CredentialRef,
                    credential_owned => false})}.

gun_options(State) ->
    Host = ?HOST,
    case ca_options(State) of
        {ok, CaOptions} ->
            {ok,
             #{transport => tls,
               protocols => [http],
               retry => 0,
               event_handler =>
                   {adk_live_gun_event_h, #{owner => self()}},
               connect_timeout => maps:get(connect_timeout_ms, State),
               tls_handshake_timeout =>
                   maps:get(tls_handshake_timeout_ms, State),
               tcp_opts => [{send_timeout,
                              maps:get(send_timeout_ms, State)},
                            {send_timeout_close, true}],
               tls_opts => [{verify, verify_peer} | CaOptions] ++
                           [{server_name_indication, Host},
                            {customize_hostname_check,
                             [{match_fun,
                               public_key:
                                 pkix_verify_hostname_match_fun(https)}]}]}};
        {error, _} = Error -> Error
    end.

ca_options(#{cacertfile := File}) when File =/= undefined ->
    {ok, [{cacertfile, path_string(File)}]};
ca_options(_State) ->
    try public_key:cacerts_get() of
        Certs when is_list(Certs), Certs =/= [] ->
            {ok, [{cacerts, Certs}]};
        _ -> fallback_ca_file()
    catch
        _:_ -> fallback_ca_file()
    end.

fallback_ca_file() ->
    Environment = case os:getenv("SSL_CERT_FILE") of
        false -> [];
        Value -> [Value]
    end,
    Candidates = Environment ++
        ["/etc/ssl/cert.pem",
         "/etc/ssl/certs/ca-certificates.crt",
         "/opt/homebrew/etc/ca-certificates/cert.pem",
         "/usr/local/etc/openssl@3/cert.pem",
         "/usr/local/etc/openssl/cert.pem"],
    case lists:dropwhile(fun(File) -> not filelib:is_regular(File) end,
                         Candidates) of
        [File | _] -> {ok, [{cacertfile, File}]};
        [] -> {error, ca_certificates_unavailable}
    end.

endpoint_path(Model) ->
    Query0 = uri_string:compose_query([{<<"model">>, Model}]),
    Query = unicode:characters_to_binary(Query0),
    <<?PATH/binary, "?", Query/binary>>.

valid_api_key(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< 4096
    andalso lists:all(fun valid_bearer_character/1,
                      binary_to_list(Value));
valid_api_key(_Value) -> false.

valid_bearer_character(Character)
  when Character >= $a, Character =< $z -> true;
valid_bearer_character(Character)
  when Character >= $A, Character =< $Z -> true;
valid_bearer_character(Character)
  when Character >= $0, Character =< $9 -> true;
valid_bearer_character($-) -> true;
valid_bearer_character($.) -> true;
valid_bearer_character($_) -> true;
valid_bearer_character($~) -> true;
valid_bearer_character($+) -> true;
valid_bearer_character($/) -> true;
valid_bearer_character($=) -> true;
valid_bearer_character(_) -> false.

valid_model(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< 256
    andalso lists:all(fun valid_model_character/1,
                      binary_to_list(Value));
valid_model(_Value) -> false.

valid_model_character(Character)
  when Character >= $a, Character =< $z -> true;
valid_model_character(Character)
  when Character >= $A, Character =< $Z -> true;
valid_model_character(Character)
  when Character >= $0, Character =< $9 -> true;
valid_model_character($-) -> true;
valid_model_character($_) -> true;
valid_model_character($.) -> true;
valid_model_character($:) -> true;
valid_model_character($/) -> true;
valid_model_character(_) -> false.

valid_optional_header(undefined, _Maximum) -> true;
valid_optional_header(Value, Maximum) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Maximum
    andalso visible_ascii(Value);
valid_optional_header(_Value, _Maximum) -> false.

visible_ascii(Value) ->
    lists:all(fun(Character) ->
                      Character >= 33 andalso Character =< 126
              end, binary_to_list(Value)).

valid_cacertfile(undefined) -> true;
valid_cacertfile(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< 4096
    andalso binary:match(Value, <<0>>) =:= nomatch;
valid_cacertfile(Value) when is_list(Value) ->
    try
        length(Value) > 0 andalso length(Value) =< 4096
        andalso lists:all(fun(Character) ->
                                 is_integer(Character)
                                 andalso Character > 0
                                 andalso Character =< 16#10ffff
                         end, Value)
    catch
        _:_ -> false
    end;
valid_cacertfile(_) -> false.

path_string(Value) when is_binary(Value) -> binary_to_list(Value);
path_string(Value) -> Value.

bounded(Value, Minimum, Maximum) ->
    is_integer(Value) andalso Value >= Minimum andalso Value =< Maximum.

phase_timer(Timeout, Phase) ->
    erlang:send_after(Timeout, self(), {phase_timeout, Phase}).

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

timeout_reason(connecting) -> connect_timeout;
timeout_reason(upgrading) -> upgrade_timeout.

notify(State, Message) ->
    maps:get(owner, State) !
        {adk_live_transport, self(), Message},
    ok.

stop_closed(Reason, State0) ->
    State = notify_closed(Reason, State0),
    close_gun(State),
    {stop, normal, State}.

notify_closed(_Reason, #{notified_closed := true} = State) -> State;
notify_closed(Reason, #{owner := Owner} = State) when is_pid(Owner) ->
    notify(State, {closed, Reason}),
    State#{notified_closed => true};
notify_closed(_Reason, State) -> State.

close_gun(State) ->
    case {maps:get(connection, State, undefined),
          maps:get(stream_ref, State, undefined)} of
        {Connection, StreamRef} when is_pid(Connection),
                                     StreamRef =/= undefined ->
            _ = catch gun:ws_send(Connection, StreamRef, close),
            _ = catch gun:close(Connection),
            ok;
        {Connection, _} when is_pid(Connection) ->
            _ = catch gun:close(Connection),
            ok;
        _ -> ok
    end.

revoke_owned_credential(#{credential_owned := true,
                          credential_ref := CredentialRef}) ->
    adk_live_credential_broker:revoke(CredentialRef);
revoke_owned_credential(_State) -> ok.

%% Credential references, optional identifiers, model paths, messages and
%% low-level failures are deliberately omitted from OTP diagnostic output.
format_status(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              #{phase => maps:get(phase, State, unknown),
                connected => maps:get(phase, State, unknown) =:= active,
                flow => maps:get(ws_flow, State, undefined),
                max_client_frame_bytes =>
                    maps:get(max_client_frame_bytes, State, undefined),
                max_server_frame_bytes =>
                    maps:get(max_server_frame_bytes, State, undefined)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).
