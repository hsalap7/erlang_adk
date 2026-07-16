-module(adk_memory_v2_ets_test).
-include_lib("eunit/include/eunit.hrl").

strict_bounds_and_validation_test_() ->
    {setup,
     fun() ->
         {ok, Pid} = adk_memory_ets:start_link(
                       #{max_content_bytes => 32,
                         max_result_bytes => 64,
                         max_entries => 2,
                         max_total_bytes => 1024}),
         Pid
     end,
     fun adk_memory_ets:stop/1,
     fun(Pid) ->
         Scope = {user, <<"bounds-app">>, <<"bounds-user">>},
         [?_assertMatch(
              {error, {invalid_memory_content, {size_limit_exceeded, _, 32}}},
              adk_memory_ets:add_entry(
                Pid, Scope,
                #{content => binary:copy(<<"x">>, 33), metadata => #{}}, #{})),
          ?_assertMatch(
              {error, {invalid_memory_scope, _, _}},
              adk_memory_ets:search(Pid, {user, <<>>, <<"user">>},
                                    <<"query">>, #{})),
          ?_assertEqual(
              {error, sensitive_memory_content},
              adk_memory_ets:add_entry(
                Pid, Scope,
                #{content => <<"api_key: abcdefghijklmnop">>,
                  metadata => #{}}, #{})),
          ?_test(capacity_case(Pid, Scope))]
     end}.

capacity_case(Pid, Scope) ->
    {ok, _} = adk_memory_ets:add_entry(
                Pid, Scope, #{content => <<"first bounded">>, metadata => #{}},
                #{}),
    {ok, _} = adk_memory_ets:add_entry(
                Pid, Scope, #{content => <<"second bounded">>, metadata => #{}},
                #{}),
    ?assertEqual(
       {error, memory_capacity_exceeded},
       adk_memory_ets:add_entry(
         Pid, Scope, #{content => <<"third bounded">>, metadata => #{}}, #{})).

invalid_config_test() ->
    ?assertMatch({error, _}, adk_memory_ets:start_link(#{unknown_limit => 1})),
    ?assertMatch({error, _}, adk_memory_ets:start_link(#{max_results => 0})).

expired_queued_add_never_commits_test() ->
    {ok, Pid} = adk_memory_ets:start_link(#{}),
    Scope = {user, <<"deadline-app">>, <<"deadline-user">>},
    try
        ok = sys:suspend(Pid),
        try
            ?assertEqual(
               {error, timeout},
               adk_memory_ets:add_entry(
                 Pid, Scope,
                 #{content => <<"late memory marker">>, metadata => #{}},
                 #{}, #{timeout_ms => 20}))
        after
            ok = sys:resume(Pid)
        end,
        {ok, []} = adk_memory_ets:search(
                     Pid, Scope, <<"late memory marker">>, #{limit => 5}),
        {ok, Stored} = adk_memory_ets:add_entry(
                         Pid, Scope,
                         #{content => <<"on-time memory marker">>,
                           metadata => #{}}, #{}),
        ?assertEqual(<<"on-time memory marker">>, maps:get(content, Stored))
    after
        ok = adk_memory_ets:stop(Pid)
    end.
