%% @doc One supervised, server-owned bidirectional Live session.
%%
%% The session owns provider setup legality, bounded ingress, transport flow,
%% subscriber cardinality/credit, interruption handling and principal
%% authorization. It is intentionally independent of the process which
%% starts it. Subscriber admission is serialized and capped per session;
%% detaching or process death immediately makes capacity reusable.
-module(adk_live_session).
-behaviour(gen_statem).

-export([start_link/1, handoff/5,
         send_text/3, send_audio/3, send_video_frame/3,
         activity_start/2, activity_end/2, audio_stream_end/2,
         send_voice_audio/4, voice_activity_start/3,
         voice_activity_end/3, voice_audio_stream_end/3,
         send_tool_response/5,
         subscribe/3, subscribe/4, subscribe_voice/4, ack/3, ack/4,
         unsubscribe/2, unsubscribe/3,
         status/2, status/3, close/3]).
-export([init/1, callback_mode/0, handle_event/4,
         terminate/3, code_change/4, format_status/1]).

-define(HANDOFF_TIMEOUT_MS, 5000).
-define(DEFAULT_CALL_TIMEOUT_MS, 5000).
-define(DEFAULT_CONNECT_TIMEOUT_MS, 10000).
-define(DEFAULT_SETUP_TIMEOUT_MS, 10000).
-define(DEFAULT_CLOSED_RETENTION_MS, 5000).
-define(DEFAULT_MAX_INGRESS_MESSAGES, 64).
-define(DEFAULT_MAX_INGRESS_BYTES, 4194304).
-define(DEFAULT_MAX_SUBSCRIBER_MESSAGES, 256).
-define(DEFAULT_MAX_SUBSCRIBER_BYTES, 8388608).
-define(DEFAULT_MAX_SUBSCRIBERS, 64).
-define(MAX_SUBSCRIBERS, 4096).
-define(DEFAULT_MAX_RECONNECT_ATTEMPTS, 3).
-define(DEFAULT_RECONNECT_BACKOFF_MS, 250).
-define(DEFAULT_TOOL_TIMEOUT_MS, 5000).
-define(DEFAULT_TOOL_MAX_CONCURRENCY, 4).
-define(DEFAULT_TOOL_MAX_HEAP_WORDS, 250000).
-define(DEFAULT_TOOL_MAX_RESPONSE_BYTES, 262144).
-define(MAX_PENDING_TOOL_CALLS, 128).
-define(MAX_COMPLETED_TOOL_CALLS, 4096).

%% Public API ---------------------------------------------------------------

-spec start_link(reference()) -> gen_statem:start_ret().
start_link(HandoffRef) when is_reference(HandoffRef) ->
    gen_statem:start_link(?MODULE, HandoffRef, []).

-spec handoff(pid(), reference(), binary(), binary(), map()) ->
    ok | {error, term()}.
handoff(Pid, HandoffRef, SessionId, Principal, Config)
  when is_pid(Pid), is_reference(HandoffRef), is_binary(SessionId),
       is_binary(Principal), is_map(Config) ->
    safe_call(Pid, {handoff, HandoffRef, SessionId, Principal, Config});
handoff(_Pid, _HandoffRef, _SessionId, _Principal, _Config) ->
    {error, invalid_live_session_handoff}.

-spec send_text(pid(), binary(), binary()) ->
    {ok, pos_integer()} | {error, term()}.
send_text(Pid, Principal, Text) ->
    api_call(Pid, Principal, {send, text, {text, Text}}).

-spec send_audio(pid(), binary(), adk_live_media:media()) ->
    {ok, pos_integer()} | {error, term()}.
send_audio(Pid, Principal, Media) ->
    api_call(Pid, Principal, {send, audio, {audio, Media}}).

%% Voice bridges carry a continuity capability captured when they subscribe.
%% Checking it inside the same gen_statem call that admits input prevents an
%% old bridge from writing after a reconnect has already completed.
-spec send_voice_audio(pid(), binary(), reference(), adk_live_media:media()) ->
    {ok, pos_integer()} | {error, term()}.
send_voice_audio(Pid, Principal, Continuity, Media)
  when is_reference(Continuity) ->
    api_call(Pid, Principal,
             {send_voice, Continuity, audio, {audio, Media}});
send_voice_audio(_Pid, _Principal, _Continuity, _Media) ->
    {error, invalid_live_session_call}.

-spec send_video_frame(pid(), binary(), adk_live_media:media()) ->
    {ok, pos_integer()} | {error, term()}.
send_video_frame(Pid, Principal, Media) ->
    api_call(Pid, Principal, {send, video, {video_frame, Media}}).

-spec activity_start(pid(), binary()) ->
    {ok, pos_integer()} | {error, term()}.
activity_start(Pid, Principal) ->
    api_call(Pid, Principal, {send, control, activity_start}).

-spec activity_end(pid(), binary()) ->
    {ok, pos_integer()} | {error, term()}.
activity_end(Pid, Principal) ->
    api_call(Pid, Principal, {send, control, activity_end}).

-spec audio_stream_end(pid(), binary()) ->
    {ok, pos_integer()} | {error, term()}.
audio_stream_end(Pid, Principal) ->
    api_call(Pid, Principal, {send, control, audio_stream_end}).

-spec voice_activity_start(pid(), binary(), reference()) ->
    {ok, pos_integer()} | {error, term()}.
voice_activity_start(Pid, Principal, Continuity)
  when is_reference(Continuity) ->
    api_call(Pid, Principal,
             {send_voice, Continuity, control, activity_start});
voice_activity_start(_Pid, _Principal, _Continuity) ->
    {error, invalid_live_session_call}.

-spec voice_activity_end(pid(), binary(), reference()) ->
    {ok, pos_integer()} | {error, term()}.
voice_activity_end(Pid, Principal, Continuity)
  when is_reference(Continuity) ->
    api_call(Pid, Principal,
             {send_voice, Continuity, control, activity_end});
voice_activity_end(_Pid, _Principal, _Continuity) ->
    {error, invalid_live_session_call}.

-spec voice_audio_stream_end(pid(), binary(), reference()) ->
    {ok, pos_integer()} | {error, term()}.
voice_audio_stream_end(Pid, Principal, Continuity)
  when is_reference(Continuity) ->
    api_call(Pid, Principal,
             {send_voice, Continuity, control, audio_stream_end});
voice_audio_stream_end(_Pid, _Principal, _Continuity) ->
    {error, invalid_live_session_call}.

-spec send_tool_response(pid(), binary(), binary(), binary(), map()) ->
    {ok, pos_integer()} | {error, term()}.
send_tool_response(Pid, Principal, Id, Name, Response) ->
    api_call(Pid, Principal,
             {send, tool_response,
              {tool_response, Id, Name, Response}}).

-spec subscribe(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
subscribe(Pid, Principal, Credit) ->
    subscribe(Pid, Principal, self(), Credit).

-spec subscribe(pid(), binary(), pid(), map()) ->
    {ok, map()} | {error, term()}.
subscribe(Pid, Principal, Subscriber, Credit) when is_pid(Subscriber) ->
    api_call(Pid, Principal, {subscribe, Subscriber, Credit});
subscribe(_Pid, _Principal, _Subscriber, _Credit) ->
    {error, invalid_live_subscription}.

-spec subscribe_voice(pid(), binary(), pid(), map()) ->
    {ok, map()} | {error, term()}.
subscribe_voice(Pid, Principal, Subscriber, Credit)
  when is_pid(Subscriber) ->
    api_call(Pid, Principal, {subscribe_voice, Subscriber, Credit});
subscribe_voice(_Pid, _Principal, _Subscriber, _Credit) ->
    {error, invalid_live_subscription}.

-spec ack(pid(), binary(), non_neg_integer()) -> ok | {error, term()}.
ack(Pid, Principal, Sequence) ->
    ack(Pid, Principal, self(), Sequence).

-spec ack(pid(), binary(), pid(), non_neg_integer()) ->
    ok | {error, term()}.
ack(Pid, Principal, Subscriber, Sequence)
  when is_pid(Subscriber), is_integer(Sequence), Sequence >= 0 ->
    api_call(Pid, Principal, {ack, Subscriber, Sequence});
ack(_Pid, _Principal, _Subscriber, _Sequence) ->
    {error, invalid_live_ack}.

-spec unsubscribe(pid(), binary()) -> ok | {error, term()}.
unsubscribe(Pid, Principal) ->
    unsubscribe(Pid, Principal, self()).

-spec unsubscribe(pid(), binary(), pid()) -> ok | {error, term()}.
unsubscribe(Pid, Principal, Subscriber) when is_pid(Subscriber) ->
    api_call(Pid, Principal, {unsubscribe, Subscriber});
unsubscribe(_Pid, _Principal, _Subscriber) ->
    {error, invalid_live_subscription}.

-spec status(pid(), binary()) -> {ok, map()} | {error, term()}.
status(Pid, Principal) ->
    status(Pid, Principal, ?DEFAULT_CALL_TIMEOUT_MS).

-spec status(pid(), binary(), pos_integer()) ->
    {ok, map()} | {error, term()}.
status(Pid, Principal, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0, TimeoutMs =< 120000 ->
    case is_pid(Pid) andalso is_binary(Principal) of
        true -> safe_call(Pid, {api, Principal, status}, TimeoutMs);
        false -> {error, invalid_live_session_call}
    end;
status(_Pid, _Principal, _TimeoutMs) ->
    {error, invalid_live_status_timeout}.

-spec close(pid(), binary(), term()) -> ok | {error, term()}.
close(Pid, Principal, Reason) ->
    api_call(Pid, Principal, {close, Reason}).

api_call(Pid, Principal, Request)
  when is_pid(Pid), is_binary(Principal) ->
    safe_call(Pid, {api, Principal, Request});
api_call(_Pid, _Principal, _Request) ->
    {error, invalid_live_session_call}.

safe_call(Pid, Request) ->
    safe_call(Pid, Request, ?DEFAULT_CALL_TIMEOUT_MS).

safe_call(Pid, Request, TimeoutMs) ->
    try gen_statem:call(Pid, Request, TimeoutMs) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, not_found};
        exit:{normal, _} -> {error, not_found};
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, live_session_unavailable}
    end.

%% gen_statem ---------------------------------------------------------------

callback_mode() -> handle_event_function.

init(HandoffRef) when is_reference(HandoffRef) ->
    process_flag(trap_exit, true),
    process_flag(message_queue_data, off_heap),
    {ok, awaiting_handoff, #{handoff_ref => HandoffRef},
     [{state_timeout, ?HANDOFF_TIMEOUT_MS, handoff_timeout}]}.

handle_event({call, From},
             {handoff, HandoffRef, SessionId, Principal, Config},
             awaiting_handoff, #{handoff_ref := Expected}) ->
    case HandoffRef =:= Expected of
        true -> accept_handoff(From, SessionId, Principal, Config);
        false -> reply(From, {error, invalid_live_session_handoff})
    end;
handle_event({call, From}, {handoff, _Ref, _Id, _Principal, _Config},
             awaiting_handoff, _Data) ->
    reply(From, {error, invalid_live_session_handoff});
handle_event({call, From}, {handoff, _Ref, _Id, _Principal, _Config},
             _State, _Data) ->
    reply(From, {error, handoff_already_completed});

handle_event(state_timeout, handoff_timeout, awaiting_handoff, Data) ->
    {stop, normal, Data};

handle_event(internal, connect, connecting, Data0) ->
    Transport = maps:get(transport, Data0),
    Options = maps:get(transport_opts, Data0),
    case safe_transport_open(Transport, Options) of
        {ok, Handle} ->
            Monitor = monitor_handle(Handle),
            Data = Data0#{transport_handle => Handle,
                          transport_monitor => Monitor},
            {keep_state, Data};
        {error, _Reason} ->
            close_transition(connect_failed, Data0)
    end;

handle_event(info, {adk_live_transport, Handle, connected}, connecting,
             #{transport_handle := Handle} = Data) ->
    send_setup(Data);
handle_event(info, {adk_live_transport, Handle, writable}, connecting,
             #{transport_handle := Handle,
               setup_frame := Frame} = Data)
  when is_binary(Frame) ->
    send_setup_frame(Frame, Data);
handle_event(info, {adk_live_transport, Handle, connected}, reconnecting,
             #{transport_handle := Handle} = Data) ->
    send_resume_setup(Data);
handle_event(info, {adk_live_transport, Handle, writable}, reconnecting,
             #{transport_handle := Handle,
               setup_frame := Frame} = Data)
  when is_binary(Frame) ->
    send_resume_setup_frame(Frame, Data);

handle_event(info, {adk_live_transport, Handle, {frame, Frame}},
             setup_pending, #{transport_handle := Handle} = Data) ->
    process_setup_frame(Frame, Data);
handle_event(info, {adk_live_transport, Handle, {frame, Frame}},
             active, #{transport_handle := Handle} = Data) ->
    process_active_frame(Frame, Data);

handle_event(info, {adk_live_transport, Handle, writable}, active,
             #{transport_handle := Handle}) ->
    {keep_state_and_data, [{next_event, internal, drain_ingress}]};
handle_event(info, {adk_live_transport, Handle, {sent, SendRef}}, active,
             #{transport_handle := Handle,
               outbound_pending :=
                   #{ref := SendRef, entry := Entry}} = Data) ->
    Data1 = release_ingress_entry(Entry, Data),
    {keep_state, Data1#{outbound_pending => undefined},
     [{next_event, internal, drain_ingress}]};
handle_event(info, {adk_live_transport, _Handle, {sent, _SendRef}},
             _State, _Data) ->
    keep_state_and_data;
handle_event(internal, drain_ingress, active, Data) ->
    drain_ingress(Data);

handle_event(info, {adk_live_tool_result, Token, Id, Result}, active, Data) ->
    handle_tool_result(Token, Id, Result, Data);
handle_event(info, {adk_live_tool_result, _Token, _Id, _Result},
             _State, _Data) ->
    keep_state_and_data;
handle_event(info, {adk_live_tool_timeout, Token, Id}, active, Data) ->
    handle_tool_timeout(Token, Id, Data);
handle_event(info, {adk_live_tool_timeout, _Token, _Id}, _State, _Data) ->
    keep_state_and_data;

handle_event(state_timeout, reconnect, reconnecting, Data) ->
    open_reconnect_transport(Data);
handle_event(state_timeout, reconnect_connect_timeout, reconnecting, Data) ->
    retry_reconnect(connect_timeout, Data);

handle_event(info, {adk_live_transport, Handle, {closed, _Opaque}},
             State, #{transport_handle := Handle} = Data)
  when State =/= closed ->
    transport_lost(State, transport_closed, Data);
handle_event(info, {'DOWN', Ref, process, _Pid, _Opaque}, State,
             #{transport_monitor := Ref} = Data)
  when State =/= closed ->
    transport_lost(State, transport_closed, Data);
handle_event(info, {'EXIT', Handle, _Opaque}, State,
             #{transport_handle := Handle} = Data)
  when State =/= closed ->
    transport_lost(State, transport_closed, Data);

handle_event(state_timeout, connect_timeout, connecting, Data) ->
    close_transition(connect_timeout, Data);
handle_event(state_timeout, setup_timeout, setup_pending,
             #{resume_pending := true} = Data) ->
    retry_reconnect(setup_timeout, Data);
handle_event(state_timeout, setup_timeout, setup_pending, Data) ->
    close_transition(setup_timeout, Data);
handle_event(state_timeout, expire, closed, Data) ->
    {stop, normal, Data};

handle_event({call, From}, {api, Principal, Request}, State, Data) ->
    case authorized(Principal, Data) of
        true -> handle_authorized_call(From, Request, State, Data);
        false -> reply(From, {error, not_found})
    end;

handle_event(info, {'DOWN', Ref, process, Pid, _Reason}, State, Data) ->
    case maps:get(Ref, maps:get(tool_worker_refs, Data, #{}), undefined) of
        undefined ->
            {keep_state, remove_subscriber_by_monitor(Ref, Pid, Data)};
        Id when State =:= active ->
            handle_tool_down(Ref, Id, Data);
        _Id ->
            keep_state_and_data
    end;
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    _ = stop_all_tool_workers(terminated, Data),
    _ = close_observability({error, terminated}, Data),
    close_transport(terminated, Data),
    release_credential(Data),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%% Provider setup and input -------------------------------------------------

accept_handoff(From, SessionId, Principal, Config) ->
    case validate_handoff(SessionId, Principal, Config) of
        {ok, Checked0} ->
            case prepare_session_credential(Checked0) of
                {ok, Checked} ->
            ProviderConfig = maps:get(provider_config, Checked),
            Model = maps:get(model, ProviderConfig),
            case adk_live_observability:new(
                   SessionId, Model, maps:get(observability, Checked)) of
                {ok, Obs0} ->
                    Obs1 = adk_live_observability:lifecycle(started, Obs0),
                    Obs = adk_live_observability:start_connect(initial, Obs1),
                    Data = Checked#{
                              session_id => SessionId,
                              owner_scope => crypto:hash(sha256, Principal),
                              started_at => erlang:system_time(millisecond),
                              transport_handle => undefined,
                              transport_monitor => undefined,
                              setup_frame => undefined,
                              ingress => queue:new(),
                              ingress_messages => 0,
                              ingress_bytes => 0,
                              outbound_pending => undefined,
                              input_sequence => 0,
                              subscribers => #{},
                              subscriber_refs => #{},
                              voice_subscribers => #{},
                              sequence => 0,
                              turn_epoch => 0,
                              generation_epoch => 0,
                              voice_continuity => make_ref(),
                              resumption_handle => undefined,
                              resumable => false,
                              go_away => false,
                              resume_pending => false,
                              reconnect_attempts => 0,
                              reconnect_phase => undefined,
                              reconnect_dropped_inputs => 0,
                              pending_tool_calls => #{},
                              completed_tool_calls => #{},
                              tool_queue => queue:new(),
                              tool_workers => #{},
                              tool_worker_refs => #{},
                              observability => Obs},
                    ConnectTimeout = maps:get(connect_timeout_ms, Data),
                    {next_state, connecting, Data,
                     [{reply, From, ok},
                      {next_event, internal, connect},
                      {state_timeout, ConnectTimeout, connect_timeout}]};
                {error, _} ->
                    release_credential(Checked),
                    reply(From, {error, invalid_live_observability})
            end;
                {error, _} = Error -> reply(From, Error)
            end;
        {error, _} = Error ->
            reply(From, Error)
    end.

send_setup(Data) ->
    Provider = maps:get(provider, Data),
    Config = maps:get(provider_config, Data),
    try Provider:setup_frame(Config) of
        {ok, Frame} when is_binary(Frame) -> send_setup_frame(Frame, Data);
        {error, _} -> close_transition(invalid_setup, Data);
        _ -> close_transition(invalid_setup, Data)
    catch
        _:_ -> close_transition(provider_failure, Data)
    end.

send_resume_setup(Data) ->
    Provider = maps:get(provider, Data),
    Config = maps:get(provider_config, Data),
    Handle = maps:get(resumption_handle, Data),
    case erlang:function_exported(Provider, resume_setup_frame, 2) of
        false -> close_transition(resumption_not_supported, Data);
        true ->
            try Provider:resume_setup_frame(Config, Handle) of
                {ok, Frame} when is_binary(Frame) ->
                    send_resume_setup_frame(Frame, Data);
                {error, _} -> close_transition(invalid_resume_setup, Data);
                _ -> close_transition(invalid_resume_setup, Data)
            catch
                _:_ -> close_transition(provider_failure, Data)
            end
    end.

send_setup_frame(Frame, Data0) ->
    Data = Data0#{setup_frame => Frame},
    case safe_transport_send(Frame, Data) of
        {ok, _Consumption} ->
            SetupTimeout = maps:get(setup_timeout_ms, Data),
            {next_state, setup_pending,
             Data#{setup_frame => undefined},
             [{state_timeout, SetupTimeout, setup_timeout}]};
        {error, busy} ->
            {keep_state, Data};
        {error, _} ->
            close_transition(transport_send_failed, Data)
    end.

send_resume_setup_frame(Frame, Data0) ->
    Data = Data0#{setup_frame => Frame,
                  reconnect_phase => sending_setup},
    case safe_transport_send(Frame, Data) of
        {ok, _Consumption} ->
            SetupTimeout = maps:get(setup_timeout_ms, Data),
            {next_state, setup_pending,
             Data#{setup_frame => undefined,
                   resume_pending => true,
                   reconnect_phase => setup_pending},
             [{state_timeout, SetupTimeout, setup_timeout}]};
        {error, busy} ->
            {keep_state, Data};
        {error, _} ->
            retry_reconnect(transport_send_failed, Data)
    end.

process_setup_frame(Frame, Data0) ->
    {Decoded, Data} = decode_provider_frame_observed(Frame, Data0),
    case Decoded of
        {ok, [#{kind := setup_complete}]} ->
            transport_consumed(Data),
            Resumed = maps:get(resume_pending, Data, false),
            Ready = #{model => maps:get(
                                 model, maps:get(provider_config, Data)),
                      resumed => Resumed,
                      input_credit =>
                          #{messages => maps:get(max_ingress_messages, Data),
                            bytes => maps:get(max_ingress_bytes, Data)}},
            Obs0 = maps:get(observability, Data),
            Obs1 = adk_live_observability:finish_connect(ok, Obs0),
            Obs = adk_live_observability:lifecycle(ready, Obs1),
            ReadyData = Data#{resume_pending => false,
                              reconnect_phase => undefined,
                              reconnect_attempts => 0,
                              go_away => false,
                              observability => Obs},
            Data1 = case Resumed of
                true ->
                    emit(resumption_status,
                         #{resumable => maps:get(resumable, ReadyData),
                           resumed => true,
                           replayed_inputs => false,
                           dropped_inputs =>
                               maps:get(reconnect_dropped_inputs, ReadyData)},
                         ReadyData);
                false -> ReadyData
            end,
            %% A handle is single-use continuity state. After a successful
            %% resume, wait for the provider's next update before another
            %% reconnect instead of falling back to an older handle.
            Data2 = case Resumed of
                true -> Data1#{resumable => false,
                               resumption_handle => undefined};
                false -> Data1
            end,
            {next_state, active,
             emit(ready, Ready,
                  Data2#{reconnect_dropped_inputs => 0})};
        {ok, _Other} ->
            close_transition(expected_setup_complete, Data);
        {error, _} = Error ->
            protocol_error_transition(Error, Data)
    end.

process_active_frame(Frame, Data0) ->
    {Decoded, Data} = decode_provider_frame_observed(Frame, Data0),
    case Decoded of
        {ok, Specs} ->
            transport_consumed(Data),
            case lists:any(
                   fun(#{kind := Kind}) -> Kind =:= setup_complete end,
                   Specs) of
                true -> close_transition(duplicate_setup_complete, Data);
                false ->
                    Data1 = apply_provider_specs(Specs, Data),
                    case maps:take(provider_close_reason, Data1) of
                        {Reason, CloseData} ->
                            close_transition(Reason, CloseData);
                        error ->
                            case maps:get(go_away, Data1, false) of
                                true -> begin_reconnect(go_away, Data1);
                                false -> {keep_state, Data1}
                            end
                    end
            end;
        {error, _} = Error ->
            protocol_error_transition(Error, Data)
    end.

protocol_error_transition(
  {error, {live_protocol_error, Path, Detail}}, Data)
  when is_list(Path), is_atom(Detail) ->
    %% Paths and reason atoms contain schema metadata only. They are useful
    %% for diagnosing provider drift while raw frames, content, media and
    %% credentials remain excluded from events and OTP diagnostics.
    SafePath = [protocol_path_segment(Segment) || Segment <- Path],
    Payload = #{reason => <<"provider_protocol_error">>,
                path => SafePath,
                detail => atom_to_binary(Detail, utf8)},
    close_transition(protocol_error, emit(error, Payload, Data));
protocol_error_transition(_Error, Data) ->
    close_transition(protocol_error, Data).

protocol_path_segment(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
protocol_path_segment(Value) when is_integer(Value), Value >= 0 -> Value;
protocol_path_segment(Value) when is_binary(Value), byte_size(Value) =< 128 ->
    Value;
protocol_path_segment(_Value) -> <<"unknown">>.

decode_provider_frame(Frame, Data) ->
    Provider = maps:get(provider, Data),
    Config = maps:get(provider_config, Data),
    try Provider:decode_server(Frame, Config) of
        {ok, Specs} when is_list(Specs) -> {ok, Specs};
        {error, _} = Error -> Error;
        _ -> {error, invalid_provider_result}
    catch
        _:_ -> {error, provider_failure}
    end.

decode_provider_frame_observed(Frame, Data0) ->
    Obs0 = maps:get(observability, Data0),
    Span = adk_live_observability:start_receive(Obs0),
    Result = decode_provider_frame(Frame, Data0),
    Status = case Result of
        {ok, _} -> ok;
        {error, Reason} when is_atom(Reason) -> {error, Reason};
        {error, _} -> {error, protocol_error}
    end,
    Obs = adk_live_observability:finish_receive(Span, Status, Obs0),
    {Result, Data0#{observability => Obs}}.

handle_authorized_call(From, status, State, Data) ->
    reply(From, {ok, status_map(State, Data)});
handle_authorized_call(From, {send_voice, _Continuity, _Kind, _Action},
                       State, _Data)
  when State =/= active ->
    reply(From, {error, {not_ready, State}});
handle_authorized_call(
  From, {send_voice, Continuity, Kind, Action}, active,
  #{voice_continuity := Continuity} = Data) ->
    case admit_input(Kind, Action, Data) of
        {ok, InputSequence, Data1} ->
            {keep_state, Data1,
             [{reply, From, {ok, InputSequence}},
              {next_event, internal, drain_ingress}]};
        {error, Reason} -> reply(From, {error, Reason})
    end;
handle_authorized_call(From, {send_voice, _Continuity, _Kind, _Action},
                       active, _Data) ->
    reply(From, {error, live_voice_reconnect_required});
handle_authorized_call(From, {send, _Kind, _Action}, State, _Data)
  when State =/= active ->
    reply(From, {error, {not_ready, State}});
handle_authorized_call(
  From, {send, tool_response,
         {tool_response, Id, _Name, _Response} = Action}, active, Data) ->
    case automatic_tool_call(Id, Data) of
        true -> reply(From, {error, tool_call_managed_by_executor});
        false ->
            case admit_input(tool_response, Action, Data) of
                {ok, InputSequence, Data1} ->
                    {keep_state, Data1,
                     [{reply, From, {ok, InputSequence}},
                      {next_event, internal, drain_ingress}]};
                {error, Reason} -> reply(From, {error, Reason})
            end
    end;
handle_authorized_call(From, {send, Kind, Action}, active, Data) ->
    case admit_input(Kind, Action, Data) of
        {ok, InputSequence, Data1} ->
            {keep_state, Data1,
             [{reply, From, {ok, InputSequence}},
              {next_event, internal, drain_ingress}]};
        {error, Reason} -> reply(From, {error, Reason})
    end;
handle_authorized_call(From, {subscribe, Subscriber, Credit}, State, Data)
  when State =/= closed ->
    case add_subscriber(Subscriber, Credit, Data) of
        {ok, Data1} ->
            Info = #{latest_sequence => maps:get(sequence, Data1),
                     state => State,
                     turn_epoch => maps:get(turn_epoch, Data1),
                     generation_epoch => maps:get(generation_epoch, Data1)},
            {keep_state, Data1, [{reply, From, {ok, Info}}]};
        {error, Reason} -> reply(From, {error, Reason})
    end;
handle_authorized_call(
  From, {subscribe_voice, Subscriber, Credit}, State, Data)
  when State =/= closed ->
    case add_subscriber(Subscriber, Credit, Data) of
        {ok, Data1} ->
            ContinuityToken = maps:get(voice_continuity, Data1),
            VoiceSubscribers = maps:get(voice_subscribers, Data1),
            Data2 = Data1#{voice_subscribers =>
                               VoiceSubscribers#{Subscriber =>
                                                     ContinuityToken}},
            Info = #{latest_sequence => maps:get(sequence, Data1),
                     state => State,
                     turn_epoch => maps:get(turn_epoch, Data1),
                     generation_epoch => maps:get(generation_epoch, Data1),
                     continuity_token => ContinuityToken},
            {keep_state, Data2, [{reply, From, {ok, Info}}]};
        {error, Reason} -> reply(From, {error, Reason})
    end;
handle_authorized_call(From, {subscribe, _Subscriber, _Credit}, closed,
                       _Data) ->
    reply(From, {error, closed});
handle_authorized_call(
  From, {subscribe_voice, _Subscriber, _Credit}, closed, _Data) ->
    reply(From, {error, closed});
handle_authorized_call(From, {ack, Subscriber, Sequence}, _State, Data) ->
    case acknowledge(Subscriber, Sequence, Data) of
        {ok, Data1} -> {keep_state, Data1, [{reply, From, ok}]};
        {error, Reason} -> reply(From, {error, Reason})
    end;
handle_authorized_call(From, {unsubscribe, Subscriber}, _State, Data) ->
    {keep_state, remove_subscriber(Subscriber, Data),
     [{reply, From, ok}]};
handle_authorized_call(From, {close, _OpaqueReason}, closed, _Data) ->
    reply(From, ok);
handle_authorized_call(From, {close, _OpaqueReason}, _State, Data) ->
    Data0 = stop_all_tool_workers(client_closed, Data),
    Data1 = terminal(client_closed, Data0),
    Data2 = close_observability({error, client_closed}, Data1),
    close_transport(client_closed, Data2),
    release_credential(Data2),
    {next_state, closed, Data2,
     [{reply, From, ok},
      {state_timeout, ?DEFAULT_CLOSED_RETENTION_MS, expire}]};
handle_authorized_call(From, _Request, _State, _Data) ->
    reply(From, {error, bad_request}).

admit_input(tool_response,
            {tool_response, Id, Name, _Response} = Action, Data) ->
    Pending = maps:get(pending_tool_calls, Data),
    case maps:get(Id, Pending, undefined) of
        Name ->
            case admit_encoded_input({tool_response, Id}, Action, Data) of
                {ok, Sequence, Data0} ->
                    Completed = maps:get(completed_tool_calls, Data0),
                    Obs0 = maps:get(observability, Data0),
                    Obs = adk_live_observability:tool(response, Name, Obs0),
                    {ok, Sequence,
                     Data0#{pending_tool_calls => maps:remove(Id, Pending),
                            completed_tool_calls => Completed#{Id => Name},
                            observability => Obs}};
                {error, _} = Error -> Error
            end;
        _ -> {error, unknown_or_cancelled_tool_call}
    end;
admit_input(audio, {audio, Media} = Action, Data) ->
    case admit_encoded_input(audio, Action, Data) of
        {ok, Sequence, Data0} ->
            Obs0 = maps:get(observability, Data0),
            Obs = adk_live_observability:media(
                    input, audio, adk_live_media:bytes(Media), Obs0),
            {ok, Sequence, Data0#{observability => Obs}};
        {error, _} = Error -> Error
    end;
admit_input(video, {video_frame, Media} = Action, Data) ->
    case admit_encoded_input(video, Action, Data) of
        {ok, Sequence, Data0} ->
            Obs0 = maps:get(observability, Data0),
            Obs = adk_live_observability:media(
                    input, video, adk_live_media:bytes(Media), Obs0),
            {ok, Sequence, Data0#{observability => Obs}};
        {error, _} = Error -> Error
    end;
admit_input(Kind, Action, Data) ->
    admit_encoded_input(Kind, Action, Data).

admit_encoded_input(Kind, Action, Data) ->
    Provider = maps:get(provider, Data),
    Config = maps:get(provider_config, Data),
    try Provider:encode_client(Action, Config) of
        {ok, Frame} when is_binary(Frame) -> enqueue_input(Kind, Frame, Data);
        {error, Reason} -> {error, Reason};
        _ -> {error, invalid_provider_result}
    catch
        _:_ -> {error, provider_failure}
    end.

enqueue_input(Kind, Frame, Data) ->
    Bytes = byte_size(Frame),
    Messages = maps:get(ingress_messages, Data),
    QueuedBytes = maps:get(ingress_bytes, Data),
    MaxMessages = maps:get(max_ingress_messages, Data),
    MaxBytes = maps:get(max_ingress_bytes, Data),
    case Bytes =< MaxBytes andalso Messages < MaxMessages
         andalso QueuedBytes + Bytes =< MaxBytes of
        false -> {error, ingress_backpressure};
        true ->
            InputSequence = maps:get(input_sequence, Data) + 1,
            Entry = #{kind => Kind,
                      frame => Frame,
                      bytes => Bytes,
                      input_sequence => InputSequence,
                      generation_epoch => maps:get(generation_epoch, Data)},
            Queue0 = maps:get(ingress, Data),
            Queue = case Kind of
                control -> queue:in_r(Entry, Queue0);
                {tool_response, _CallId} -> queue:in_r(Entry, Queue0);
                _ -> queue:in(Entry, Queue0)
            end,
            {ok, InputSequence,
             Data#{ingress => Queue,
                   ingress_messages => Messages + 1,
                   ingress_bytes => QueuedBytes + Bytes,
                   input_sequence => InputSequence}}
    end.

drain_ingress(Data) ->
    case maps:get(outbound_pending, Data, undefined) of
        #{ref := _} -> keep_state_and_data;
        undefined -> drain_next_ingress(Data)
    end.

drain_next_ingress(Data) ->
    Queue = maps:get(ingress, Data),
    case queue:out(Queue) of
        {empty, _} -> keep_state_and_data;
        {{value, #{frame := Frame} = Entry}, Queue1} ->
            case safe_transport_send(Frame, Data) of
                {ok, synchronous} ->
                    Data1 = release_ingress_entry(
                              Entry, Data#{ingress => Queue1}),
                    Actions = case queue:is_empty(Queue1) of
                        true -> [];
                        false -> [{next_event, internal, drain_ingress}]
                    end,
                    {keep_state, Data1, Actions};
                {ok, SendRef} ->
                    {keep_state,
                     Data#{ingress => Queue1,
                           outbound_pending =>
                               #{ref => SendRef, entry => Entry}}};
                {error, busy} ->
                    keep_state_and_data;
                {error, _} ->
                    close_transition(transport_send_failed, Data)
            end
    end.

release_ingress_entry(#{bytes := Bytes}, Data) ->
    Data#{ingress_messages => maps:get(ingress_messages, Data) - 1,
          ingress_bytes => maps:get(ingress_bytes, Data) - Bytes}.

%% Provider events ----------------------------------------------------------

apply_provider_specs(Specs, Data) ->
    {Interruptions, Others} = lists:partition(
                                fun(#{kind := Kind}) ->
                                    Kind =:= interrupted
                                end, Specs),
    %% Media in a frame which also declares interruption belongs to the
    %% interrupted generation.  Never enqueue it after the priority control
    %% event under the next generation epoch.
    DeliverableOthers = case Interruptions of
        [] -> Others;
        _ -> [Spec || Spec = #{kind := Kind} <- Others, Kind =/= audio]
    end,
    lists:foldl(fun apply_provider_spec_until_close/2, Data,
                Interruptions ++ DeliverableOthers).

apply_provider_spec_until_close(_Spec,
                                #{provider_close_reason := _} = Data) ->
    Data;
apply_provider_spec_until_close(Spec, Data) ->
    apply_provider_spec(Spec, Data).

apply_provider_spec(#{kind := resumption_update,
                      payload := #{handle := Handle,
                                   resumable := Resumable}}, Data) ->
    Data1 = Data#{resumption_handle => Handle,
                  resumable => Resumable},
    emit(resumption_status,
         #{resumable => Resumable, handle_updated => true}, Data1);
apply_provider_spec(#{kind := tool_call,
                      payload := #{id := Id, name := Name} = Payload}, Data) ->
    Pending = maps:get(pending_tool_calls, Data),
    Completed = maps:get(completed_tool_calls, Data),
    case maps:is_key(Id, Pending) orelse maps:is_key(Id, Completed)
         orelse map_size(Pending) >= ?MAX_PENDING_TOOL_CALLS
         orelse map_size(Completed) >= ?MAX_COMPLETED_TOOL_CALLS of
        true ->
            ErrorData = emit(
                          error,
                          #{reason => <<"duplicate_or_excess_tool_call">>,
                            call_id => Id}, Data),
            %% Gemini function calls are synchronous. Silently ignoring an
            %% untrackable call leaves the provider waiting forever, so close
            %% the stream after emitting bounded correlation metadata.
            ErrorData#{provider_close_reason => invalid_tool_call_sequence};
        false ->
            Obs0 = maps:get(observability, Data),
            Obs = adk_live_observability:tool(received, Name, Obs0),
            Data0 = emit(tool_call, Payload,
                         Data#{pending_tool_calls => Pending#{Id => Name},
                               observability => Obs}),
            maybe_schedule_tool(Payload, Data0)
    end;
apply_provider_spec(#{kind := tool_cancelled,
                      payload := #{ids := Ids} = Payload}, Data0) ->
    Data1 = cancel_tool_calls(Ids, Data0),
    emit(tool_cancelled, Payload, Data1);
apply_provider_spec(#{kind := interrupted, payload := Payload}, Data0) ->
    Generation = maps:get(generation_epoch, Data0),
    %% Interruption cancels the provider's output generation, not already
    %% accepted client input. Keep queued/in-flight input audio and only drop
    %% stale output audio which has not reached subscribers yet.
    Data2 = purge_subscriber_audio(Data0, Generation),
    Obs0 = maps:get(observability, Data2),
    Obs = adk_live_observability:lifecycle(interrupted, Obs0),
    Data3 = emit(interrupted, Payload, Data2#{observability => Obs}),
    Data3#{generation_epoch => Generation + 1};
apply_provider_spec(#{kind := turn_complete, payload := Payload}, Data0) ->
    Data = emit(turn_complete, Payload, Data0),
    Data#{turn_epoch => maps:get(turn_epoch, Data) + 1};
apply_provider_spec(#{kind := go_away, payload := Payload}, Data) ->
    Obs0 = maps:get(observability, Data),
    Obs = adk_live_observability:lifecycle(go_away, Obs0),
    emit(go_away, Payload, Data#{go_away => true, observability => Obs});
apply_provider_spec(#{kind := audio, payload := Media}, Data) ->
    Obs0 = maps:get(observability, Data),
    Obs = adk_live_observability:media(
            output, audio, adk_live_media:bytes(Media), Obs0),
    emit(audio, Media, Data#{observability => Obs});
apply_provider_spec(#{kind := Kind, payload := Payload}, Data) ->
    emit(Kind, Payload, Data).

emit(Kind, Payload, Data) ->
    Sequence = maps:get(sequence, Data) + 1,
    Turn = maps:get(turn_epoch, Data),
    Generation = maps:get(generation_epoch, Data),
    case adk_live_event:new(Kind, Payload) of
        {ok, Event0} ->
            {ok, Event} = adk_live_event:with_envelope(
                            Event0, Sequence, Turn, Generation),
            broadcast(Event, Data#{sequence => Sequence});
        {error, _} ->
            %% Provider adapters are trusted modules, but their output remains
            %% structurally checked. Never broadcast an unchecked payload.
            Data
    end.

terminal(Reason, Data) ->
    emit(terminal, #{reason => atom_to_binary(Reason, utf8)}, Data).

%% Trusted tool execution --------------------------------------------------

maybe_schedule_tool(_Call, #{tool_execution := disabled} = Data) -> Data;
maybe_schedule_tool(#{name := Name} = Call,
                    #{tool_execution := Execution} = Data) ->
    case lists:member(Name, maps:get(allowed_tools, Execution)) of
        false -> Data;
        true ->
            Queue = queue:in(Call, maps:get(tool_queue, Data)),
            drain_tool_workers(Data#{tool_queue => Queue})
    end.

automatic_tool_call(Id, Data) ->
    maps:is_key(Id, maps:get(tool_workers, Data)) orelse
    lists:any(fun(#{id := QueuedId}) -> QueuedId =:= Id end,
              queue:to_list(maps:get(tool_queue, Data))).

drain_tool_workers(#{tool_execution := disabled} = Data) -> Data;
drain_tool_workers(#{tool_execution := Execution} = Data) ->
    Workers = maps:get(tool_workers, Data),
    Queue = maps:get(tool_queue, Data),
    case map_size(Workers) < maps:get(max_concurrency, Execution)
         andalso not queue:is_empty(Queue) of
        false -> Data;
        true ->
            {{value, Call}, Remaining} = queue:out(Queue),
            Data0 = Data#{tool_queue => Remaining},
            drain_tool_workers(start_tool_worker(Call, Execution, Data0))
    end.

start_tool_worker(#{id := Id, name := Name} = Call, Execution, Data0) ->
    Token = make_ref(),
    Owner = self(),
    Executor = maps:get(executor, Execution),
    Options = maps:get(options, Execution),
    MaxResponseBytes = maps:get(max_response_bytes, Execution),
    MaxHeapWords = maps:get(max_heap_words, Execution),
    Obs0 = maps:get(observability, Data0),
    Span = adk_live_observability:start_tool(Name, Id, Obs0),
    Worker = fun() ->
        tool_worker(Owner, Token, Executor, Call, Options,
                    MaxResponseBytes)
    end,
    SpawnOptions = [monitor, {message_queue_data, off_heap},
                    {fullsweep_after, 0},
                    {max_heap_size,
                     #{size => MaxHeapWords, kill => true,
                       error_logger => false}}],
    {Pid, Monitor} = spawn_opt(Worker, SpawnOptions),
    Timer = erlang:send_after(
              maps:get(timeout_ms, Execution), Owner,
              {adk_live_tool_timeout, Token, Id}),
    Entry = #{token => Token, pid => Pid, monitor => Monitor,
              timer => Timer, name => Name, span => Span},
    Workers = maps:get(tool_workers, Data0),
    Refs = maps:get(tool_worker_refs, Data0),
    Obs = adk_live_observability:tool(started, Name, Obs0),
    Data0#{tool_workers => Workers#{Id => Entry},
           tool_worker_refs => Refs#{Monitor => Id},
           observability => Obs}.

tool_worker(Owner, Token, Executor, Call, Options, MaxResponseBytes) ->
    Result0 = try Executor:execute(Call, Options) of
        Returned -> Returned
    catch
        _:_ -> {error, executor_failed}
    end,
    Result = normalize_tool_result(Result0, MaxResponseBytes),
    Owner ! {adk_live_tool_result, Token, maps:get(id, Call), Result}.

normalize_tool_result({ok, Response}, MaxBytes) when is_map(Response) ->
    case adk_json:normalize(Response) of
        {ok, Checked} when is_map(Checked) ->
            try byte_size(jsx:encode(Checked)) of
                Size when Size =< MaxBytes -> {ok, Checked};
                _ -> {error, response_too_large}
            catch
                _:_ -> {error, invalid_response}
            end;
        _ -> {error, invalid_response}
    end;
normalize_tool_result({error, _Opaque}, _MaxBytes) ->
    {error, execution_failed};
normalize_tool_result(_Other, _MaxBytes) ->
    {error, invalid_executor_result}.

handle_tool_result(Token, Id, Result, Data) ->
    case take_tool_worker(Id, Token, Data) of
        error -> keep_state_and_data;
        {ok, Entry, Data0} ->
            complete_tool_execution(Id, Result, Entry, Data0)
    end.

handle_tool_timeout(Token, Id, Data) ->
    case take_tool_worker(Id, Token, Data) of
        error -> keep_state_and_data;
        {ok, Entry, Data0} ->
            exit(maps:get(pid, Entry), kill),
            complete_tool_execution(
              Id, {error, execution_timeout}, Entry, Data0)
    end.

handle_tool_down(Ref, Id, Data) ->
    case maps:get(Id, maps:get(tool_workers, Data), undefined) of
        #{monitor := Ref, token := Token} ->
            case take_tool_worker(Id, Token, Data) of
                {ok, Entry, Data0} ->
                    complete_tool_execution(
                      Id, {error, worker_terminated}, Entry, Data0);
                error -> keep_state_and_data
            end;
        _ -> keep_state_and_data
    end.

complete_tool_execution(Id, Result, Entry, Data0) ->
    Name = maps:get(name, Entry),
    {Status, Outcome, Response} = tool_execution_response(Result),
    Obs0 = maps:get(observability, Data0),
    Obs1 = adk_live_observability:finish_tool(
             maps:get(span, Entry), Status, Obs0),
    Obs = adk_live_observability:tool(Outcome, Name, Obs1),
    Data1 = Data0#{observability => Obs},
    case maps:get(Id, maps:get(pending_tool_calls, Data1), undefined) of
        Name ->
            case admit_automatic_tool_response(Id, Name, Response, Data1) of
                {ok, Data2} ->
                    {keep_state, drain_tool_workers(Data2),
                     [{next_event, internal, drain_ingress}]};
                {error, Data2} ->
                    close_transition(tool_response_failed, Data2)
            end;
        _ ->
            {keep_state, drain_tool_workers(Data1)}
    end.

tool_execution_response({ok, Response}) ->
    {ok, completed, Response};
tool_execution_response({error, execution_timeout}) ->
    {{error, timeout}, timeout,
     #{<<"error">> => <<"tool_execution_failed">>,
       <<"type">> => <<"timeout">>}};
tool_execution_response({error, response_too_large}) ->
    {{error, response_too_large}, failed,
     #{<<"error">> => <<"tool_execution_failed">>,
       <<"type">> => <<"response_too_large">>}};
tool_execution_response({error, _}) ->
    {{error, execution_failed}, failed,
     #{<<"error">> => <<"tool_execution_failed">>,
       <<"type">> => <<"execution_failed">>}}.

admit_automatic_tool_response(Id, Name, Response, Data) ->
    Action = {tool_response, Id, Name, Response},
    case admit_input(tool_response, Action, Data) of
        {ok, _Sequence, Data0} -> {ok, Data0};
        {error, ingress_backpressure} ->
            %% Accepted input is never silently discarded to make room. The
            %% caller closes the synchronous stream, which cannot then remain
            %% waiting for a response that the bounded queue rejected.
            {error, Data};
        {error, _} -> {error, Data}
    end.

take_tool_worker(Id, Token, Data) ->
    Workers = maps:get(tool_workers, Data),
    case maps:get(Id, Workers, undefined) of
        #{token := Token, monitor := Monitor, timer := Timer} = Entry ->
            _ = erlang:cancel_timer(Timer),
            erlang:demonitor(Monitor, [flush]),
            Refs = maps:remove(Monitor, maps:get(tool_worker_refs, Data)),
            {ok, Entry,
             Data#{tool_workers => maps:remove(Id, Workers),
                   tool_worker_refs => Refs}};
        _ -> error
    end.

cancel_tool_calls(Ids, Data0) ->
    Queued = [Call || Call <- queue:to_list(maps:get(tool_queue, Data0)),
                       not lists:member(maps:get(id, Call), Ids)],
    Data1 = Data0#{tool_queue => queue:from_list(Queued)},
    Data2 = lists:foldl(fun cancel_one_tool_call/2, Data1, Ids),
    purge_tool_response_inputs(Data2, Ids).

cancel_one_tool_call(Id, Data0) ->
    Pending = maps:get(pending_tool_calls, Data0),
    Name = maps:get(Id, Pending, undefined),
    Data1 = case maps:get(Id, maps:get(tool_workers, Data0), undefined) of
        #{token := Token} ->
            case take_tool_worker(Id, Token, Data0) of
                {ok, Entry, Taken} ->
                    exit(maps:get(pid, Entry), kill),
                    ToolObs0 = maps:get(observability, Taken),
                    ToolObs = adk_live_observability:finish_tool(
                                maps:get(span, Entry), {error, cancelled},
                                ToolObs0),
                    Taken#{observability => ToolObs};
                error -> Data0
            end;
        _ -> Data0
    end,
    case Name of
        undefined -> Data1;
        _ ->
            Completed = maps:get(completed_tool_calls, Data1),
            CancelObs0 = maps:get(observability, Data1),
            CancelObs = adk_live_observability:tool(
                          cancelled, Name, CancelObs0),
            Data1#{pending_tool_calls => maps:remove(Id, Pending),
                   completed_tool_calls => Completed#{Id => Name},
                   observability => CancelObs}
    end.

stop_all_tool_workers(Reason, Data0) ->
    Workers = maps:get(tool_workers, Data0, #{}),
    Obs0 = maps:get(observability, Data0, disabled),
    Obs = maps:fold(
            fun(_Id, Entry, Acc) ->
                _ = erlang:cancel_timer(maps:get(timer, Entry)),
                erlang:demonitor(maps:get(monitor, Entry), [flush]),
                exit(maps:get(pid, Entry), kill),
                Obs1 = adk_live_observability:finish_tool(
                         maps:get(span, Entry), {error, Reason}, Acc),
                adk_live_observability:tool(
                  cancelled, maps:get(name, Entry), Obs1)
            end, Obs0, Workers),
    Data0#{tool_workers => #{}, tool_worker_refs => #{},
           tool_queue => queue:new(), observability => Obs}.

cancel_tools_for_continuity(Reason, Data0) ->
    Data = stop_all_tool_workers(Reason, Data0),
    Pending = maps:get(pending_tool_calls, Data),
    Completed = maps:get(completed_tool_calls, Data),
    Data#{pending_tool_calls => #{},
          completed_tool_calls => maps:merge(Completed, Pending)}.

%% Subscriber credit -------------------------------------------------------

add_subscriber(Subscriber, Credit, Data) ->
    Subscribers = maps:get(subscribers, Data),
    case maps:is_key(Subscriber, Subscribers) of
        true -> {error, already_subscribed};
        false ->
            case map_size(Subscribers) < maps:get(max_subscribers, Data) of
                false -> {error, subscriber_limit};
                true ->
                    case validate_credit(Credit, Data) of
                        {ok, Messages, Bytes} ->
                            Ref = erlang:monitor(process, Subscriber),
                            Sub = #{monitor => Ref,
                                    window_messages => Messages,
                                    window_bytes => Bytes,
                                    credit_messages => Messages,
                                    credit_bytes => Bytes,
                                    inflight => #{},
                                    queue => queue:new(),
                                    queued_messages => 0,
                                    queued_bytes => 0},
                            Refs = maps:get(subscriber_refs, Data),
                            {ok,
                             Data#{subscribers =>
                                       Subscribers#{Subscriber => Sub},
                                   subscriber_refs =>
                                       Refs#{Ref => Subscriber}}};
                        {error, _} = Error -> Error
                    end
            end
    end.

validate_credit(#{messages := Messages, bytes := Bytes} = Credit, Data)
  when is_integer(Messages), Messages > 0,
       is_integer(Bytes), Bytes > 0 ->
    case lists:sort(maps:keys(Credit)) =:= [bytes, messages]
         andalso Messages =< maps:get(max_subscriber_messages, Data)
         andalso Bytes =< maps:get(max_subscriber_bytes, Data) of
        true -> {ok, Messages, Bytes};
        false -> {error, invalid_credit}
    end;
validate_credit(_Credit, _Data) -> {error, invalid_credit}.

broadcast(Event, Data) ->
    SessionId = maps:get(session_id, Data),
    MaxMessages = maps:get(max_subscriber_messages, Data),
    MaxBytes = maps:get(max_subscriber_bytes, Data),
    Subscribers0 = maps:get(subscribers, Data),
    Refs0 = maps:get(subscriber_refs, Data),
    Voice0 = maps:get(voice_subscribers, Data),
    {Subscribers, Refs, Voice} = maps:fold(
      fun(Pid, Sub0, {SubsAcc, RefsAcc, VoiceAcc}) ->
          case queue_subscriber_event(Event, Sub0,
                                      MaxMessages, MaxBytes,
                                      SessionId, Pid) of
              {ok, Sub} ->
                  {SubsAcc#{Pid => Sub}, RefsAcc, VoiceAcc};
              drop ->
                  Ref = maps:get(monitor, Sub0),
                  erlang:demonitor(Ref, [flush]),
                  Pid ! {adk_live_subscriber_dropped,
                         SessionId, backpressure},
                  {SubsAcc, maps:remove(Ref, RefsAcc),
                   maps:remove(Pid, VoiceAcc)}
          end
      end, {#{}, Refs0, Voice0}, Subscribers0),
    Data#{subscribers => Subscribers,
          subscriber_refs => Refs,
          voice_subscribers => Voice}.

queue_subscriber_event(Event, Sub0, MaxMessages, MaxBytes,
                       SessionId, Pid) ->
    EventBytes = adk_live_event:bytes(Event),
    WindowBytes = maps:get(window_bytes, Sub0),
    QueuedMessages = maps:get(queued_messages, Sub0),
    QueuedBytes = maps:get(queued_bytes, Sub0),
    case EventBytes =< WindowBytes
         andalso QueuedMessages < MaxMessages
         andalso QueuedBytes + EventBytes =< MaxBytes of
        false -> drop;
        true ->
            Entry = {adk_live_event:sequence(Event), Event, EventBytes},
            Queue = queue:in(Entry, maps:get(queue, Sub0)),
            Sub1 = Sub0#{queue => Queue,
                         queued_messages => QueuedMessages + 1,
                         queued_bytes => QueuedBytes + EventBytes},
            {ok, drain_subscriber(Sub1, SessionId, Pid)}
    end.

drain_subscriber(Sub0, SessionId, Pid) ->
    case queue:peek(maps:get(queue, Sub0)) of
        empty -> Sub0;
        {value, {Sequence, Event, EventBytes}} ->
            Messages = maps:get(credit_messages, Sub0),
            Bytes = maps:get(credit_bytes, Sub0),
            case Messages > 0 andalso Bytes >= EventBytes of
                false -> Sub0;
                true ->
                    {{value, _}, Queue} = queue:out(maps:get(queue, Sub0)),
                    Pid ! {adk_live_event, SessionId, Sequence, Event},
                    Inflight = maps:get(inflight, Sub0),
                    Sub = Sub0#{queue => Queue,
                                queued_messages =>
                                    maps:get(queued_messages, Sub0) - 1,
                                queued_bytes =>
                                    maps:get(queued_bytes, Sub0) - EventBytes,
                                credit_messages => Messages - 1,
                                credit_bytes => Bytes - EventBytes,
                                inflight => Inflight#{Sequence => EventBytes}},
                    drain_subscriber(Sub, SessionId, Pid)
            end
    end.

acknowledge(Subscriber, Sequence, Data) ->
    Subscribers = maps:get(subscribers, Data),
    case maps:find(Subscriber, Subscribers) of
        error -> {error, not_subscribed};
        {ok, Sub0} ->
            Inflight0 = maps:get(inflight, Sub0),
            case maps:take(Sequence, Inflight0) of
                error -> {error, unknown_sequence};
                {EventBytes, Inflight} ->
                    Messages = erlang:min(
                                 maps:get(window_messages, Sub0),
                                 maps:get(credit_messages, Sub0) + 1),
                    Bytes = erlang:min(
                              maps:get(window_bytes, Sub0),
                              maps:get(credit_bytes, Sub0) + EventBytes),
                    Sub1 = Sub0#{inflight => Inflight,
                                 credit_messages => Messages,
                                 credit_bytes => Bytes},
                    SessionId = maps:get(session_id, Data),
                    Sub = drain_subscriber(Sub1, SessionId, Subscriber),
                    {ok, Data#{subscribers =>
                                   Subscribers#{Subscriber => Sub}}}
            end
    end.

remove_subscriber(Subscriber, Data) ->
    Subscribers = maps:get(subscribers, Data),
    case maps:take(Subscriber, Subscribers) of
        error -> Data;
        {Sub, Remaining} ->
            Ref = maps:get(monitor, Sub),
            erlang:demonitor(Ref, [flush]),
            Refs = maps:remove(Ref, maps:get(subscriber_refs, Data)),
            Voice = maps:remove(
                      Subscriber, maps:get(voice_subscribers, Data)),
            Data#{subscribers => Remaining,
                  subscriber_refs => Refs,
                  voice_subscribers => Voice}
    end.

remove_subscriber_by_monitor(Ref, Pid, Data) ->
    case maps:get(Ref, maps:get(subscriber_refs, Data), undefined) of
        Pid ->
            Subscribers = maps:remove(Pid, maps:get(subscribers, Data)),
            Refs = maps:remove(Ref, maps:get(subscriber_refs, Data)),
            Voice = maps:remove(Pid, maps:get(voice_subscribers, Data)),
            Data#{subscribers => Subscribers,
                  subscriber_refs => Refs,
                  voice_subscribers => Voice};
        _ -> Data
    end.

purge_tool_response_inputs(Data, Ids) ->
    Entries0 = queue:to_list(maps:get(ingress, Data)),
    Entries = [Entry || Entry <- Entries0,
                        not cancelled_tool_response(Entry, Ids)],
    {PendingMessages, PendingBytes} = pending_ingress_usage(Data),
    Data#{ingress => queue:from_list(Entries),
          ingress_messages => length(Entries) + PendingMessages,
          ingress_bytes => lists:sum([maps:get(bytes, E) || E <- Entries])
                           + PendingBytes}.

pending_ingress_usage(#{outbound_pending :=
                            #{entry := #{bytes := Bytes}}}) -> {1, Bytes};
pending_ingress_usage(_Data) -> {0, 0}.

cancelled_tool_response(#{kind := {tool_response, Id}}, Ids) ->
    lists:member(Id, Ids);
cancelled_tool_response(_Entry, _Ids) -> false.

purge_subscriber_audio(Data, Generation) ->
    Subscribers0 = maps:get(subscribers, Data),
    Subscribers = maps:map(
      fun(_Pid, Sub) -> purge_subscriber_audio_queue(Sub, Generation) end,
      Subscribers0),
    Data#{subscribers => Subscribers}.

purge_subscriber_audio_queue(Sub, Generation) ->
    Entries0 = queue:to_list(maps:get(queue, Sub)),
    Entries = [Entry || Entry = {_Seq, Event, _Bytes} <- Entries0,
                        not (adk_live_event:kind(Event) =:= audio andalso
                             maps:get(generation_epoch, Event) =:= Generation)],
    Sub#{queue => queue:from_list(Entries),
         queued_messages => length(Entries),
         queued_bytes => lists:sum([Bytes || {_Seq, _Event, Bytes} <- Entries])}.

%% Validation, transport, diagnostics --------------------------------------

validate_handoff(SessionId, Principal, Config) ->
    case valid_identity(SessionId, 256) andalso valid_identity(Principal, 4096) of
        false -> {error, invalid_live_session_identity};
        true -> validate_session_config(Config)
    end.

validate_session_config(Config) ->
    Allowed = [provider, provider_config, transport, transport_opts,
               max_ingress_messages, max_ingress_bytes,
               max_subscribers, max_subscriber_messages,
               max_subscriber_bytes,
               connect_timeout_ms, setup_timeout_ms,
               max_reconnect_attempts, reconnect_backoff_ms,
               tool_execution, observability],
    case maps:keys(Config) -- Allowed of
        [] -> validate_session_config_fields(Config);
        [Key | _] -> {error, {invalid_live_session_option, Key}}
    end.

validate_session_config_fields(Config) ->
    Provider = maps:get(provider, Config, adk_live_gemini),
    ProviderConfig = maps:get(provider_config, Config, #{}),
    Transport = maps:get(transport, Config, undefined),
    TransportOpts = maps:get(transport_opts, Config, #{}),
    Values = #{max_ingress_messages =>
                   maps:get(max_ingress_messages, Config,
                            ?DEFAULT_MAX_INGRESS_MESSAGES),
               max_ingress_bytes =>
                   maps:get(max_ingress_bytes, Config,
                            ?DEFAULT_MAX_INGRESS_BYTES),
               max_subscriber_messages =>
                   maps:get(max_subscriber_messages, Config,
                            ?DEFAULT_MAX_SUBSCRIBER_MESSAGES),
               max_subscriber_bytes =>
                   maps:get(max_subscriber_bytes, Config,
                            ?DEFAULT_MAX_SUBSCRIBER_BYTES),
               max_subscribers =>
                   maps:get(max_subscribers, Config,
                            ?DEFAULT_MAX_SUBSCRIBERS),
               connect_timeout_ms =>
                   maps:get(connect_timeout_ms, Config,
                            ?DEFAULT_CONNECT_TIMEOUT_MS),
               setup_timeout_ms =>
                   maps:get(setup_timeout_ms, Config,
                            ?DEFAULT_SETUP_TIMEOUT_MS),
               max_reconnect_attempts =>
                   maps:get(max_reconnect_attempts, Config,
                            ?DEFAULT_MAX_RECONNECT_ATTEMPTS),
               reconnect_backoff_ms =>
                   maps:get(reconnect_backoff_ms, Config,
                            ?DEFAULT_RECONNECT_BACKOFF_MS)},
    case is_atom(Provider) andalso is_atom(Transport)
         andalso is_map(ProviderConfig) andalso is_map(TransportOpts)
         andalso valid_limit_values(Values)
         andalso provider_available(Provider)
         andalso transport_available(Transport) of
        false -> {error, invalid_live_session_config};
        true ->
            case Provider:validate_config(ProviderConfig) of
                {ok, CheckedProviderConfig} ->
                    case {validate_tool_execution(
                            maps:get(tool_execution, Config, disabled),
                            CheckedProviderConfig,
                            maps:get(max_ingress_bytes, Values)),
                          adk_live_observability:validate_config(
                            maps:get(observability, Config, disabled))} of
                        {{ok, ToolExecution}, {ok, Observability}} ->
                            {ok, Values#{
                                   provider => Provider,
                                   provider_config => CheckedProviderConfig,
                                   transport => Transport,
                                   transport_opts => TransportOpts,
                                   tool_execution => ToolExecution,
                                   observability => Observability}};
                        {{error, _} = Error, _} -> Error;
                        {_, {error, _} = Error} -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

prepare_session_credential(Checked) ->
    Options = maps:get(transport_opts, Checked),
    case {maps:find(api_key, Options),
          maps:find(credential_ref, Options)} of
        {{ok, _ApiKey}, {ok, _Reference}} ->
            {error, invalid_live_transport_credentials};
        {{ok, ApiKey}, error} ->
            case adk_live_credential_broker:start(self(), ApiKey) of
                {ok, CredentialRef} ->
                    Sanitized = maps:remove(api_key, Options),
                    {ok, Checked#{transport_opts =>
                                     Sanitized#{credential_ref =>
                                                    CredentialRef},
                                 credential_ref => CredentialRef,
                                 credential_owned => true}};
                {error, _} ->
                    {error, invalid_live_transport_credentials}
            end;
        {error, {ok, CredentialRef}} ->
            case adk_live_credential_broker:valid_ref(CredentialRef) of
                true ->
                    {ok, Checked#{credential_ref => CredentialRef,
                                 credential_owned => false}};
                false -> {error, invalid_live_transport_credentials}
            end;
        {error, error} ->
            {ok, Checked#{credential_ref => undefined,
                         credential_owned => false}}
    end.

validate_tool_execution(disabled, _ProviderConfig, _MaxIngressBytes) ->
    {ok, disabled};
validate_tool_execution(Execution, ProviderConfig, MaxIngressBytes)
  when is_map(Execution) ->
    AllowedKeys = [enabled, executor, policy, allowed_tools, options,
                   timeout_ms, max_concurrency, max_heap_words,
                   max_response_bytes],
    Required = [enabled, executor, policy, allowed_tools],
    Unknown = maps:keys(Execution) -- AllowedKeys,
    Missing = Required -- maps:keys(Execution),
    Enabled = maps:get(enabled, Execution, false),
    Executor = maps:get(executor, Execution, undefined),
    Policy = maps:get(policy, Execution, undefined),
    ToolNames = maps:get(allowed_tools, Execution, []),
    Options = maps:get(options, Execution, #{}),
    Timeout = maps:get(timeout_ms, Execution, ?DEFAULT_TOOL_TIMEOUT_MS),
    MaxHeap = maps:get(max_heap_words, Execution,
                       ?DEFAULT_TOOL_MAX_HEAP_WORDS),
    MaxResponse = maps:get(max_response_bytes, Execution,
                           ?DEFAULT_TOOL_MAX_RESPONSE_BYTES),
    DefaultConcurrency = case Policy of
        sequential -> 1;
        _ -> ?DEFAULT_TOOL_MAX_CONCURRENCY
    end,
    MaxConcurrency = maps:get(max_concurrency, Execution,
                              DefaultConcurrency),
    Declared = [Name || #{type := function, name := Name} <-
                            maps:get(tools, ProviderConfig, [])],
    case {Unknown, Missing, Enabled =:= true, is_atom(Executor),
          valid_tool_policy(Policy, MaxConcurrency),
          valid_tool_names(ToolNames), is_map(Options),
          bounded(Timeout, 10, 120000),
          bounded(MaxHeap, 1000, 10000000),
          bounded(MaxResponse, 256, 1048576),
          MaxResponse =< MaxIngressBytes,
          lists:all(fun(Name) -> lists:member(Name, Declared) end,
                    ToolNames)} of
        {[], [], true, true, true, true, true, true, true, true, true, true} ->
            case callbacks_available(Executor, [{execute, 2}]) of
                true ->
                    {ok, #{executor => Executor, policy => Policy,
                           allowed_tools => ToolNames, options => Options,
                           timeout_ms => Timeout,
                           max_concurrency => MaxConcurrency,
                           max_heap_words => MaxHeap,
                           max_response_bytes => MaxResponse}};
                false -> {error, invalid_live_tool_executor}
            end;
        {[_ | _], _, _, _, _, _, _, _, _, _, _, _} ->
            {error, {invalid_live_tool_execution_option, hd(Unknown)}};
        {_, [_ | _], _, _, _, _, _, _, _, _, _, _} ->
            {error, {missing_live_tool_execution_option, hd(Missing)}};
        _ -> {error, invalid_live_tool_execution}
    end;
validate_tool_execution(_, _ProviderConfig, _MaxIngressBytes) ->
    {error, invalid_live_tool_execution}.

valid_tool_policy(sequential, 1) -> true;
valid_tool_policy(concurrent, Max) -> bounded(Max, 1, 32);
valid_tool_policy(_, _) -> false.

valid_tool_names(Names) when is_list(Names), Names =/= [],
                             length(Names) =< 128 ->
    length(Names) =:= length(lists:usort(Names))
    andalso lists:all(fun(Name) -> valid_identity(Name, 128) end, Names);
valid_tool_names(_) -> false.

valid_limit_values(Values) ->
    bounded(maps:get(max_ingress_messages, Values), 1, 4096)
    andalso bounded(maps:get(max_ingress_bytes, Values), 1024, 67108864)
    andalso bounded(maps:get(max_subscriber_messages, Values), 1, 4096)
    andalso bounded(maps:get(max_subscriber_bytes, Values), 1024, 67108864)
    andalso bounded(maps:get(max_subscribers, Values),
                    1, ?MAX_SUBSCRIBERS)
    andalso bounded(maps:get(connect_timeout_ms, Values), 100, 120000)
    andalso bounded(maps:get(setup_timeout_ms, Values), 100, 120000)
    andalso bounded(maps:get(max_reconnect_attempts, Values), 0, 10)
    andalso bounded(maps:get(reconnect_backoff_ms, Values), 10, 60000).

provider_available(Module) ->
    callbacks_available(Module,
                        [{capabilities, 0}, {validate_config, 1},
                         {setup_frame, 1}, {encode_client, 2},
                         {decode_server, 2}]).

transport_available(Module) ->
    callbacks_available(Module, [{open, 2}, {send, 2}, {close, 2}]).

callbacks_available(Module, Callbacks) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            lists:all(fun({Name, Arity}) ->
                          erlang:function_exported(Module, Name, Arity)
                      end, Callbacks);
        _ -> false
    end.

safe_transport_open(Transport, Options) ->
    try Transport:open(self(), Options) of
        {ok, Handle} -> {ok, Handle};
        {error, _} = Error -> Error;
        _ -> {error, invalid_transport_result}
    catch
        _:_ -> {error, transport_failure}
    end.

safe_transport_send(Frame, Data) ->
    Transport = maps:get(transport, Data),
    Handle = maps:get(transport_handle, Data),
    try Transport:send(Handle, Frame) of
        ok -> {ok, synchronous};
        {ok, SendRef} -> {ok, SendRef};
        {error, busy} -> {error, busy};
        {error, _} -> {error, transport_send_failed};
        _ -> {error, transport_send_failed}
    catch
        _:_ -> {error, transport_send_failed}
    end.

transport_consumed(Data) ->
    Transport = maps:get(transport, Data),
    Handle = maps:get(transport_handle, Data),
    case erlang:function_exported(Transport, consumed, 2) of
        true -> _ = catch Transport:consumed(Handle, 1), ok;
        false -> ok
    end.

transport_lost(active, Reason, Data) ->
    begin_reconnect(Reason, Data);
transport_lost(setup_pending, Reason,
               #{resume_pending := true} = Data) ->
    retry_reconnect(Reason, Data);
transport_lost(reconnecting, Reason, Data) ->
    retry_reconnect(Reason, Data);
transport_lost(_State, Reason, Data) ->
    close_transition(Reason, Data).

begin_reconnect(Reason, Data) ->
    case can_resume(Data) of
        false -> close_transition(resumption_unavailable, Data);
        true ->
            invalidate_voice_continuity(Data),
            Dropped = maps:get(ingress_messages, Data),
            DroppedTotal = maps:get(reconnect_dropped_inputs, Data) + Dropped,
            ToolSafe = cancel_tools_for_continuity(reconnect, Data),
            Data0 = release_transport(ToolSafe),
            Obs0 = maps:get(observability, Data0),
            Obs = adk_live_observability:lifecycle(reconnecting, Obs0),
            Data1 = clear_ingress(
                      Data0#{go_away => false,
                             voice_continuity => make_ref(),
                             resume_pending => false,
                             reconnect_phase => backoff,
                             reconnect_dropped_inputs => DroppedTotal,
                             observability => Obs}),
            Payload = #{reason => atom_to_binary(Reason, utf8),
                        replayed_inputs => false,
                        dropped_inputs => Dropped,
                        attempt => maps:get(reconnect_attempts, Data1) + 1},
            Data2 = emit(reconnecting, Payload, Data1),
            {next_state, reconnecting, Data2,
             [{state_timeout, reconnect_delay(Data2), reconnect}]}
    end.

invalidate_voice_continuity(Data) ->
    SessionId = maps:get(session_id, Data),
    maps:foreach(
      fun(Subscriber, ContinuityToken) ->
          Subscriber !
              {adk_live_voice_continuity_invalidated, self(), SessionId,
               ContinuityToken}
      end, maps:get(voice_subscribers, Data)),
    ok.

retry_reconnect(Reason, Data) ->
    Obs0 = maps:get(observability, Data),
    Obs1 = adk_live_observability:finish_connect({error, Reason}, Obs0),
    DataObserved = Data#{observability => Obs1},
    case maps:get(reconnect_attempts, DataObserved) >=
         maps:get(max_reconnect_attempts, DataObserved) of
        true ->
            close_transition(reconnect_exhausted, DataObserved);
        false ->
            Data0 = release_transport(DataObserved),
            Data1 = Data0#{resume_pending => false,
                           reconnect_phase => backoff,
                           setup_frame => undefined},
            Payload = #{reason => atom_to_binary(Reason, utf8),
                        replayed_inputs => false,
                        dropped_inputs => 0,
                        attempt => maps:get(reconnect_attempts, Data1) + 1},
            Data2 = emit(reconnecting, Payload, Data1),
            {next_state, reconnecting, Data2,
             [{state_timeout, reconnect_delay(Data2), reconnect}]}
    end.

open_reconnect_transport(Data0) ->
    Attempt = maps:get(reconnect_attempts, Data0) + 1,
    Transport = maps:get(transport, Data0),
    Options = maps:get(transport_opts, Data0),
    Obs0 = maps:get(observability, Data0),
    Obs = adk_live_observability:start_connect(reconnect, Obs0),
    Data1 = Data0#{reconnect_attempts => Attempt,
                   reconnect_phase => connecting,
                   observability => Obs},
    case safe_transport_open(Transport, Options) of
        {ok, Handle} ->
            Monitor = monitor_handle(Handle),
            Timeout = maps:get(connect_timeout_ms, Data1),
            {keep_state,
             Data1#{transport_handle => Handle,
                    transport_monitor => Monitor},
             [{state_timeout, Timeout, reconnect_connect_timeout}]};
        {error, _} ->
            retry_reconnect(connect_failed, Data1)
    end.

can_resume(Data) ->
    Config = maps:get(provider_config, Data),
    maps:get(session_resumption, Config, false) =:= true
    andalso maps:get(resumable, Data, false) =:= true
    andalso is_binary(maps:get(resumption_handle, Data, undefined))
    andalso maps:get(max_reconnect_attempts, Data) > 0.

reconnect_delay(Data) ->
    Base = maps:get(reconnect_backoff_ms, Data),
    Attempt = erlang:min(maps:get(reconnect_attempts, Data), 6),
    erlang:min(Base * (1 bsl Attempt), 60000).

clear_ingress(Data) ->
    Data#{ingress => queue:new(),
          ingress_messages => 0,
          ingress_bytes => 0,
          outbound_pending => undefined}.

release_transport(Data) ->
    close_transport(reconnect, Data),
    case maps:get(transport_monitor, Data, undefined) of
        Ref when is_reference(Ref) -> erlang:demonitor(Ref, [flush]);
        _ -> ok
    end,
    Data#{transport_handle => undefined,
          transport_monitor => undefined,
          outbound_pending => undefined}.

close_transport(Reason, Data) ->
    case maps:get(transport_handle, Data, undefined) of
        undefined -> ok;
        Handle ->
            Transport = maps:get(transport, Data),
            _ = catch Transport:close(Handle, Reason),
            ok
    end.

close_transition(Reason, Data0) ->
    Data1 = stop_all_tool_workers(Reason, Data0),
    Data2 = terminal(Reason, Data1),
    Data = close_observability({error, Reason}, Data2),
    close_transport(Reason, Data),
    release_credential(Data),
    {next_state, closed, Data,
     [{state_timeout, ?DEFAULT_CLOSED_RETENTION_MS, expire}]}.

close_observability(Status, Data) ->
    case maps:get(observability, Data, disabled) of
        disabled -> Data;
        Obs -> Data#{observability => adk_live_observability:close(Status, Obs)}
    end.

release_credential(#{credential_owned := true,
                     credential_ref := CredentialRef}) ->
    adk_live_credential_broker:revoke(CredentialRef);
release_credential(_Data) -> ok.

monitor_handle(Handle) when is_pid(Handle) ->
    erlang:monitor(process, Handle);
monitor_handle(_Handle) -> undefined.

authorized(Principal, #{owner_scope := Expected})
  when is_binary(Principal), byte_size(Principal) > 0 ->
    crypto:hash(sha256, Principal) =:= Expected;
authorized(_Principal, _Data) -> false.

valid_identity(Value, Maximum) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< Maximum
    andalso try unicode:characters_to_binary(Value, utf8, utf8) of
                Value -> true;
                _ -> false
            catch _:_ -> false
            end;
valid_identity(_Value, _Maximum) -> false.

bounded(Value, Minimum, Maximum) ->
    is_integer(Value) andalso Value >= Minimum andalso Value =< Maximum.

status_map(State, Data) ->
    ProviderConfig = maps:get(provider_config, Data),
    #{session_id => maps:get(session_id, Data),
      state => State,
      model => maps:get(model, ProviderConfig),
      automatic_activity_detection =>
          maps:get(automatic_activity_detection, ProviderConfig, undefined),
      started_at => maps:get(started_at, Data),
      latest_sequence => maps:get(sequence, Data),
      input_queue_messages => maps:get(ingress_messages, Data),
      input_queue_bytes => maps:get(ingress_bytes, Data),
      subscriber_count => map_size(maps:get(subscribers, Data)),
      max_subscribers => maps:get(max_subscribers, Data),
      turn_epoch => maps:get(turn_epoch, Data),
      generation_epoch => maps:get(generation_epoch, Data),
      resumable => maps:get(resumable, Data),
      go_away => maps:get(go_away, Data),
      reconnect_attempts => maps:get(reconnect_attempts, Data),
      pending_tool_calls => map_size(maps:get(pending_tool_calls, Data)),
      tool_execution_policy => tool_execution_policy(Data),
      active_tool_workers => map_size(maps:get(tool_workers, Data)),
      queued_tool_calls => queue:len(maps:get(tool_queue, Data)),
      replayed_inputs => false}.

tool_execution_policy(#{tool_execution := disabled}) -> manual;
tool_execution_policy(#{tool_execution := Execution}) ->
    maps:get(policy, Execution).

reply(From, Value) ->
    {keep_state_and_data, [{reply, From, Value}]}.

%% Provider config, transport options, resumption handles, media frames and
%% subscriber queues must never enter sys/OTP diagnostics.
format_status(Status) ->
    maps:map(
      fun(state, Data) when is_map(Data) ->
              #{configured => maps:is_key(session_id, Data),
                started_at => maps:get(started_at, Data, undefined),
                input_queue_messages =>
                    maps:get(ingress_messages, Data, 0),
                input_queue_bytes => maps:get(ingress_bytes, Data, 0),
                subscriber_count =>
                    map_size(maps:get(subscribers, Data, #{})),
                latest_sequence => maps:get(sequence, Data, 0),
                resumable => maps:get(resumable, Data, false)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).
