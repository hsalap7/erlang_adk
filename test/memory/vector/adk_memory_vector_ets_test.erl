-module(adk_memory_vector_ets_test).
-include_lib("eunit/include/eunit.hrl").

vector_and_hybrid_reference_test_() ->
    {setup,
     fun() -> adk_memory_vector_ets:start_link(#{max_entries => 2}) end,
     fun({ok, Pid}) -> adk_memory_vector_ets:stop(Pid) end,
     fun({ok, Pid}) -> [
         ?_test(vector_hybrid_and_isolation(Pid)),
         ?_test(bounds_and_fail_closed_validation(Pid))
     ] end}.

vector_hybrid_and_isolation(Pid) ->
    Scope = {user, <<"vector-app">>, <<"alice">>},
    Other = {user, <<"vector-app">>, <<"bob">>},
    Docs = [#{id => <<"otp">>, content => <<"OTP supervision trees">>,
              vector => [1, 0, 0],
              metadata => #{<<"topic">> => <<"beam">>}},
            #{id => <<"other">>, content => <<"unrelated storage">>,
              vector => [0, 1, 0], metadata => #{}}],
    {ok, #{added := 2}} = adk_memory_vector_ets:upsert(
                           Pid, Scope, Docs, #{}),
    {ok, [VectorHit | _]} = adk_memory_vector_ets:vector_search(
                              Pid, Scope, [1, 0, 0], #{limit => 2}),
    ?assertEqual(<<"otp">>, maps:get(id, VectorHit)),
    {ok, [HybridHit | _]} = adk_memory_vector_ets:hybrid_search(
                              Pid, Scope,
                              #{text => <<"supervision">>,
                                vector => [0.5, 0.5, 0]},
                              #{limit => 2, vector_weight => 0.2,
                                lexical_weight => 0.8}),
    ?assertEqual(<<"otp">>, maps:get(id, HybridHit)),
    ?assertEqual(hybrid, maps:get(score_type, HybridHit)),
    {ok, []} = adk_memory_vector_ets:vector_search(
                 Pid, Other, [1, 0, 0], #{limit => 2}).

bounds_and_fail_closed_validation(Pid) ->
    Scope = {user, <<"vector-app">>, <<"alice">>},
    {error, vector_memory_capacity_exceeded} =
        adk_memory_vector_ets:upsert(
          Pid, Scope,
          [#{id => <<"third">>, content => <<"capacity">>,
             vector => [0, 0, 1]}], #{}),
    {error, invalid_vector_memory_vector} =
        adk_memory_vector_ets:vector_search(
          Pid, Scope, [1, 0], #{limit => 2}),
    Huge = 1 bsl 4096,
    {error, invalid_vector_memory_vector} =
        adk_memory_vector_ets:vector_search(
          Pid, Scope, [Huge, 0, 0], #{limit => 2}),
    {error, invalid_hybrid_memory_weights} =
        adk_memory_vector_ets:hybrid_search(
          Pid, Scope, #{text => <<"safe">>, vector => [1, 0, 0]},
          #{limit => 1, vector_weight => Huge, lexical_weight => 1}),
    ?assertMatch(#{entries := 2}, adk_memory_vector_ets:status(Pid)),
    ?assertMatch({error, sensitive_memory_content},
                 adk_memory_vector_ets:upsert(
                   Pid, Scope,
                   [#{id => <<"secret">>,
                      content => <<"password=do-not-store">>,
                      vector => [1, 0, 0]}], #{})).
