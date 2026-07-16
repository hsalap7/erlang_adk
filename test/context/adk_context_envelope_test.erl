-module(adk_context_envelope_test).

-include_lib("eunit/include/eunit.hrl").

tool_secrets_are_pruned_before_provider_test() ->
    History = [#{role => tool,
                 content =>
                   {tool_response, <<"lookup">>,
                    #{<<"answer">> => <<"safe">>,
                      <<"api_key">> => <<"must-not-reach-model">>},
                    undefined, <<"call-1">>}}],
    {ok, [#{content :=
               {tool_response, <<"lookup">>, Safe, undefined,
                <<"call-1">>}}]} =
        adk_context_envelope:sanitize_history(History),
    ?assertEqual(<<"safe">>, maps:get(<<"answer">>, Safe)),
    ?assertNot(maps:is_key(<<"api_key">>, Safe)).

complete_envelope_is_measured_and_stable_test() ->
    Config = #{provider => ignored_runtime_atom,
               api_key => <<"not-hashed">>,
               instructions => <<"system instruction">>,
               temperature => 0.2},
    History = [#{role => system, content => <<"system instruction">>},
               #{role => user, content => <<"hello">>}],
    Tools = [#{<<"name">> => <<"lookup">>,
               <<"description">> => <<"look something up">>,
               <<"parameters">> => #{<<"type">> => <<"object">>}}],
    {ok, First} = adk_context_envelope:measure(Config, History, Tools),
    {ok, Second} = adk_context_envelope:measure(Config, History, Tools),
    ?assert(maps:get(bytes, First) >
            byte_size(<<"system instructionhello">>)),
    ?assert(maps:get(framing_bytes, First) > 0),
    ?assertEqual(maps:get(fingerprint, First),
                 maps:get(fingerprint, Second)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(First), <<"not-hashed">>)).

complete_request_budget_fails_structurally_test() ->
    Config = #{instructions => binary:copy(<<"i">>, 512)},
    History = [#{role => user, content => binary:copy(<<"x">>, 512)}],
    {error, {request_context_budget_exceeded, Details}} =
        adk_context_envelope:check(
          Config, History, [],
          #{max_request_bytes => 100, max_request_tokens => infinity}),
    ?assert(maps:get(bytes, Details) > 100),
    ?assertEqual(100, maps:get(max_bytes, Details)).

request_budget_options_are_eagerly_validated_test() ->
    ?assertEqual(
       {error, {invalid_context_options, max_request_bytes}},
       adk_context_policy:build([], #{max_request_bytes => 0})),
    ?assertMatch(
       {ok, _},
       adk_context_policy:build(
         [], #{max_request_bytes => 1024,
               max_request_tokens => 512})).
