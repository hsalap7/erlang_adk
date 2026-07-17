%% @doc Versioned provider-neutral events emitted by a Live session.
%%
%% These maps are process-local envelopes.  In particular an `audio' payload
%% contains a raw `adk_live_media' binary and is ephemeral by default.  A
%% persistence/UI boundary must explicitly project durable event kinds rather
%% than blindly serializing this value.
-module(adk_live_event).

-export([new/2, new/3, with_envelope/4, validate/1,
         kind/1, sequence/1, bytes/1, durability/1]).

-define(SCHEMA_VERSION, 1).
-define(MAX_JSON_PAYLOAD_BYTES, 1048576).

-type kind() ::
    ready | audio | content | input_transcription | output_transcription |
    usage | grounding | tool_call | tool_response | tool_cancelled |
    generation_complete | turn_complete | interrupted | go_away |
    resumption_status | reconnecting | terminal | error.
-type durability() :: durable | ephemeral.
-type event() :: #{
    schema_version := 1,
    kind := kind(),
    payload := term(),
    sequence := non_neg_integer(),
    turn_epoch := non_neg_integer(),
    generation_epoch := non_neg_integer(),
    timestamp := integer(),
    durability := durability()
}.

-export_type([kind/0, durability/0, event/0]).

-spec new(kind(), term()) -> {ok, event()} | {error, term()}.
new(Kind, Payload) ->
    new(Kind, Payload, #{}).

-spec new(kind(), term(), map()) -> {ok, event()} | {error, term()}.
new(Kind, Payload, Opts) when is_map(Opts) ->
    case normalize_payload(Kind, Payload) of
        {ok, CheckedPayload} ->
            Event = #{schema_version => ?SCHEMA_VERSION,
                      kind => Kind,
                      payload => CheckedPayload,
                      sequence => maps:get(sequence, Opts, 0),
                      turn_epoch => maps:get(turn_epoch, Opts, 0),
                      generation_epoch => maps:get(generation_epoch, Opts, 0),
                      timestamp => maps:get(
                                     timestamp, Opts,
                                     erlang:system_time(millisecond)),
                      durability => event_durability(Kind, CheckedPayload)},
            case validate(Event) of
                ok -> {ok, Event};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
new(_Kind, _Payload, _Opts) ->
    {error, invalid_live_event_options}.

-spec with_envelope(event(), pos_integer(), non_neg_integer(),
                    non_neg_integer()) -> {ok, event()} | {error, term()}.
with_envelope(Event, Sequence, TurnEpoch, GenerationEpoch)
  when is_integer(Sequence), Sequence > 0,
       is_integer(TurnEpoch), TurnEpoch >= 0,
       is_integer(GenerationEpoch), GenerationEpoch >= 0 ->
    Updated = Event#{sequence => Sequence,
                     turn_epoch => TurnEpoch,
                     generation_epoch => GenerationEpoch},
    case validate(Updated) of
        ok -> {ok, Updated};
        {error, _} = Error -> Error
    end;
with_envelope(_Event, _Sequence, _TurnEpoch, _GenerationEpoch) ->
    {error, invalid_live_event_envelope}.

-spec validate(term()) -> ok | {error, term()}.
validate(#{schema_version := ?SCHEMA_VERSION,
           kind := Kind,
           payload := Payload,
           sequence := Sequence,
           turn_epoch := TurnEpoch,
           generation_epoch := GenerationEpoch,
           timestamp := Timestamp,
           durability := Durability} = Event) ->
    Expected = [schema_version, kind, payload, sequence, turn_epoch,
                generation_epoch, timestamp, durability],
    case lists:sort(maps:keys(Event)) =:= lists:sort(Expected)
         andalso valid_kind(Kind)
         andalso is_integer(Sequence) andalso Sequence >= 0
         andalso is_integer(TurnEpoch) andalso TurnEpoch >= 0
         andalso is_integer(GenerationEpoch) andalso GenerationEpoch >= 0
         andalso is_integer(Timestamp)
         andalso Durability =:= event_durability(Kind, Payload) of
        false -> {error, invalid_live_event};
        true ->
            case normalize_payload(Kind, Payload) of
                {ok, Payload} -> ok;
                {ok, _Different} -> {error, noncanonical_live_event};
                {error, _} = Error -> Error
            end
    end;
validate(_Event) ->
    {error, invalid_live_event}.

-spec kind(event()) -> kind().
kind(#{kind := Kind}) -> Kind.

-spec sequence(event()) -> non_neg_integer().
sequence(#{sequence := Sequence}) -> Sequence.

-spec durability(event()) -> durability().
durability(#{durability := Durability}) -> Durability.

%% @doc Number of subscriber-window bytes charged by this event.
-spec bytes(event()) -> pos_integer().
bytes(#{kind := audio, payload := Media}) ->
    128 + adk_live_media:bytes(Media);
bytes(#{payload := Payload}) ->
    128 + json_payload_bytes(Payload).

normalize_payload(audio, Media) ->
    case adk_live_media:validate(Media) of
        ok ->
            case maps:get(kind, Media) of
                audio -> {ok, Media};
                _ -> {error, invalid_live_audio_event}
            end;
        {error, Reason} -> {error, {invalid_live_audio_event, Reason}}
    end;
normalize_payload(content, Payload) ->
    normalize_json_map(Payload);
normalize_payload(input_transcription, Payload) ->
    normalize_transcription(Payload);
normalize_payload(output_transcription, Payload) ->
    normalize_transcription(Payload);
normalize_payload(tool_call, Payload) ->
    normalize_tool_call(Payload);
normalize_payload(tool_response, Payload) ->
    normalize_tool_response(Payload);
normalize_payload(tool_cancelled, #{ids := Ids} = Payload) ->
    case exact_keys(Payload, [ids]) andalso valid_ids(Ids) of
        true -> {ok, Payload};
        false -> {error, invalid_live_tool_cancellation}
    end;
normalize_payload(Kind, Payload) ->
    case valid_map_payload_kind(Kind) of
        true -> normalize_json_map(Payload);
        false -> {error, invalid_live_event_kind}
    end.

normalize_transcription(#{text := Text, final := Final} = Payload)
  when is_binary(Text), is_boolean(Final) ->
    case exact_keys(Payload, [text, final]) andalso valid_utf8(Text) of
        true -> {ok, Payload};
        false -> {error, invalid_live_transcription}
    end;
normalize_transcription(_Payload) ->
    {error, invalid_live_transcription}.

normalize_tool_call(#{id := Id, name := Name, args := Args} = Payload)
  when is_binary(Id), is_binary(Name), is_map(Args) ->
    case exact_keys(Payload, [id, name, args])
         andalso valid_identifier(Id) andalso valid_identifier(Name) of
        true ->
            case normalize_json_map(Args) of
                {ok, CheckedArgs} -> {ok, Payload#{args => CheckedArgs}};
                {error, _} -> {error, invalid_live_tool_call}
            end;
        false -> {error, invalid_live_tool_call}
    end;
normalize_tool_call(_Payload) ->
    {error, invalid_live_tool_call}.

normalize_tool_response(#{id := Id, name := Name,
                          response := Response} = Payload)
  when is_binary(Id), is_binary(Name), is_map(Response) ->
    case exact_keys(Payload, [id, name, response])
         andalso valid_identifier(Id) andalso valid_identifier(Name) of
        true ->
            case normalize_json_map(Response) of
                {ok, Checked} -> {ok, Payload#{response => Checked}};
                {error, _} -> {error, invalid_live_tool_response}
            end;
        false -> {error, invalid_live_tool_response}
    end;
normalize_tool_response(_Payload) ->
    {error, invalid_live_tool_response}.

normalize_json_map(Payload) when is_map(Payload) ->
    case adk_json:normalize(Payload) of
        {ok, Normalized} when is_map(Normalized) ->
            case json_payload_bytes(Normalized) =< ?MAX_JSON_PAYLOAD_BYTES of
                true -> {ok, atomize_known_keys(Normalized, Payload)};
                false -> {error, live_event_payload_too_large}
            end;
        _ -> {error, invalid_live_event_payload}
    end;
normalize_json_map(_Payload) ->
    {error, invalid_live_event_payload}.

%% adk_json normalizes atom keys to binaries.  Internal event contracts use
%% atom keys, so preserve an already JSON-safe atom-keyed map after checking.
atomize_known_keys(_Normalized, Original) -> Original.

valid_map_payload_kind(Kind) ->
    lists:member(Kind,
                 [ready, usage, grounding, generation_complete,
                  turn_complete, interrupted, go_away, resumption_status,
                  reconnecting, terminal, error]).

valid_kind(Kind) ->
    Kind =:= audio orelse Kind =:= content orelse
    Kind =:= input_transcription orelse
    Kind =:= output_transcription orelse
    Kind =:= tool_call orelse Kind =:= tool_response orelse
    Kind =:= tool_cancelled orelse valid_map_payload_kind(Kind).

event_durability(audio, _Payload) -> ephemeral;
event_durability(ready, _Payload) -> ephemeral;
event_durability(reconnecting, _Payload) -> ephemeral;
event_durability(resumption_status, _Payload) -> ephemeral;
event_durability(input_transcription, #{final := false}) -> ephemeral;
event_durability(output_transcription, #{final := false}) -> ephemeral;
event_durability(_Kind, _Payload) -> durable.

valid_ids(Ids) when is_list(Ids), Ids =/= [], length(Ids) =< 128 ->
    lists:all(fun valid_identifier/1, Ids)
    andalso length(Ids) =:= length(lists:usort(Ids));
valid_ids(_Ids) -> false.

valid_identifier(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< 256
    andalso valid_utf8(Value);
valid_identifier(_Value) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

json_payload_bytes(Payload) ->
    try byte_size(jsx:encode(Payload))
    catch _:_ -> ?MAX_JSON_PAYLOAD_BYTES + 1
    end.

exact_keys(Map, Keys) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Keys).
