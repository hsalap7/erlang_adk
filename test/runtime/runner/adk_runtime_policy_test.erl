-module(adk_runtime_policy_test).
-include_lib("eunit/include/eunit.hrl").

empty_policy_is_fail_closed_test() ->
    {ok, Policy} = adk_runtime_policy:compile(#{}),
    {deny, AgentDecision} = adk_runtime_policy:check_agent(
                              Policy, <<"agent">>, <<"hello">>),
    ?assertEqual(<<"not_allowed">>, reason(AgentDecision)),
    {deny, ToolDecision} = adk_runtime_policy:check_tool(
                             Policy, <<"tool">>, #{}),
    ?assertEqual(<<"not_allowed">>, reason(ToolDecision)),
    Description = adk_runtime_policy:describe(Policy),
    ?assertEqual([], maps:get(<<"allow">>,
                              maps:get(<<"agents">>, Description))),
    ?assertEqual(65536, maps:get(<<"max_argument_bytes">>, Description)),
    ?assertEqual(1048576, maps:get(<<"max_content_bytes">>, Description)).

explicit_allow_and_deny_precedence_test() ->
    {ok, Policy} = adk_runtime_policy:compile(
                     #{agents => #{allow => all,
                                   deny => [<<"blocked-agent">>]},
                       tools => #{allow => [<<"weather">>, <<"shell">>],
                                  deny => [<<"shell">>]}}),
    {allow, _} = adk_runtime_policy:check_agent(
                   Policy, <<"writer">>, <<"hello">>),
    {deny, AgentDenied} = adk_runtime_policy:check_agent(
                            Policy, <<"blocked-agent">>, <<"hello">>),
    ?assertEqual(<<"explicitly_denied">>, reason(AgentDenied)),
    {allow, _} = adk_runtime_policy:check_tool(
                   Policy, <<"weather">>, #{city => <<"Pune">>}),
    {deny, ToolDenied} = adk_runtime_policy:check_tool(
                           Policy, <<"shell">>, #{}),
    ?assertEqual(<<"explicitly_denied">>, reason(ToolDenied)),
    {deny, NotAllowed} = adk_runtime_policy:check_tool(
                           Policy, <<"unknown">>, #{}),
    ?assertEqual(<<"not_allowed">>, reason(NotAllowed)).

argument_budget_uses_canonical_json_bytes_test() ->
    Arguments = #{city => <<"Bengaluru">>, days => 2},
    {ok, Canonical} = adk_json:normalize(Arguments),
    ExactBytes = byte_size(jsx:encode(Canonical)),
    {ok, ExactPolicy} = adk_runtime_policy:compile(
                          #{tools => #{allow => [<<"weather">>]},
                            max_argument_bytes => ExactBytes}),
    {allow, ExactDecision} = adk_runtime_policy:check_tool(
                               ExactPolicy, <<"weather">>, Arguments),
    ?assertEqual(ExactBytes, measured(ExactDecision)),
    {ok, SmallerPolicy} = adk_runtime_policy:compile(
                            #{tools => #{allow => [<<"weather">>]},
                              max_argument_bytes => ExactBytes - 1}),
    {deny, TooLarge} = adk_runtime_policy:check_tool(
                         SmallerPolicy, <<"weather">>, Arguments),
    ?assertEqual(<<"argument_budget_exceeded">>, reason(TooLarge)),
    ?assertEqual(ExactBytes, measured(TooLarge)).

content_budget_counts_binary_payload_bytes_test() ->
    Content = <<"1234567890">>,
    {ok, ExactPolicy} = adk_runtime_policy:compile(
                          #{agents => #{allow => [<<"writer">>]},
                            max_content_bytes => 10}),
    {allow, Exact} = adk_runtime_policy:check_agent(
                       ExactPolicy, <<"writer">>, Content),
    ?assertEqual(10, measured(Exact)),
    {ok, SmallPolicy} = adk_runtime_policy:compile(
                          #{agents => #{allow => [<<"writer">>]},
                            max_content_bytes => 9}),
    {deny, TooLarge} = adk_runtime_policy:check_agent(
                         SmallPolicy, <<"writer">>, Content),
    ?assertEqual(<<"content_budget_exceeded">>, reason(TooLarge)),
    ?assertEqual(10, measured(TooLarge)).

content_only_check_has_no_name_allowlist_test() ->
    {ok, Policy} = adk_runtime_policy:compile(
                     #{max_content_bytes => 3}),
    {allow, _} = adk_runtime_policy:check_content(
                   Policy, <<"model-output">>, <<"abc">>),
    {deny, Decision} = adk_runtime_policy:check_content(
                         Policy, <<"model-output">>, <<"abcd">>),
    ?assertEqual(<<"content_budget_exceeded">>, reason(Decision)).

invalid_runtime_values_fail_closed_without_leaking_terms_test() ->
    Secret = <<"runtime-secret-must-not-appear">>,
    {ok, Policy} = adk_runtime_policy:compile(
                     #{tools => #{allow => [<<"tool">>]},
                       agents => #{allow => [<<"agent">>]}}),
    Arguments = #{password => Secret, callback => fun() -> Secret end},
    {deny, InvalidArguments} = adk_runtime_policy:check_tool(
                                 Policy, <<"tool">>, Arguments),
    ?assertEqual(<<"invalid_arguments">>, reason(InvalidArguments)),
    assert_secret_absent(Secret, InvalidArguments),
    {deny, InvalidContent} = adk_runtime_policy:check_agent(
                               Policy, <<"agent">>, <<255>>),
    ?assertEqual(<<"invalid_content">>, reason(InvalidContent)),
    ?assertEqual(null, measured(InvalidContent)).

denied_subject_is_not_evaluated_test() ->
    {ok, Policy} = adk_runtime_policy:compile(
                     #{tools => #{allow => all,
                                  deny => [<<"blocked">>]}}),
    Secret = <<"denied-secret">>,
    {deny, Decision} = adk_runtime_policy:check_tool(
                         Policy, <<"blocked">>,
                         #{value => Secret, unsafe => self()}),
    ?assertEqual(<<"explicitly_denied">>, reason(Decision)),
    ?assertEqual(null, measured(Decision)),
    assert_secret_absent(Secret, Decision).

audit_decision_is_json_safe_and_contains_no_runtime_content_test() ->
    Secret = <<"api-key-super-secret">>,
    {ok, Policy} = adk_runtime_policy:compile(
                     #{id => <<"production-policy">>,
                       tools => #{allow => [<<"lookup">>]},
                       max_argument_bytes => 1024}),
    {allow, Decision} = adk_runtime_policy:check_tool(
                          Policy, <<"lookup">>,
                          #{api_key => Secret, query => <<"safe">>}),
    Encoded = jsx:encode(Decision),
    ?assertEqual(nomatch, binary:match(Encoded, Secret)),
    ?assertEqual(<<"production-policy">>,
                 maps:get(<<"policy_id">>, Decision)),
    ?assert(is_binary(maps:get(<<"decision_digest">>, Decision))),
    ?assertEqual(Decision, jsx:decode(Encoded, [return_maps])),
    ?assertNot(contains_runtime_handle(Decision)).

malformed_policy_and_subject_fail_closed_test() ->
    {deny, InvalidPolicy} = adk_runtime_policy:check_agent(
                              #{}, <<"agent">>, <<"hello">>),
    ?assertEqual(<<"invalid_policy">>, reason(InvalidPolicy)),
    {ok, Policy} = adk_runtime_policy:compile(
                     #{agents => #{allow => all}}),
    {deny, InvalidSubject} = adk_runtime_policy:check_agent(
                               Policy, self(), <<"hello">>),
    ?assertEqual(<<"invalid_subject">>, reason(InvalidSubject)),
    ?assertEqual(<<"<invalid>">>,
                 maps:get(<<"subject">>, InvalidSubject)).

strict_configuration_validation_test() ->
    ?assertEqual({error, unsupported_runtime_policy_options},
                 adk_runtime_policy:compile(#{unknown => true})),
    ?assertEqual({error, invalid_max_argument_bytes},
                 adk_runtime_policy:compile(
                   #{max_argument_bytes => infinity})),
    ?assertEqual({error, {invalid_runtime_policy_allow, agents}},
                 adk_runtime_policy:compile(
                   #{agents => #{allow => [self()]}})),
    ?assertEqual({error, {unsupported_runtime_policy_rules, tools}},
                 adk_runtime_policy:compile(
                   #{tools => #{allow => all, mode => permissive}})),
    ?assertEqual({error, invalid_runtime_policy_id},
                 adk_runtime_policy:compile(#{id => <<>>})).

telemetry_is_structural_and_secret_free_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    HandlerId = {?MODULE, make_ref()},
    TestPid = self(),
    ok = telemetry:attach(
           HandlerId, [erlang_adk, policy, decision],
           fun(Name, Measurements, Metadata, Pid) ->
               Pid ! {policy_telemetry, Name, Measurements, Metadata}
           end, TestPid),
    Secret = <<"telemetry-secret">>,
    try
        {ok, Policy} = adk_runtime_policy:compile(
                         #{tools => #{allow => [<<"lookup">>]}}),
        {allow, _} = adk_runtime_policy:check_tool(
                       Policy, <<"lookup">>, #{token => Secret}),
        receive
            {policy_telemetry, [erlang_adk, policy, decision],
             Measurements, Metadata} ->
                ?assertNot(contains_runtime_handle(Measurements)),
                ?assertNot(contains_runtime_handle(Metadata)),
                assert_secret_absent(Secret,
                                     #{measurements => Measurements,
                                       metadata => Metadata})
        after 1000 -> erlang:error(telemetry_timeout)
        end
    after
        telemetry:detach(HandlerId)
    end.

reason(Decision) -> maps:get(<<"reason">>, Decision).

measured(Decision) ->
    maps:get(<<"measured_bytes">>, maps:get(<<"budget">>, Decision)).

assert_secret_absent(Secret, Value) ->
    {ok, Canonical} = adk_json:normalize(Value),
    ?assertEqual(nomatch, binary:match(jsx:encode(Canonical), Secret)).

contains_runtime_handle(Value) when is_pid(Value); is_reference(Value);
                                    is_port(Value); is_function(Value) -> true;
contains_runtime_handle(Value) when is_map(Value) ->
    contains_runtime_handle(maps:keys(Value)) orelse
    contains_runtime_handle(maps:values(Value));
contains_runtime_handle(Value) when is_list(Value) ->
    lists:any(fun contains_runtime_handle/1, Value);
contains_runtime_handle(Value) when is_tuple(Value) ->
    contains_runtime_handle(tuple_to_list(Value));
contains_runtime_handle(_Value) -> false.
