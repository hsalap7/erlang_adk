-module(adk_eval_llm_judge_test).
-include_lib("eunit/include/eunit.hrl").

structured_score_and_secret_redaction_test() ->
    Secret = <<"judge-test-secret">>,
    Output = jsx:encode(
               #{<<"score">> => 0.75,
                 <<"rationale">> =>
                     <<"The answer passed; judge-test-secret">>}),
    Config = (base_config(Output))#{
        provider_config =>
            #{fixture_result => {ok, Output},
              test_pid => self(), api_key => Secret}},
    Input = #{<<"turns">> =>
                  [#{<<"actual">> => <<"ERLANG">>,
                     <<"api_key">> => Secret}],
              <<"trajectory">> => []},
    ?assertEqual(ok, adk_eval_llm_judge:validate_config(Config)),
    {ok, 0.75, Metadata} =
        adk_eval_llm_judge:score_case(Input, Config),
    ?assertEqual(<<"llm_rubric">>, maps:get(<<"judge">>, Metadata)),
    ?assertEqual(1, maps:get(<<"judge_schema_version">>, Metadata)),
    ?assertEqual(<<"answer-quality">>,
                 maps:get(<<"rubric_id">>, Metadata)),
    ?assertEqual(<<"2026-07-14">>,
                 maps:get(<<"rubric_version">>, Metadata)),
    ?assertEqual(<<"gemini-3.1-flash-lite">>,
                 maps:get(<<"model">>, Metadata)),
    ?assertEqual(<<"The answer passed; [REDACTED]">>,
                 maps:get(<<"rationale">>, Metadata)),
    receive
        {llm_judge_provider_request, _Worker, undefined,
         ProviderConfig, History, []} ->
            ?assertEqual(adk_eval_llm_judge_test_provider,
                         maps:get(provider, ProviderConfig)),
            ?assertEqual(<<"application/json">>,
                         maps:get(response_mime_type, ProviderConfig)),
            ?assert(is_map(maps:get(response_schema, ProviderConfig))),
            Prompt = iolist_to_binary(
                       [maps:get(content, Message) || Message <- History]),
            ?assertEqual(nomatch, binary:match(Prompt, Secret)),
            ?assertNotEqual(nomatch, binary:match(Prompt, <<"ERLANG">>))
    after 1000 ->
        erlang:error(missing_judge_provider_request)
    end,
    ?assertEqual(nomatch,
                 binary:match(term_to_binary({ok, 0.75, Metadata}), Secret)).

provider_model_version_metadata_test() ->
    Output = <<"{\"score\":1,\"rationale\":\"exact\"}">>,
    {ok, Envelope} = adk_provider_result:new(
                       <<"fixture">>, <<"generation_metadata">>,
                       {ok, Output},
                       #{<<"model_version">> =>
                             <<"gemini-3.1-flash-lite-202607">>}),
    Config = base_config(Envelope),
    {ok, 1.0, Metadata} =
        adk_eval_llm_judge:score_case(case_input(), Config),
    ?assertEqual(<<"gemini-3.1-flash-lite-202607">>,
                 maps:get(<<"provider_model_version">>, Metadata)).

strict_config_and_prompt_bounds_test() ->
    Base = base_config(ok_output()),
    ?assertEqual(
       ok,
       adk_eval_llm_judge:validate_config(
         maps:without([provider, provider_config], Base))),
    ?assertEqual(
       {error, {llm_judge, invalid_rubric}},
       adk_eval_llm_judge:validate_config(maps:remove(rubric, Base))),
    ?assertEqual(
       {error, {llm_judge, unknown_config_key}},
       adk_eval_llm_judge:validate_config(Base#{unexpected => true})),
    ?assertEqual(
       {error, {llm_judge, invalid_provider_config}},
       adk_eval_llm_judge:validate_config(
         Base#{provider_config => #{max_output_tokens => 99}})),
    PromptBounded = Base#{rubric => binary:copy(<<"r">>, 700),
                          max_prompt_bytes => 1024},
    ?assertEqual(
       {error, {llm_judge, prompt_too_large}},
       adk_eval_llm_judge:score_case(case_input(), PromptBounded)),
    ?assertEqual(
       {error, {llm_judge, invalid_request_timeout}},
       adk_eval_llm_judge:validate_config(
         Base#{request_timeout_ms => 120001})).

output_validation_and_provider_error_are_fail_closed_test() ->
    InvalidScore = base_config(
                     <<"{\"score\":1.1,\"rationale\":\"bad\"}">>),
    ?assertEqual(
       {error, {llm_judge, invalid_judge_output}},
       adk_eval_llm_judge:score_case(case_input(), InvalidScore)),
    ExtraField = base_config(
                   <<"{\"score\":1,\"rationale\":\"ok\",\"pass\":true}">>),
    ?assertEqual(
       {error, {llm_judge, invalid_judge_output}},
       adk_eval_llm_judge:score_case(case_input(), ExtraField)),
    Oversized = (base_config(binary:copy(<<"x">>, 100)))#{
                  max_output_bytes => 64,
                  max_rationale_bytes => 32},
    ?assertEqual(
       {error, {llm_judge, output_too_large}},
       adk_eval_llm_judge:score_case(case_input(), Oversized)),
    Secret = <<"provider-body-secret">>,
    ProviderError = (base_config(ok_output()))#{
        provider_config =>
            #{api_key => Secret,
              fixture_result =>
                  {error, {http_status, 500, Secret}}}},
    Error = adk_eval_llm_judge:score_case(case_input(), ProviderError),
    ?assertEqual({error, {llm_judge, provider_request_failed}}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)).

request_timeout_kills_provider_worker_test() ->
    Config = (base_config(ok_output()))#{
        request_timeout_ms => 20,
        provider_config =>
            #{fixture_result => {ok, ok_output()},
              test_pid => self(), delay_ms => 5000}},
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(
       {error, {llm_judge, request_timeout}},
       adk_eval_llm_judge:score_case(case_input(), Config)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    Worker = receive
        {llm_judge_provider_request, Pid, undefined, _, _, _} -> Pid
    after 1000 -> erlang:error(missing_timed_provider_worker)
    end,
    Monitor = erlang:monitor(process, Worker),
    receive
        {'DOWN', Monitor, process, Worker, _} -> ok
    after 1000 -> erlang:error(timed_provider_worker_survived)
    end.

caller_death_kills_provider_worker_test() ->
    TestPid = self(),
    Config = (base_config(ok_output()))#{
        request_timeout_ms => 5000,
        provider_config =>
            #{fixture_result => {ok, ok_output()},
              test_pid => TestPid, delay_ms => 5000}},
    Caller = spawn(fun() ->
                       _ = adk_eval_llm_judge:score_case(
                             case_input(), Config)
                   end),
    Worker = receive
        {llm_judge_provider_request, Pid, undefined, _, _, _} -> Pid
    after 1000 -> erlang:error(missing_owned_provider_worker)
    end,
    Monitor = erlang:monitor(process, Worker),
    exit(Caller, kill),
    receive
        {'DOWN', Monitor, process, Worker, _} -> ok
    after 1000 -> erlang:error(orphaned_provider_worker)
    end.

independent_judges_are_not_serialized_test() ->
    TestPid = self(),
    Config = (base_config(ok_output()))#{
        provider_config =>
            #{fixture_result => {ok, ok_output()},
              test_pid => TestPid, wait_for_continue => true}},
    Parent = self(),
    _ = [spawn(fun() ->
                   Parent ! {judge_done,
                             adk_eval_llm_judge:score_case(
                               case_input(), Config)}
               end) || _ <- [1, 2]],
    Worker1 = receive_started_worker(),
    Worker2 = receive_started_worker(),
    ?assertNotEqual(Worker1, Worker2),
    Worker1 ! llm_judge_continue,
    Worker2 ! llm_judge_continue,
    receive {judge_done, {ok, 1.0, _}} -> ok
    after 1000 -> erlang:error(first_judge_not_completed)
    end,
    receive {judge_done, {ok, 1.0, _}} -> ok
    after 1000 -> erlang:error(second_judge_not_completed)
    end.

eval_set_judge_accounting_test() ->
    {ok, Set} = adk_eval_set:new(
                  <<"judge-set">>, <<"1">>,
                  [#{id => <<"case">>, input => <<"ERLANG">>,
                     expected => <<"ERLANG">>}]),
    Adapter = #{module => adk_eval_set_test_adapter,
                target => ignored,
                config => #{mode => echo_expected}},
    Judge = #{id => <<"rubric-judge">>,
              kind => judge,
              module => adk_eval_llm_judge,
              scope => 'case',
              threshold => 0.8,
              config => base_config(ok_output())},
    {ok, Result} = adk_eval_set:run(Adapter, Set, [Judge], #{}),
    ?assertEqual(true, maps:get(<<"passed">>, Result)),
    [Case] = maps:get(<<"cases">>, Result),
    [Sample] = maps:get(<<"samples">>, Case),
    [Metric] = maps:get(<<"criteria">>, Sample),
    ?assertEqual(<<"judge">>, maps:get(<<"kind">>, Metric)),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Metric)),
    ?assertEqual(1.0, maps:get(<<"score">>, Metric)),
    ?assertEqual(<<"2026-07-14">>,
                 maps:get(<<"rubric_version">>,
                          maps:get(<<"metadata">>, Metric))).

receive_started_worker() ->
    receive
        {llm_judge_provider_request, Pid, undefined, _, _, _} -> Pid
    after 1000 -> erlang:error(judge_provider_did_not_start)
    end.

base_config(Result) ->
    #{rubric =>
          <<"Score 1 when the final answer satisfies the request; "
            "otherwise score 0.">>,
      rubric_id => <<"answer-quality">>,
      rubric_version => <<"2026-07-14">>,
      provider => adk_eval_llm_judge_test_provider,
      provider_config => #{fixture_result => normalize_result(Result)}}.

normalize_result({provider_result, _} = Result) -> Result;
normalize_result({ok, _} = Result) -> Result;
normalize_result(Result) when is_binary(Result) -> {ok, Result}.

ok_output() ->
    <<"{\"score\":1,\"rationale\":\"satisfies the rubric\"}">>.

case_input() ->
    #{<<"eval_case">> => #{<<"id">> => <<"case">>},
      <<"turns">> => [#{<<"actual">> => <<"ERLANG">>}],
      <<"trajectory">> => []}.
