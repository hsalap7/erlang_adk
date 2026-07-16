-module(adk_json_test).
-include_lib("eunit/include/eunit.hrl").

normalizes_erlang_tool_values_test() ->
    Input = #{approved => true,
              approver => <<"operator@example.com">>,
              status => recovered,
              tuple => {one, 2},
              charlist => "hello",
              array => [#{item => false}]},
    {ok, Json} = adk_json:normalize(Input),
    ?assertEqual(true, maps:get(<<"approved">>, Json)),
    ?assertEqual(<<"recovered">>, maps:get(<<"status">>, Json)),
    ?assertEqual([<<"one">>, 2], maps:get(<<"tuple">>, Json)),
    ?assertEqual(<<"hello">>, maps:get(<<"charlist">>, Json)),
    ?assertEqual([#{<<"item">> => false}], maps:get(<<"array">>, Json)),
    ?assertEqual(Json, jsx:decode(jsx:encode(Json), [return_maps])).

rejects_internal_terms_without_echoing_them_test() ->
    Secret = <<"seeded-secret-in-unsupported-term">>,
    Unsupported = {self(), Secret},
    Formatted = adk_agent:format_result(Unsupported),
    Encoded = jsx:encode(Formatted),
    ?assertEqual(nomatch, binary:match(Encoded, Secret)),
    ?assertMatch(#{<<"serialization_error">> := _}, Formatted).

duplicate_normalized_keys_are_rejected_test() ->
    ?assertEqual(
       {error, {duplicate_map_key, [], <<"same">>}},
       adk_json:normalize(#{same => 1, <<"same">> => 2})).

formatted_resume_value_is_event_json_safe_test() ->
    Result = #{approved => true,
               approver => <<"operator@example.com">>},
    ToolResponse = #{<<"success">> => true,
                     <<"result">> => adk_agent:format_result(Result)},
    Event = adk_event:new(
              <<"tool">>,
              {tool_response, <<"request_human_approval">>,
               ToolResponse, undefined, <<"call-1">>}),
    {ok, Map} = adk_event:encode(Event),
    {ok, Event} = adk_event:decode(
                    jsx:decode(jsx:encode(Map), [return_maps])).
