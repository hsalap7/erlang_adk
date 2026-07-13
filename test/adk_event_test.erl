-module(adk_event_test).
-include_lib("eunit/include/eunit.hrl").

-include("../include/adk_event.hrl").

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
