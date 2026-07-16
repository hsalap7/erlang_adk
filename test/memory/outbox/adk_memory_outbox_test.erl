-module(adk_memory_outbox_test).
-include_lib("eunit/include/eunit.hrl").

-define(JOBS, adk_memory_outbox_test_job).
-define(USAGE, adk_memory_outbox_test_usage).

memory_outbox_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun(Handle) ->
          ?_test(batching_sanitization_and_dedupe(Handle))
      end,
      fun(Handle) ->
          ?_test(bounded_concurrent_admission(Handle))
      end,
      fun(Handle) ->
          ?_test(lease_crash_recovery_and_terminal_failure(Handle))
      end,
      fun(Handle) ->
          ?_test(processor_restart_uses_adapter_idempotency(Handle))
      end,
      fun(Handle) ->
          ?_test(processor_bounds_and_cancels_resolver(Handle))
      end,
      fun(Handle) ->
          ?_test(ownership_loss_prevents_adapter_mutation(Handle))
      end]}.

setup() ->
    {ok, Handle} = adk_memory_outbox:init(base_config()),
    clear_tables(Handle),
    Handle.

cleanup(Handle) ->
    clear_tables(Handle),
    ok.

batching_sanitization_and_dedupe(Handle) ->
    Scope = {user, <<"outbox-app">>, <<"outbox-user">>},
    Events0 = [event(Index) || Index <- lists:seq(1, 1000)],
    SecretEvent = adk_event:new(
                    <<"user">>, <<"password=do-not-persist">>,
                    #{invocation_id => <<"secret-invocation">>}),
    Events = Events0 ++ [SecretEvent, SecretEvent],
    Request = request(Scope, <<"session-exact">>, Events),
    {ok, First} = adk_memory_outbox:enqueue(Handle, Request),
    ?assertEqual(false, maps:get(deduplicated, First)),
    ?assertEqual(Scope, maps:get(scope, First)),
    ?assertEqual(<<"session-exact">>, maps:get(session_id, First)),
    ?assertEqual({adk_memory_outbox_test_adapter, <<"primary-v2">>},
                 maps:get(adapter, First)),
    ?assertEqual(1001, maps:get(event_count, First)),
    ?assertEqual(1, maps:get(input_duplicates, First)),
    ?assertEqual(3, maps:get(batch_count, First)),
    JobId = maps:get(job_id, First),
    {ok, Duplicate} = adk_memory_outbox:enqueue(Handle, Request),
    ?assertEqual(JobId, maps:get(job_id, Duplicate)),
    ?assertEqual(true, maps:get(deduplicated, Duplicate)),
    {ok, #{active_jobs := 1}} = adk_memory_outbox:stats(Handle),

    {ok, FirstClaim} = adk_memory_outbox:claim_due(
                         Handle, <<"owner-one">>, 1000, 20),
    ?assertEqual(500, length(maps:get(events, FirstClaim))),
    none = adk_memory_outbox:claim_due(
             Handle, <<"too-early">>, 1010, 20),
    {ok, RecoveredClaim} = adk_memory_outbox:claim_due(
                             Handle, <<"owner-two">>, 1020, 20),
    ?assertEqual(maps:get(batch_id, FirstClaim),
                 maps:get(batch_id, RecoveredClaim)),
    ?assertEqual(maps:get(event_ids, FirstClaim),
                 maps:get(event_ids, RecoveredClaim)),
    ?assertEqual(2, maps:get(attempt, RecoveredClaim)),
    {ok, _} = adk_memory_outbox:complete_batch(
                Handle, JobId, <<"owner-two">>, result(500), 1021),
    {ok, SecondClaim} = adk_memory_outbox:claim_due(
                          Handle, <<"owner-three">>, 1022, 20),
    ?assertEqual(500, length(maps:get(events, SecondClaim))),
    {ok, _} = adk_memory_outbox:complete_batch(
                Handle, JobId, <<"owner-three">>, result(500), 1023),
    {ok, LastClaim} = adk_memory_outbox:claim_due(
                        Handle, <<"owner-four">>, 1024, 20),
    ?assertEqual(1, length(maps:get(events, LastClaim))),
    EncodedLast = jsx:encode(maps:get(events, LastClaim)),
    ?assertEqual(nomatch, binary:match(EncodedLast, <<"do-not-persist">>)),
    ?assertNotEqual(nomatch, binary:match(EncodedLast, <<"[REDACTED]">>)),
    {ok, Completed} = adk_memory_outbox:complete_batch(
                        Handle, JobId, <<"owner-four">>, result(1), 1025),
    ?assertEqual(completed, maps:get(phase, Completed)),
    ?assertEqual(1001, maps:get(added, maps:get(result, Completed))),
    {ok, #{active_jobs := 0}} = adk_memory_outbox:stats(Handle),

    [Persisted] = mnesia:dirty_read(?JOBS, JobId),
    ?assertEqual(false, contains_opaque(Persisted)),
    PersistedBinary = term_to_binary(Persisted),
    ?assertEqual(nomatch,
                 binary:match(PersistedBinary, <<"do-not-persist">>)).

bounded_concurrent_admission(_BaseHandle) ->
    LimitedConfig = (base_config())#{max_active_global => 4,
                                     max_active_per_scope => 2,
                                     max_active_bytes_global => 33554432,
                                     max_active_bytes_per_scope => 16777216},
    {ok, Handle} = adk_memory_outbox:init(LimitedConfig),
    clear_tables(Handle),
    ScopeA = {user, <<"bounded-app">>, <<"user-a">>},
    RequestsA = [request(ScopeA, session(Index), [event(Index)])
                 || Index <- lists:seq(1, 10)],
    RepliesA = concurrent_enqueue(Handle, RequestsA),
    ?assertEqual(2, length([ok || {_Request, {ok, _}} <- RepliesA])),
    ?assertEqual(8, length([capacity || {_Request, {error,
                      {memory_outbox_capacity_exceeded, SeenScope,
                       active_jobs, 2}}} <- RepliesA,
                       SeenScope =:= ScopeA])),
    AcceptedA = [Request || {Request, {ok, _}} <- RepliesA],

    ScopeB = {user, <<"bounded-app">>, <<"user-b">>},
    RequestsB = [request(ScopeB, session(Index), [event(Index + 20)])
                 || Index <- lists:seq(1, 2)],
    RepliesB = concurrent_enqueue(Handle, RequestsB),
    ?assertEqual(2, length([ok || {_Request, {ok, _}} <- RepliesB])),
    ScopeC = {user, <<"bounded-app">>, <<"user-c">>},
    {error, {memory_outbox_capacity_exceeded, global,
             active_jobs, 4}} = adk_memory_outbox:enqueue(
                                  Handle,
                                  request(ScopeC, <<"global-full">>,
                                          [event(99)])),
    [AlreadyAccepted | _] = AcceptedA,
    {ok, Dedupe} = adk_memory_outbox:enqueue(Handle, AlreadyAccepted),
    ?assertEqual(true, maps:get(deduplicated, Dedupe)),
    {ok, #{active_jobs := 4}} = adk_memory_outbox:stats(Handle),
    {atomic, ok} = mnesia:clear_table(?USAGE),
    {ok, RecoveredHandle} = adk_memory_outbox:init(LimitedConfig),
    {ok, #{active_jobs := 4}} = adk_memory_outbox:stats(RecoveredHandle),
    Claims = concurrent_claims(RecoveredHandle, 8, 5000),
    Work = [Claim || {ok, Claim} <- Claims],
    ?assertEqual(4, length(Work)),
    ?assertEqual(4, length(lists:usort(
                             [maps:get(job_id, Claim) || Claim <- Work]))).

lease_crash_recovery_and_terminal_failure(_BaseHandle) ->
    {ok, Handle} = adk_memory_outbox:init(
                     (base_config())#{backoff_base_ms => 5,
                                      max_backoff_ms => 10}),
    clear_tables(Handle),
    Request = (request({user, <<"crash-app">>, <<"crash-user">>},
                       <<"crash-session">>, [event(1)]))#{max_attempts => 2},
    {ok, Queued} = adk_memory_outbox:enqueue(Handle, Request),
    JobId = maps:get(job_id, Queued),
    {ok, Work1} = adk_memory_outbox:claim_due(
                    Handle, <<"crashed-owner">>, 2000, 10),
    BatchId = maps:get(batch_id, Work1),
    none = adk_memory_outbox:claim_due(
             Handle, <<"other-owner">>, 2009, 10),
    {ok, Work2} = adk_memory_outbox:claim_due(
                    Handle, <<"restarted-owner">>, 2010, 10),
    ?assertEqual(BatchId, maps:get(batch_id, Work2)),
    ?assertEqual(2, maps:get(attempt, Work2)),
    {ok, Failed} = adk_memory_outbox:retry(
                     Handle, JobId, <<"restarted-owner">>,
                     {adapter_error, #{password => <<"never-store-this">>}},
                     2011),
    ?assertEqual(failed, maps:get(phase, Failed)),
    ?assertEqual(0, maps:get(active_jobs,
                             element(2, adk_memory_outbox:stats(Handle)))),
    FailureBytes = jsx:encode(maps:get(last_error, Failed)),
    ?assertEqual(nomatch, binary:match(FailureBytes, <<"never-store-this">>)),
    ?assertNotEqual(nomatch, binary:match(FailureBytes, <<"[REDACTED]">>)).

processor_restart_uses_adapter_idempotency(Handle) ->
    {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(
                      #{test_pid => self(), block_first => true}),
    {ok, Registry} = adk_memory_outbox_registry:start_link(),
    Identity = {adk_memory_outbox_test_adapter, <<"primary-v2">>},
    ok = adk_memory_outbox_registry:register(
           Registry, Identity,
           {adk_memory_outbox_test_adapter, Adapter}),
    ProcessorOpts = #{outbox => Handle,
                      resolver => {adk_memory_outbox_registry, Registry},
                      poll_interval_ms => 5,
                      lease_ms => 700,
                      call_timeout_ms => 200,
                      max_concurrency => 2},
    {ok, FirstProcessor} = adk_memory_outbox_processor:start_link(ProcessorOpts),
    unlink(FirstProcessor),
    Scope = {user, <<"processor-app">>, <<"processor-user">>},
    {ok, Queued} = adk_memory_outbox_processor:submit(
                     FirstProcessor,
                     request(Scope, <<"processor-session">>,
                             [event(1), event(2), event(3)])),
    JobId = maps:get(job_id, Queued),
    receive
        {memory_outbox_adapter_committed, Adapter, 1, Scope,
         <<"processor-session">>, _Ids, 3, 0} -> ok
    after 3000 -> erlang:error(first_adapter_call_not_observed)
    end,
    {ok, Running} = adk_memory_outbox:status(Handle, JobId),
    ?assertEqual(running, maps:get(phase, Running)),
    %% Claim revision 1 is followed by the mandatory pre-adapter renewal.
    ?assertEqual(2, maps:get(revision, Running)),
    exit(FirstProcessor, kill),
    ok = adk_memory_outbox_test_adapter:release(Adapter),
    timer:sleep(750),
    {ok, SecondProcessor} = adk_memory_outbox_processor:start_link(ProcessorOpts),
    unlink(SecondProcessor),
    Completed = wait_for_phase(Handle, JobId, completed, 3000),
    ?assertEqual(completed, maps:get(phase, Completed)),
    #{calls := 2, unique_events := 3} =
        adk_memory_outbox_test_adapter:stats(Adapter),
    ?assertEqual(3, maps:get(duplicates, maps:get(result, Completed))),
    gen_server:stop(SecondProcessor),
    gen_server:stop(Registry),
    adk_memory_outbox_test_adapter:stop(Adapter).

processor_bounds_and_cancels_resolver(Handle) ->
    {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(
                      #{test_pid => self()}),
    ResolverState = #{mode => hang,
                      test_pid => self(),
                      service_ref =>
                          {adk_memory_outbox_test_adapter, Adapter}},
    ProcessorOpts = #{outbox => Handle,
                      resolver => {adk_memory_outbox_test_resolver,
                                   ResolverState},
                      poll_interval_ms => 5,
                      lease_ms => 350,
                      call_timeout_ms => 50,
                      max_concurrency => 1},
    {ok, Processor} = adk_memory_outbox_processor:start_link(ProcessorOpts),
    try
        Scope = {user, <<"resolver-app">>, <<"resolver-user">>},
        Request = (request(Scope, <<"resolver-timeout">>, [event(41)]))#{
                    max_attempts => 1},
        Started = erlang:monotonic_time(millisecond),
        {ok, Queued} = adk_memory_outbox_processor:submit(
                         Processor, Request),
        JobId = maps:get(job_id, Queued),
        ResolverPid = receive
            {memory_outbox_resolver_started, Pid, hang,
             adk_memory_outbox_test_adapter, <<"primary-v2">>} -> Pid
        after 1000 -> erlang:error(resolver_was_not_started)
        end,
        Failed = wait_for_phase(Handle, JobId, failed, 1500),
        Elapsed = erlang:monotonic_time(millisecond) - Started,
        ?assert(Elapsed < 1000),
        ?assertEqual(1, maps:get(attempt, Failed)),
        assert_process_down(ResolverPid),
        ?assertEqual(#{calls => 0, unique_events => 0},
                     adk_memory_outbox_test_adapter:stats(Adapter))
    after
        gen_server:stop(Processor),
        adk_memory_outbox_test_adapter:stop(Adapter)
    end.

ownership_loss_prevents_adapter_mutation(Handle) ->
    {ok, Adapter} = adk_memory_outbox_test_adapter:start_link(
                      #{test_pid => self()}),
    ResolverState = #{mode => block,
                      test_pid => self(),
                      service_ref =>
                          {adk_memory_outbox_test_adapter, Adapter}},
    ProcessorOpts = #{outbox => Handle,
                      resolver => {adk_memory_outbox_test_resolver,
                                   ResolverState},
                      poll_interval_ms => 5,
                      lease_ms => 650,
                      call_timeout_ms => 200,
                      max_concurrency => 1},
    {ok, Processor} = adk_memory_outbox_processor:start_link(ProcessorOpts),
    try
        Scope = {user, <<"ownership-app">>, <<"ownership-user">>},
        {ok, Queued} = adk_memory_outbox_processor:submit(
                         Processor,
                         request(Scope, <<"ownership-race">>, [event(42)])),
        JobId = maps:get(job_id, Queued),
        ResolverPid = receive
            {memory_outbox_resolver_started, Pid, block,
             adk_memory_outbox_test_adapter, <<"primary-v2">>} -> Pid
        after 1000 -> erlang:error(resolver_was_not_started)
        end,
        {ok, Cancelled} = adk_memory_outbox:cancel(
                            Handle, JobId, test_cancel_before_adapter),
        ?assertEqual(cancelled, maps:get(phase, Cancelled)),
        ResolverPid ! memory_outbox_resolver_release,
        assert_process_down(ResolverPid),
        timer:sleep(100),
        {ok, Status} = adk_memory_outbox:status(Handle, JobId),
        ?assertEqual(cancelled, maps:get(phase, Status)),
        ?assertEqual(#{calls => 0, unique_events => 0},
                     adk_memory_outbox_test_adapter:stats(Adapter)),
        receive
            {memory_outbox_adapter_committed, Adapter, _, _, _, _, _, _} ->
                erlang:error(adapter_called_after_ownership_loss)
        after 50 -> ok
        end
    after
        gen_server:stop(Processor),
        adk_memory_outbox_test_adapter:stop(Adapter)
    end.

base_config() ->
    #{jobs_table => ?JOBS, usage_table => ?USAGE}.

request(Scope, SessionId, Events) ->
    #{scope => Scope,
      session_id => SessionId,
      adapter => {adk_memory_outbox_test_adapter, <<"primary-v2">>},
      events => Events}.

event(Index) ->
    Number = integer_to_binary(Index),
    adk_event:new(<<"user">>, <<"memory event ", Number/binary>>,
                  #{invocation_id => <<"inv-", Number/binary>>}).

session(Index) -> <<"session-", (integer_to_binary(Index))/binary>>.

result(Added) -> #{added => Added, duplicates => 0, skipped => 0}.

concurrent_enqueue(Handle, Requests) ->
    Parent = self(),
    [spawn(fun() -> Parent ! {outbox_enqueue,
                              Request,
                              adk_memory_outbox:enqueue(Handle, Request)} end)
     || Request <- Requests],
    collect_enqueue(length(Requests), []).

collect_enqueue(0, Acc) -> Acc;
collect_enqueue(Remaining, Acc) ->
    receive
        {outbox_enqueue, Request, Reply} ->
            collect_enqueue(Remaining - 1, [{Request, Reply} | Acc])
    after 10000 -> erlang:error({missing_outbox_enqueue_replies, Remaining})
    end.

concurrent_claims(Handle, Count, Now) ->
    Parent = self(),
    [spawn(fun() ->
        Token = <<"claim-", (integer_to_binary(Index))/binary>>,
        Parent ! {outbox_claim,
                  adk_memory_outbox:claim_due(Handle, Token, Now, 100)}
     end) || Index <- lists:seq(1, Count)],
    collect_claims(Count, []).

collect_claims(0, Acc) -> Acc;
collect_claims(Remaining, Acc) ->
    receive
        {outbox_claim, Reply} ->
            collect_claims(Remaining - 1, [Reply | Acc])
    after 10000 -> erlang:error({missing_outbox_claim_replies, Remaining})
    end.

wait_for_phase(Handle, JobId, Phase, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_phase_loop(Handle, JobId, Phase, Deadline).

wait_for_phase_loop(Handle, JobId, Phase, Deadline) ->
    case adk_memory_outbox:status(Handle, JobId) of
        {ok, #{phase := Phase} = Status} -> Status;
        {ok, Status} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(10),
                        wait_for_phase_loop(Handle, JobId, Phase, Deadline);
                false -> erlang:error({phase_timeout, Status})
            end;
        Error -> erlang:error({status_failed, Error})
    end.

assert_process_down(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 -> erlang:error({process_still_alive, Pid})
    end.

clear_tables(Handle) ->
    lists:foreach(
      fun(Table) ->
          case mnesia:clear_table(Table) of
              {atomic, ok} -> ok;
              {aborted, {no_exists, Table}} -> ok
          end
      end, adk_memory_outbox:table_names(Handle)).

contains_opaque(Value) when is_pid(Value); is_reference(Value);
                            is_port(Value); is_function(Value) -> true;
contains_opaque(Map) when is_map(Map) ->
    lists:any(fun({Key, Item}) -> contains_opaque(Key) orelse
                                  contains_opaque(Item)
              end, maps:to_list(Map));
contains_opaque(Tuple) when is_tuple(Tuple) ->
    lists:any(fun contains_opaque/1, tuple_to_list(Tuple));
contains_opaque(List) when is_list(List) ->
    lists:any(fun contains_opaque/1, List);
contains_opaque(_) -> false.
