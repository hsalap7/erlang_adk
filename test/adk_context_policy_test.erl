-module(adk_context_policy_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

context_policy_test_() ->
    [fun budget_overflow_and_latest_truncation/0,
     fun bounded_compression_success/0,
     fun compressor_timeout_is_killed/0,
     fun compressor_is_killed_when_owner_dies/0,
     fun compressor_crash_is_contained/0,
     fun unknown_options_and_compressors_are_rejected_eagerly/0,
     fun input_event_count_is_bounded/0,
     fun complete_tool_exchanges_are_atomic/0,
     fun canonical_model_content_is_filterable_and_atomic/0,
     fun malformed_compressor_output_is_rejected/0,
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

compressor_is_killed_when_owner_dies() ->
    Parent = self(),
    Event = adk_event:new(<<"user">>, binary:copy(<<"x">>, 200)),
    Owner = spawn(
              fun() ->
                  Result = adk_context_policy:build(
                             [Event],
                             #{max_bytes => 1,
                               overflow => compress,
                               compressor =>
                                   {adk_context_test_compressor,
                                    #{mode => timeout, notify => Parent}},
                               compressor_timeout => 5000}),
                  Parent ! {unexpected_owner_result, Result}
              end),
    OwnerMonitor = erlang:monitor(process, Owner),
    Executor = receive
        {compressor_started, ExecutorPid} -> ExecutorPid
    after 1000 ->
        error(compressor_did_not_start)
    end,
    ExecutorMonitor = erlang:monitor(process, Executor),
    exit(Owner, kill),
    receive
        {'DOWN', OwnerMonitor, process, Owner, killed} -> ok
    after 1000 -> error(owner_did_not_stop)
    end,
    receive
        {'DOWN', ExecutorMonitor, process, Executor, _} -> ok
    after 1000 -> error(compressor_outlived_owner)
    end,
    receive
        {unexpected_owner_result, Result} ->
            error({owner_returned_after_kill, Result})
    after 0 -> ok
    end.

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

unknown_options_and_compressors_are_rejected_eagerly() ->
    ?assertEqual(
       {error, {invalid_context_options,
                {unknown_keys, [max_btyes]}}},
       adk_context_policy:build(
         not_an_event_list, #{max_btyes => 100})),
    ?assertEqual(
       {error, {invalid_filter, {unknown_keys, [authros]}}},
       adk_event_filter:normalize(#{authros => [<<"user">>]})),
    ?assertEqual(
       {error, {invalid_compressor, unavailable}},
       adk_context_policy:build(
         not_an_event_list,
         #{compressor => adk_missing_context_compressor})),
    ?assertEqual(
       {error, {invalid_compressor, missing_callback}},
       adk_context_policy:build(
         not_an_event_list,
         #{compressor => adk_context_compressor})).

input_event_count_is_bounded() ->
    One = adk_event:new(<<"user">>, <<"one">>),
    Two = adk_event:new(<<"agent">>, <<"two">>),
    ?assertEqual(
       {error, context_input_too_many_events},
       adk_context_policy:build(
         [One, Two], #{max_input_events => 1})),
    ?assertMatch(
       {ok, #{input_events := 2}},
       adk_context_policy:build(
         [One, Two], #{max_input_events => 2})).

complete_tool_exchanges_are_atomic() ->
    {Call, Response} = tool_exchange(10, 11),
    {ok, Complete} = adk_context_policy:build([Call, Response], #{}),
    ?assertEqual(2, maps:get(output_events, Complete)),
    {ok, Filtered} = adk_context_policy:build(
                       [Call, Response],
                       #{include_content_types => [<<"tool_response">>]}),
    ?assertEqual([], maps:get(events, Filtered)),

    Current = (adk_event:new(<<"user">>, <<"current">>))#adk_event{
                timestamp = 12},
    {ok, ResponseOnly} = adk_context_policy:build([Response], #{}),
    {ok, CurrentOnly} = adk_context_policy:build([Current], #{}),
    Boundary = maps:get(bytes, ResponseOnly) + maps:get(bytes, CurrentOnly),
    {ok, Truncated} = adk_context_policy:build(
                        [Call, Response, Current],
                        #{max_bytes => Boundary, overflow => truncate}),
    [Only] = maps:get(events, Truncated),
    ?assertEqual(Current#adk_event.id, maps:get(<<"id">>, Only)),
    ?assertEqual(2, maps:get(dropped_events, Truncated)).

canonical_model_content_is_filterable_and_atomic() ->
    {ok, Text} = adk_content:text(<<"inspect">>),
    {ok, Image} = adk_content:inline_data(<<"image/png">>, <<1, 2, 3>>),
    {ok, Multimodal} = adk_content:new([Text, Image]),
    MultiEvent = (adk_event:new(<<"user">>, Multimodal))#adk_event{
                   timestamp = 20},
    {ok, MultiContext} = adk_context_policy:build(
                           [MultiEvent],
                           #{include_content_types => [<<"model_content">>]}),
    ?assertEqual(1, maps:get(output_events, MultiContext)),

    {ok, CallPart} = adk_content:function_call(
                       <<"lookup">>, #{}, #{id => <<"model-call-1">>}),
    {ok, ResponsePart} = adk_content:function_response(
                           <<"lookup">>, #{<<"ok">> => true},
                           #{id => <<"model-call-1">>}),
    {ok, CallContent} = adk_content:new([CallPart]),
    {ok, ResponseContent} = adk_content:new([ResponsePart]),
    InvocationId = <<"model-invocation">>,
    CallEvent = (adk_event:new(
                   <<"agent">>, CallContent,
                   #{invocation_id => InvocationId}))#adk_event{timestamp = 21},
    ResponseEvent = (adk_event:new(
                       <<"tool">>, ResponseContent,
                       #{invocation_id => InvocationId}))#adk_event{
                      timestamp = 22},
    ?assertEqual(1, length(adk_event_filter:complete_exchange_groups(
                             begin
                                 {ok, Built} = adk_context_policy:build(
                                                   [CallEvent, ResponseEvent],
                                                   #{}),
                                 maps:get(events, Built)
                             end))),
    {ok, AtomicFilter} = adk_context_policy:build(
                           [CallEvent, ResponseEvent],
                           #{include_authors => [<<"agent">>]}),
    ?assertEqual([], maps:get(events, AtomicFilter)).

malformed_compressor_output_is_rejected() ->
    First = (adk_event:new(<<"user">>, <<"first">>))#adk_event{
              timestamp = 30},
    Current = (adk_event:new(<<"user">>, <<"current">>))#adk_event{
                timestamp = 31},
    Base = #{max_bytes => 1,
             overflow => compress,
             compressor => adk_context_test_compressor},
    ?assertEqual(
       {error, {invalid_compressor_output, duplicate_event_id}},
       adk_context_policy:build(
         [First, Current],
         Base#{compressor =>
                   {adk_context_test_compressor,
                    #{mode => duplicate_current}}})),
    ?assertEqual(
       {error, {invalid_compressor_output, non_chronological_events}},
       adk_context_policy:build(
         [First, Current],
         Base#{compressor =>
                   {adk_context_test_compressor, #{mode => reverse}}})),
    ?assertEqual(
       {error, {invalid_compressor_output, current_event_missing}},
       adk_context_policy:build(
         [First, Current],
         Base#{compressor =>
                   {adk_context_test_compressor, #{mode => drop_current}}})),
    ?assertEqual(
       {error, {invalid_compressor_output, retained_event_modified}},
       adk_context_policy:build(
         [First, Current],
         Base#{compressor =>
                   {adk_context_test_compressor, #{mode => mutate_current}}})),
    {Call, Response} = tool_exchange(28, 29),
    ?assertEqual(
       {error, {invalid_compressor_output, partial_tool_exchange}},
       adk_context_policy:build(
         [Call, Response, Current],
         Base#{compressor =>
                   {adk_context_test_compressor,
                    #{mode => partial_exchange}}})).

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
    Fingerprint = maps:get(context_fingerprint, A1),
    ?assertEqual(KeyA1, maps:get(value, Fingerprint)),
    ?assertEqual(context_fingerprint,
                 maps:get(semantics, maps:get(cache, A1))),
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

tool_exchange(CallTimestamp, ResponseTimestamp) ->
    InvocationId = <<"tool-invocation">>,
    CallId = <<"tool-call-1">>,
    Call = (adk_event:new(
              <<"agent">>,
              {tool_calls,
               [{<<"lookup">>, #{<<"q">> => <<"x">>}, undefined, CallId}]},
              #{invocation_id => InvocationId}))#adk_event{
             timestamp = CallTimestamp},
    Response = (adk_event:new(
                  <<"tool">>,
                  {tool_response, <<"lookup">>,
                   #{<<"answer">> => 1}, undefined, CallId},
                  #{invocation_id => InvocationId}))#adk_event{
                 timestamp = ResponseTimestamp},
    {Call, Response}.

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
