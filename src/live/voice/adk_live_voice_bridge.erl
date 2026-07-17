%% @doc Owner-bound binary bridge between a WebSocket adapter and ADK Live.
%%
%% The bridge is deliberately transport agnostic.  It accepts only strict v1
%% binary frames, applies synchronous ingress backpressure, and forwards a
%% small public event projection to its owner.  Forwarded events retain their
%% ADK subscriber credit until the owner returns an exact binary ACK frame;
%% non-public events are acknowledged internally.
-module(adk_live_voice_bridge).
-behaviour(gen_server).

-export([start/4, frame/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_CREDIT_MESSAGES, 8).
-define(DEFAULT_CREDIT_BYTES, 262144).
-define(DEFAULT_MAX_AUDIO_FRAME_BYTES, 65536).
-define(MAX_CREDIT_MESSAGES, 256).
-define(MAX_CREDIT_BYTES, 8388608).
-define(MAX_AUDIO_FRAME_BYTES, 1048576).
-define(CALL_TIMEOUT_MS, 5000).
-define(FRAME_CALL_TIMEOUT_MS, 6000).
-define(MAX_PUBLIC_FRAME_BYTES, 1048591).

-record(state, {
    session :: pid(),
    principal :: binary(),
    session_id :: binary(),
    owner :: pid(),
    owner_monitor :: reference(),
    session_monitor :: reference(),
    continuity_token = undefined :: reference() | undefined,
    credit :: map(),
    max_audio_frame_bytes :: pos_integer(),
    max_output_frame_bytes :: pos_integer(),
    input_sample_rate = undefined :: undefined | 16000 | 24000,
    next_audio_sequence = 1 :: pos_integer(),
    pending = #{} :: map(),
    subscribed = false :: boolean()
}).

-type options() :: #{
    credit => #{messages := pos_integer(), bytes := pos_integer()},
    max_audio_frame_bytes => pos_integer()
}.
-export_type([options/0]).

-spec start(pid(), binary(), pid(), map()) -> gen_server:start_ret().
start(Session, Principal, Owner, Opts)
  when is_pid(Session), is_binary(Principal), is_pid(Owner), is_map(Opts) ->
    case validate_start(Session, Principal, Owner, Opts) of
        {ok, Credit, MaxAudioFrameBytes} ->
            case gen_server:start(
                   ?MODULE,
                   {Session, Principal, Owner, Credit,
                    MaxAudioFrameBytes}, []) of
                {ok, Bridge} ->
                    case safe_call(Bridge, initialize) of
                        ok -> {ok, Bridge};
                        {error, _} = Error ->
                            ensure_stopped(Bridge),
                            Error;
                        _Invalid ->
                            ensure_stopped(Bridge),
                            {error, invalid_live_voice_initialization}
                    end;
                {error, _} = Error -> Error;
                Other -> Other
            end;
        {error, _} = Error ->
            Error
    end;
start(_Session, _Principal, _Owner, _Opts) ->
    {error, invalid_live_voice_bridge}.

-spec frame(pid(), binary()) -> {ok, pos_integer()} | ok | {error, term()}.
frame(Bridge, Binary)
  when is_pid(Bridge), is_binary(Binary),
       byte_size(Binary) =< ?MAX_PUBLIC_FRAME_BYTES ->
    case local_pid(Bridge) of
        true -> safe_frame_call(Bridge, {frame, Binary});
        false -> {error, invalid_live_voice_bridge}
    end;
frame(Bridge, Binary) when is_pid(Bridge), is_binary(Binary) ->
    case local_pid(Bridge) of
        true -> {error, live_voice_frame_too_large};
        false -> {error, invalid_live_voice_bridge}
    end;
frame(_Bridge, _Binary) ->
    {error, invalid_live_voice_frame}.

-spec stop(pid()) -> ok | {error, term()}.
stop(Bridge) when is_pid(Bridge) ->
    case local_pid(Bridge) of
        true -> safe_call(Bridge, stop);
        false -> {error, invalid_live_voice_bridge}
    end;
stop(_Bridge) ->
    {error, invalid_live_voice_bridge}.

init({Session, Principal, Owner, Credit, MaxAudioFrameBytes}) ->
    process_flag(message_queue_data, off_heap),
    OwnerMonitor = erlang:monitor(process, Owner),
    SessionMonitor = erlang:monitor(process, Session),
    {ok, #state{
            session = Session,
            principal = Principal,
            session_id = <<>>,
            owner = Owner,
            owner_monitor = OwnerMonitor,
            session_monitor = SessionMonitor,
            credit = Credit,
            max_audio_frame_bytes = MaxAudioFrameBytes,
            max_output_frame_bytes = maps:get(bytes, Credit)
        }}.

handle_call(initialize, _From, #state{subscribed = false} = State) ->
    case status_claim_and_subscribe(
           State#state.session, State#state.principal,
           State#state.credit) of
        {ok, SessionId, ContinuityToken, InputSampleRate} ->
            Active = State#state{session_id = SessionId,
                                 continuity_token = ContinuityToken,
                                 input_sample_rate = InputSampleRate,
                                 subscribed = true},
            case signal_input_config(Active) of
                ok -> {reply, ok, Active};
                {error, Reason} ->
                    {stop, normal, {error, Reason}, Active}
            end;
        {error, Reason} ->
            {stop, normal, {error, Reason}, State}
    end;
handle_call({frame, Binary}, {Caller, _Tag},
            #state{owner = Caller, subscribed = true} = State) ->
    handle_owner_frame(Binary, State);
handle_call({frame, _Binary}, _From, State) ->
    {reply, {error, not_live_voice_owner}, State};
handle_call(stop, {Caller, _Tag}, #state{owner = Caller} = State) ->
    {stop, normal, ok, State};
handle_call(stop, _From, State) ->
    {reply, {error, not_live_voice_owner}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_live_voice_bridge_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({adk_live_event, SessionId, Sequence, Event},
            #state{session_id = SessionId} = State) ->
    handle_live_event(Sequence, Event, State);
handle_info({adk_live_subscriber_dropped, SessionId, Reason},
            #state{session_id = SessionId} = State) ->
    {stop, {subscriber_dropped, bounded_reason(Reason)}, State};
handle_info(
  {adk_live_voice_continuity_invalidated, Session, SessionId,
   ContinuityToken},
  #state{session = Session,
         session_id = SessionId,
         continuity_token = ContinuityToken} = State) ->
    {stop, {shutdown, live_voice_reconnect_required}, State};
handle_info({'DOWN', Ref, process, Owner, _Reason},
            #state{owner = Owner, owner_monitor = Ref} = State) ->
    {stop, normal, State};
handle_info({'DOWN', Ref, process, Session, _Reason},
            #state{session = Session, session_monitor = Ref} = State) ->
    {stop, live_session_down, State#state{subscribed = false}};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{subscribed = true, session = Session,
                          principal = Principal}) ->
    _ = adk_live_session:unsubscribe(Session, Principal, self()),
    _ = adk_live_voice_registry:release(Session, self()),
    ok;
terminate(_Reason, #state{session = Session}) ->
    _ = adk_live_voice_registry:release(Session, self()),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Principal, media and pending frames must never appear in OTP diagnostics.
format_status(Status) ->
    maps:map(
      fun(state, #state{} = State) ->
              #{session_id => State#state.session_id,
                owner => State#state.owner,
                credit => State#state.credit,
                max_audio_frame_bytes => State#state.max_audio_frame_bytes,
                input_sample_rate => State#state.input_sample_rate,
                next_audio_sequence => State#state.next_audio_sequence,
                pending_events => map_size(State#state.pending)};
         (message, _Message) -> redacted;
         (_Key, Value) -> Value
      end, Status).

handle_owner_frame(Binary, State) ->
    case adk_live_voice_protocol:decode_client(
           Binary, State#state.max_audio_frame_bytes) of
        {ok, {audio, Sequence, Rate, Pcm}} ->
            handle_audio(Sequence, Rate, Pcm, State);
        {ok, {ack, Sequence}} ->
            handle_ack(Sequence, State);
        {ok, audio_stream_end} ->
            live_input(audio_stream_end, State);
        {ok, activity_start} ->
            live_input(activity_start, State);
        {ok, activity_end} ->
            live_input(activity_end, State);
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

handle_audio(Sequence, _Rate, _Pcm,
             #state{next_audio_sequence = Expected} = State)
  when Sequence =/= Expected ->
    {reply, {error, {out_of_order_live_voice_audio, Expected}}, State};
handle_audio(_Sequence, Rate, _Pcm,
             #state{input_sample_rate = Expected} = State)
  when Rate =/= Expected ->
    {reply,
     {error, {unexpected_live_voice_input_sample_rate, Expected}}, State};
handle_audio(_Sequence, Rate, Pcm, State) ->
    case adk_live_media:audio_pcm(Pcm, Rate, 1) of
        {ok, Media} ->
            case adk_live_session:send_voice_audio(
                   State#state.session, State#state.principal,
                   State#state.continuity_token, Media) of
                {ok, InputSequence} ->
                    {reply, {ok, InputSequence},
                     State#state{
                       next_audio_sequence =
                           State#state.next_audio_sequence + 1}};
                {error, {not_ready, reconnecting}} ->
                    reconnect_required_reply(State);
                {error, live_voice_reconnect_required} ->
                    reconnect_required_reply(State);
                {error, timeout} ->
                    outcome_unknown_reply(State);
                {error, _} = Error ->
                    {reply, Error, State}
            end;
        {error, Reason} ->
            {reply, {error, {invalid_live_voice_audio, Reason}}, State}
    end.

handle_ack(Sequence, #state{pending = Pending} = State) ->
    case maps:is_key(Sequence, Pending) of
        false ->
            {reply, {error, unknown_live_voice_event_sequence}, State};
        true ->
            case acknowledge(Sequence, State) of
                ok ->
                    {reply, ok,
                     State#state{pending = maps:remove(Sequence, Pending)}};
                {error, timeout} ->
                    outcome_unknown_reply(State);
                {error, _} = Error ->
                    {reply, Error, State}
            end
    end.

live_input(Action, State) ->
    Result = case Action of
        audio_stream_end ->
            adk_live_session:voice_audio_stream_end(
              State#state.session, State#state.principal,
              State#state.continuity_token);
        activity_start ->
            adk_live_session:voice_activity_start(
              State#state.session, State#state.principal,
              State#state.continuity_token);
        activity_end ->
            adk_live_session:voice_activity_end(
              State#state.session, State#state.principal,
              State#state.continuity_token)
    end,
    case Result of
        {error, {not_ready, reconnecting}} ->
            reconnect_required_reply(State);
        {error, live_voice_reconnect_required} ->
            reconnect_required_reply(State);
        {error, timeout} ->
            outcome_unknown_reply(State);
        _Other ->
            {reply, Result, State}
    end.

reconnect_required_reply(State) ->
    {stop, {shutdown, live_voice_reconnect_required},
     {error, live_voice_reconnect_required}, State}.

outcome_unknown_reply(State) ->
    %% Do not block termination on a second call to the timed-out session.
    %% Its subscriber monitor removes this bridge as soon as we exit.
    {stop, {shutdown, live_voice_outcome_unknown},
     {error, live_voice_outcome_unknown},
     State#state{subscribed = false}}.

handle_live_event(Sequence, Event, State) ->
    case valid_delivery(Sequence, Event, State#state.pending) of
        false ->
            {noreply, State};
        true ->
            handle_valid_live_event(Sequence, Event, State)
    end.

handle_valid_live_event(Sequence, Event, State) ->
    case adk_live_event:kind(Event) of
        reconnecting ->
            forward_reconnect_and_stop(Event, State);
        _Other ->
            case adk_live_voice_protocol:encode_event(
                   Event, State#state.max_output_frame_bytes) of
                {ok, Binary} ->
                    State#state.owner !
                        {adk_live_voice_frame, self(), Binary},
                    {noreply,
                     State#state{
                       pending = (State#state.pending)#{Sequence => true}}};
                skip ->
                    acknowledge_internal(Sequence, State);
                {error, _Reason} ->
                    %% A valid but unrepresentable/oversized event is not
                    %% public.  Release its exact credit and keep raw content
                    %% out of the owner mailbox.
                    acknowledge_internal(Sequence, State)
            end
    end.

forward_reconnect_and_stop(Event, State) ->
    case adk_live_voice_protocol:encode_event(
           Event, State#state.max_output_frame_bytes) of
        {ok, Binary} ->
            State#state.owner ! {adk_live_voice_frame, self(), Binary};
        _NotRepresentable ->
            ok
    end,
    {stop, {shutdown, live_voice_reconnect_required}, State}.

acknowledge_internal(Sequence, State) ->
    case acknowledge(Sequence, State) of
        ok -> {noreply, State};
        {error, timeout} ->
            {stop, {shutdown, live_voice_outcome_unknown},
             State#state{subscribed = false}};
        {error, Reason} -> {stop, {live_voice_ack_failed, Reason}, State}
    end.

acknowledge(Sequence, State) ->
    adk_live_session:ack(
      State#state.session, State#state.principal, self(), Sequence).

valid_delivery(Sequence, Event, Pending) ->
    is_integer(Sequence) andalso Sequence > 0
    andalso not maps:is_key(Sequence, Pending)
    andalso try adk_live_event:sequence(Event) =:= Sequence
            catch _:_ -> false
            end.

status_claim_and_subscribe(Session, Principal, Credit) ->
    case adk_live_session:status(Session, Principal, ?CALL_TIMEOUT_MS) of
        {ok, #{state := reconnecting}} ->
            {error, live_voice_reconnect_required};
        {ok, #{state := active, session_id := SessionId} = Status}
          when is_binary(SessionId), byte_size(SessionId) > 0,
               byte_size(SessionId) =< 256 ->
            case trusted_input_sample_rate(Status) of
                {ok, InputSampleRate} ->
                    claim_and_subscribe(
                      Session, Principal, Credit, SessionId,
                      InputSampleRate);
                {error, _} = Error ->
                    Error
            end;
        {ok, #{state := active}} ->
            {error, invalid_live_status};
        {ok, #{state := State}} ->
            {error, {not_ready, State}};
        {ok, _Invalid} ->
            {error, invalid_live_status};
        {error, _} = Error ->
            Error
    end.

trusted_input_sample_rate(#{input_audio_sample_rate := Rate})
  when Rate =:= 16000; Rate =:= 24000 ->
    {ok, Rate};
trusted_input_sample_rate(_Status) ->
    {error, invalid_live_status}.

claim_and_subscribe(Session, Principal, Credit, SessionId,
                    InputSampleRate) ->
    case adk_live_voice_registry:claim(Session, self()) of
        ok ->
            case subscribe_active(Session, Principal, Credit) of
                {ok, ContinuityToken} ->
                    {ok, SessionId, ContinuityToken, InputSampleRate};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

signal_input_config(#state{owner = Owner,
                           input_sample_rate = Rate}) ->
    Format = #{sample_rate => Rate, channels => 1, format => pcm_s16le},
    case adk_live_voice_protocol:encode_input_config(Format) of
        {ok, Frame} ->
            Owner ! {adk_live_voice_frame, self(), Frame},
            ok;
        {error, _} ->
            %% The trusted session status was checked before subscription.
            %% Keep a stable boundary error if state corruption ever makes
            %% this impossible.
            {error, invalid_live_voice_input_config}
    end.

subscribe_active(Session, Principal, Credit) ->
    case adk_live_session:subscribe_voice(
           Session, Principal, self(), Credit) of
        {ok, #{state := active,
               continuity_token := ContinuityToken}}
          when is_reference(ContinuityToken) ->
            {ok, ContinuityToken};
        {ok, #{state := reconnecting}} ->
            rollback_subscription(Session, Principal),
            {error, live_voice_reconnect_required};
        {ok, #{state := State}} ->
            rollback_subscription(Session, Principal),
            {error, {not_ready, State}};
        {ok, _Invalid} ->
            rollback_subscription(Session, Principal),
            {error, invalid_live_subscription};
        {error, _} = Error ->
            _ = adk_live_voice_registry:release(Session, self()),
            Error
    end.

rollback_subscription(Session, Principal) ->
    _ = adk_live_session:unsubscribe(Session, Principal, self()),
    _ = adk_live_voice_registry:release(Session, self()),
    ok.

validate_start(Session, Principal, Owner, Opts) ->
    Allowed = [credit, max_audio_frame_bytes],
    case local_pid(Session) andalso local_pid(Owner)
         andalso is_process_alive(Session) andalso is_process_alive(Owner)
         andalso byte_size(Principal) > 0
         andalso byte_size(Principal) =< 4096
         andalso maps:keys(Opts) -- Allowed =:= [] of
        false ->
            {error, invalid_live_voice_bridge};
        true ->
            Credit = maps:get(
                       credit, Opts,
                       #{messages => ?DEFAULT_CREDIT_MESSAGES,
                         bytes => ?DEFAULT_CREDIT_BYTES}),
            MaxAudioFrameBytes = maps:get(
                                   max_audio_frame_bytes, Opts,
                                   ?DEFAULT_MAX_AUDIO_FRAME_BYTES),
            case valid_credit(Credit) andalso
                 is_integer(MaxAudioFrameBytes) andalso
                 MaxAudioFrameBytes >= 2 andalso
                 MaxAudioFrameBytes =< ?MAX_AUDIO_FRAME_BYTES of
                true -> {ok, Credit, MaxAudioFrameBytes};
                false -> {error, invalid_live_voice_bridge_options}
            end
    end.

valid_credit(#{messages := Messages, bytes := Bytes} = Credit) ->
    lists:sort(maps:keys(Credit)) =:= [bytes, messages]
    andalso is_integer(Messages) andalso Messages >= 1
    andalso Messages =< ?MAX_CREDIT_MESSAGES
    andalso is_integer(Bytes) andalso Bytes >= 1024
    andalso Bytes =< ?MAX_CREDIT_BYTES;
valid_credit(_Credit) ->
    false.

safe_call(Bridge, Request) ->
    try gen_server:call(Bridge, Request, ?CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, not_found};
        exit:{normal, _} -> {error, not_found};
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, live_voice_bridge_unavailable}
    end.

%% Give the nested session call a short grace period to report its terminal
%% outcome.  If the outer deadline still expires, the input outcome is
%% unknowable; kill and await the bridge before replying so it cannot be used
%% for a retry.
safe_frame_call(Bridge, Request) ->
    try gen_server:call(Bridge, Request, ?FRAME_CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, not_found};
        exit:{normal, _} -> {error, not_found};
        exit:{timeout, _} ->
            ensure_stopped(Bridge),
            {error, live_voice_outcome_unknown};
        exit:_ -> {error, live_voice_bridge_unavailable}
    end.

bounded_reason(Reason) when is_atom(Reason) -> Reason;
bounded_reason(_Reason) -> subscriber_dropped.

local_pid(Pid) ->
    node(Pid) =:= node().

ensure_stopped(Bridge) ->
    Ref = erlang:monitor(process, Bridge),
    exit(Bridge, kill),
    receive
        {'DOWN', Ref, process, Bridge, _Reason} -> ok
    end.
