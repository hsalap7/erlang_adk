-module(adk_event_test).
-include_lib("eunit/include/eunit.hrl").

-include("adk_event.hrl").

new_event_generates_id_test() ->
    Event = adk_event:new(<<"user">>, <<"Hello">>),
    ?assertMatch(#adk_event{}, Event),
    ?assert(is_binary(Event#adk_event.id)),
    ?assert(is_binary(Event#adk_event.invocation_id)),
    ?assertEqual(<<"user">>, Event#adk_event.author),
    ?assertEqual(<<"Hello">>, Event#adk_event.content).

new_event_sets_timestamp_test() ->
    Before = erlang:system_time(millisecond),
    Event = adk_event:new(<<"agent">>, <<"Hi">>),
    After = erlang:system_time(millisecond),
    ?assert(Event#adk_event.timestamp >= Before),
    ?assert(Event#adk_event.timestamp =< After).

with_state_delta_attaches_delta_test() ->
    Event1 = adk_event:new(<<"agent">>, <<"Response">>),
    Delta = #{<<"key">> => <<"val">>},
    Event2 = adk_event:with_state_delta(Event1, Delta),
    Actions = Event2#adk_event.actions,
    ?assertEqual(Delta, maps:get(<<"state_delta">>, Actions)).

is_final_response_true_test() ->
    Event = adk_event:new(<<"agent">>, <<"Final">>, #{is_final => true}),
    ?assert(adk_event:is_final_response(Event)).

is_final_response_false_test() ->
    Event = adk_event:new(<<"agent">>, <<"Partial">>, #{partial => true}),
    ?assertNot(adk_event:is_final_response(Event)).

to_map_roundtrip_test() ->
    Event1 = adk_event:new(<<"user">>, <<"Content">>, #{is_final => true, actions => #{<<"k">> => <<"v">>}}),
    Map = adk_event:to_map(Event1),
    ?assertEqual(adk_event:codec_version(),
                 maps:get(<<"schema_version">>, Map)),
    Event2 = adk_event:from_map(Map),
    ?assertEqual(Event1, Event2).

unicode_charlist_serialization_test() ->
    Text = "café \x{2615}",
    Event = adk_event:new(<<"agent">>, Text),
    Map = adk_event:to_map(Event),
    #{<<"text">> := Encoded} = maps:get(<<"content">>, Map),
    ?assertEqual(unicode:characters_to_binary(Text), Encoded).

runner_pause_is_not_model_history_test() ->
    User = adk_event:new(<<"user">>, <<"do it">>),
    Pause = adk_event:new(<<"runner">>, <<"approve it">>,
                          #{actions => #{<<"pause">> => #{}}}),
    [OnlyMessage] = adk_memory:get_history(
                      adk_memory:from_events([User, Pause])),
    ?assertEqual(user, maps:get(role, OnlyMessage)),
    ?assertEqual(<<"do it">>, maps:get(content, OnlyMessage)).

multiple_gemini_tool_calls_json_roundtrip_test() ->
    Calls = [
        {<<"first_tool">>,
         #{<<"nested">> => [1, true, null]},
         <<"thought-signature-1">>, <<"call-1">>},
        {<<"second_tool">>,
         #{<<"query">> => <<"weather">>},
         undefined, <<"call-2">>}
    ],
    Actions = #{
        <<"trace">> => #{
            <<"sampled">> => true,
            <<"attributes">> => [<<"one">>, <<"two">>]
        }
    },
    Event = adk_event:new(
              <<"GeminiAgent">>, {tool_calls, Calls},
              #{actions => Actions, is_final => false}),

    {ok, Encoded} = adk_event:encode(Event),
    #{<<"content">> := #{<<"calls">> := EncodedCalls}} = Encoded,
    ?assertEqual([
        #{<<"name">> => <<"first_tool">>,
          <<"args">> => #{<<"nested">> => [1, true, null]},
          <<"thought_signature">> => <<"thought-signature-1">>,
          <<"call_id">> => <<"call-1">>},
        #{<<"name">> => <<"second_tool">>,
          <<"args">> => #{<<"query">> => <<"weather">>},
          <<"thought_signature">> => null,
          <<"call_id">> => <<"call-2">>}
    ], EncodedCalls),

    %% This is the boundary that failed when the calls were left as tuples.
    Json = jsx:encode(Encoded),
    JsonMap = jsx:decode(Json, [return_maps]),
    ?assertEqual({ok, Event}, adk_event:decode(JsonMap)).

tool_call_tuple_arities_survive_json_test() ->
    Calls = [
        {<<"two_fields">>, #{<<"a">> => 1}},
        {<<"three_fields">>, #{<<"b">> => 2}, undefined},
        {<<"four_fields">>, #{<<"c">> => 3}, <<"sig">>, <<"id">>}
    ],
    Event = adk_event:new(<<"agent">>, {tool_calls, Calls}),
    {ok, Encoded} = adk_event:encode(Event),
    CallsMap = maps:get(<<"calls">>, maps:get(<<"content">>, Encoded)),
    [Two, Three, Four] = CallsMap,
    ?assertNot(maps:is_key(<<"thought_signature">>, Two)),
    ?assertNot(maps:is_key(<<"call_id">>, Two)),
    ?assertEqual(null, maps:get(<<"thought_signature">>, Three)),
    ?assertNot(maps:is_key(<<"call_id">>, Three)),
    ?assertEqual(<<"sig">>, maps:get(<<"thought_signature">>, Four)),
    ?assertEqual(<<"id">>, maps:get(<<"call_id">>, Four)),
    JsonMap = jsx:decode(jsx:encode(Encoded), [return_maps]),
    {ok, Decoded} = adk_event:decode(JsonMap),
    ?assertEqual(Event, Decoded).

tool_response_json_roundtrip_test() ->
    Content = {tool_response, <<"get_weather">>,
               #{<<"forecast">> => <<"sunny">>,
                 <<"temperatures">> => [21.5, 22],
                 <<"cached">> => false},
               undefined, <<"weather-call-1">>},
    Event = adk_event:new(<<"tool">>, Content),
    {ok, Encoded} = adk_event:encode(Event),
    EncodedContent = maps:get(<<"content">>, Encoded),
    ?assertEqual(null, maps:get(<<"signature">>, EncodedContent)),
    ?assertEqual(<<"weather-call-1">>,
                 maps:get(<<"call_id">>, EncodedContent)),
    JsonMap = jsx:decode(jsx:encode(Encoded), [return_maps]),
    ?assertEqual({ok, Event}, adk_event:decode(JsonMap)).

legacy_tool_call_map_is_still_readable_test() ->
    LegacyCalls = [
        {<<"legacy_three">>, #{<<"x">> => 1}, undefined},
        {<<"legacy_four">>, #{<<"y">> => 2}, <<"sig">>, <<"id">>}
    ],
    Legacy = legacy_event_map(
               #{<<"type">> => <<"tool_calls">>,
                 <<"calls">> => LegacyCalls}),
    {ok, Event} = adk_event:decode(Legacy),
    ?assertEqual({tool_calls, LegacyCalls}, Event#adk_event.content),
    ?assertEqual(Event, adk_event:from_map(Legacy)).

legacy_unknown_content_is_still_readable_test() ->
    Legacy = legacy_event_map(
               #{<<"type">> => <<"unknown">>,
                 <<"data">> => <<"old rendered term">>}),
    {ok, Event} = adk_event:decode(Legacy),
    ?assertEqual(<<"old rendered term">>, Event#adk_event.content).

canonical_call_map_aliases_are_readable_test() ->
    Base = legacy_event_map(
             #{<<"type">> => <<"tool_calls">>,
               <<"calls">> => [
                   #{<<"name">> => <<"aliased">>,
                     <<"arguments">> => #{<<"v">> => 1},
                     <<"signature">> => <<"sig">>,
                     <<"id">> => <<"call">>}
               ]}),
    Canonical = Base#{<<"schema_version">> => adk_event:codec_version()},
    {ok, Event} = adk_event:decode(Canonical),
    ?assertEqual(
       {tool_calls, [{<<"aliased">>, #{<<"v">> => 1},
                      <<"sig">>, <<"call">>}]},
       Event#adk_event.content).

actions_are_checked_recursively_test() ->
    Event = adk_event:new(
              <<"agent">>, <<"text">>,
              #{actions => #{
                  <<"safe">> => [1, #{<<"ok">> => true}],
                  <<"unsafe">> => [<<"before">>, {internal, tuple}]
              }}),
    ?assertEqual(
       {error, {invalid_json_value,
                [<<"actions">>, <<"unsafe">>, 1],
                {unsupported_type, tuple}}},
       adk_event:encode(Event)).

non_binary_action_key_is_rejected_test() ->
    Event = adk_event:new(<<"agent">>, <<"text">>,
                          #{actions => #{atom_key => <<"value">>}}),
    ?assertEqual(
       {error, {invalid_json_value, [<<"actions">>],
                {invalid_object_key, atom}}},
       adk_event:encode(Event)).

invalid_utf8_is_rejected_before_jsx_test() ->
    InvalidUtf8 = <<16#ff>>,
    Event = adk_event:new(
              <<"agent">>, <<"text">>,
              #{actions => #{<<"payload">> => InvalidUtf8}}),
    ?assertEqual(
       {error, {invalid_json_value,
                [<<"actions">>, <<"payload">>], invalid_utf8}},
       adk_event:encode(Event)).

invalid_charlist_returns_typed_error_test() ->
    Event = adk_event:new(<<"agent">>, [self()]),
    ?assertEqual(
       {error, {invalid_content, [<<"content">>], invalid_unicode}},
       adk_event:encode(Event)).

canonical_decode_checks_unknown_content_fields_test() ->
    {ok, Encoded0} = adk_event:encode(
                       adk_event:new(<<"agent">>, <<"text">>)),
    Content0 = maps:get(<<"content">>, Encoded0),
    Encoded = Encoded0#{
        <<"content">> => Content0#{<<"unsafe_extension">> => {'not', json}}
    },
    ?assertEqual(
       {error, {invalid_json_value,
                [<<"content">>, <<"unsafe_extension">>],
                {unsupported_type, tuple}}},
       adk_event:decode(Encoded)).

unsupported_content_is_not_stringified_test() ->
    Event = adk_event:new(<<"agent">>, self()),
    Expected = {invalid_content, [<<"content">>],
                {unsupported_type, pid}},
    ?assertEqual({error, Expected}, adk_event:encode(Event)),
    ?assertError({adk_event_codec, Expected}, adk_event:to_map(Event)).

unsupported_schema_version_is_rejected_test() ->
    {ok, Encoded} = adk_event:encode(
                      adk_event:new(<<"agent">>, <<"text">>)),
    ?assertEqual(
       {error, {unsupported_schema_version, 99}},
       adk_event:decode(Encoded#{<<"schema_version">> => 99})).

malformed_event_returns_typed_error_test() ->
    ?assertEqual(
       {error, {invalid_event, [<<"id">>], missing_required_field}},
       adk_event:decode(#{<<"schema_version">> => 1})).

legacy_event_map(Content) ->
    #{
        <<"id">> => <<"legacy-event-id">>,
        <<"invocation_id">> => <<"legacy-invocation-id">>,
        <<"author">> => <<"legacy-agent">>,
        <<"content">> => Content,
        <<"actions">> => #{},
        <<"timestamp">> => 123456789,
        <<"partial">> => false,
        <<"is_final">> => false
    }.
