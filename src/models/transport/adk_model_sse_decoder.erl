%% @doc Bounded incremental Server-Sent Events decoder for model providers.
%%
%% The decoder is deliberately transport- and provider-neutral. It accepts
%% arbitrary TCP/HTTP chunk boundaries, supports LF and CRLF line endings,
%% joins repeated `data' fields with a newline, and never creates atoms from
%% remote field names or event types.
-module(adk_model_sse_decoder).

-export([new/0, new/1, feed/2, finish/1]).

-define(DEFAULT_MAX_BUFFER_BYTES, 1048576).
-define(DEFAULT_MAX_EVENT_BYTES, 1048576).
-define(DEFAULT_MAX_EVENTS_PER_FEED, 1024).
-define(HARD_MAX_BYTES, 67108864).
-define(HARD_MAX_EVENTS, 65536).

-type event() :: #{data := binary(),
                   event => binary(),
                   id => binary(),
                   retry => non_neg_integer()}.
-type state() :: map().

-export_type([event/0, state/0]).

-spec new() -> state().
new() ->
    new(#{}).

-spec new(map()) -> state() | no_return().
new(Options) when is_map(Options) ->
    case validate_options(Options) of
        {ok, Limits} -> initial_state(Limits);
        {error, Reason} -> error(Reason)
    end;
new(_) ->
    error(invalid_sse_decoder_options).

-spec feed(state(), binary()) ->
    {ok, [event()], state()} | {error, term()}.
feed(State, Chunk) when is_map(State), is_binary(Chunk) ->
    case valid_state(State) of
        false -> {error, invalid_sse_decoder_state};
        true -> feed_checked(State, Chunk)
    end;
feed(_State, _Chunk) ->
    {error, invalid_sse_decoder_input}.

-spec finish(state()) -> {ok, [event()]} | {error, term()}.
finish(State) when is_map(State) ->
    case valid_state(State) of
        false -> {error, invalid_sse_decoder_state};
        true ->
            Buffer = maps:get(buffer, State),
            State0 = State#{buffer => <<>>},
            case process_final_buffer(Buffer, State0, [], 0) of
                {ok, Events, State1, Count} ->
                    case dispatch_event(State1, Events, Count) of
                        {ok, Finished, _State2, _Count2} ->
                            {ok, lists:reverse(Finished)};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end;
finish(_) ->
    {error, invalid_sse_decoder_state}.

validate_options(Options) ->
    Allowed = [max_buffer_bytes, max_event_bytes, max_events_per_feed],
    case maps:keys(Options) -- Allowed of
        [] ->
            Limits = #{max_buffer_bytes =>
                           maps:get(max_buffer_bytes, Options,
                                    ?DEFAULT_MAX_BUFFER_BYTES),
                       max_event_bytes =>
                           maps:get(max_event_bytes, Options,
                                    ?DEFAULT_MAX_EVENT_BYTES),
                       max_events_per_feed =>
                           maps:get(max_events_per_feed, Options,
                                    ?DEFAULT_MAX_EVENTS_PER_FEED)},
            validate_limits(Limits);
        _ -> {error, invalid_sse_decoder_options}
    end.

validate_limits(#{max_buffer_bytes := Buffer,
                  max_event_bytes := Event,
                  max_events_per_feed := Events} = Limits)
  when is_integer(Buffer), Buffer > 0, Buffer =< ?HARD_MAX_BYTES,
       is_integer(Event), Event > 0, Event =< ?HARD_MAX_BYTES,
       is_integer(Events), Events > 0, Events =< ?HARD_MAX_EVENTS ->
    {ok, Limits};
validate_limits(_) ->
    {error, invalid_sse_decoder_limits}.

initial_state(Limits) ->
    Limits#{buffer => <<>>,
            event_type => undefined,
            event_id => undefined,
            retry => undefined,
            data_lines => [],
            event_bytes => 0,
            has_fields => false}.

valid_state(#{buffer := Buffer,
              event_type := EventType,
              event_id := EventId,
              retry := Retry,
              data_lines := DataLines,
              event_bytes := EventBytes,
              has_fields := HasFields,
              max_buffer_bytes := MaxBuffer,
              max_event_bytes := MaxEvent,
              max_events_per_feed := MaxEvents}) ->
    is_binary(Buffer) andalso
    valid_optional_binary(EventType) andalso
    valid_optional_binary(EventId) andalso
    (Retry =:= undefined orelse
     (is_integer(Retry) andalso Retry >= 0)) andalso
    is_list(DataLines) andalso
    is_integer(EventBytes) andalso EventBytes >= 0 andalso
    is_boolean(HasFields) andalso
    is_integer(MaxBuffer) andalso MaxBuffer > 0 andalso
    is_integer(MaxEvent) andalso MaxEvent > 0 andalso
    is_integer(MaxEvents) andalso MaxEvents > 0;
valid_state(_) -> false.

valid_optional_binary(undefined) -> true;
valid_optional_binary(Value) -> is_binary(Value).

feed_checked(State, Chunk) ->
    Buffer = maps:get(buffer, State),
    case byte_size(Chunk) =< ?HARD_MAX_BYTES andalso
         byte_size(Buffer) + byte_size(Chunk) =< ?HARD_MAX_BYTES of
        false -> {error, sse_feed_limit_exceeded};
        true ->
            Combined = <<Buffer/binary, Chunk/binary>>,
            State0 = State#{buffer => <<>>},
            case process_binary_lines(Combined, State0, [], 0) of
                {ok, Events, State1, _Count, Remainder} ->
                    case byte_size(Remainder) =<
                         maps:get(max_buffer_bytes, State1) of
                        true ->
                            {ok, lists:reverse(Events),
                             State1#{buffer => Remainder}};
                        false -> {error, sse_buffer_limit_exceeded}
                    end;
                {error, _} = Error -> Error
            end
    end.

%% Scan one line at a time. `binary:split(..., [global])' would allocate a
%% list proportional to every delimiter before the event-count bound could
%% run, allowing a single chunk containing many tiny lines to amplify memory.
process_binary_lines(Binary, State, Events, Count) ->
    case binary:match(Binary, <<"\n">>) of
        nomatch -> {ok, Events, State, Count, Binary};
        {Position, 1} ->
            <<Line0:Position/binary, _Newline, Rest/binary>> = Binary,
            Line = strip_cr(Line0),
            case process_line(Line, State, Events, Count) of
                {ok, NewEvents, NewState, NewCount} ->
                    process_binary_lines(
                      Rest, NewState, NewEvents, NewCount);
                {error, _} = Error -> Error
            end
    end.

process_final_buffer(<<>>, State, Events, Count) ->
    {ok, Events, State, Count};
process_final_buffer(Buffer, State, Events, Count) ->
    process_line(strip_cr(Buffer), State, Events, Count).

strip_cr(Line) when byte_size(Line) > 0 ->
    Size = byte_size(Line) - 1,
    case Line of
        <<Rest:Size/binary, "\r">> -> Rest;
        _ -> Line
    end;
strip_cr(Line) -> Line.

process_line(<<>>, State, Events, Count) ->
    dispatch_event(State, Events, Count);
process_line(<<":", _/binary>>, State, Events, Count) ->
    {ok, Events, State, Count};
process_line(Line, State, Events, Count) ->
    Size = maps:get(event_bytes, State) + byte_size(Line),
    case Size =< maps:get(max_event_bytes, State) of
        false -> {error, sse_event_limit_exceeded};
        true ->
            {Field, Value} = field_value(Line),
            apply_field(Field, Value,
                        State#{event_bytes => Size,
                               has_fields => true},
                        Events, Count)
    end.

field_value(Line) ->
    case binary:match(Line, <<":">>) of
        nomatch -> {Line, <<>>};
        {Position, 1} ->
            <<Field:Position/binary, _Colon, Rest/binary>> = Line,
            {Field, strip_space(Rest)}
    end.

strip_space(<<" ", Rest/binary>>) -> Rest;
strip_space(Value) -> Value.

apply_field(<<"data">>, Value, State, Events, Count) ->
    {ok, Events,
     State#{data_lines => [Value | maps:get(data_lines, State)]}, Count};
apply_field(<<"event">>, Value, State, Events, Count) ->
    {ok, Events, State#{event_type => Value}, Count};
apply_field(<<"id">>, Value, State, Events, Count) ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, Events, State#{event_id => Value}, Count};
        _ -> {ok, Events, State, Count}
    end;
apply_field(<<"retry">>, Value, State, Events, Count) ->
    case decimal(Value) of
        {ok, Retry} -> {ok, Events, State#{retry => Retry}, Count};
        error -> {ok, Events, State, Count}
    end;
apply_field(_Unknown, _Value, State, Events, Count) ->
    {ok, Events, State, Count}.

decimal(<<>>) -> error;
decimal(Value) ->
    try binary_to_integer(Value) of
        Integer when Integer >= 0 -> {ok, Integer};
        _ -> error
    catch error:badarg -> error
    end.

dispatch_event(State, Events, Count) ->
    %% Per the EventSource dispatch algorithm, an event/id/retry-only block
    %% updates connection state but does not dispatch a MessageEvent. A
    %% present `data:' line is dispatchable even when its value is empty.
    case maps:get(data_lines, State) of
        [] -> {ok, Events, reset_event(State), Count};
        _DataLines ->
            MaxEvents = maps:get(max_events_per_feed, State),
            case Count < MaxEvents of
                false -> {error, sse_event_count_limit_exceeded};
                true ->
                    Event0 = #{data => join_data(
                                      maps:get(data_lines, State))},
                    Event1 = maybe_put(event,
                                       maps:get(event_type, State), Event0),
                    Event2 = maybe_put(id,
                                       maps:get(event_id, State), Event1),
                    Event3 = maybe_put(retry,
                                       maps:get(retry, State), Event2),
                    {ok, [Event3 | Events], reset_event(State), Count + 1}
            end
    end.

join_data(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Lines))).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

reset_event(State) ->
    State#{event_type => undefined,
           event_id => undefined,
           retry => undefined,
           data_lines => [],
           event_bytes => 0,
           has_fields => false}.
