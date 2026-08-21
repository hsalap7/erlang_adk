-module(adk_memory_erasure_epoch_test).
-include_lib("eunit/include/eunit.hrl").

-define(JOBS, adk_memory_erasure_epoch_test_job).
-define(USAGE, adk_memory_erasure_epoch_test_usage).
-define(SCHEDULE, adk_memory_erasure_epoch_test_schedule).

erasure_epoch_and_retention_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun({Outbox, Memory}) -> [
         ?_test(queued_and_inflight_jobs_are_fenced(Outbox, Memory)),
         ?_test(post_erasure_resubmission_has_new_identity(Outbox, Memory)),
         ?_test(terminal_retention_and_cluster_semantics(Outbox))
     ] end}.

mnesia_erase_write_race_test_() ->
    {setup,
     fun() ->
         {ok, Pid} = adk_memory_mnesia:start_link(#{}),
         Pid
     end,
     fun(Pid) -> adk_memory_mnesia:stop(Pid) end,
     fun(Pid) -> ?_test(mnesia_erase_write_race(Pid)) end}.

sharded_erasure_capability_test() ->
    {ok, Handle} = adk_memory_sharded:start_link(
                     #{adapter => adk_memory_mnesia,
                       scope_strategy => exact_scope}),
    try
        Capabilities = adk_memory_sharded:capabilities(Handle),
        ?assertEqual(true,
                     maps:get(erasure_epoch_fencing, Capabilities))
    after
        ok = adk_memory_sharded:stop(Handle)
    end.

setup() ->
    {ok, Outbox} = adk_memory_outbox:init(
                     #{jobs_table => ?JOBS, usage_table => ?USAGE,
                       schedule_table => ?SCHEDULE,
                       terminal_retention_ms => 0}),
    clear_outbox(Outbox),
    {ok, Memory} = adk_memory_ets:start_link(#{}),
    {Outbox, Memory}.

cleanup({Outbox, Memory}) ->
    adk_memory_ets:stop(Memory),
    clear_outbox(Outbox).

queued_and_inflight_jobs_are_fenced(Outbox, Memory) ->
    Scope = {user, <<"erase-app">>, <<"queued-user">>},
    {ok, Queued} = adk_memory_outbox:enqueue(
                     Outbox, request(Scope, <<"queued">>, 1)),
    Captured = maps:get(erasure_epoch, Queued),
    {error, not_found} = adk_memory_ets:delete_user(Memory, Scope),
    none = adk_memory_outbox:claim_due(
             Outbox, <<"queued-owner">>, now_ms(), 1000),
    {ok, #{phase := cancelled}} = adk_memory_outbox:status(
                                     Outbox, maps:get(job_id, Queued)),
    {ok, Current} = adk_memory_erasure_epoch:current(Scope),
    ?assert(Current > Captured),

    InflightScope = {user, <<"erase-app">>, <<"inflight-user">>},
    {ok, Inflight} = adk_memory_outbox:enqueue(
                       Outbox, request(InflightScope, <<"inflight">>, 2)),
    {ok, Work} = adk_memory_outbox:claim_due(
                   Outbox, <<"inflight-owner">>, now_ms(), 1000),
    ?assertEqual(maps:get(job_id, Inflight), maps:get(job_id, Work)),
    {error, not_found} = adk_memory_ets:delete_user(Memory, InflightScope),
    {error, {memory_erasure_epoch_stale, _, _}} =
        adk_memory_ets:add_events(
          Memory, InflightScope, maps:get(session_id, Work),
          maps:get(events, Work),
          #{erasure_epoch => maps:get(erasure_epoch, Work)}),
    {ok, #{phase := cancelled}} = adk_memory_outbox:retry(
                                     Outbox, maps:get(job_id, Work),
                                     <<"inflight-owner">>, stale, now_ms()),
    {ok, []} = adk_memory_ets:search(
                 Memory, InflightScope, <<"memory">>, #{limit => 10}).

post_erasure_resubmission_has_new_identity(Outbox, Memory) ->
    Scope = {user, <<"erase-app">>, <<"resubmission-user">>},
    Event = adk_event:new(
              <<"user">>, <<"same event may be valid after erasure">>),
    Request = #{scope => Scope,
                session_id => <<"same-session">>,
                adapter => {adk_memory_ets, <<"fenced-ets">>},
                events => [Event]},
    {ok, First} = adk_memory_outbox:enqueue(Outbox, Request),
    FirstId = maps:get(job_id, First),
    FirstEpoch = maps:get(erasure_epoch, First),
    FirstOwner = <<"pre-erasure-owner">>,
    {ok, FirstWork} = adk_memory_outbox:claim_due(
                        Outbox, FirstOwner, now_ms(), 1000),
    {ok, FirstResult} = adk_memory_ets:add_events(
                          Memory, Scope, <<"same-session">>,
                          maps:get(events, FirstWork),
                          #{erasure_epoch => FirstEpoch}),
    {ok, #{phase := completed}} = adk_memory_outbox:complete_batch(
                                    Outbox, FirstId, FirstOwner,
                                    FirstResult, now_ms()),

    ok = adk_memory_ets:delete_user(Memory, Scope),
    {ok, Second} = adk_memory_outbox:enqueue(Outbox, Request),
    SecondId = maps:get(job_id, Second),
    ?assertNotEqual(FirstId, SecondId),
    ?assertEqual(false, maps:get(deduplicated, Second)),
    ?assert(maps:get(erasure_epoch, Second) > FirstEpoch),
    {ok, Duplicate} = adk_memory_outbox:enqueue(Outbox, Request),
    ?assertEqual(SecondId, maps:get(job_id, Duplicate)),
    ?assertEqual(true, maps:get(deduplicated, Duplicate)),

    SecondOwner = <<"post-erasure-owner">>,
    {ok, SecondWork} = adk_memory_outbox:claim_due(
                         Outbox, SecondOwner, now_ms(), 1000),
    ?assertEqual(SecondId, maps:get(job_id, SecondWork)),
    {ok, SecondResult} = adk_memory_ets:add_events(
                           Memory, Scope, <<"same-session">>,
                           maps:get(events, SecondWork),
                           #{erasure_epoch =>
                                 maps:get(erasure_epoch, SecondWork)}),
    {ok, #{phase := completed}} = adk_memory_outbox:complete_batch(
                                    Outbox, SecondId, SecondOwner,
                                    SecondResult, now_ms()),
    {ok, Entries} = adk_memory_ets:search(
                      Memory, Scope, <<"valid after erasure">>,
                      #{limit => 10}),
    ?assertEqual(1, length(Entries)).

terminal_retention_and_cluster_semantics(Outbox) ->
    Scope = {user, <<"erase-app">>, <<"retention-user">>},
    {ok, Queued} = adk_memory_outbox:enqueue(
                     Outbox, request(Scope, <<"retention">>, 3)),
    Now = now_ms(),
    {ok, _} = adk_memory_outbox:claim_due(
                Outbox, <<"retention-owner">>, Now, 1000),
    {ok, #{phase := completed}} = adk_memory_outbox:complete_batch(
                                    Outbox, maps:get(job_id, Queued),
                                    <<"retention-owner">>,
                                    #{added => 1, duplicates => 0,
                                      skipped => 0}, Now + 1),
    {ok, #{deleted := Deleted}} = adk_memory_outbox:prune_terminal(
                                    Outbox, Now + 2, 10),
    ?assert(Deleted >= 1),
    {error, not_found} = adk_memory_outbox:status(
                           Outbox, maps:get(job_id, Queued)),
    {ok, Semantics} = adk_memory_outbox:semantics(Outbox),
    ?assertEqual(at_least_once, maps:get(delivery, Semantics)),
    ?assertEqual(transactional_epoch,
                 maps:get(erasure_fencing, Semantics)),
    ?assertEqual(fail_closed,
                 maps:get(partition_behavior,
                          maps:get(cluster, Semantics))).

mnesia_erase_write_race(Pid) ->
    Scope = {user, <<"erase-race-app">>, <<"race-user">>},
    lists:foreach(fun(Index) ->
        {ok, Epoch} = adk_memory_erasure_epoch:current(Scope),
        Number = integer_to_binary(Index),
        Event = adk_event:new(
                  <<"user">>, <<"race marker ", Number/binary>>),
        Parent = self(),
        spawn(fun() -> Parent ! {race_add,
            adk_memory_mnesia:add_events(
              Pid, Scope, <<"race-session">>, [Event],
              #{erasure_epoch => Epoch})}
        end),
        spawn(fun() -> Parent ! {race_erase,
            adk_memory_mnesia:delete_user(Pid, Scope)}
        end),
        receive {race_add, _} -> ok after 5000 -> error(add_timeout) end,
        receive {race_erase, _} -> ok after 5000 -> error(erase_timeout) end,
        {ok, []} = adk_memory_mnesia:search(
                     Pid, Scope, <<"race marker">>, #{limit => 50})
    end, lists:seq(1, 20)).

request(Scope, SessionId, Index) ->
    Number = integer_to_binary(Index),
    #{scope => Scope, session_id => SessionId,
      adapter => {adk_memory_ets, <<"fenced-ets">>},
      events => [adk_event:new(
                   <<"user">>, <<"memory event ", Number/binary>>)]}.

clear_outbox(Handle) ->
    lists:foreach(fun(Table) ->
        case mnesia:clear_table(Table) of
            {atomic, ok} -> ok;
            {aborted, {no_exists, Table}} -> ok
        end
    end, adk_memory_outbox:table_names(Handle)).

now_ms() -> erlang:system_time(millisecond).
