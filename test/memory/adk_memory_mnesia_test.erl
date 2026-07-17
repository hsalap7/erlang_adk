-module(adk_memory_mnesia_test).
-include_lib("eunit/include/eunit.hrl").

durability_and_concurrent_idempotency_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Pid) ->
         [?_test(restart_durability(Pid)),
          ?_test(concurrent_service_idempotency(Pid))]
     end}.

setup() ->
    {ok, Pid} = adk_memory_mnesia:start_link(#{}),
    lists:foreach(fun(Table) -> {atomic, ok} = mnesia:clear_table(Table) end,
                  adk_memory_mnesia:table_names()),
    Pid.

cleanup(Pid) ->
    adk_memory_mnesia:stop(Pid),
    lists:foreach(fun(Table) -> mnesia:clear_table(Table) end,
                  adk_memory_mnesia:table_names()),
    ok.

restart_durability(Pid) ->
    Scope = {user, <<"durable-app">>, <<"durable-user">>},
    {ok, Stored} = adk_memory_mnesia:add_entry(
                     Pid, Scope,
                     #{content => <<"durable across adapter restart">>,
                       metadata => #{<<"kind">> => <<"durable">>}},
                     #{idempotency_key => <<"durable-1">>}),
    ok = adk_memory_mnesia:stop(Pid),
    {ok, Restarted} = adk_memory_mnesia:start_link(#{}),
    try
        {ok, [Hit]} = adk_memory_mnesia:search(
                        Restarted, Scope, <<"adapter restart">>, #{limit => 5}),
        ?assertEqual(maps:get(id, Stored), maps:get(id, Hit)),
        {ok, Duplicate} = adk_memory_mnesia:add_entry(
                            Restarted, Scope,
                            #{content => <<"durable across adapter restart">>,
                              metadata => #{<<"kind">> => <<"durable">>}},
                            #{idempotency_key => <<"durable-1">>}),
        ?assertEqual(maps:get(id, Stored), maps:get(id, Duplicate))
    after
        adk_memory_mnesia:stop(Restarted)
    end.

concurrent_service_idempotency(_StoppedPid) ->
    Scope = {user, <<"concurrent-app">>, <<"concurrent-user">>},
    {ok, One} = adk_memory_mnesia:start_link(#{}),
    {ok, Two} = adk_memory_mnesia:start_link(#{}),
    Parent = self(),
    Input = #{content => <<"one durable idempotent write">>, metadata => #{}},
    Opts = #{idempotency_key => <<"same-operation">>},
    Pids = [case Index rem 2 of 0 -> One; _ -> Two end
            || Index <- lists:seq(1, 40)],
    lists:foreach(
      fun(Service) ->
          spawn(fun() -> Parent ! {memory_add_done,
                                   adk_memory_mnesia:add_entry(
                                     Service, Scope, Input, Opts)} end)
      end, Pids),
    Replies = collect(40, []),
    Ids = lists:usort([maps:get(id, Entry) || {ok, Entry} <- Replies]),
    ?assertEqual(40, length(Replies)),
    ?assertEqual(1, length(Ids)),
    {ok, Hits} = adk_memory_mnesia:search(
                   One, Scope, <<"idempotent write">>, #{limit => 5}),
    ?assertEqual(1, length(Hits)),
    adk_memory_mnesia:stop(One),
    adk_memory_mnesia:stop(Two).

collect(0, Acc) -> Acc;
collect(Remaining, Acc) ->
    receive
        {memory_add_done, Reply} -> collect(Remaining - 1, [Reply | Acc])
    after 10000 -> erlang:error({missing_memory_replies, Remaining})
    end.
