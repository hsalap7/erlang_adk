-module(adk_context_policy_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

context_policy_test_() ->
    [fun budget_overflow_and_latest_truncation/0,
     fun bounded_compression_success/0,
     fun compressor_timeout_is_killed/0,
     fun compressor_crash_is_contained/0,
     fun secret_keys_are_removed_before_encoding/0,
     fun deterministic_secret_independent_cache_keys/0,
     fun include_exclude_filters_are_deterministic/0].

budget_overflow_and_latest_truncation() ->
    Older = adk_event:new(<<"user">>, <<"older">>),
    Newer = adk_event:new(<<"agent">>, <<"newer">>),
    {ok, NewerOnly} = adk_context_policy:build([Newer], #{}),
    NewerBytes = maps:get(bytes, NewerOnly),
    NewerTokens = maps:get(estimated_tokens, NewerOnly),
    ?assert(NewerTokens > 1),
    ?assertMatch(
       {error, {context_budget_exceeded, _}},
       adk_context_policy:build(
         [Older, Newer], #{max_bytes => NewerBytes})),
    ?assertMatch(
       {error, {context_budget_exceeded, _}},
       adk_context_policy:build(
         [Newer], #{max_tokens => NewerTokens - 1})),
    {ok, Truncated} = adk_context_policy:build(
                        [Older, Newer],
                        #{max_bytes => NewerBytes,
                          overflow => truncate}),
    ?assertEqual(1, maps:get(output_events, Truncated)),
    [Only] = maps:get(events, Truncated),
    ?assertEqual(Newer#adk_event.id, maps:get(<<"id">>, Only)),
    ?assertEqual(1, maps:get(dropped_events, Truncated)).

bounded_compression_success() ->
    First = adk_event:new(<<"user">>, <<"first context item">>),
    Last = adk_event:new(<<"agent">>, <<"last context item">>),
    {ok, LastOnly} = adk_context_policy:build([Last], #{}),
    Budget = maps:get(bytes, LastOnly),
    {ok, Context} = adk_context_policy:build(
                      [First, Last],
                      #{max_bytes => Budget,
                        overflow => compress,
                        compressor =>
                            {adk_context_test_compressor, #{mode => last}},
                        compressor_cache_identity => <<"last-v1">>}),
    ?assertEqual(true, maps:get(compressed, Context)),
    ?assertEqual(1, maps:get(output_events, Context)),
    [Only] = maps:get(events, Context),
    ?assertEqual(Last#adk_event.id, maps:get(<<"id">>, Only)),
    ?assert(maps:get(bytes, Context) =< Budget).

compressor_timeout_is_killed() ->
    Event = adk_event:new(<<"user">>, binary:copy(<<"x">>, 200)),
    Result = adk_context_policy:build(
               [Event],
               #{max_bytes => 1,
                 overflow => compress,
                 compressor =>
                     {adk_context_test_compressor,
                      #{mode => timeout, notify => self()}},
                 compressor_timeout => 100}),
    ?assertEqual({error, compressor_timeout}, Result),
    Pid = receive
        {compressor_started, WorkerPid} -> WorkerPid
    after 1000 ->
        error(compressor_did_not_start)
    end,
    ?assertNot(is_process_alive(Pid)).

compressor_crash_is_contained() ->
    Event = adk_event:new(<<"user">>, binary:copy(<<"x">>, 200)),
    ?assertEqual(
       {error, {compressor_crashed, error}},
       adk_context_policy:build(
         [Event],
         #{max_bytes => 1,
           overflow => compress,
           compressor =>
               {adk_context_test_compressor, #{mode => crash}}})).

secret_keys_are_removed_before_encoding() ->
    Event0 = adk_event:new(
               <<"tool">>,
               {tool_response, <<"oauth">>,
                #{<<"access_token">> => self(),
                  <<"safe">> => #{<<"value">> => 7,
                                  <<"client-secret">> => <<"hidden">>}}},
               #{actions =>
                     #{access_token => self(),
                       <<"trace">> =>
                           #{<<"authorization">> => <<"Bearer hidden">>,
                             <<"ok">> => true}}}),
    {ok, Context} = adk_context_policy:build([Event0], #{}),
    [Event] = maps:get(events, Context),
    ?assertEqual(false, contains_sensitive_key(Event)),
    %% The final model-context boundary is directly encodable JSON.
    ?assert(is_binary(jsx:encode(Event))),
    Content = maps:get(<<"content">>, Event),
    Result = maps:get(<<"result">>, Content),
    ?assertEqual(#{<<"safe">> => #{<<"value">> => 7}}, Result).

deterministic_secret_independent_cache_keys() ->
    Base = adk_event:new(<<"agent">>, <<"cache me">>),
    EventA = Base#adk_event{
               actions = #{<<"access_token">> => <<"secret-a">>,
                           <<"safe">> => 1}},
    EventB = Base#adk_event{
               actions = #{<<"safe">> => 1,
                           <<"access-token">> => <<"secret-b">>}},
    EventC = Base#adk_event{
               actions = #{<<"safe">> => 2,
                           <<"access_token">> => <<"secret-a">>}},
    {ok, A1} = adk_context_policy:build(
                 [EventA], #{max_tokens => 1000, max_bytes => 10000}),
    {ok, A2} = adk_context_policy:build(
                 [EventA], #{max_bytes => 10000, max_tokens => 1000}),
    {ok, B} = adk_context_policy:build(
                [EventB], #{max_tokens => 1000, max_bytes => 10000}),
    {ok, C} = adk_context_policy:build(
                [EventC], #{max_tokens => 1000, max_bytes => 10000}),
    KeyA1 = maps:get(key, maps:get(cache, A1)),
    ?assertEqual(KeyA1, maps:get(key, maps:get(cache, A2))),
    ?assertEqual(KeyA1, maps:get(key, maps:get(cache, B))),
    ?assertNotEqual(KeyA1, maps:get(key, maps:get(cache, C))).

include_exclude_filters_are_deterministic() ->
    User = adk_event:new(<<"user">>, <<"question">>),
    Agent = adk_event:new(<<"agent">>, <<"answer">>,
                          #{is_final => true}),
    Tool = adk_event:new(<<"tool">>,
                         {tool_response, <<"lookup">>, #{<<"v">> => 1}}),
    Opts = #{include_authors => [<<"agent">>, <<"tool">>],
             exclude_content_types => [<<"tool_response">>]},
    {ok, Context} = adk_context_policy:build([User, Agent, Tool], Opts),
    [Only] = maps:get(events, Context),
    ?assertEqual(Agent#adk_event.id, maps:get(<<"id">>, Only)),
    {ok, Empty} = adk_context_policy:build(
                    [User, Agent, Tool], #{exclude_authors => all}),
    ?assertEqual([], maps:get(events, Empty)).

contains_sensitive_key(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          adk_context_guard:sensitive_key(Key) orelse
          contains_sensitive_key(Value)
      end,
      maps:to_list(Map));
contains_sensitive_key(List) when is_list(List) ->
    lists:any(fun contains_sensitive_key/1, List);
contains_sensitive_key(_) -> false.
