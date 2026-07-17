%% @doc Logical Anthropic Messages SSE decoder and bounded stream assembler.
%%
%% `adk_model_sse_decoder' owns byte framing. This module validates the named
%% event/data agreement required by Anthropic, assembles text and tool inputs,
%% and deliberately keeps unknown future event types as binaries.
-module(adk_llm_anthropic_stream).

-export([new/0, new/1,
         decode_event/1, decode_event/2,
         feed/2, push/2,
         content/1, result/1]).

-define(STATE_VERSION, 1).
-define(MAX_EVENT_BYTES, 9437184).
-define(MAX_EVENT_TYPE_BYTES, 128).
-define(MAX_CALL_ID_BYTES, 256).
-define(MAX_TOOL_NAME_BYTES, 128).

-type emission() :: {text, binary()}.
-type state() :: map().
-export_type([emission/0, state/0]).

-spec new() -> state().
new() ->
    new(#{}).

-spec new(map()) -> state() | no_return().
new(LimitOverrides) when is_map(LimitOverrides) ->
    case adk_content:normalize_limits(LimitOverrides) of
        {ok, Limits} ->
            #{version => ?STATE_VERSION,
              phase => awaiting_start,
              limits => Limits,
              metadata => undefined,
              usage => #{},
              stop_reason => null,
              stop_sequence => null,
              active => undefined,
              next_index => 0,
              completed => [],
              saw_message_delta => false};
        {error, Reason} -> error({invalid_anthropic_stream_limits, Reason})
    end;
new(_) ->
    error(invalid_anthropic_stream_limits).

%% @doc Decode an event emitted by `adk_model_sse_decoder'. SSE id/retry
%% fields are intentionally ignored at this provider layer.
-spec decode_event(map()) -> {ok, term()} | {error, term()}.
decode_event(#{event := Name, data := Data}) ->
    decode_event(Name, Data);
decode_event(_) ->
    {error, invalid_anthropic_sse_event}.

-spec decode_event(binary(), binary() | map()) ->
    {ok, term()} | {error, term()}.
decode_event(Name, Data) when is_binary(Name),
                              byte_size(Name) > 0,
                              byte_size(Name) =< ?MAX_EVENT_TYPE_BYTES ->
    case valid_utf8(Name) of
        false -> {error, invalid_anthropic_event_name};
        true ->
            case decode_data(Data) of
                {ok, Map} -> decode_named_event(Name, Map);
                {error, _} = Error -> Error
            end
    end;
decode_event(_Name, _Data) ->
    {error, invalid_anthropic_event_name}.

%% @doc Decode and apply one provider-neutral SSE envelope.
-spec feed(state(), map()) ->
    {ok, state(), [emission()]}
    | {done, term(), state()}
    | {error, term()}.
feed(State, WireEvent) ->
    case decode_event(WireEvent) of
        {ok, Event} -> push(Event, State);
        {error, _} = Error -> Error
    end.

-spec push(term(), state()) ->
    {ok, state(), [emission()]}
    | {done, term(), state()}
    | {error, term()}.
push(Event, State) when is_map(State) ->
    case valid_state(State) of
        true -> push_checked(Event, State);
        false -> {error, invalid_anthropic_stream_state}
    end;
push(_Event, _State) ->
    {error, invalid_anthropic_stream_state}.

-spec content(state()) ->
    {ok, adk_content:content()} | {error, term()}.
content(#{active := undefined, completed := Completed,
          limits := Limits} = State) ->
    case valid_state(State) of
        false -> {error, invalid_anthropic_stream_state};
        true ->
            case lists:reverse(Completed) of
                [] -> {error, empty_anthropic_stream};
                Parts -> adk_content:new(Parts, Limits)
            end
    end;
content(State) when is_map(State) ->
    case valid_state(State) of
        true -> {error, anthropic_content_block_in_progress};
        false -> {error, invalid_anthropic_stream_state}
    end;
content(_) ->
    {error, invalid_anthropic_stream_state}.

-spec result(state()) -> term().
result(#{phase := done, metadata := Metadata,
         usage := Usage, stop_reason := StopReason,
         stop_sequence := StopSequence} = State) ->
    case {valid_state(State), content(State)} of
        {true, {ok, Content}} ->
            Calls = adk_llm_anthropic_content:tool_calls(Content),
            Outcome = case Calls of
                [] -> streamed;
                _ -> {tool_calls, Calls}
            end,
            FinalMetadata = Metadata#{
                <<"usage_metadata">> => Usage,
                <<"stop_reason">> => StopReason,
                <<"stop_sequence">> => StopSequence},
            case adk_provider_result:new(
                   <<"anthropic">>, <<"generation_metadata">>,
                   Outcome, FinalMetadata) of
                {ok, ProviderResult} -> ProviderResult;
                {error, Reason} ->
                    {error, {invalid_anthropic_stream_metadata, Reason}}
            end;
        {true, {error, _} = Error} -> Error;
        _ -> {error, invalid_anthropic_stream_state}
    end;
result(State) when is_map(State) ->
    case valid_state(State) of
        true -> {error, anthropic_stream_not_complete};
        false -> {error, invalid_anthropic_stream_state}
    end;
result(_) ->
    {error, invalid_anthropic_stream_state}.

decode_data(Data) when is_binary(Data) ->
    case byte_size(Data) =< ?MAX_EVENT_BYTES of
        false -> {error, anthropic_stream_event_too_large};
        true ->
            try jsx:decode(Data, [return_maps]) of
                Map when is_map(Map) -> decode_data(Map);
                _ -> {error, invalid_anthropic_stream_json}
            catch
                _:_ -> {error, invalid_anthropic_stream_json}
            end
    end;
decode_data(Map) when is_map(Map) ->
    case strict_json_bounded(Map, ?MAX_EVENT_BYTES) of
        ok -> {ok, Map};
        {error, _} = Error -> Error
    end;
decode_data(_) ->
    {error, invalid_anthropic_stream_json}.

decode_named_event(Name, #{<<"type">> := Type} = Map)
  when is_binary(Type) ->
    case Name =:= Type of
        true -> decode_event_fields(Name, Map);
        false -> {error, anthropic_event_type_mismatch}
    end;
decode_named_event(_Name, _Map) ->
    {error, missing_anthropic_event_type}.

decode_event_fields(<<"message_start">>,
                    #{<<"message">> :=
                          #{<<"type">> := <<"message">>,
                            <<"role">> := <<"assistant">>,
                            <<"content">> := []} = Message}) ->
    case adk_llm_anthropic_content:metadata(Message) of
        {ok, Metadata} -> {ok, {message_start, Metadata}};
        {error, _} -> {error, invalid_anthropic_message_start}
    end;
decode_event_fields(<<"message_start">>, _Map) ->
    {error, invalid_anthropic_message_start};
decode_event_fields(<<"content_block_start">>,
                    #{<<"index">> := Index,
                      <<"content_block">> := Block})
  when is_integer(Index), Index >= 0, is_map(Block) ->
    decode_block_start(Index, Block);
decode_event_fields(<<"content_block_start">>, _Map) ->
    {error, invalid_anthropic_content_block_start};
decode_event_fields(<<"content_block_delta">>,
                    #{<<"index">> := Index, <<"delta">> := Delta})
  when is_integer(Index), Index >= 0, is_map(Delta) ->
    decode_block_delta(Index, Delta);
decode_event_fields(<<"content_block_delta">>, _Map) ->
    {error, invalid_anthropic_content_block_delta};
decode_event_fields(<<"content_block_stop">>,
                    #{<<"index">> := Index})
  when is_integer(Index), Index >= 0 ->
    {ok, {content_block_stop, Index}};
decode_event_fields(<<"content_block_stop">>, _Map) ->
    {error, invalid_anthropic_content_block_stop};
decode_event_fields(<<"message_delta">>,
                    #{<<"delta">> := Delta, <<"usage">> := Usage})
  when is_map(Delta), is_map(Usage) ->
    decode_message_delta(Delta, Usage);
decode_event_fields(<<"message_delta">>, _Map) ->
    {error, invalid_anthropic_message_delta};
decode_event_fields(<<"message_stop">>, _Map) ->
    {ok, message_stop};
decode_event_fields(<<"ping">>, _Map) ->
    {ok, ping};
decode_event_fields(<<"error">>, Map) ->
    case adk_llm_anthropic_content:decode_error(Map) of
        {error, invalid_anthropic_error_response} ->
            {error, invalid_anthropic_stream_error};
        {error, Reason} -> {ok, {error_event, Reason}}
    end;
decode_event_fields(Unknown, _Map) ->
    {ok, {unknown_event, Unknown}}.

decode_block_start(Index,
                   #{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    case utf8_binary(Text) of
        true -> {ok, {content_block_start, Index, {text, Text}}};
        false -> {error, invalid_anthropic_text_block_start}
    end;
decode_block_start(Index,
                   #{<<"type">> := <<"tool_use">>,
                     <<"id">> := Id, <<"name">> := Name,
                     <<"input">> := Input}) ->
    case {bounded_utf8(Id, ?MAX_CALL_ID_BYTES),
          valid_tool_name(Name), is_map(Input)} of
        {true, true, true} ->
            {ok, {content_block_start, Index,
                  {tool_use, Id, Name, Input}}};
        _ -> {error, invalid_anthropic_tool_block_start}
    end;
decode_block_start(Index, #{<<"type">> := Type})
  when is_binary(Type), byte_size(Type) > 0,
       byte_size(Type) =< ?MAX_EVENT_TYPE_BYTES ->
    {ok, {content_block_start, Index, {ignored, Type}}};
decode_block_start(_Index, _Block) ->
    {error, invalid_anthropic_content_block_start}.

decode_block_delta(Index,
                   #{<<"type">> := <<"text_delta">>,
                     <<"text">> := Text}) ->
    case utf8_binary(Text) of
        true -> {ok, {content_block_delta, Index, {text, Text}}};
        false -> {error, invalid_anthropic_text_delta}
    end;
decode_block_delta(Index,
                   #{<<"type">> := <<"input_json_delta">>,
                     <<"partial_json">> := Partial}) ->
    case utf8_binary(Partial) of
        true -> {ok, {content_block_delta, Index,
                      {input_json, Partial}}};
        false -> {error, invalid_anthropic_tool_input_delta}
    end;
decode_block_delta(Index, #{<<"type">> := Type})
  when is_binary(Type), byte_size(Type) > 0,
       byte_size(Type) =< ?MAX_EVENT_TYPE_BYTES ->
    {ok, {content_block_delta, Index, {ignored, Type}}};
decode_block_delta(_Index, _Delta) ->
    {error, invalid_anthropic_content_block_delta}.

decode_message_delta(Delta, Usage) ->
    StopReason = maps:get(<<"stop_reason">>, Delta, unchanged),
    StopSequence = maps:get(<<"stop_sequence">>, Delta, unchanged),
    case {delta_wire_binary(StopReason, 128),
          delta_wire_binary(StopSequence, 4096),
          maps:find(<<"output_tokens">>, Usage),
          strict_json_bounded(Usage, 131072)} of
        {true, true, {ok, OutputTokens}, ok}
          when is_integer(OutputTokens), OutputTokens >= 0 ->
            {ok, {message_delta, StopReason, StopSequence, Usage}};
        _ -> {error, invalid_anthropic_message_delta}
    end.

push_checked(_Event, #{phase := done}) ->
    {error, anthropic_stream_already_done};
push_checked(ping, State) ->
    {ok, State, []};
push_checked({unknown_event, _Type}, State) ->
    {ok, State, []};
push_checked({error_event, Reason}, _State) ->
    {error, {anthropic_stream_error, Reason}};
push_checked({message_start, Metadata},
             #{phase := awaiting_start} = State) ->
    case valid_start_metadata(Metadata) of
        true ->
            Usage = maps:get(<<"usage_metadata">>, Metadata),
            {ok, State#{phase => content,
                        metadata => Metadata,
                        usage => Usage,
                        stop_reason => maps:get(<<"stop_reason">>, Metadata),
                        stop_sequence => maps:get(<<"stop_sequence">>, Metadata)}, []};
        false -> {error, invalid_anthropic_message_start}
    end;
push_checked({content_block_start, Index, Kind},
             #{phase := content, active := undefined} = State) ->
    start_block(Index, Kind, State);
push_checked({content_block_delta, Index, Delta},
             #{phase := content, active := Active} = State)
  when is_map(Active) ->
    update_block(Index, Delta, State);
push_checked({content_block_stop, Index},
             #{phase := content, active := Active} = State)
  when is_map(Active) ->
    stop_block(Index, State);
push_checked({message_delta, StopReason, StopSequence, Usage},
             #{phase := Phase, active := undefined} = State)
  when Phase =:= content; Phase =:= message_delta ->
    case valid_logical_message_delta(StopReason, StopSequence, Usage) of
        true ->
            {ok, State#{phase => message_delta,
                        usage => maps:merge(maps:get(usage, State), Usage),
                        stop_reason => delta_value(
                                         StopReason,
                                         maps:get(stop_reason, State)),
                        stop_sequence => delta_value(
                                           StopSequence,
                                           maps:get(stop_sequence, State)),
                        saw_message_delta => true}, []};
        false -> {error, invalid_anthropic_message_delta}
    end;
push_checked(message_stop,
             #{phase := message_delta, active := undefined,
               saw_message_delta := true} = State) ->
    Done = State#{phase => done},
    case result(Done) of
        {error, _} = Error -> Error;
        Result -> {done, Result, Done}
    end;
push_checked(Event, State) ->
    {error, {invalid_anthropic_stream_order,
             event_kind(Event), maps:get(phase, State)}}.

start_block(Index, _Kind, #{next_index := Next} = _State)
  when Index =/= Next ->
    {error, {invalid_anthropic_content_block_index, Index, Next}};
start_block(Index, Kind, State) ->
    MaxParts = maps:get(max_parts, maps:get(limits, State)),
    case Index < MaxParts of
        false -> {error, {anthropic_part_limit_exceeded, MaxParts}};
        true -> start_block_checked(Index, Kind, State)
    end.

start_block_checked(Index, {text, Initial}, State) ->
    Max = maps:get(max_text_bytes, maps:get(limits, State)),
    case utf8_binary(Initial) of
        false -> {error, invalid_anthropic_text_block_start};
        true ->
            Size = byte_size(Initial),
            case Size =< Max of
                true ->
            Active = #{kind => text, index => Index,
                       chunks => [Initial], bytes => Size},
            Emissions = case Initial of
                <<>> -> [];
                _ -> [{text, Initial}]
            end,
            {ok, State#{active => Active}, Emissions};
                false ->
                    {error, {anthropic_text_limit_exceeded, Size, Max}}
            end
    end;
start_block_checked(Index, {tool_use, Id, Name, Input}, State) ->
    Max = maps:get(max_function_payload_bytes, maps:get(limits, State)),
    case {bounded_utf8(Id, ?MAX_CALL_ID_BYTES), valid_tool_name(Name),
          is_map(Input), strict_json_bounded(Input, Max)} of
        {true, true, true, ok} ->
            Active = #{kind => tool, index => Index,
                       id => Id, name => Name, seed => Input,
                       chunks => [], bytes => 0},
            {ok, State#{active => Active}, []};
        _ -> {error, invalid_anthropic_tool_input}
    end;
start_block_checked(Index, {ignored, Type}, State) ->
    case bounded_utf8(Type, ?MAX_EVENT_TYPE_BYTES) of
        true ->
            Active = #{kind => ignored, index => Index, type => Type},
            {ok, State#{active => Active}, []};
        false -> {error, invalid_anthropic_content_block_start}
    end.

update_block(Index, _Delta, #{active := #{index := Expected}})
  when Index =/= Expected ->
    {error, {invalid_anthropic_content_block_index, Index, Expected}};
update_block(_Index, {text, Text},
             #{active := #{kind := text, chunks := Chunks,
                           bytes := Bytes} = Active} = State) ->
    Max = maps:get(max_text_bytes, maps:get(limits, State)),
    case utf8_binary(Text) of
        false -> {error, invalid_anthropic_text_delta};
        true ->
            NewBytes = Bytes + byte_size(Text),
            case NewBytes =< Max of
                true ->
            NewActive = Active#{chunks => [Text | Chunks],
                                bytes => NewBytes},
            Emissions = case Text of <<>> -> []; _ -> [{text, Text}] end,
            {ok, State#{active => NewActive}, Emissions};
                false ->
                    {error, {anthropic_text_limit_exceeded, NewBytes, Max}}
            end
    end;
update_block(_Index, {input_json, Partial},
             #{active := #{kind := tool, chunks := Chunks,
                           bytes := Bytes} = Active} = State) ->
    Max = maps:get(max_function_payload_bytes, maps:get(limits, State)),
    case utf8_binary(Partial) of
        false -> {error, invalid_anthropic_tool_input_delta};
        true ->
            NewBytes = Bytes + byte_size(Partial),
            case NewBytes =< Max of
                true ->
            NewActive = Active#{chunks => [Partial | Chunks],
                                bytes => NewBytes},
            {ok, State#{active => NewActive}, []};
                false ->
                    {error, {anthropic_tool_input_limit_exceeded,
                             NewBytes, Max}}
            end
    end;
update_block(_Index, {ignored, _Type}, State) ->
    {ok, State, []};
update_block(_Index, _Delta,
             #{active := #{kind := ignored}} = State) ->
    {ok, State, []};
update_block(_Index, Delta, #{active := #{kind := Kind}}) ->
    {error, {invalid_anthropic_delta_for_block,
             delta_kind(Delta), Kind}}.

stop_block(Index, #{active := #{index := Expected}})
  when Index =/= Expected ->
    {error, {invalid_anthropic_content_block_index, Index, Expected}};
stop_block(_Index, #{active := #{kind := text,
                                chunks := Chunks}} = State) ->
    Text = iolist_to_binary(lists:reverse(Chunks)),
    finish_part(#{<<"type">> => <<"text">>, <<"text">> => Text}, State);
stop_block(_Index, #{active := #{kind := tool} = Active} = State) ->
    case complete_tool_input(Active, maps:get(limits, State)) of
        {ok, Input} ->
            Part = #{<<"type">> => <<"function_call">>,
                     <<"id">> => maps:get(id, Active),
                     <<"name">> => maps:get(name, Active),
                     <<"args">> => Input},
            finish_part(Part, State);
        {error, _} = Error -> Error
    end;
stop_block(_Index, #{active := #{kind := ignored}} = State) ->
    {ok, advance_block(State), []}.

finish_part(Part, #{limits := Limits, completed := Completed} = State) ->
    case adk_content:new([Part], Limits) of
        {ok, Canonical} ->
            [CanonicalPart] = adk_content:parts(Canonical),
            {ok, advance_block(
                   State#{completed => [CanonicalPart | Completed]}), []};
        {error, Reason} ->
            {error, {invalid_anthropic_stream_content, Reason}}
    end.

advance_block(State) ->
    State#{active => undefined,
           next_index => maps:get(next_index, State) + 1}.

complete_tool_input(#{seed := Seed, chunks := []}, Limits) ->
    Max = maps:get(max_function_payload_bytes, Limits),
    case strict_json_bounded(Seed, Max) of
        ok -> {ok, Seed};
        {error, _} -> {error, invalid_anthropic_tool_input}
    end;
complete_tool_input(#{seed := Seed, chunks := Chunks}, Limits)
  when map_size(Seed) =:= 0 ->
    Json = iolist_to_binary(lists:reverse(Chunks)),
    try jsx:decode(Json, [return_maps]) of
        Input when is_map(Input) ->
            Max = maps:get(max_function_payload_bytes, Limits),
            case strict_json_bounded(Input, Max) of
                ok -> {ok, Input};
                {error, _} -> {error, invalid_anthropic_tool_input}
            end;
        _ -> {error, anthropic_tool_input_must_be_object}
    catch
        _:_ -> {error, invalid_anthropic_tool_input_json}
    end;
complete_tool_input(_Active, _Limits) ->
    {error, conflicting_anthropic_tool_input}.

strict_json_bounded(Value, Max) ->
    case adk_json:normalize(Value) of
        {ok, Value} ->
            try jsx:encode(Value) of
                Encoded when byte_size(Encoded) =< Max -> ok;
                _ -> {error, anthropic_stream_json_too_large}
            catch
                _:_ -> {error, invalid_anthropic_stream_json}
            end;
        {ok, _Coerced} ->
            {error, anthropic_stream_json_must_be_canonical};
        {error, _} -> {error, invalid_anthropic_stream_json}
    end.

valid_state(#{version := ?STATE_VERSION,
              phase := Phase, limits := Limits,
              metadata := Metadata, usage := Usage,
              stop_reason := StopReason,
              stop_sequence := StopSequence,
              active := Active, next_index := Next,
              completed := Completed,
              saw_message_delta := Saw}) ->
    valid_phase(Phase) andalso valid_limits(Limits) andalso
        valid_phase_metadata(Phase, Metadata) andalso
        is_map(Usage) andalso
        strict_json_bounded(Usage, 131072) =:= ok andalso
        optional_wire_binary(StopReason, 128) andalso
        optional_wire_binary(StopSequence, 4096) andalso
        valid_active(Active) andalso
        is_integer(Next) andalso Next >= 0 andalso
        is_list(Completed) andalso is_boolean(Saw);
valid_state(_) -> false.

valid_phase(awaiting_start) -> true;
valid_phase(content) -> true;
valid_phase(message_delta) -> true;
valid_phase(done) -> true;
valid_phase(_) -> false.

valid_phase_metadata(awaiting_start, undefined) -> true;
valid_phase_metadata(Phase, Metadata)
  when Phase =:= content; Phase =:= message_delta; Phase =:= done ->
    valid_start_metadata(Metadata);
valid_phase_metadata(_, _) -> false.

valid_start_metadata(#{<<"message_id">> := Id,
                       <<"model">> := Model,
                       <<"stop_reason">> := StopReason,
                       <<"stop_sequence">> := StopSequence,
                       <<"usage_metadata">> := Usage} = Metadata) ->
    bounded_utf8(Id, 512) andalso bounded_utf8(Model, 512) andalso
        optional_wire_binary(StopReason, 128) andalso
        optional_wire_binary(StopSequence, 4096) andalso
        valid_initial_usage(Usage) andalso
        strict_json_bounded(Metadata, 262144) =:= ok;
valid_start_metadata(_) -> false.

valid_initial_usage(Usage) when is_map(Usage) ->
    case {maps:find(<<"input_tokens">>, Usage),
          maps:find(<<"output_tokens">>, Usage),
          strict_json_bounded(Usage, 131072)} of
        {{ok, Input}, {ok, Output}, ok} ->
            is_integer(Input) andalso Input >= 0 andalso
                is_integer(Output) andalso Output >= 0;
        _ -> false
    end;
valid_initial_usage(_) -> false.

valid_logical_message_delta(StopReason, StopSequence, Usage)
  when is_map(Usage) ->
    delta_wire_binary(StopReason, 128) andalso
        delta_wire_binary(StopSequence, 4096) andalso
        case maps:find(<<"output_tokens">>, Usage) of
            {ok, Tokens} when is_integer(Tokens), Tokens >= 0 ->
                strict_json_bounded(Usage, 131072) =:= ok;
            _ -> false
        end;
valid_logical_message_delta(_, _, _) -> false.

valid_limits(Limits) when is_map(Limits) ->
    case adk_content:normalize_limits(Limits) of
        {ok, Limits} -> true;
        _ -> false
    end;
valid_limits(_) -> false.

valid_active(undefined) -> true;
valid_active(#{kind := text, index := Index, chunks := Chunks,
               bytes := Bytes}) ->
    is_integer(Index) andalso Index >= 0 andalso is_list(Chunks) andalso
        lists:all(fun utf8_binary/1, Chunks) andalso
        is_integer(Bytes) andalso Bytes >= 0;
valid_active(#{kind := tool, index := Index, id := Id, name := Name,
               seed := Seed, chunks := Chunks, bytes := Bytes}) ->
    is_integer(Index) andalso Index >= 0 andalso
        bounded_utf8(Id, ?MAX_CALL_ID_BYTES) andalso valid_tool_name(Name)
        andalso is_map(Seed) andalso is_list(Chunks) andalso
        lists:all(fun utf8_binary/1, Chunks) andalso
        is_integer(Bytes) andalso Bytes >= 0;
valid_active(#{kind := ignored, index := Index, type := Type}) ->
    is_integer(Index) andalso Index >= 0 andalso
        bounded_utf8(Type, ?MAX_EVENT_TYPE_BYTES);
valid_active(_) -> false.

event_kind({Name, _}) when is_atom(Name) -> Name;
event_kind({Name, _, _}) when is_atom(Name) -> Name;
event_kind({Name, _, _, _}) when is_atom(Name) -> Name;
event_kind(Name) when is_atom(Name) -> Name;
event_kind(_) -> invalid.

delta_kind({Kind, _}) -> Kind;
delta_kind(_) -> invalid.

optional_wire_binary(null, _Max) -> true;
optional_wire_binary(Value, Max) -> bounded_utf8_allow_empty(Value, Max).

delta_wire_binary(unchanged, _Max) -> true;
delta_wire_binary(Value, Max) -> optional_wire_binary(Value, Max).

delta_value(unchanged, Existing) -> Existing;
delta_value(Value, _Existing) -> Value.

bounded_utf8(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                              byte_size(Value) =< Max ->
    valid_utf8(Value);
bounded_utf8(_, _) -> false.

bounded_utf8_allow_empty(Value, Max)
  when is_binary(Value), byte_size(Value) =< Max ->
    valid_utf8(Value);
bounded_utf8_allow_empty(_, _) -> false.

utf8_binary(Value) when is_binary(Value) -> valid_utf8(Value);
utf8_binary(_) -> false.

valid_tool_name(Name) when is_binary(Name),
                           byte_size(Name) > 0,
                           byte_size(Name) =< ?MAX_TOOL_NAME_BYTES ->
    valid_utf8(Name) andalso
        re:run(Name, <<"^[A-Za-z0-9_-]{1,128}$">>,
               [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.
