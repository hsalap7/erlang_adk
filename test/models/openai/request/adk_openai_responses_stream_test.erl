-module(adk_openai_responses_stream_test).

-include_lib("eunit/include/eunit.hrl").

text_stream_assembles_and_completes_test() ->
    {ok, S0} = adk_openai_responses_stream:new(#{}),
    {ok, [], S1} = decode(event(1, <<"response.created">>), S0),
    {ok, [{text_delta, <<"Hel">>}], S2} = decode(
      text_delta(2, <<"Hel">>), S1),
    {ok, [{text_delta, <<"lo">>}], S3} = decode(
      text_delta(3, <<"lo">>), S2),
    {ok, [], S4} = decode(text_done(4, <<"Hello">>), S3),
    Response = completed_response([text_item(<<"Hello">>)]),
    {ok, [{completed, Result}], S5} = decode(
      #{<<"type">> => <<"response.completed">>,
        <<"sequence_number">> => 5,
        <<"response">> => Response}, S4),
    {ok, Result} = adk_openai_responses_stream:finish(S5),
    {ok, {ok, <<"Hello">>}, _} = adk_provider_result:decode(Result).

fragmented_function_call_stream_test() ->
    {ok, S0} = adk_openai_responses_stream:new(#{}),
    Added = #{<<"type">> => <<"response.output_item.added">>,
              <<"sequence_number">> => 1,
              <<"output_index">> => 0,
              <<"item">> => call_item(<<>>)},
    {ok, [{tool_call_started, 0, <<"weather">>, <<"call_1">>}], S1} =
        decode(Added, S0),
    {ok, [{tool_call_arguments_delta, 0, <<"{\"city\":" >>}], S2} =
        decode(call_delta(2, <<"{\"city\":" >>), S1),
    {ok, [{tool_call_arguments_delta, 0, <<"\"Paris\"}">>}], S3} =
        decode(call_delta(3, <<"\"Paris\"}">>), S2),
    Done = #{<<"type">> => <<"response.function_call_arguments.done">>,
             <<"sequence_number">> => 4,
             <<"output_index">> => 0,
             <<"item_id">> => <<"fc_1">>,
             <<"name">> => <<"weather">>,
             <<"arguments">> => <<"{\"city\":\"Paris\"}">>},
    ExpectedCall = {<<"weather">>, #{<<"city">> => <<"Paris">>},
                    undefined, <<"call_1">>},
    {ok, [{tool_call_completed, 0, ExpectedCall}], S4} = decode(Done, S3),
    ItemDone = #{<<"type">> => <<"response.output_item.done">>,
                 <<"sequence_number">> => 5,
                 <<"output_index">> => 0,
                 <<"item">> => call_item(
                                    <<"{\"city\":\"Paris\"}">>)},
    {ok, [], S5} = decode(ItemDone, S4),
    Response = completed_response(
                 [call_item(<<"{\"city\":\"Paris\"}">>)]),
    {ok, [{completed, Result}], S6} = decode(
      #{<<"type">> => <<"response.completed">>,
        <<"sequence_number">> => 6,
        <<"response">> => Response}, S5),
    {ok, Result} = adk_openai_responses_stream:finish(S6),
    {ok, {tool_calls, [ExpectedCall]}, _} =
        adk_provider_result:decode(Result).

finish_requires_terminal_event_test() ->
    {ok, State} = adk_openai_responses_stream:new(#{}),
    ?assertEqual({error, incomplete_openai_stream},
                 adk_openai_responses_stream:finish(State)).

text_done_mismatch_fails_without_echoing_content_test() ->
    {ok, S0} = adk_openai_responses_stream:new(#{}),
    {ok, _, S1} = decode(text_delta(1, <<"secret">>), S0),
    {error, openai_stream_text_mismatch, Failed} =
        decode(text_done(2, <<"different">>), S1),
    ?assertEqual({error, openai_stream_text_mismatch},
                 adk_openai_responses_stream:finish(Failed)).

function_done_mismatch_and_invalid_json_fail_test() ->
    {ok, S0} = adk_openai_responses_stream:new(#{}),
    {ok, _, S1} = decode(
      #{<<"type">> => <<"response.output_item.added">>,
        <<"sequence_number">> => 1,
        <<"output_index">> => 0,
        <<"item">> => call_item(<<>>)}, S0),
    {ok, _, S2} = decode(call_delta(2, <<"{}">>), S1),
    Mismatch = #{<<"type">> =>
                     <<"response.function_call_arguments.done">>,
                 <<"sequence_number">> => 3,
                 <<"output_index">> => 0,
                 <<"item_id">> => <<"fc_1">>,
                 <<"name">> => <<"weather">>,
                 <<"arguments">> => <<"{\"x\":1}">>},
    ?assertMatch(
       {error, openai_stream_call_mismatch, _},
       decode(Mismatch, S2)),

    {ok, T0} = adk_openai_responses_stream:new(#{}),
    {ok, _, T1} = decode(
      #{<<"type">> => <<"response.output_item.added">>,
        <<"sequence_number">> => 1,
        <<"output_index">> => 0,
        <<"item">> => call_item(<<>>)}, T0),
    {ok, _, T2} = decode(call_delta(2, <<"[]">>), T1),
    BadJson = Mismatch#{<<"arguments">> => <<"[]">>},
    ?assertMatch(
       {error, invalid_openai_function_arguments, _},
       decode(BadJson, T2)).

stream_bounds_and_sequence_are_enforced_test() ->
    {ok, E0} = adk_openai_responses_stream:new(
                 #{max_stream_events => 1}),
    {ok, [], E1} = decode(event(1, <<"future.event">>), E0),
    ?assertMatch(
       {error, {openai_stream_event_limit_exceeded, 1}, _},
       decode(event(2, <<"future.event">>), E1)),

    {ok, Q0} = adk_openai_responses_stream:new(#{}),
    {ok, [], Q1} = decode(event(2, <<"response.created">>), Q0),
    ?assertMatch(
       {error, non_monotonic_openai_stream_sequence, _},
       decode(event(2, <<"response.in_progress">>), Q1)),

    {ok, B0} = adk_openai_responses_stream:new(
                 #{content_limits => #{max_text_bytes => 3}}),
    ?assertMatch(
       {error, openai_stream_text_limit_exceeded, _},
       decode(text_delta(1, <<"four">>), B0)).

provider_failure_is_sanitized_test() ->
    {ok, S0} = adk_openai_responses_stream:new(#{}),
    FailedResponse = #{<<"status">> => <<"failed">>,
                       <<"error">> =>
                           #{<<"code">> => <<"server_error">>,
                             <<"message">> => <<"secret prompt">>}},
    Event = #{<<"type">> => <<"response.failed">>,
              <<"sequence_number">> => 1,
              <<"response">> => FailedResponse},
    {error, {openai_api_error, <<"server_error">>}, Failed} =
        decode(Event, S0),
    ?assertEqual(
       {error, {openai_api_error, <<"server_error">>}},
       adk_openai_responses_stream:finish(Failed)).

completion_is_verified_against_streamed_text_test() ->
    {ok, S0} = adk_openai_responses_stream:new(#{}),
    {ok, _, S1} = decode(text_delta(1, <<"one">>), S0),
    {ok, [], S2} = decode(text_done(2, <<"one">>), S1),
    Event = #{<<"type">> => <<"response.completed">>,
              <<"sequence_number">> => 3,
              <<"response">> => completed_response(
                                    [text_item(<<"two">>)])},
    ?assertMatch(
       {error, openai_stream_completion_mismatch, _},
       decode(Event, S2)).

tampered_stream_state_fails_closed_test() ->
    {ok, S0} = adk_openai_responses_stream:new(#{}),
    {ok, _, S1} = decode(text_delta(1, <<"a">>), S0),
    [{Key, _Part}] = maps:to_list(maps:get(text_parts, S1)),
    Corrupt = S1#{text_parts => #{Key => invalid}},
    ?assertMatch(
       {error, invalid_openai_stream_state, _},
       decode(text_delta(2, <<"b">>), Corrupt)).

decode(Event, State) ->
    adk_openai_responses_stream:decode_event(Event, State).

event(Sequence, Type) ->
    #{<<"type">> => Type, <<"sequence_number">> => Sequence}.

text_delta(Sequence, Delta) ->
    #{<<"type">> => <<"response.output_text.delta">>,
      <<"sequence_number">> => Sequence,
      <<"item_id">> => <<"msg_1">>,
      <<"output_index">> => 0,
      <<"content_index">> => 0,
      <<"delta">> => Delta}.

text_done(Sequence, Text) ->
    #{<<"type">> => <<"response.output_text.done">>,
      <<"sequence_number">> => Sequence,
      <<"item_id">> => <<"msg_1">>,
      <<"output_index">> => 0,
      <<"content_index">> => 0,
      <<"text">> => Text}.

call_delta(Sequence, Delta) ->
    #{<<"type">> => <<"response.function_call_arguments.delta">>,
      <<"sequence_number">> => Sequence,
      <<"item_id">> => <<"fc_1">>,
      <<"output_index">> => 0,
      <<"delta">> => Delta}.

call_item(Arguments) ->
    #{<<"type">> => <<"function_call">>,
      <<"id">> => <<"fc_1">>,
      <<"call_id">> => <<"call_1">>,
      <<"name">> => <<"weather">>,
      <<"arguments">> => Arguments}.

completed_response(Output) ->
    #{<<"id">> => <<"resp_1">>,
      <<"object">> => <<"response">>,
      <<"status">> => <<"completed">>,
      <<"error">> => null,
      <<"model">> => <<"gpt-test-2026-01-01">>,
      <<"output">> => Output,
      <<"usage">> => #{<<"input_tokens">> => 2,
                         <<"output_tokens">> => 1,
                         <<"total_tokens">> => 3}}.

text_item(Text) ->
    #{<<"type">> => <<"message">>,
      <<"id">> => <<"msg_1">>,
      <<"role">> => <<"assistant">>,
      <<"status">> => <<"completed">>,
      <<"content">> =>
          [#{<<"type">> => <<"output_text">>,
             <<"text">> => Text,
             <<"annotations">> => []}]}.
