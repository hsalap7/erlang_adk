-module(adk_memory_embedding_provider_test).
-include_lib("eunit/include/eunit.hrl").

bounded_embedding_provider_test_() ->
    [?_test(valid_batch()),
     ?_test(rejects_bad_shape_and_bounds()),
     ?_test(redacts_provider_usage()),
     ?_test(timeout_and_error_redaction())].

valid_batch() ->
    {ok, Result} = adk_memory_embedding_provider:embed(
                     {adk_memory_embedding_test_provider, #{mode => good}},
                     <<"embed-v1">>, [<<"one">>, <<"two">>],
                     #{purpose => document}, #{}),
    ?assertEqual(2, length(maps:get(vectors, Result))),
    ?assertEqual(3, maps:get(dimensions, Result)).

rejects_bad_shape_and_bounds() ->
    {error, invalid_embedding_result} =
        adk_memory_embedding_provider:embed(
          {adk_memory_embedding_test_provider, #{mode => bad_shape}},
          <<"embed-v1">>, [<<"one">>], #{}, #{}),
    {error, embedding_input_count_limit_exceeded} =
        adk_memory_embedding_provider:embed(
          {adk_memory_embedding_test_provider, #{mode => good}},
          <<"embed-v1">>, [<<"one">>, <<"two">>], #{},
          #{max_inputs => 1}),
    {error, invalid_embedding_result} =
        adk_memory_embedding_provider:embed(
          {adk_memory_embedding_test_provider, #{mode => good}},
          <<"embed-v1">>, [<<"one">>], #{},
          #{max_result_bytes => 16}),
    {error, embedding_model_mismatch} =
        adk_memory_embedding_provider:embed(
          {adk_memory_embedding_test_provider, #{mode => wrong_model}},
          <<"embed-v1">>, [<<"one">>], #{}, #{}).

redacts_provider_usage() ->
    {ok, Result} = adk_memory_embedding_provider:embed(
                     {adk_memory_embedding_test_provider,
                      #{mode => secret_usage}},
                     <<"embed-v1">>, [<<"one">>], #{}, #{}),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(maps:get(usage, Result)),
                              <<"usage-secret">>)).

timeout_and_error_redaction() ->
    {error, embedding_provider_timeout} =
        adk_memory_embedding_provider:embed(
          {adk_memory_embedding_test_provider, #{mode => hang}},
          <<"embed-v1">>, [<<"one">>], #{}, #{timeout_ms => 10}),
    Error = adk_memory_embedding_provider:embed(
              {adk_memory_embedding_test_provider,
               #{mode => secret_error}},
              <<"embed-v1">>, [<<"one">>], #{}, #{}),
    Bytes = term_to_binary(Error),
    ?assertEqual(nomatch, binary:match(Bytes, <<"do-not-leak">>)).
