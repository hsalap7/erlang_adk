%% @private Bounded state machine for credit/ack artifact transfers.
-module(adk_artifact_stream_worker).
-behaviour(gen_server).

-export([start_link/1, description/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DESCRIBE_TIMEOUT_MS, 5000).
-define(MAX_HEAP_WORDS, 33554432).
-define(MAX_CHUNKS, 65536).

-record(state, {
    mode :: upload | download,
    owner :: pid(),
    owner_monitor :: reference(),
    ref :: reference(),
    deadline :: integer(),
    timer :: reference(),
    chunk_bytes :: pos_integer(),
    max_bytes :: pos_integer(),
    max_credit_messages :: pos_integer(),
    max_credit_bytes :: pos_integer(),
    backend = undefined :: undefined | redacted | {module(), term()},
    scope = undefined :: term(),
    name = undefined :: undefined | binary(),
    put_options = #{} :: map(),
    chunks = [] :: [binary()],
    total = 0 :: non_neg_integer(),
    next_sequence = 1 :: pos_integer(),
    artifact = undefined :: undefined | map(),
    data = <<>> :: binary(),
    offset = 0 :: non_neg_integer(),
    credit_messages = 0 :: non_neg_integer(),
    credit_bytes = 0 :: non_neg_integer(),
    awaiting_ack = undefined :: undefined | {pos_integer(), pos_integer()},
    operation = undefined :: undefined | {pid(), reference(), reference()},
    terminal = false :: boolean()
}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec description(pid()) ->
    {ok, adk_artifact_stream:stream(), map()} | {error, term()}.
description(Pid) when is_pid(Pid) ->
    try gen_server:call(Pid, describe, ?DESCRIBE_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:_ -> {error, unavailable}
    end.

init(Args) ->
    process_flag(message_queue_data, off_heap),
    _ = process_flag(max_heap_size,
                     #{size => ?MAX_HEAP_WORDS, kill => true,
                       error_logger => false,
                       include_shared_binaries => true}),
    case prepare(Args) of
        {ok, State0} ->
            Timeout = remaining(State0#state.deadline),
            Timer = erlang:send_after(Timeout, self(), stream_deadline),
            {ok, State0#state{timer = Timer}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(describe, _From, State = #state{mode = upload}) ->
    Credit = #{messages => 1, bytes => State#state.chunk_bytes},
    Description = #{protocol => credit_ack,
                    direction => upload,
                    credit => Credit,
                    max_bytes => State#state.max_bytes,
                    deadline => State#state.deadline},
    {reply, {ok, stream_handle(State), Description}, State};
handle_call(describe, _From, State = #state{mode = download,
                                            artifact = Artifact}) ->
    Metadata = maps:without([data], Artifact),
    {reply, {ok, stream_handle(State), Metadata}, State};
handle_call({stream, Ref, Request}, From, State) ->
    case authorized(Ref, From, State) of
        false -> {reply, {error, unauthorized_stream_owner}, State};
        true -> handle_stream_call(Request, From, State)
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(stream_deadline, State) ->
    fail_stream(timeout, State);
handle_info({artifact_stream_operation, OpRef, Pid, CompletedAt, Result},
            State = #state{operation = {Pid, Monitor, OpRef}}) ->
    _ = erlang:demonitor(Monitor, [flush]),
    Reply = case CompletedAt =< State#state.deadline of
        true -> sanitize_result(Result);
        false -> {error, timeout}
    end,
    notify_terminal(Reply, State),
    {stop, normal, State#state{operation = undefined, terminal = true}};
handle_info({'DOWN', Monitor, process, Pid, _Reason},
            State = #state{operation = {Pid, Monitor, _OpRef}}) ->
    notify_owner({error, unavailable}, State),
    {stop, normal, State#state{operation = undefined, terminal = true}};
handle_info({'DOWN', Monitor, process, Owner, _Reason},
            State = #state{owner_monitor = Monitor, owner = Owner}) ->
    kill_operation(State),
    {stop, normal, State#state{terminal = true}};
handle_info(stream_complete, State) ->
    {stop, normal, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = erlang:cancel_timer(State#state.timer),
    kill_operation(State),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, State = #state{}) ->
              State#state{chunks = [], data = <<>>, artifact = undefined,
                          backend = redacted, scope = redacted,
                          name = undefined, put_options = #{}};
         (message, _Message) -> redacted;
         (log, _Log) -> [];
         (reason, _Reason) -> redacted;
         (_Key, Value) -> Value
      end, Status);
format_status(Status) -> Status.

handle_stream_call(_Request, _From, State = #state{terminal = true}) ->
    {reply, {error, closed}, State};
handle_stream_call(Request, From, State) ->
    case remaining(State#state.deadline) of
        0 ->
            gen_server:reply(From, {error, timeout}),
            fail_stream(timeout, State);
        _ -> handle_active_call(Request, From, State)
    end.

handle_active_call({upload_chunk, Sequence, Chunk}, _From,
                   State = #state{mode = upload, operation = undefined}) ->
    handle_upload_chunk(Sequence, Chunk, State);
handle_active_call(finish_upload, From,
                   State = #state{mode = upload, operation = undefined}) ->
    start_commit(From, State);
handle_active_call({credit, Messages, Bytes}, _From,
                   State = #state{mode = download}) ->
    add_credit(Messages, Bytes, State);
handle_active_call({ack, Sequence}, _From,
                   State = #state{mode = download}) ->
    acknowledge(Sequence, State);
handle_active_call({cancel, _OpaqueReason}, _From, State) ->
    kill_operation(State),
    notify_owner({error, cancelled}, State),
    {stop, normal, ok, State#state{terminal = true}};
handle_active_call(_Request, _From, State) ->
    {reply, {error, invalid_stream_operation}, State}.

handle_upload_chunk(Sequence, Chunk,
                    State = #state{next_sequence = Sequence})
  when is_binary(Chunk), byte_size(Chunk) > 0 ->
    Size = byte_size(Chunk),
    case {Size =< State#state.chunk_bytes,
          State#state.total + Size =< State#state.max_bytes} of
        {false, _} -> {reply, {error, chunk_too_large}, State};
        {_, false} -> {reply, {error, artifact_too_large}, State};
        {true, true} ->
            Ack = #{ack => Sequence,
                    credit => #{messages => 1,
                                bytes => State#state.chunk_bytes}},
            NewState = State#state{chunks = [Chunk | State#state.chunks],
                                   total = State#state.total + Size,
                                   next_sequence = Sequence + 1},
            {reply, {ok, Ack}, NewState}
    end;
handle_upload_chunk(Sequence, _Chunk, State)
  when not is_integer(Sequence); Sequence =< 0 ->
    {reply, {error, invalid_sequence}, State};
handle_upload_chunk(_Sequence, Chunk, State) when not is_binary(Chunk) ->
    {reply, {error, invalid_chunk}, State};
handle_upload_chunk(_Sequence, _Chunk, State) ->
    {reply, {error, sequence_mismatch}, State}.

start_commit(_From, State) ->
    Data = iolist_to_binary(lists:reverse(State#state.chunks)),
    Owner = self(),
    OpRef = make_ref(),
    Backend = State#state.backend,
    Scope = State#state.scope,
    Name = State#state.name,
    PutOptions = State#state.put_options,
    Timeout = erlang:max(1, remaining(State#state.deadline)),
    Fun = fun() ->
        Result = backend_put(Backend, Scope, Name, Data, PutOptions, Timeout),
        CompletedAt = erlang:monotonic_time(millisecond),
        Owner ! {artifact_stream_operation, OpRef, self(), CompletedAt, Result}
    end,
    SpawnOptions = [monitor, {message_queue_data, off_heap},
                    {max_heap_size,
                     #{size => ?MAX_HEAP_WORDS, kill => true,
                       error_logger => false,
                       include_shared_binaries => true}}],
    try erlang:spawn_opt(Fun, SpawnOptions) of
        {Pid, Monitor} ->
            {reply, {ok, #{status => committing}},
             State#state{operation = {Pid, Monitor, OpRef}, chunks = []}}
    catch
        _:_ -> {reply, {error, unavailable}, State}
    end.

backend_put({Module, Handle}, Scope, Name, Data, PutOptions, Timeout)
  when is_atom(Module) ->
    try Module:put(Handle, Scope, Name, Data, PutOptions,
                   #{timeout_ms => Timeout}) of
        Result -> Result
    catch
        _:_ -> {error, unavailable}
    end;
backend_put(_Backend, _Scope, _Name, _Data, _PutOptions, _Timeout) ->
    {error, unavailable}.

add_credit(Messages, Bytes, State)
  when is_integer(Messages), Messages > 0,
       is_integer(Bytes), Bytes > 0 ->
    NewMessages = State#state.credit_messages + Messages,
    NewBytes = State#state.credit_bytes + Bytes,
    case NewMessages =< State#state.max_credit_messages andalso
         NewBytes =< State#state.max_credit_bytes of
        true ->
            NewState = State#state{credit_messages = NewMessages,
                                   credit_bytes = NewBytes},
            {reply, ok, maybe_emit(NewState)};
        false -> {reply, {error, credit_limit_exceeded}, State}
    end;
add_credit(_Messages, _Bytes, State) ->
    {reply, {error, invalid_credit}, State}.

acknowledge(Sequence,
            State = #state{awaiting_ack = {Sequence, Length}})
  when is_integer(Sequence), Sequence > 0 ->
    NewState = State#state{awaiting_ack = undefined,
                           offset = State#state.offset + Length},
    {reply, ok, maybe_emit(NewState)};
acknowledge(_Sequence, State = #state{awaiting_ack = undefined}) ->
    {reply, {error, no_chunk_in_flight}, State};
acknowledge(_Sequence, State) ->
    {reply, {error, ack_mismatch}, State}.

maybe_emit(State = #state{awaiting_ack = {_Sequence, _Length}}) ->
    State;
maybe_emit(State = #state{offset = Offset, data = Data})
  when Offset >= byte_size(Data) ->
    Metadata = maps:without([data], State#state.artifact),
    notify_owner({done, Metadata}, State),
    _ = erlang:send_after(0, self(), stream_complete),
    State#state{terminal = true};
maybe_emit(State = #state{credit_messages = 0}) -> State;
maybe_emit(State = #state{credit_bytes = 0}) -> State;
maybe_emit(State) ->
    Remaining = byte_size(State#state.data) - State#state.offset,
    Length = lists:min([Remaining, State#state.chunk_bytes,
                        State#state.credit_bytes]),
    Chunk = binary:part(State#state.data, State#state.offset, Length),
    Sequence = State#state.next_sequence,
    notify_owner({chunk, Sequence, State#state.offset, Chunk}, State),
    State#state{credit_messages = State#state.credit_messages - 1,
                credit_bytes = State#state.credit_bytes - Length,
                next_sequence = Sequence + 1,
                awaiting_ack = {Sequence, Length}}.

prepare(#{mode := Mode, stream_options := Options, limits := Limits} = Args)
  when (Mode =:= upload orelse Mode =:= download),
       is_map(Options), is_map(Limits) ->
    Allowed = [owner, timeout_ms, chunk_bytes, max_bytes, range],
    Unknown = maps:without(Allowed, Options),
    Owner = maps:get(owner, Options, self()),
    Timeout = maps:get(timeout_ms, Options,
                       maps:get(timeout_ms, Limits, 30000)),
    Chunk = maps:get(chunk_bytes, Options,
                     maps:get(chunk_bytes, Limits, 65536)),
    RequestedMax = maps:get(max_bytes, Options,
                            maps:get(max_bytes, Limits, 67108864)),
    Max = maps:get(max_bytes, Limits, 67108864),
    MaxCreditMessages = maps:get(max_credit_messages, Limits, 8),
    MaxCreditBytes = maps:get(max_credit_bytes, Limits, Chunk * 8),
    case {map_size(Unknown), is_pid(Owner), valid_positive(Timeout),
          valid_positive(Chunk), valid_positive(RequestedMax),
          RequestedMax =< Max, valid_positive(MaxCreditMessages),
          valid_positive(MaxCreditBytes), Chunk =< MaxCreditBytes,
          ((RequestedMax + Chunk - 1) div Chunk) =< ?MAX_CHUNKS} of
        {0, true, true, true, true, true, true, true, true, true} ->
            Ref = make_ref(),
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            Monitor = erlang:monitor(process, Owner),
            prepare_mode(Args,
                         #state{mode = Mode, owner = Owner,
                                owner_monitor = Monitor, ref = Ref,
                                deadline = Deadline,
                                timer = make_ref(), chunk_bytes = Chunk,
                                max_bytes = RequestedMax,
                                max_credit_messages = MaxCreditMessages,
                                max_credit_bytes = MaxCreditBytes});
        {Size, _, _, _, _, _, _, _, _, _} when Size > 0 ->
            {error, {unknown_transfer_options,
                     lists:sort(maps:keys(Unknown))}};
        _ -> {error, invalid_transfer_options}
    end;
prepare(_Args) ->
    {error, invalid_stream_arguments}.

prepare_mode(#{mode := upload, backend := {Module, _Handle} = Backend,
               scope := Scope, name := Name, put_options := PutOptions}, State)
  when is_atom(Module), is_binary(Name), is_map(PutOptions) ->
    case adk_artifact_core:validate_put(Scope, Name, <<>>, PutOptions) of
        {ok, _MimeType, _Metadata} ->
            {ok, State#state{backend = Backend, scope = Scope, name = Name,
                             put_options = PutOptions}};
        {error, _} = Error -> Error
    end;
prepare_mode(#{mode := download, artifact := Artifact}, State)
  when is_map(Artifact) ->
    case maps:find(data, Artifact) of
        {ok, Data} when is_binary(Data), byte_size(Data) =< State#state.max_bytes ->
            {ok, State#state{artifact = Artifact, data = Data,
                             total = byte_size(Data)}};
        {ok, Data} when is_binary(Data) -> {error, artifact_too_large};
        _ -> {error, invalid_artifact}
    end;
prepare_mode(_Args, _State) ->
    {error, invalid_stream_arguments}.

authorized(Ref, {Caller, _Tag}, State) ->
    Ref =:= State#state.ref andalso Caller =:= State#state.owner.

stream_handle(State) ->
    {adk_artifact_stream, self(), State#state.ref}.

fail_stream(Reason, State) ->
    kill_operation(State),
    notify_owner({error, Reason}, State),
    {stop, normal, State#state{operation = undefined, terminal = true}}.

kill_operation(#state{operation = {Pid, Monitor, _OpRef}}) ->
    exit(Pid, kill),
    _ = erlang:demonitor(Monitor, [flush]),
    ok;
kill_operation(_State) -> ok.

notify_terminal({ok, Metadata}, State) when is_map(Metadata) ->
    notify_owner({done, Metadata}, State);
notify_terminal({error, Reason}, State) ->
    notify_owner({error, Reason}, State).

notify_owner(Event, State) ->
    _ = erlang:send(State#state.owner,
                    {adk_artifact_stream, State#state.ref, Event},
                    [noconnect, nosuspend]),
    ok.

sanitize_result({ok, Metadata}) when is_map(Metadata) -> {ok, Metadata};
sanitize_result({error, timeout}) -> {error, timeout};
sanitize_result({error, artifact_too_large}) -> {error, artifact_too_large};
sanitize_result({error, _Opaque}) -> {error, unavailable};
sanitize_result(_) -> {error, unavailable}.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

valid_positive(Value) -> is_integer(Value) andalso Value > 0.
