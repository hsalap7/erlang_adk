%% @doc Bounded raw-SSE assembler for compatible Chat Completions streams.
%%
%% `feed/2' accepts arbitrary HTTP/TCP byte chunks and delegates SSE framing
%% to `adk_model_sse_decoder'. This module then validates Chat Completions
%% deltas, assembles interleaved parallel tool calls by numeric index, and
%% creates one checked provider result when `[DONE]' is received.
-module(adk_llm_compatible_stream).

-export([new/0, new/1, feed/2, finish/1, result/1, content/1]).

-define(STATE_VERSION, 1).
-define(DEFAULT_MAX_EVENTS, 100000).
-define(MAX_EVENTS, 1000000).
-define(DEFAULT_MAX_SSE_EVENT_BYTES, 9437184).
-define(MAX_ID_BYTES, 512).
-define(MAX_MODEL_BYTES, 512).
-define(MAX_FINGERPRINT_BYTES, 512).

-type emission() :: {text, binary()}.
-type state() :: map().
-export_type([emission/0, state/0]).

-spec new() -> {ok, state()} | {error, term()}.
new() -> new(#{}).

-spec new(map()) -> {ok, state()} | {error, term()}.
new(Options) when is_map(Options) ->
    Limits0 = content_limits(Options),
    MaxEvents = maps:get(max_stream_events, Options, ?DEFAULT_MAX_EVENTS),
    SseOptions = maps:get(
                   sse_options, Options,
                   #{max_buffer_bytes => ?DEFAULT_MAX_SSE_EVENT_BYTES,
                     max_event_bytes => ?DEFAULT_MAX_SSE_EVENT_BYTES,
                     max_events_per_feed => 4096}),
    case {adk_content:normalize_limits(Limits0),
          valid_max_events(MaxEvents), is_map(SseOptions)} of
        {{ok, Limits}, true, true} ->
            try adk_model_sse_decoder:new(SseOptions) of
                Sse ->
                    {ok, #{version => ?STATE_VERSION,
                           phase => streaming,
                           sse => Sse,
                           limits => Limits,
                           max_events => MaxEvents,
                           event_count => 0,
                           response_id => undefined,
                           model => undefined,
                           fingerprint => undefined,
                           usage => #{},
                           text_fragments => [],
                           text_bytes => 0,
                           calls => #{},
                           finish_reason => undefined,
                           content => undefined,
                           result => undefined}}
            catch
                error:_ -> {error, invalid_compatible_sse_options}
            end;
        {{error, Reason}, _, _} ->
            {error, {invalid_compatible_content_limits, Reason}};
        {_, false, _} -> {error, invalid_compatible_stream_event_limit};
        {_, _, false} -> {error, invalid_compatible_sse_options}
    end;
new(_Options) -> {error, invalid_compatible_stream_options}.

%% @doc Feed raw SSE bytes. The terminal form retains emissions produced by
%% earlier events in the same byte chunk, so a coalesced delta plus `[DONE]'
%% can never lose text delivered to the caller.
-spec feed(state(), binary()) ->
    {ok, state(), [emission()]} |
    {done, adk_provider_result:result(), state(), [emission()]} |
    {error, term()}.
feed(State, Chunk) when is_map(State), is_binary(Chunk) ->
    case valid_state(State) of
        false -> {error, invalid_compatible_stream_state};
        true ->
            case maps:get(phase, State) of
                done -> {error, compatible_stream_already_done};
                streaming -> feed_streaming(State, Chunk)
            end
    end;
feed(_State, _Chunk) -> {error, invalid_compatible_stream_input}.

-spec finish(state()) ->
    {ok, adk_provider_result:result()} | {error, term()}.
finish(State) when is_map(State) ->
    case valid_state(State) of
        false -> {error, invalid_compatible_stream_state};
        true -> finish_checked(State)
    end;
finish(_State) -> {error, invalid_compatible_stream_state}.

-spec result(state()) ->
    {ok, adk_provider_result:result()} | {error, term()}.
result(#{version := ?STATE_VERSION, phase := done, result := Result}) ->
    {ok, Result};
result(#{version := ?STATE_VERSION, phase := streaming}) ->
    {error, compatible_stream_not_complete};
result(_State) -> {error, invalid_compatible_stream_state}.

-spec content(state()) ->
    {ok, adk_content:content()} | {error, term()}.
content(#{version := ?STATE_VERSION, phase := done,
          content := Content}) when is_map(Content) ->
    {ok, Content};
content(#{version := ?STATE_VERSION, phase := streaming}) ->
    {error, compatible_stream_not_complete};
content(_State) -> {error, invalid_compatible_stream_state}.

feed_streaming(State, Chunk) ->
    case adk_model_sse_decoder:feed(maps:get(sse, State), Chunk) of
        {ok, Events, Sse} ->
            process_events(Events, State#{sse => Sse}, []);
        {error, Reason} -> {error, {compatible_sse_error, Reason}}
    end.

process_events([], State, Emissions) ->
    {ok, State, lists:reverse(Emissions)};
process_events([Event | Rest], State0, Emissions0) ->
    case count_event(State0) of
        {error, _} = Error -> Error;
        {ok, State1} ->
            case process_event(Event, State1) of
                {ok, State2, Emissions} ->
                    process_events(Rest, State2,
                                   lists:reverse(Emissions, Emissions0));
                {done, Result, State2} ->
                    case Rest of
                        [] ->
                            {done, Result, State2,
                             lists:reverse(Emissions0)};
                        _ -> {error, compatible_events_after_done}
                    end;
                {error, _} = Error -> Error
            end
    end.

count_event(State) ->
    Count = maps:get(event_count, State),
    Max = maps:get(max_events, State),
    case Count < Max of
        true -> {ok, State#{event_count => Count + 1}};
        false -> {error, compatible_stream_event_limit_exceeded}
    end.

process_event(#{data := <<"[DONE]">>}, State) ->
    finalize(State);
process_event(#{data := Data}, State) when is_binary(Data) ->
    case decode_chunk(Data) of
        {ok, Chunk} -> apply_chunk(Chunk, State);
        {error, _} = Error -> Error
    end.

decode_chunk(Data) ->
    Max = ?DEFAULT_MAX_SSE_EVENT_BYTES,
    case byte_size(Data) =< Max of
        false -> {error, compatible_stream_chunk_too_large};
        true ->
            try jsx:decode(Data, [return_maps]) of
                Map when is_map(Map) -> {ok, Map};
                _ -> {error, invalid_compatible_stream_json}
            catch
                _:_ -> {error, invalid_compatible_stream_json}
            end
    end.

apply_chunk(#{<<"error">> := _} = Chunk, _State) ->
    adk_llm_compatible_request:decode_error(Chunk);
apply_chunk(Chunk, State0) ->
    Choices = maps:get(<<"choices">>, Chunk, undefined),
    case capture_chunk_metadata(Chunk, Choices, State0) of
        {ok, State1} -> apply_choices(Choices, State1);
        {error, _} = Error -> Error
    end.

capture_chunk_metadata(Chunk, Choices, State0) ->
    case capture_identity(Chunk, Choices, State0) of
        {ok, State1} ->
            case capture_fingerprint(Chunk, State1) of
                {ok, State2} -> capture_usage(Chunk, State2);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

capture_identity(Chunk, Choices, State) ->
    Id = maps:get(<<"id">>, Chunk, undefined),
    Model = maps:get(<<"model">>, Chunk, undefined),
    case {Id, Model, Choices} of
        {undefined, undefined, []} -> {ok, State};
        _ ->
            case {bounded_utf8(Id, ?MAX_ID_BYTES),
                  bounded_utf8(Model, ?MAX_MODEL_BYTES)} of
                {true, true} ->
                    match_or_set_identity(Id, Model, State);
                _ -> {error, invalid_compatible_stream_identity}
            end
    end.

match_or_set_identity(Id, Model,
                      #{response_id := undefined, model := undefined} = State) ->
    {ok, State#{response_id => Id, model => Model}};
match_or_set_identity(Id, Model,
                      #{response_id := Id, model := Model} = State) ->
    {ok, State};
match_or_set_identity(_Id, _Model, _State) ->
    {error, compatible_stream_identity_mismatch}.

capture_fingerprint(Chunk, State) ->
    case maps:get(<<"system_fingerprint">>, Chunk, undefined) of
        undefined -> {ok, State};
        null -> {ok, State};
        Value ->
            case bounded_utf8(Value, ?MAX_FINGERPRINT_BYTES) of
                false -> {error, invalid_compatible_stream_fingerprint};
                true -> match_or_set_fingerprint(Value, State)
            end
    end.

match_or_set_fingerprint(Value, #{fingerprint := undefined} = State) ->
    {ok, State#{fingerprint => Value}};
match_or_set_fingerprint(Value, #{fingerprint := Value} = State) ->
    {ok, State};
match_or_set_fingerprint(_Value, _State) ->
    {error, compatible_stream_fingerprint_mismatch}.

capture_usage(Chunk, State) ->
    case maps:find(<<"usage">>, Chunk) of
        error -> {ok, State};
        {ok, null} -> {ok, State};
        {ok, Usage} ->
            case normalize_usage(Usage) of
                {ok, Normalized} ->
                    Existing = maps:get(usage, State),
                    case usage_consistent(Existing, Normalized) of
                        true -> {ok, State#{usage => maps:merge(
                                                       Existing,
                                                       Normalized)}};
                        false -> {error, compatible_stream_usage_mismatch}
                    end;
                {error, _} -> {error, invalid_compatible_stream_usage}
            end
    end.

usage_consistent(Existing, New) ->
    lists:all(
      fun({Key, Value}) ->
              case maps:find(Key, Existing) of
                  error -> true;
                  {ok, Value} -> true;
                  {ok, _Other} -> false
              end
      end, maps:to_list(New)).

apply_choices([], State) -> {ok, State, []};
apply_choices([#{<<"index">> := 0,
                 <<"delta">> := Delta} = Choice], State0)
  when is_map(Delta) ->
    case apply_delta(Delta, State0) of
        {ok, State1, Emissions} ->
            case capture_finish_reason(Choice, State1) of
                {ok, State2} -> {ok, State2, Emissions};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
apply_choices(_Choices, _State) ->
    {error, invalid_compatible_stream_choices}.

apply_delta(Delta, State0) ->
    case validate_delta_role(maps:get(<<"role">>, Delta, undefined)) of
        ok ->
            case append_text_delta(
                   maps:get(<<"content">>, Delta, undefined), State0) of
                {ok, State1, TextEmissions} ->
                    case append_tool_deltas(
                           maps:get(<<"tool_calls">>, Delta, []), State1) of
                        {ok, State2} -> {ok, State2, TextEmissions};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_delta_role(undefined) -> ok;
validate_delta_role(null) -> ok;
validate_delta_role(<<"assistant">>) -> ok;
validate_delta_role(_Role) -> {error, invalid_compatible_stream_role}.

append_text_delta(undefined, State) -> {ok, State, []};
append_text_delta(null, State) -> {ok, State, []};
append_text_delta(<<>>, State) -> {ok, State, []};
append_text_delta(Text, State) when is_binary(Text) ->
    Max = maps:get(max_text_bytes, maps:get(limits, State)),
    Bytes = maps:get(text_bytes, State) + byte_size(Text),
    case valid_utf8(Text) andalso Bytes =< Max of
        true ->
            {ok, State#{text_fragments =>
                            [Text | maps:get(text_fragments, State)],
                        text_bytes => Bytes},
             [{text, Text}]};
        false when Bytes > Max ->
            {error, compatible_stream_text_limit_exceeded};
        false -> {error, invalid_compatible_stream_text_delta}
    end;
append_text_delta(_Text, _State) ->
    {error, invalid_compatible_stream_text_delta}.

append_tool_deltas(Deltas, State) ->
    MaxCalls = maps:get(max_parts, maps:get(limits, State)),
    case bounded_list_length(Deltas, MaxCalls) of
        {ok, _} -> append_tool_deltas(Deltas, State, #{});
        too_many -> {error, compatible_stream_tool_call_limit_exceeded};
        improper -> {error, invalid_compatible_stream_tool_deltas}
    end.

append_tool_deltas([], State, _Seen) -> {ok, State};
append_tool_deltas([Delta | Rest], State0, Seen) ->
    case maps:get(<<"index">>, Delta, undefined) of
        Index when is_integer(Index), Index >= 0 ->
            Max = maps:get(max_parts, maps:get(limits, State0)),
            case Index < Max andalso not maps:is_key(Index, Seen) of
                true ->
                    case append_tool_delta(Index, Delta, State0) of
                        {ok, State1} ->
                            append_tool_deltas(Rest, State1,
                                               Seen#{Index => true});
                        {error, _} = Error -> Error
                    end;
                false -> {error, invalid_compatible_stream_tool_index}
            end;
        _ -> {error, invalid_compatible_stream_tool_index}
    end.

append_tool_delta(Index, Delta, State) ->
    Calls = maps:get(calls, State),
    case maps:find(Index, Calls) of
        error -> start_tool_delta(Index, Delta, State);
        {ok, Call} -> update_tool_delta(Index, Delta, Call, State)
    end.

start_tool_delta(Index,
                 #{<<"id">> := CallId, <<"type">> := <<"function">>,
                   <<"function">> := Function}, State)
  when is_map(Function) ->
    Name = maps:get(<<"name">>, Function, undefined),
    Arguments = maps:get(<<"arguments">>, Function, <<>>),
    Max = maps:get(max_function_payload_bytes, maps:get(limits, State)),
    case {valid_call_id(CallId), valid_tool_name(Name),
          valid_fragment(Arguments, Max)} of
        {true, true, true} ->
            Call = #{id => CallId, name => Name,
                     fragments => initial_fragments(Arguments),
                     bytes => byte_size(Arguments)},
            Calls = maps:get(calls, State),
            {ok, State#{calls => Calls#{Index => Call}}};
        _ -> {error, invalid_compatible_stream_tool_start}
    end;
start_tool_delta(_Index, _Delta, _State) ->
    {error, invalid_compatible_stream_tool_start}.

update_tool_delta(Index, Delta, Call0, State) ->
    Id = maps:get(<<"id">>, Delta, undefined),
    Type = maps:get(<<"type">>, Delta, undefined),
    Function = maps:get(<<"function">>, Delta, undefined),
    case {optional_match(Id, maps:get(id, Call0)),
          optional_match(Type, <<"function">>), is_map(Function)} of
        {true, true, true} ->
            Name = maps:get(<<"name">>, Function, undefined),
            Arguments = maps:get(<<"arguments">>, Function, <<>>),
            Max = maps:get(max_function_payload_bytes,
                           maps:get(limits, State)),
            Bytes = maps:get(bytes, Call0) + value_size(Arguments),
            case optional_match(Name, maps:get(name, Call0)) andalso
                 valid_fragment(Arguments, Max) andalso Bytes =< Max of
                true ->
                    Fragments = case Arguments of
                        <<>> -> maps:get(fragments, Call0);
                        _ -> [Arguments | maps:get(fragments, Call0)]
                    end,
                    Call = Call0#{fragments => Fragments, bytes => Bytes},
                    Calls = maps:get(calls, State),
                    {ok, State#{calls => Calls#{Index => Call}}};
                false when Bytes > Max ->
                    {error, compatible_stream_arguments_limit_exceeded};
                false -> {error, invalid_compatible_stream_tool_delta}
            end;
        _ -> {error, invalid_compatible_stream_tool_delta}
    end.

optional_match(undefined, _Expected) -> true;
optional_match(null, _Expected) -> true;
optional_match(Value, Value) -> true;
optional_match(_Value, _Expected) -> false.

valid_fragment(Value, Max) when is_binary(Value), byte_size(Value) =< Max ->
    valid_utf8(Value);
valid_fragment(_Value, _Max) -> false.

value_size(Value) when is_binary(Value) -> byte_size(Value);
value_size(_Value) -> 0.

initial_fragments(<<>>) -> [];
initial_fragments(Value) -> [Value].

capture_finish_reason(Choice, State) ->
    case maps:get(<<"finish_reason">>, Choice, null) of
        null -> {ok, State};
        Reason when is_binary(Reason) ->
            case maps:get(finish_reason, State) of
                undefined -> {ok, State#{finish_reason => Reason}};
                Reason -> {ok, State};
                _ -> {error, compatible_stream_finish_reason_mismatch}
            end;
        _ -> {error, invalid_compatible_stream_finish_reason}
    end.

finalize(State) ->
    case {maps:get(response_id, State), maps:get(model, State),
          maps:get(finish_reason, State)} of
        {undefined, _, _} ->
            {error, missing_compatible_stream_identity};
        {_, undefined, _} ->
            {error, missing_compatible_stream_identity};
        {_, _, undefined} ->
            {error, missing_compatible_stream_finish_reason};
        {_Id, _Model, FinishReason} ->
            finalize_content(FinishReason, State)
    end.

finalize_content(FinishReason, State) ->
    Text = iolist_to_binary(lists:reverse(
                              maps:get(text_fragments, State))),
    case completed_wire_calls(State) of
        {ok, WireCalls} ->
            Message0 = #{<<"role">> => <<"assistant">>,
                         <<"content">> =>
                             case Text of
                                 <<>> when WireCalls =/= [] -> null;
                                 _ -> Text
                             end},
            Message = case WireCalls of
                [] -> Message0;
                _ -> Message0#{<<"tool_calls">> => WireCalls}
            end,
            Limits = maps:get(limits, State),
            case adk_llm_compatible_content:decode_message(Message, Limits) of
                {ok, Content, Calls} ->
                    case validate_finish(FinishReason, Calls) of
                        ok -> complete_result(FinishReason, Content,
                                              Calls, State);
                        {error, _} = Error -> Error
                    end;
                {error, _} ->
                    {error, invalid_compatible_stream_content}
            end;
        {error, _} = Error -> Error
    end.

completed_wire_calls(State) ->
    Ordered = lists:sort(maps:to_list(maps:get(calls, State))),
    completed_wire_calls(Ordered, maps:get(limits, State), [], #{}).

completed_wire_calls([], _Limits, Acc, _Ids) ->
    {ok, lists:reverse(Acc)};
completed_wire_calls([{_Index, Call} | Rest], Limits, Acc, Ids) ->
    Id = maps:get(id, Call),
    Name = maps:get(name, Call),
    Arguments = iolist_to_binary(lists:reverse(
                                   maps:get(fragments, Call))),
    Max = maps:get(max_function_payload_bytes, Limits),
    case not maps:is_key(Id, Ids) andalso byte_size(Arguments) =< Max andalso
         valid_json_object(Arguments) of
        true ->
            Wire = #{<<"id">> => Id,
                     <<"type">> => <<"function">>,
                     <<"function">> =>
                         #{<<"name">> => Name,
                           <<"arguments">> => Arguments}},
            completed_wire_calls(Rest, Limits, [Wire | Acc],
                                 Ids#{Id => true});
        false -> {error, invalid_compatible_stream_tool_arguments}
    end.

valid_json_object(Json) ->
    try jsx:decode(Json, [return_maps]) of
        Value when is_map(Value) ->
            case adk_json:normalize(Value) of
                {ok, Value} -> true;
                _ -> false
            end;
        _ -> false
    catch _:_ -> false
    end.

validate_finish(<<"stop">>, []) -> ok;
validate_finish(<<"tool_calls">>, [_ | _]) -> ok;
validate_finish(<<"function_call">>, [_ | _]) -> ok;
validate_finish(<<"length">>, _Calls) ->
    {error, compatible_response_incomplete};
validate_finish(<<"content_filter">>, _Calls) ->
    {error, compatible_response_filtered};
validate_finish(_Reason, _Calls) ->
    {error, invalid_compatible_finish_reason}.

complete_result(FinishReason, Content, Calls, State) ->
    Outcome = case Calls of
        [] -> streamed;
        _ -> {tool_calls, Calls}
    end,
    Metadata0 = #{<<"response_id">> => maps:get(response_id, State),
                  <<"response_model">> => maps:get(model, State),
                  <<"finish_reason">> => FinishReason},
    Metadata1 = maybe_metadata(<<"usage">>, maps:get(usage, State),
                               #{}, Metadata0),
    Metadata = maybe_metadata(<<"system_fingerprint">>,
                              maps:get(fingerprint, State),
                              undefined, Metadata1),
    case adk_provider_result:new(
           <<"openai_compatible">>, <<"chat_completions">>,
           Outcome, Metadata) of
        {ok, Result} ->
            Done = State#{phase => done, content => Content,
                          result => Result},
            {done, Result, Done};
        {error, _} -> {error, invalid_compatible_stream_metadata}
    end.

finish_checked(#{phase := done} = State) -> result(State);
finish_checked(#{phase := streaming} = State0) ->
    case adk_model_sse_decoder:finish(maps:get(sse, State0)) of
        {ok, Events} ->
            case process_events(Events, State0, []) of
                {done, Result, _Done, _Emissions} -> {ok, Result};
                {ok, State1, _Emissions} ->
                    case maps:get(finish_reason, State1) of
                        undefined -> {error, incomplete_compatible_stream};
                        _ ->
                            case finalize(State1) of
                                {done, Result, _Done} -> {ok, Result};
                                {error, _} = Error -> Error
                            end
                    end;
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, {compatible_sse_error, Reason}}
    end.

normalize_usage(Usage) when is_map(Usage) ->
    Fields = [{<<"prompt_tokens">>, <<"input_tokens">>},
              {<<"completion_tokens">>, <<"output_tokens">>},
              {<<"total_tokens">>, <<"total_tokens">>}],
    copy_usage(Fields, Usage, #{});
normalize_usage(_Usage) -> {error, invalid_usage}.

copy_usage([], _Usage, Acc) -> {ok, Acc};
copy_usage([{Source, Target} | Rest], Usage, Acc) ->
    case maps:find(Source, Usage) of
        error -> copy_usage(Rest, Usage, Acc);
        {ok, Value} when is_integer(Value), Value >= 0 ->
            copy_usage(Rest, Usage, Acc#{Target => Value});
        {ok, _} -> {error, invalid_usage_integer}
    end.

content_limits(#{content_limits := Limits}) when is_map(Limits) -> Limits;
content_limits(Map) when is_map(Map) ->
    Allowed = maps:keys(adk_content:default_limits()),
    case lists:all(fun(Key) -> lists:member(Key, Allowed) end,
                   maps:keys(Map)) of
        true -> Map;
        false -> #{}
    end.

valid_state(#{version := ?STATE_VERSION,
              phase := Phase, sse := Sse, limits := Limits,
              max_events := MaxEvents, event_count := EventCount,
              response_id := ResponseId, model := Model,
              fingerprint := Fingerprint, usage := Usage,
              text_fragments := Text, text_bytes := TextBytes,
              calls := Calls, finish_reason := FinishReason,
              content := Content, result := Result}) ->
    (Phase =:= streaming orelse Phase =:= done) andalso
        is_map(Sse) andalso valid_limits(Limits) andalso
        valid_max_events(MaxEvents) andalso
        is_integer(EventCount) andalso EventCount >= 0 andalso
        EventCount =< MaxEvents andalso
        valid_optional_bounded(ResponseId, ?MAX_ID_BYTES) andalso
        valid_optional_bounded(Model, ?MAX_MODEL_BYTES) andalso
        valid_optional_bounded(Fingerprint, ?MAX_FINGERPRINT_BYTES) andalso
        valid_usage(Usage) andalso
        valid_fragments(Text, TextBytes,
                        maps:get(max_text_bytes, Limits)) andalso
        valid_calls(Calls, Limits) andalso
        valid_optional_bounded(FinishReason, 64) andalso
        (Content =:= undefined orelse is_map(Content)) andalso
        (Result =:= undefined orelse is_tuple(Result));
valid_state(_) -> false.

valid_limits(Limits) when is_map(Limits) ->
    adk_content:normalize_limits(Limits) =:= {ok, Limits};
valid_limits(_Limits) -> false.

valid_optional_bounded(undefined, _Max) -> true;
valid_optional_bounded(Value, Max) -> bounded_utf8(Value, Max).

valid_usage(Usage) when is_map(Usage) ->
    map_size(Usage) =< 3 andalso
        lists:all(
          fun({Key, Value}) ->
                  lists:member(Key, [<<"input_tokens">>,
                                     <<"output_tokens">>,
                                     <<"total_tokens">>]) andalso
                  is_integer(Value) andalso Value >= 0
          end, maps:to_list(Usage));
valid_usage(_Usage) -> false.

valid_fragments(Fragments, Bytes, Max)
  when is_list(Fragments), is_integer(Bytes), Bytes >= 0, Bytes =< Max ->
    try lists:all(fun(Fragment) ->
                          is_binary(Fragment) andalso valid_utf8(Fragment)
                  end, Fragments) andalso
        iolist_size(Fragments) =:= Bytes
    catch _:_ -> false
    end;
valid_fragments(_Fragments, _Bytes, _Max) -> false.

valid_calls(Calls, Limits) when is_map(Calls), is_map(Limits) ->
    MaxParts = maps:get(max_parts, Limits),
    MaxBytes = maps:get(max_function_payload_bytes, Limits),
    map_size(Calls) =< MaxParts andalso
        lists:all(
          fun({Index, Call}) ->
                  is_integer(Index) andalso Index >= 0 andalso
                      Index < MaxParts andalso
                      valid_call_state(Call, MaxBytes)
          end, maps:to_list(Calls));
valid_calls(_Calls, _Limits) -> false.

valid_call_state(#{id := Id, name := Name,
                   fragments := Fragments, bytes := Bytes}, Max) ->
    valid_call_id(Id) andalso valid_tool_name(Name) andalso
        valid_fragments(Fragments, Bytes, Max);
valid_call_state(_Call, _Max) -> false.

valid_max_events(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< ?MAX_EVENTS.

valid_tool_name(Name) when is_binary(Name), byte_size(Name) > 0,
                           byte_size(Name) =< 64 ->
    re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match;
valid_tool_name(_) -> false.

valid_call_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< 256 -> valid_utf8(Value);
valid_call_id(_) -> false.

bounded_utf8(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                              byte_size(Value) =< Max -> valid_utf8(Value);
bounded_utf8(_Value, _Max) -> false.

valid_utf8(Value) when is_binary(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end;
valid_utf8(_) -> false.

bounded_list_length(Value, Max) ->
    bounded_list_length(Value, Max, 0).

bounded_list_length([], _Max, Count) -> {ok, Count};
bounded_list_length([_ | _], Max, Count) when Count >= Max -> too_many;
bounded_list_length([_ | Rest], Max, Count) ->
    bounded_list_length(Rest, Max, Count + 1);
bounded_list_length(_, _Max, _Count) -> improper.

maybe_metadata(_Key, Value, Value, Map) -> Map;
maybe_metadata(Key, Value, _Missing, Map) -> Map#{Key => Value}.
