-module(adk_failure_contract_test).

-include_lib("eunit/include/eunit.hrl").

exception_class_and_safe_tag_contract_test() ->
    Classes = [{error, error}, {exit, exit}, {throw, throw},
               {unexpected, exception}],
    [?assertMatch(
        {adk_failure,
         #{component := component, operation := operation,
           class := Expected, reason := reason}},
        adk_failure:exception(component, operation, Class, reason))
     || {Class, Expected} <- Classes],
    ?assertMatch(
       {adk_failure,
        #{component := unknown_component,
          operation := unknown_operation}},
       adk_failure:external(<<"component">>, 42, failure)).

reason_classification_contract_test() ->
    Values =
        [{atom_reason, atom_reason},
         {<<"body">>, binary_failure},
         {[value], list_failure},
         {#{value => true}, map_failure},
         {{tag, value}, tag},
         {{tag, one, two}, tag},
         {{tag, one, two, three}, tag},
         {{tag, one, two, three, four}, tag},
         {{one, two, three, four, five, six}, tuple_failure},
         {7, integer_failure},
         {1.5, float_failure},
         {self(), process_failure},
         {make_ref(), reference_failure},
         {fun() -> ok end, function_failure},
         {<<1:1>>, unknown_failure}],
    [begin
         {adk_failure, Metadata} =
             adk_failure:external(component, operation, Value),
         ?assertEqual(Expected, maps:get(reason, Metadata))
     end || {Value, Expected} <- Values],
    Existing = {adk_failure, #{reason => retained_reason}},
    {adk_failure, ExistingMetadata} =
        adk_failure:external(component, operation, Existing),
    ?assertEqual(retained_reason, maps:get(reason, ExistingMetadata)),
    {adk_failure, MissingMetadata} =
        adk_failure:external(
          component, operation, {adk_failure, #{class => external}}),
    ?assertEqual(failure, maps:get(reason, MissingMetadata)),
    Port = open_port({spawn_driver, "ram_file_drv"}, [binary]),
    try
        {adk_failure, PortMetadata} =
            adk_failure:external(component, operation, Port),
        ?assertEqual(port_failure, maps:get(reason, PortMetadata))
    after
        catch port_close(Port)
    end.

callback_and_sanitize_contract_test() ->
    Existing = adk_failure:external(component, operation, existing),
    ?assertEqual(Existing,
                 adk_failure:sanitize(other, other, Existing)),
    ?assertEqual(Existing,
                 adk_failure:callback_value(other, other, Existing)),
    ?assertMatch(
       {error, {adk_failure, #{reason := failed}}},
       adk_failure:callback_value(component, operation, {error, failed})),
    ?assertMatch(
       {failed, {adk_failure, #{reason := stopped}}},
       adk_failure:callback_value(component, operation, {failed, stopped})),
    ?assertMatch(
       {'EXIT', {adk_failure, #{reason := crashed}}},
       adk_failure:callback_value(component, operation, {'EXIT', crashed})),
    ?assertMatch(
       {adk_failure, #{reason := raw_failure}},
       adk_failure:callback_value(component, operation, raw_failure)),
    ?assert(adk_failure:is_failure(Existing)),
    ?assertNot(adk_failure:is_failure({adk_failure, invalid})),
    ?assertNot(adk_failure:is_failure(other)).

status_discovery_contract_test() ->
    StatusReasons =
        [{http_error, 503, private},
         {http_status, 429},
         {http_failure, 502, private, more},
         {status, 418, private, more, fields},
         #{status_code => 401},
         #{<<"http_status">> => 504},
         #{wrapper => [ignored, #{<<"status_code">> => 409}]},
         [ignored, {status, 422}]],
    [assert_status(Reason, Expected)
     || Reason <- StatusReasons,
        Expected <- [expected_status(Reason)]],
    assert_no_status({http_error, 99}),
    assert_no_status(#{status => 600}),
    assert_no_status(lists:duplicate(32, ignored) ++ [{status, 429}]),
    assert_no_status([ignored | improper]),
    TooDeep = #{a => #{b => #{c => #{d => #{e =>
                  #{status => 503}}}}}},
    assert_no_status(TooDeep).

correlation_fingerprints_are_allowlisted_and_bounded_test() ->
    Reason =
        #{invocation_id => <<"invocation">>,
          <<"run_id">> => run_atom,
          call_id => 42,
          <<"task_ref">> => <<"task">>,
          nested => #{request_id => <<"request">>,
                      <<"correlation_id">> => <<"correlation">>},
          empty => <<>>,
          unrelated => <<"must-not-survive">>},
    {adk_failure, Metadata} =
        adk_failure:external(component, operation, Reason),
    Correlation = maps:get(correlation, Metadata),
    ?assertEqual(
       lists:sort([invocation_id, run_id, call_id, task_ref,
                   request_id, correlation_id]),
       lists:sort(maps:keys(Correlation))),
    [?assertEqual(24, byte_size(Value))
     || Value <- maps:values(Correlation)],
    ?assertNot(lists:member(<<"invocation">>, maps:values(Correlation))),

    Oversized = binary:copy(<<"x">>, 513),
    {adk_failure, InvalidMetadata} =
        adk_failure:external(
          component, operation,
          #{request_id => <<>>, run_id => Oversized,
            call_id => make_ref()}),
    ?assertNot(maps:is_key(correlation, InvalidMetadata)),
    {adk_failure, ImproperMetadata} =
        adk_failure:external(
          component, operation, [#{request_id => <<"kept">>} | tail]),
    ?assertMatch(#{request_id := _},
                 maps:get(correlation, ImproperMetadata)),

    %% Exercise both accepted JSON spellings for every public correlation key.
    AlternateSpellings =
        #{task_ref => <<"task-atom">>,
          correlation_id => <<"correlation-atom">>,
          <<"invocation_id">> => <<"invocation-binary">>,
          <<"call_id">> => <<"call-binary">>,
          <<"request_id">> => <<"request-binary">>},
    {adk_failure, AlternateMetadata} =
        adk_failure:external(component, operation, AlternateSpellings),
    AlternateCorrelation = maps:get(correlation, AlternateMetadata),
    ?assertEqual(
       lists:sort([task_ref, correlation_id, invocation_id,
                   call_id, request_id]),
       lists:sort(maps:keys(AlternateCorrelation))),
    [?assertEqual(24, byte_size(Value))
     || Value <- maps:values(AlternateCorrelation)].

model_and_log_views_are_json_safe_test() ->
    Failure = adk_failure:external(
                provider, request,
                #{status => 429, request_id => <<"request">>}),
    Metadata = adk_failure:log_metadata(other, other, Failure),
    ?assertEqual(provider, maps:get(component, Metadata)),
    #{<<"failure">> := Json} =
        adk_failure:model_response(other, other, Failure),
    ?assertEqual(<<"provider">>, maps:get(<<"component">>, Json)),
    ?assertEqual(<<"request">>, maps:get(<<"operation">>, Json)),
    ?assertEqual(<<"external">>, maps:get(<<"class">>, Json)),
    ?assertEqual(<<"map_failure">>, maps:get(<<"reason">>, Json)),
    ?assertEqual(429, maps:get(<<"status">>, Json)),
    ?assertMatch(#{<<"request_id">> := _},
                 maps:get(<<"correlation">>, Json)).

assert_status(Reason, Status) ->
    {adk_failure, Metadata} =
        adk_failure:external(component, operation, Reason),
    ?assertEqual(Status, maps:get(status, Metadata)).

assert_no_status(Reason) ->
    {adk_failure, Metadata} =
        adk_failure:external(component, operation, Reason),
    ?assertNot(maps:is_key(status, Metadata)).

expected_status({_, Status}) -> Status;
expected_status({_, Status, _}) -> Status;
expected_status({_, Status, _, _}) -> Status;
expected_status({_, Status, _, _, _}) -> Status;
expected_status(#{status_code := Status}) -> Status;
expected_status(#{<<"http_status">> := Status}) -> Status;
expected_status(#{wrapper := [_, #{<<"status_code">> := Status}]}) -> Status;
expected_status([_, {status, Status}]) -> Status.
