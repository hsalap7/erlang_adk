%% @doc Logical, bounded assembler for OpenAI Responses streaming events.
%%
%% The transport decodes each SSE `data' JSON object and passes the resulting
%% binary-keyed map to `decode_event/2'. Text and function arguments are
%% accumulated as reverse iolists, bounded before concatenation, and verified
%% against their corresponding `done' and `response.completed' values.
-module(adk_openai_responses_stream).

-export([new/1, decode_event/2, finish/1]).

-define(STATE_VERSION, 1).
-define(DEFAULT_MAX_EVENTS, 100000).
-define(MAX_EVENTS_CEILING, 1000000).
-define(MAX_OUTPUT_INDEX, 255).
-define(MAX_EVENT_TYPE_BYTES, 128).
-define(MAX_ITEM_ID_BYTES, 256).

-type logical_event() ::
    {text_delta, binary()} |
    {tool_call_started, non_neg_integer(), binary(), binary()} |
    {tool_call_arguments_delta, non_neg_integer(), binary()} |
    {tool_call_completed, non_neg_integer(), tuple()} |
    {completed, adk_provider_result:result()}.
-type state() :: map().
-export_type([logical_event/0, state/0]).

-spec new(map()) -> {ok, state()} | {error, term()}.
new(Options) when is_map(Options) ->
    LimitOverrides = adk_openai_responses_codec:content_limits(Options),
    MaxEvents = maps:get(max_stream_events, Options, ?DEFAULT_MAX_EVENTS),
    case {adk_content:normalize_limits(LimitOverrides),
          valid_max_events(MaxEvents)} of
        {{ok, Limits}, true} ->
            {ok, #{version => ?STATE_VERSION,
                   status => streaming,
                   limits => Limits,
                   max_events => MaxEvents,
                   event_count => 0,
                   last_sequence => -1,
                   text_parts => #{},
                   text_order => [],
                   text_bytes => 0,
                   calls => #{},
                   result => undefined,
                   failure => undefined}};
        {{error, _} = Error, _} -> Error;
        {_, false} -> {error, invalid_openai_stream_event_limit}
    end;
new(_) -> {error, invalid_openai_stream_options}.

-spec decode_event(term(), state()) ->
    {ok, [logical_event()], state()} |
    {error, term(), state()}.
decode_event(Event, State0) when is_map(Event), is_map(State0) ->
    case valid_streaming_state(State0) of
        false -> {error, invalid_openai_stream_state, State0};
        true ->
            case begin_event(Event, State0) of
                {ok, Type, State1} ->
                    safe_handle_event(Type, Event, State1);
                {error, Reason} -> fail(Reason, State0)
            end
    end;
decode_event(_Event, State) ->
    {error, invalid_openai_stream_event, State}.

-spec finish(state()) ->
    {ok, adk_provider_result:result()} | {error, term()}.
finish(#{version := ?STATE_VERSION, status := completed,
         result := Result}) ->
    {ok, Result};
finish(#{version := ?STATE_VERSION, status := failed,
         failure := Reason}) ->
    {error, Reason};
finish(#{version := ?STATE_VERSION, status := streaming}) ->
    {error, incomplete_openai_stream};
finish(_) -> {error, invalid_openai_stream_state}.

valid_streaming_state(#{version := ?STATE_VERSION,
                        status := streaming,
                        event_count := Count,
                        max_events := Max,
                        last_sequence := LastSequence,
                        limits := Limits,
                        text_parts := TextParts,
                        text_order := TextOrder,
                        text_bytes := TextBytes,
                        calls := Calls,
                        result := _Result,
                        failure := _Failure}) ->
    is_integer(Count) andalso Count >= 0 andalso
        is_integer(Max) andalso Max > 0 andalso
        is_integer(LastSequence) andalso LastSequence >= -1 andalso
        is_map(Limits) andalso is_map(TextParts) andalso
        is_list(TextOrder) andalso is_integer(TextBytes) andalso
        TextBytes >= 0 andalso is_map(Calls);
valid_streaming_state(_) -> false.

safe_handle_event(Type, Event, State) ->
    try handle_event(Type, Event, State) of
        {ok, Actions, NewState} = Ok
          when is_list(Actions), is_map(NewState) -> Ok;
        {error, _Reason, NewState} = Error when is_map(NewState) -> Error;
        _ -> fail(invalid_openai_stream_state, State)
    catch
        _:_ -> fail(invalid_openai_stream_state, State)
    end.

begin_event(Event, State) ->
    Count = maps:get(event_count, State),
    Max = maps:get(max_events, State),
    Type = maps:get(<<"type">>, Event, undefined),
    case Count < Max andalso valid_event_type(Type) of
        false when Count >= Max ->
            {error, {openai_stream_event_limit_exceeded, Max}};
        false -> {error, invalid_openai_stream_event_type};
        true ->
            case check_sequence(Event, State) of
                {ok, State1} ->
                    {ok, Type, State1#{event_count => Count + 1}};
                {error, _} = Error -> Error
            end
    end.

check_sequence(Event, State) ->
    case maps:find(<<"sequence_number">>, Event) of
        error -> {ok, State};
        {ok, Sequence} when is_integer(Sequence), Sequence >= 0 ->
            Last = maps:get(last_sequence, State),
            case Sequence > Last of
                true -> {ok, State#{last_sequence => Sequence}};
                false -> {error, non_monotonic_openai_stream_sequence}
            end;
        {ok, _} -> {error, invalid_openai_stream_sequence}
    end.

handle_event(<<"response.output_text.delta">>, Event, State) ->
    handle_text_delta(Event, State);
handle_event(<<"response.output_text.done">>, Event, State) ->
    handle_text_done(Event, State);
handle_event(<<"response.output_item.added">>, Event, State) ->
    handle_output_item_added(Event, State);
handle_event(<<"response.function_call_arguments.delta">>, Event, State) ->
    handle_call_delta(Event, State);
handle_event(<<"response.function_call_arguments.done">>, Event, State) ->
    handle_call_done(Event, State);
handle_event(<<"response.output_item.done">>, Event, State) ->
    handle_output_item_done(Event, State);
handle_event(<<"response.completed">>, Event, State) ->
    handle_completed(Event, State);
handle_event(<<"response.failed">>, Event, State) ->
    handle_failed_response(Event, State);
handle_event(<<"response.incomplete">>, Event, State) ->
    handle_incomplete_response(Event, State);
handle_event(<<"response.cancelled">>, _Event, State) ->
    fail(openai_response_cancelled, State);
handle_event(<<"error">>, Event, State) ->
    {error, Reason} = adk_openai_responses_codec:decode_api_error(Event),
    fail(Reason, State);
handle_event(<<"response.created">>, _Event, State) -> {ok, [], State};
handle_event(<<"response.in_progress">>, _Event, State) -> {ok, [], State};
handle_event(<<"response.queued">>, _Event, State) -> {ok, [], State};
handle_event(<<"response.content_part.added">>, _Event, State) ->
    {ok, [], State};
handle_event(<<"response.content_part.done">>, _Event, State) ->
    {ok, [], State};
handle_event(_FutureEventType, _Event, State) ->
    %% OpenAI documents addition of stream event types as backwards
    %% compatible. Unknown bounded types are therefore ignored, not atomized.
    {ok, [], State}.

handle_text_delta(Event, State) ->
    case text_coordinates(Event) of
        {ok, Key, Delta} ->
            Limits = maps:get(limits, State),
            MaxPart = maps:get(max_text_bytes, Limits),
            MaxTotal = maps:get(max_text_bytes, Limits),
            TextParts0 = maps:get(text_parts, State),
            Part0 = maps:get(Key, TextParts0,
                             #{fragments => [], bytes => 0,
                               done => false}),
            PartBytes = maps:get(bytes, Part0) + byte_size(Delta),
            TotalBytes = maps:get(text_bytes, State) + byte_size(Delta),
            case valid_utf8(Delta) andalso
                 not maps:get(done, Part0) andalso
                 PartBytes =< MaxPart andalso TotalBytes =< MaxTotal of
                true ->
                    First = not maps:is_key(Key, TextParts0),
                    Part = Part0#{fragments =>
                                      [Delta | maps:get(fragments, Part0)],
                                  bytes => PartBytes},
                    Order0 = maps:get(text_order, State),
                    Order = case First of
                        true -> Order0 ++ [Key];
                        false -> Order0
                    end,
                    State1 = State#{text_parts => TextParts0#{Key => Part},
                                    text_order => Order,
                                    text_bytes => TotalBytes},
                    {ok, [{text_delta, Delta}], State1};
                false when PartBytes > MaxPart orelse TotalBytes > MaxTotal ->
                    fail(openai_stream_text_limit_exceeded, State);
                false -> fail(invalid_openai_text_delta, State)
            end;
        {error, Reason} -> fail(Reason, State)
    end.

handle_text_done(Event, State) ->
    case {text_key(Event), maps:get(<<"text">>, Event, undefined)} of
        {{ok, Key}, Text} when is_binary(Text) ->
            TextParts0 = maps:get(text_parts, State),
            Limits = maps:get(limits, State),
            Max = maps:get(max_text_bytes, Limits),
            case {maps:find(Key, TextParts0), valid_utf8(Text),
                  byte_size(Text) =< Max} of
                {error, true, true} ->
                    Part = #{fragments => [Text], bytes => byte_size(Text),
                             done => true},
                    Total = maps:get(text_bytes, State) + byte_size(Text),
                    case Total =< Max of
                        true ->
                            {ok, [], State#{
                                text_parts => TextParts0#{Key => Part},
                                text_order =>
                                    maps:get(text_order, State) ++ [Key],
                                text_bytes => Total}};
                        false -> fail(openai_stream_text_limit_exceeded,
                                      State)
                    end;
                {{ok, Part0}, true, true} ->
                    Assembled = assemble_fragments(Part0),
                    case not maps:get(done, Part0) andalso
                         Assembled =:= Text of
                        true ->
                            Part = Part0#{done => true},
                            {ok, [], State#{
                                text_parts => TextParts0#{Key => Part}}};
                        false -> fail(openai_stream_text_mismatch, State)
                    end;
                _ -> fail(invalid_openai_text_done, State)
            end;
        _ -> fail(invalid_openai_text_done, State)
    end.

handle_output_item_added(Event, State) ->
    case {output_index(Event), maps:get(<<"item">>, Event, undefined)} of
        {{ok, Index}, #{<<"type">> := <<"function_call">>} = Item} ->
            start_call(Index, Item, State);
        {{ok, _Index}, Item} when is_map(Item) -> {ok, [], State};
        _ -> fail(invalid_openai_output_item_added, State)
    end.

start_call(Index, Item, State) ->
    Calls0 = maps:get(calls, State),
    Name = maps:get(<<"name">>, Item, undefined),
    CallId = maps:get(<<"call_id">>, Item, undefined),
    ItemId = maps:get(<<"id">>, Item, undefined),
    Initial = maps:get(<<"arguments">>, Item, <<>>),
    Limits = maps:get(limits, State),
    Max = maps:get(max_function_payload_bytes, Limits),
    case {maps:is_key(Index, Calls0), valid_tool_name(Name),
          valid_call_id(CallId), valid_item_id(ItemId),
          is_binary(Initial) andalso byte_size(Initial) =< Max andalso
              valid_utf8(Initial)} of
        {false, true, true, true, true} ->
            Call = #{name => Name, call_id => CallId, item_id => ItemId,
                     fragments => initial_fragments(Initial),
                     bytes => byte_size(Initial), done => false,
                     call => undefined},
            {ok, [{tool_call_started, Index, Name, CallId}],
             State#{calls => Calls0#{Index => Call}}};
        {true, _, _, _, _} -> fail(duplicate_openai_stream_call, State);
        _ -> fail(invalid_openai_stream_call, State)
    end.

handle_call_delta(Event, State) ->
    case {output_index(Event), maps:get(<<"item_id">>, Event, undefined),
          maps:get(<<"delta">>, Event, undefined)} of
        {{ok, Index}, ItemId, Delta}
          when is_binary(ItemId), is_binary(Delta) ->
            Calls0 = maps:get(calls, State),
            case maps:find(Index, Calls0) of
                {ok, Call0} ->
                    Max = maps:get(max_function_payload_bytes,
                                   maps:get(limits, State)),
                    Bytes = maps:get(bytes, Call0) + byte_size(Delta),
                    case ItemId =:= maps:get(item_id, Call0) andalso
                         not maps:get(done, Call0) andalso
                         valid_utf8(Delta) andalso Bytes =< Max of
                        true ->
                            Call = Call0#{fragments =>
                                             [Delta |
                                              maps:get(fragments, Call0)],
                                         bytes => Bytes},
                            {ok, [{tool_call_arguments_delta, Index, Delta}],
                             State#{calls => Calls0#{Index => Call}}};
                        false when Bytes > Max ->
                            fail(openai_stream_arguments_limit_exceeded,
                                 State);
                        false -> fail(invalid_openai_call_delta, State)
                    end;
                error -> fail(openai_call_delta_before_start, State)
            end;
        _ -> fail(invalid_openai_call_delta, State)
    end.

handle_call_done(Event, State) ->
    case {output_index(Event), maps:get(<<"item_id">>, Event, undefined),
          maps:get(<<"name">>, Event, undefined),
          maps:get(<<"arguments">>, Event, undefined)} of
        {{ok, Index}, ItemId, Name, Arguments}
          when is_binary(ItemId), is_binary(Name), is_binary(Arguments) ->
            finalize_call(Index, ItemId, Name, Arguments, State);
        _ -> fail(invalid_openai_call_done, State)
    end.

handle_output_item_done(Event, State) ->
    case {output_index(Event), maps:get(<<"item">>, Event, undefined)} of
        {{ok, Index}, #{<<"type">> := <<"function_call">>} = Item} ->
            Calls = maps:get(calls, State),
            case maps:find(Index, Calls) of
                {ok, #{done := true} = Call} ->
                    case completed_item_matches(Item, Call) of
                        true -> {ok, [], State};
                        false -> fail(openai_stream_call_mismatch, State)
                    end;
                {ok, Call} ->
                    finalize_call(
                      Index, maps:get(<<"id">>, Item, undefined),
                      maps:get(<<"name">>, Item, undefined),
                      maps:get(<<"arguments">>, Item, undefined), State,
                      maps:get(call_id, Call));
                error -> fail(openai_call_done_before_start, State)
            end;
        {{ok, _Index}, Item} when is_map(Item) -> {ok, [], State};
        _ -> fail(invalid_openai_output_item_done, State)
    end.

finalize_call(Index, ItemId, Name, Arguments, State) ->
    finalize_call(Index, ItemId, Name, Arguments, State, undefined).

finalize_call(Index, ItemId, Name, Arguments, State, ExpectedCallId) ->
    Calls0 = maps:get(calls, State),
    case maps:find(Index, Calls0) of
        {ok, Call0} when is_binary(Arguments) ->
            Max = maps:get(max_function_payload_bytes,
                           maps:get(limits, State)),
            Assembled = assemble_fragments(Call0),
            CallIdMatches = case ExpectedCallId of
                undefined -> true;
                _ -> ExpectedCallId =:= maps:get(call_id, Call0)
            end,
            case not maps:get(done, Call0) andalso
                 ItemId =:= maps:get(item_id, Call0) andalso
                 Name =:= maps:get(name, Call0) andalso CallIdMatches andalso
                 byte_size(Arguments) =< Max andalso
                 Assembled =:= Arguments of
                true ->
                    WireItem = #{<<"type">> => <<"function_call">>,
                                 <<"name">> => Name,
                                 <<"call_id">> => maps:get(call_id, Call0),
                                 <<"arguments">> => Arguments},
                    case adk_openai_responses_content:decode_output(
                           [WireItem], maps:get(limits, State)) of
                        {ok, _Content, [Call]} ->
                            Call1 = Call0#{done => true, call => Call},
                            {ok, [{tool_call_completed, Index, Call}],
                             State#{calls => Calls0#{Index => Call1}}};
                        {error, _} ->
                            fail(invalid_openai_function_arguments, State)
                    end;
                false -> fail(openai_stream_call_mismatch, State)
            end;
        _ -> fail(openai_call_done_before_start, State)
    end.

handle_completed(Event, State) ->
    case maps:get(<<"response">>, Event, undefined) of
        Response when is_map(Response) ->
            case adk_openai_responses_codec:decode_response(
                   Response, maps:get(limits, State)) of
                {ok, Result} ->
                    case completed_matches_stream(Result, State) of
                        true ->
                            State1 = State#{status => completed,
                                            result => Result},
                            {ok, [{completed, Result}], State1};
                        false -> fail(openai_stream_completion_mismatch,
                                      State)
                    end;
                {error, Reason} -> fail(Reason, State)
            end;
        _ -> fail(invalid_openai_completed_event, State)
    end.

handle_failed_response(Event, State) ->
    case maps:get(<<"response">>, Event, undefined) of
        Response when is_map(Response) ->
            case adk_openai_responses_codec:decode_response(
                   Response, maps:get(limits, State)) of
                {error, Reason} -> fail(Reason, State);
                {ok, _} -> fail(invalid_openai_failed_event, State)
            end;
        _ -> fail(invalid_openai_failed_event, State)
    end.

handle_incomplete_response(Event, State) ->
    case maps:get(<<"response">>, Event, undefined) of
        Response when is_map(Response) ->
            case adk_openai_responses_codec:decode_response(
                   Response, maps:get(limits, State)) of
                {error, Reason} -> fail(Reason, State);
                {ok, _} -> fail(invalid_openai_incomplete_event, State)
            end;
        _ -> fail(invalid_openai_incomplete_event, State)
    end.

completed_matches_stream(Result, State) ->
    case adk_provider_result:decode(Result) of
        {ok, {ok, Text}, _Metadata} when is_binary(Text) ->
            case maps:get(text_bytes, State) of
                0 -> true;
                _ -> streamed_text(State) =:= Text
            end;
        {ok, {ok, _Content}, _Metadata} ->
            maps:get(text_bytes, State) =:= 0 andalso
                map_size(maps:get(calls, State)) =:= 0;
        {ok, {tool_calls, Calls}, _Metadata} ->
            StreamCalls = completed_stream_calls(State),
            case StreamCalls of
                [] -> true;
                _ -> StreamCalls =:= Calls
            end;
        _ -> false
    end.

completed_stream_calls(State) ->
    Calls = maps:get(calls, State),
    Ordered = lists:sort(maps:to_list(Calls)),
    case lists:all(fun({_Index, Call}) -> maps:get(done, Call) end,
                   Ordered) of
        true -> [maps:get(call, Call) || {_Index, Call} <- Ordered];
        false -> incomplete
    end.

streamed_text(State) ->
    TextParts = maps:get(text_parts, State),
    iolist_to_binary(
      [assemble_fragments(maps:get(Key, TextParts))
       || Key <- maps:get(text_order, State)]).

completed_item_matches(Item, Call) ->
    maps:get(<<"id">>, Item, undefined) =:= maps:get(item_id, Call) andalso
        maps:get(<<"call_id">>, Item, undefined) =:=
            maps:get(call_id, Call) andalso
        maps:get(<<"name">>, Item, undefined) =:= maps:get(name, Call) andalso
        maps:get(<<"arguments">>, Item, undefined) =:=
            assemble_fragments(Call).

text_coordinates(Event) ->
    case {text_key(Event), maps:get(<<"delta">>, Event, undefined)} of
        {{ok, Key}, Delta} when is_binary(Delta) -> {ok, Key, Delta};
        _ -> {error, invalid_openai_text_delta}
    end.

text_key(Event) ->
    case {output_index(Event), content_index(Event),
          maps:get(<<"item_id">>, Event, undefined)} of
        {{ok, OutputIndex}, {ok, ContentIndex}, ItemId}
          when is_binary(ItemId) ->
            case valid_item_id(ItemId) of
                true -> {ok, {OutputIndex, ContentIndex, ItemId}};
                false -> {error, invalid_item_id}
            end;
        _ -> {error, invalid_text_coordinates}
    end.

output_index(Event) -> bounded_index(maps:get(<<"output_index">>,
                                              Event, undefined)).

content_index(Event) -> bounded_index(maps:get(<<"content_index">>,
                                               Event, undefined)).

bounded_index(Value) when is_integer(Value), Value >= 0,
                          Value =< ?MAX_OUTPUT_INDEX -> {ok, Value};
bounded_index(_) -> {error, invalid_index}.

assemble_fragments(#{fragments := Fragments}) ->
    iolist_to_binary(lists:reverse(Fragments)).

initial_fragments(<<>>) -> [];
initial_fragments(Value) -> [Value].

fail(Reason, State) ->
    {error, Reason, State#{status => failed, failure => Reason}}.

valid_max_events(Value) ->
    is_integer(Value) andalso Value > 0 andalso
        Value =< ?MAX_EVENTS_CEILING.

valid_event_type(Type) when is_binary(Type), byte_size(Type) > 0,
                                byte_size(Type) =< ?MAX_EVENT_TYPE_BYTES ->
    valid_utf8(Type);
valid_event_type(_) -> false.

valid_item_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< ?MAX_ITEM_ID_BYTES ->
    valid_utf8(Value);
valid_item_id(_) -> false.

valid_tool_name(Name) when is_binary(Name), byte_size(Name) > 0,
                           byte_size(Name) =< 64 ->
    re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

valid_call_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< 64 -> valid_utf8(Value);
valid_call_id(_) -> false.

valid_utf8(Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end;
valid_utf8(_) -> false.
