-module(adk_eval_store_hardening_test).
-include_lib("eunit/include/eunit.hrl").

store_hardening_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun ets_indexed_paging_is_scope_local_case/0,
      fun ets_byte_quotas_and_baseline_accounting_case/0,
      fun ets_atomic_creation_and_safe_pruning_case/0,
      fun ets_recovery_runs_in_batches_case/0,
      fun adapter_phase_cursor_and_recovery_invariants_case/0,
      fun mnesia_indexed_paging_pruning_and_config_case/0,
      fun mnesia_atomic_creation_and_byte_quota_case/0,
      fun mnesia_usage_is_reconciled_case/0,
      fun mnesia_concurrent_fresh_init_is_serialized_case/0,
      fun mnesia_rejects_wrong_existing_schema_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, _} = application:ensure_all_started(mnesia),
    reset_all_tables(),
    ok.

cleanup(_Setup) ->
    reset_all_tables(),
    ok.

ets_indexed_paging_is_scope_local_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(
                    #{max_sets => 500, max_page_limit => 2}),
    unlink(Store),
    Scope = scope(<<"ets-page-target">>),
    try
        lists:foreach(
          fun(N) ->
              Other = case N rem 2 of
                  0 -> scope(<<"aaa">>);
                  1 -> scope(<<"zzz">>)
              end,
              {ok, _} = adk_eval_store_ets:put_set(
                          Store, Other, eval_set(<<"noise">>, id(N)))
          end, lists:seq(1, 200)),
        lists:foreach(
          fun(N) ->
              {ok, _} = adk_eval_store_ets:put_set(
                          Store, Scope, eval_set(<<"target">>, id(N)))
          end, lists:seq(1, 5)),
        Items = all_pages(adk_eval_store_ets, Store, Scope, 2),
        ?assertEqual(5, length(Items)),
        ?assert(lists:all(
                  fun(#{scope := ItemScope}) -> ItemScope =:= Scope end,
                  Items))
    after
        ok = adk_eval_store_ets:stop(Store)
    end.

ets_recovery_runs_in_batches_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(
                    #{max_sets => 1, max_jobs => 250}),
    unlink(Store),
    Scope = scope(<<"ets-batched-recovery">>),
    try
        {ok, _} = adk_eval_store_ets:put_set(
                    Store, Scope, eval_set(<<"batch">>, <<"1">>)),
        lists:foreach(
          fun(N) ->
              {ok, _} = adk_eval_store_ets:create_job(
                          Store, Scope,
                          job(id(N), <<"batch">>, <<"1">>))
          end, lists:seq(1, 205)),
        ?assertEqual(
           {ok, 205},
           adk_eval_store_ets:recover_active(Store, <<"restart">>)),
        {ok, #{phase := failed}} = adk_eval_store_ets:get_job(
                                    Store, Scope, id(1)),
        {ok, #{phase := failed}} = adk_eval_store_ets:get_job(
                                    Store, Scope, id(205))
    after
        ok = adk_eval_store_ets:stop(Store)
    end.

ets_byte_quotas_and_baseline_accounting_case() ->
    Scope = scope(<<"quota-probe">>),
    Set1 = eval_set(<<"quota">>, <<"01">>),
    {ok, Probe} = adk_eval_store_ets:start_link(#{}),
    unlink(Probe),
    {ok, _} = adk_eval_store_ets:put_set(Probe, Scope, Set1),
    ProbeCaps = adk_eval_store_ets:capabilities(Probe),
    OneSetBytes = maps:get(total_bytes, maps:get(usage, ProbeCaps)),
    ok = adk_eval_store_ets:stop(Probe),

    Cap = OneSetBytes + 64,
    {ok, Scoped} = adk_eval_store_ets:start_link(
                     #{max_record_bytes => Cap,
                       max_scope_bytes => Cap,
                       max_total_bytes => Cap * 3}),
    unlink(Scoped),
    try
        {ok, _} = adk_eval_store_ets:put_set(Scoped, Scope, Set1),
        ?assertEqual(
           {error, eval_scope_byte_capacity_reached},
           adk_eval_store_ets:put_set(
             Scoped, Scope, eval_set(<<"quota">>, <<"02">>)))
    after
        ok = adk_eval_store_ets:stop(Scoped)
    end,

    {ok, Total} = adk_eval_store_ets:start_link(
                    #{max_record_bytes => Cap,
                      max_scope_bytes => Cap,
                      max_total_bytes => Cap}),
    unlink(Total),
    try
        {ok, _} = adk_eval_store_ets:put_set(Total, Scope, Set1),
        ?assertEqual(
           {error, eval_store_total_byte_capacity_reached},
           adk_eval_store_ets:put_set(
             Total, scope(<<"quota-other">>),
             eval_set(<<"quota">>, <<"02">>)))
    after
        ok = adk_eval_store_ets:stop(Total)
    end,

    {ok, RecordLimited} = adk_eval_store_ets:start_link(
                            #{max_record_bytes => 1,
                              max_scope_bytes => 2,
                              max_total_bytes => 3}),
    unlink(RecordLimited),
    ?assertEqual(
       {error, eval_record_byte_capacity_reached},
       adk_eval_store_ets:put_set(RecordLimited, Scope, Set1)),
    ok = adk_eval_store_ets:stop(RecordLimited),

    {ok, BaselineStore} = adk_eval_store_ets:start_link(#{}),
    unlink(BaselineStore),
    BaselineScope = scope(<<"baseline-bytes">>),
    JobId = <<"completed">>,
    try
        {ok, _} = adk_eval_store_ets:create_evaluation(
                    BaselineStore, BaselineScope,
                    eval_set(<<"baseline">>, <<"1">>),
                    job(JobId, <<"baseline">>, <<"1">>)),
        {ok, _} = adk_eval_store_ets:transition_job(
                    BaselineStore, BaselineScope, JobId, [queued], running,
                    #{started_at => 1}),
        {ok, _} = adk_eval_store_ets:transition_job(
                    BaselineStore, BaselineScope, JobId, [running], completed,
                    #{finished_at => 2, result => legacy_result(
                                                     <<"baseline">>, <<"1">>)}),
        Before = total_bytes(BaselineStore),
        {ok, _} = adk_eval_store_ets:put_baseline(
                    BaselineStore, BaselineScope, <<"release">>, JobId),
        After = total_bytes(BaselineStore),
        ?assert(After > Before),
        {ok, _} = adk_eval_store_ets:put_baseline(
                    BaselineStore, BaselineScope, <<"release">>, JobId),
        ?assertEqual(After, total_bytes(BaselineStore))
    after
        ok = adk_eval_store_ets:stop(BaselineStore)
    end.

ets_atomic_creation_and_safe_pruning_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(
                    #{max_sets => 5, max_jobs => 4,
                      max_baselines => 2, max_prune_limit => 1}),
    unlink(Store),
    Scope = scope(<<"ets-prune">>),
    try
        {ok, _} = adk_eval_store_ets:create_evaluation(
                    Store, Scope, eval_set(<<"kept">>, <<"1">>),
                    job(<<"kept-job">>, <<"kept">>, <<"1">>)),
        {ok, _} = adk_eval_store_ets:transition_job(
                    Store, Scope, <<"kept-job">>, [queued], running,
                    #{started_at => 1}),
        {ok, _} = adk_eval_store_ets:transition_job(
                    Store, Scope, <<"kept-job">>, [running], completed,
                    #{finished_at => 2,
                      result => legacy_result(<<"kept">>, <<"1">>)}),
        {ok, _} = adk_eval_store_ets:put_baseline(
                    Store, Scope, <<"protected">>, <<"kept-job">>),
        {ok, _} = adk_eval_store_ets:create_evaluation(
                    Store, Scope, eval_set(<<"old">>, <<"1">>),
                    job(<<"old-job">>, <<"old">>, <<"1">>)),
        {ok, _} = adk_eval_store_ets:transition_job(
                    Store, Scope, <<"old-job">>, [queued], cancelled,
                    #{finished_at => 3, reason => <<"done">>}),
        {ok, _} = adk_eval_store_ets:create_evaluation(
                    Store, Scope, eval_set(<<"active">>, <<"1">>),
                    job(<<"active-job">>, <<"active">>, <<"1">>)),
        Reclaimed = prune_all(adk_eval_store_ets, Store, Scope,
                              erlang:system_time(millisecond) + 1000),
        ?assertEqual(1, maps:get(jobs_deleted, Reclaimed)),
        ?assertEqual(1, maps:get(set_revisions_deleted, Reclaimed)),
        ?assertMatch({ok, _}, adk_eval_store_ets:get_job(
                                Store, Scope, <<"kept-job">>)),
        ?assertMatch({ok, _}, adk_eval_store_ets:get_job(
                                Store, Scope, <<"active-job">>)),
        ?assertEqual({error, not_found}, adk_eval_store_ets:get_job(
                                           Store, Scope, <<"old-job">>)),
        ?assertMatch({ok, _}, adk_eval_store_ets:get_baseline(
                                Store, Scope, <<"protected">>)),
        WithBaselines = prune_all_with_baselines(
                          adk_eval_store_ets, Store, Scope,
                          erlang:system_time(millisecond) + 1000),
        ?assertEqual(1, maps:get(baselines_deleted, WithBaselines)),
        ?assertEqual(1, maps:get(jobs_deleted, WithBaselines)),
        ?assertEqual(1, maps:get(set_revisions_deleted, WithBaselines)),
        ?assertEqual({error, not_found}, adk_eval_store_ets:get_baseline(
                                           Store, Scope, <<"protected">>))
    after
        ok = adk_eval_store_ets:stop(Store)
    end,

    {ok, Atomic} = adk_eval_store_ets:start_link(
                     #{max_sets => 3, max_jobs => 1}),
    unlink(Atomic),
    AtomicScope = scope(<<"atomic">>),
    try
        {ok, _} = adk_eval_store_ets:create_evaluation(
                    Atomic, AtomicScope, eval_set(<<"first">>, <<"1">>),
                    job(<<"first-job">>, <<"first">>, <<"1">>)),
        ?assertEqual(
           {error, eval_job_capacity_reached},
           adk_eval_store_ets:create_evaluation(
             Atomic, AtomicScope, eval_set(<<"orphan">>, <<"1">>),
             job(<<"second-job">>, <<"orphan">>, <<"1">>))),
        ?assertEqual(
           {error, not_found},
           adk_eval_store_ets:get_set(
             Atomic, AtomicScope, <<"orphan">>, <<"1">>)),
        ?assertEqual(
           {error, eval_set_not_found},
           adk_eval_store_ets:create_job(
             Atomic, AtomicScope,
             job(<<"missing-job">>, <<"missing">>, <<"1">>)))
    after
        ok = adk_eval_store_ets:stop(Atomic)
    end.

mnesia_indexed_paging_pruning_and_config_case() ->
    Config = mnesia_config(main),
    {ok, Handle} = adk_eval_store_mnesia:init(Config),
    Scope = scope(<<"mnesia-page-target">>),
    lists:foreach(
      fun(N) ->
          Other = case N rem 2 of
              0 -> scope(<<"aaa">>);
              1 -> scope(<<"zzz">>)
          end,
          {ok, _} = adk_eval_store_mnesia:put_set(
                      Handle, Other, eval_set(<<"noise">>, id(N)))
      end, lists:seq(1, 120)),
    lists:foreach(
      fun(N) ->
          {ok, _} = adk_eval_store_mnesia:put_set(
                      Handle, Scope, eval_set(<<"target">>, id(N)))
      end, lists:seq(1, 5)),
    ?assertEqual(ordered_set,
                 mnesia:table_info(maps:get(sets_table, Config), type)),
    ?assertEqual(5, length(all_pages(
                             adk_eval_store_mnesia, Handle, Scope, 2))),
    {ok, _} = adk_eval_store_mnesia:create_evaluation(
                Handle, Scope, eval_set(<<"old">>, <<"1">>),
                job(<<"old-job">>, <<"old">>, <<"1">>)),
    {ok, _} = adk_eval_store_mnesia:transition_job(
                Handle, Scope, <<"old-job">>, [queued], cancelled,
                #{finished_at => 3, reason => <<"done">>}),
    {ok, _} = adk_eval_store_mnesia:create_evaluation(
                Handle, Scope, eval_set(<<"protected">>, <<"1">>),
                job(<<"protected-job">>, <<"protected">>, <<"1">>)),
    {ok, _} = adk_eval_store_mnesia:transition_job(
                Handle, Scope, <<"protected-job">>, [queued], running,
                #{task_ref => <<"internal-ref">>, started_at => 1}),
    {ok, StoredRunning} = adk_eval_store_mnesia:get_job(
                            Handle, Scope, <<"protected-job">>),
    ?assertNot(maps:is_key(task_ref, StoredRunning)),
    {ok, _} = adk_eval_store_mnesia:transition_job(
                Handle, Scope, <<"protected-job">>, [running], completed,
                #{finished_at => 2,
                  result => legacy_result(<<"protected">>, <<"1">>)}),
    BeforeBaseline = mnesia_total_bytes(Config),
    {ok, _} = adk_eval_store_mnesia:put_baseline(
                Handle, Scope, <<"release">>, <<"protected-job">>),
    ?assert(mnesia_total_bytes(Config) > BeforeBaseline),
    Pruned = prune_all(adk_eval_store_mnesia, Handle, Scope,
                       erlang:system_time(millisecond) + 1000),
    ?assertEqual(1, maps:get(jobs_deleted, Pruned)),
    ?assertEqual(6, maps:get(set_revisions_deleted, Pruned)),
    ?assertMatch({ok, _}, adk_eval_store_mnesia:get_baseline(
                            Handle, Scope, <<"release">>)),
    WithBaselines = prune_all_with_baselines(
                      adk_eval_store_mnesia, Handle, Scope,
                      erlang:system_time(millisecond) + 1000),
    ?assertEqual(1, maps:get(baselines_deleted, WithBaselines)),
    ?assertEqual(1, maps:get(jobs_deleted, WithBaselines)),
    ?assertEqual(1, maps:get(set_revisions_deleted, WithBaselines)),
    ?assertEqual(
       {error, eval_store_config_mismatch},
       adk_eval_store_mnesia:init(Config#{max_sets => 401})),
    Limits = maps:get(limits, Handle),
    Forged = Handle#{limits => Limits#{max_sets => 1000000}},
    ?assertEqual(#{}, adk_eval_store_mnesia:capabilities(Forged)),
    ?assertEqual(
       {error, invalid_eval_store_handle},
       adk_eval_store_mnesia:put_set(
         Forged, scope(<<"forged">>), eval_set(<<"forged">>, <<"1">>))).

adapter_phase_cursor_and_recovery_invariants_case() ->
    {ok, Ets} = adk_eval_store_ets:start_link(#{}),
    unlink(Ets),
    try
        assert_phase_and_cursor_invariants(adk_eval_store_ets, Ets,
                                           scope(<<"ets-invariants">>))
    after
        ok = adk_eval_store_ets:stop(Ets)
    end,
    PhaseConfig = mnesia_config(phase),
    {ok, Mnesia} = adk_eval_store_mnesia:init(PhaseConfig),
    assert_phase_and_cursor_invariants(
      adk_eval_store_mnesia, Mnesia, scope(<<"mnesia-invariants">>)),

    Set = eval_set(<<"recovery">>, <<"1">>),
    Job = job(<<"recovery-job">>, <<"recovery">>, <<"1">>),
    {ok, Probe} = adk_eval_store_ets:start_link(#{}),
    unlink(Probe),
    ProbeScope = scope(<<"ets-recovery">>),
    {ok, _} = adk_eval_store_ets:create_evaluation(
                Probe, ProbeScope, Set, Job),
    ExactBytes = total_bytes(Probe),
    ok = adk_eval_store_ets:stop(Probe),
    {ok, Full} = adk_eval_store_ets:start_link(
                   #{max_record_bytes => ExactBytes,
                     max_scope_bytes => ExactBytes,
                     max_total_bytes => ExactBytes}),
    unlink(Full),
    FullScope = ProbeScope,
    try
        {ok, _} = adk_eval_store_ets:create_evaluation(
                    Full, FullScope, Set, Job),
        ?assertEqual(ExactBytes, total_bytes(Full)),
        ?assertEqual({ok, 1}, adk_eval_store_ets:recover_active(
                                      Full, <<"restart">>)),
        {ok, #{phase := failed}} = adk_eval_store_ets:get_job(
                                    Full, FullScope, <<"recovery-job">>)
    after
        ok = adk_eval_store_ets:stop(Full)
    end,

    MProbeConfig = mnesia_config(recovery_probe),
    {ok, MProbe} = adk_eval_store_mnesia:init(MProbeConfig),
    MProbeScope = scope(<<"mnesia-recovery">>),
    {ok, _} = adk_eval_store_mnesia:create_evaluation(
                MProbe, MProbeScope, Set, Job),
    MExact = mnesia_total_bytes(MProbeConfig),
    MFullConfig = (mnesia_config(recovery_full))#{
                    max_record_bytes => MExact,
                    max_scope_bytes => MExact,
                    max_total_bytes => MExact},
    {ok, MFull} = adk_eval_store_mnesia:init(MFullConfig),
    MFullScope = MProbeScope,
    {ok, _} = adk_eval_store_mnesia:create_evaluation(
                MFull, MFullScope, Set, Job),
    ?assertEqual(MExact, mnesia_total_bytes(MFullConfig)),
    ?assertEqual({ok, 1}, adk_eval_store_mnesia:recover_active(
                                  MFull, <<"restart">>)),
    {ok, #{phase := failed}} = adk_eval_store_mnesia:get_job(
                                MFull, MFullScope, <<"recovery-job">>).

mnesia_atomic_creation_and_byte_quota_case() ->
    AtomicConfig = (mnesia_config(atomic))#{max_jobs => 1},
    {ok, Atomic} = adk_eval_store_mnesia:init(AtomicConfig),
    Scope = scope(<<"mnesia-atomic">>),
    {ok, _} = adk_eval_store_mnesia:create_evaluation(
                Atomic, Scope, eval_set(<<"first">>, <<"1">>),
                job(<<"first-job">>, <<"first">>, <<"1">>)),
    ?assertEqual(
       {error, eval_job_capacity_reached},
       adk_eval_store_mnesia:create_evaluation(
         Atomic, Scope, eval_set(<<"orphan">>, <<"1">>),
         job(<<"orphan-job">>, <<"orphan">>, <<"1">>))),
    ?assertEqual(
       {error, not_found},
       adk_eval_store_mnesia:get_set(
         Atomic, Scope, <<"orphan">>, <<"1">>)),
    ?assertEqual(
       {error, eval_set_not_found},
       adk_eval_store_mnesia:create_job(
         Atomic, Scope, job(<<"missing">>, <<"missing">>, <<"1">>))),

    ProbeConfig = mnesia_config(quota_probe),
    {ok, Probe} = adk_eval_store_mnesia:init(ProbeConfig),
    ProbeScope = scope(<<"mnesia-quota-probe">>),
    {ok, _} = adk_eval_store_mnesia:put_set(
                Probe, ProbeScope, eval_set(<<"quota">>, <<"01">>)),
    OneSetBytes = mnesia_total_bytes(ProbeConfig),
    Cap = OneSetBytes + 64,
    QuotaConfig = (mnesia_config(quota))#{
                    max_record_bytes => Cap,
                    max_scope_bytes => Cap,
                    max_total_bytes => Cap * 3},
    {ok, Quota} = adk_eval_store_mnesia:init(QuotaConfig),
    QuotaScope = scope(<<"mnesia-quota">>),
    {ok, _} = adk_eval_store_mnesia:put_set(
                Quota, QuotaScope, eval_set(<<"quota">>, <<"01">>)),
    ?assertEqual(
       {error, eval_scope_byte_capacity_reached},
       adk_eval_store_mnesia:put_set(
         Quota, QuotaScope, eval_set(<<"quota">>, <<"02">>))),
    ?assertEqual(
       {error, eval_record_byte_capacity_reached},
       adk_eval_store_mnesia:put_set(
         Quota, scope(<<"mnesia-large-record">>),
         eval_set_with_payload(<<"large">>, <<"1">>,
                               binary:copy(<<"x">>, Cap)))).

mnesia_usage_is_reconciled_case() ->
    Config = (mnesia_config(reconcile))#{max_sets => 25,
                                         reconciliation_batch_size => 3},
    {ok, Handle} = adk_eval_store_mnesia:init(Config),
    Scope = scope(<<"mnesia-reconcile">>),
    lists:foreach(
      fun(N) ->
          {ok, _} = adk_eval_store_mnesia:put_set(
                      Handle, Scope, eval_set(<<"set">>, id(N)))
      end, lists:seq(1, 25)),
    {atomic, ok} = mnesia:clear_table(maps:get(usage_table, Config)),
    {ok, Reopened} = adk_eval_store_mnesia:init(Config),
    ?assertEqual(
       {error, eval_set_capacity_reached},
       adk_eval_store_mnesia:put_set(
         Reopened, Scope, eval_set(<<"set">>, <<"26">>))).

mnesia_concurrent_fresh_init_is_serialized_case() ->
    Config = (mnesia_config(concurrent))#{reconciliation_batch_size => 2},
    Parent = self(),
    Pids = [spawn(fun() ->
                      Parent ! {self(), adk_eval_store_mnesia:init(Config)}
                  end) || _ <- lists:seq(1, 2)],
    Results = [receive {Pid, Result} -> Result after 10000 -> timeout end
               || Pid <- Pids],
    ?assert(lists:all(fun({ok, _}) -> true; (_) -> false end, Results)).

mnesia_rejects_wrong_existing_schema_case() ->
    Config = mnesia_config(bad),
    Table = maps:get(sets_table, Config),
    {atomic, ok} = mnesia:create_table(
                     Table,
                     [{attributes, [key, bad]},
                      {record_name, wrong_eval_row},
                      {disc_copies, [node()]}, {type, set}]),
    ?assertMatch(
       {error, {eval_store_table_schema_mismatch, Table, _, _, _}},
       adk_eval_store_mnesia:init(Config)).

assert_phase_and_cursor_invariants(Module, Store, Scope) ->
    Set = eval_set(<<"phase">>, <<"1">>),
    JobId = <<"phase-job">>,
    {ok, _} = Module:create_evaluation(
                Store, Scope, Set, job(JobId, <<"phase">>, <<"1">>)),
    ?assertEqual(
       {error, invalid_eval_job_patch},
       Module:transition_job(
         Store, Scope, JobId, [queued], running, #{})),
    ?assertEqual(
       {error, invalid_eval_job_patch},
       Module:transition_job(
         Store, Scope, JobId, [queued], running,
         #{started_at => 1, finished_at => 2})),
    {ok, _} = Module:transition_job(
                Store, Scope, JobId, [queued], running,
                #{task_ref => <<"legacy-internal">>, started_at => 1}),
    {ok, Running} = Module:get_job(Store, Scope, JobId),
    ?assertNot(maps:is_key(task_ref, Running)),
    ?assertEqual(
       {error, invalid_eval_job_result},
       Module:transition_job(
         Store, Scope, JobId, [running], completed,
         #{result => legacy_result(<<"phase">>, <<"1">>)})),
    ?assertEqual(
       {error, invalid_eval_job_patch},
       Module:transition_job(
         Store, Scope, JobId, [running], failed,
         #{finished_at => 2})),
    {ok, _} = Module:transition_job(
                Store, Scope, JobId, [running], failed,
                #{finished_at => 2, reason => <<"failed">>}),
    Huge = binary:copy(<<"a">>, 4096),
    ?assertEqual(
       {error, invalid_eval_store_page_options},
       Module:list_sets(Store, Scope, #{limit => 1, cursor => Huge})),
    ?assertEqual(
       {error, invalid_eval_prune_options},
       Module:prune(Store, Scope,
                    #{before => 3, limit => 1, cursor => Huge})).

all_pages(Module, Store, Scope, Limit) ->
    all_pages(Module, Store, Scope, Limit, <<>>, []).

all_pages(Module, Store, Scope, Limit, Cursor, Acc) ->
    Options = case Cursor of
        <<>> -> #{limit => Limit};
        _ -> #{limit => Limit, cursor => Cursor}
    end,
    {ok, Page} = Module:list_sets(Store, Scope, Options),
    Items = Acc ++ maps:get(items, Page),
    case maps:get(next_cursor, Page) of
        undefined -> Items;
        Next -> all_pages(Module, Store, Scope, Limit, Next, Items)
    end.

prune_all(Module, Store, Scope, Before) ->
    prune_all(Module, Store, Scope, Before, false, <<>>,
              #{baselines_deleted => 0, jobs_deleted => 0,
                set_revisions_deleted => 0,
                bytes_reclaimed => 0}).

prune_all_with_baselines(Module, Store, Scope, Before) ->
    prune_all(Module, Store, Scope, Before, true, <<>>,
              #{baselines_deleted => 0, jobs_deleted => 0,
                set_revisions_deleted => 0,
                bytes_reclaimed => 0}).

prune_all(Module, Store, Scope, Before, IncludeBaselines, Cursor, Acc0) ->
    Options = case Cursor of
        <<>> -> #{before => Before, limit => 1,
                  include_baselines => IncludeBaselines};
        _ -> #{before => Before, limit => 1, cursor => Cursor,
               include_baselines => IncludeBaselines}
    end,
    {ok, Result} = Module:prune(Store, Scope, Options),
    Acc = lists:foldl(
            fun(Key, A) -> A#{Key => maps:get(Key, A) + maps:get(Key, Result)}
            end, Acc0,
            [baselines_deleted, jobs_deleted,
             set_revisions_deleted, bytes_reclaimed]),
    case maps:get(next_cursor, Result) of
        undefined -> Acc;
        Next -> prune_all(Module, Store, Scope, Before,
                          IncludeBaselines, Next, Acc)
    end.

total_bytes(Store) ->
    maps:get(total_bytes,
             maps:get(usage, adk_eval_store_ets:capabilities(Store))).

eval_set(Id, Version) ->
    {ok, Set} = adk_eval_set:new(
                  Id, Version,
                  [#{id => <<"case">>, input => <<"input">>,
                     expected => <<"expected">>}]),
    Set.

eval_set_with_payload(Id, Version, Payload) ->
    {ok, Set} = adk_eval_set:new(
                  Id, Version,
                  [#{id => <<"case">>, input => Payload,
                     expected => <<"expected">>}]),
    Set.

job(JobId, SetId, SetVersion) ->
    #{job_id => JobId, eval_set_id => SetId,
      eval_set_version => SetVersion, metadata => #{}}.

legacy_result(SetId, SetVersion) ->
    #{<<"result_schema_version">> => 1,
      <<"eval_set_id">> => SetId,
      <<"eval_set_version">> => SetVersion,
      <<"cases">> => [], <<"passed">> => true}.

scope(Name) -> {app, <<"eval-store-hardening-", Name/binary>>}.
id(N) -> integer_to_binary(N).

mnesia_config(main) ->
    base_mnesia_config(adk_eval_hard_sets, adk_eval_hard_jobs,
                       adk_eval_hard_baselines, adk_eval_hard_usage);
mnesia_config(reconcile) ->
    base_mnesia_config(adk_eval_hard_r_sets, adk_eval_hard_r_jobs,
                       adk_eval_hard_r_baselines, adk_eval_hard_r_usage);
mnesia_config(atomic) ->
    base_mnesia_config(adk_eval_hard_a_sets, adk_eval_hard_a_jobs,
                       adk_eval_hard_a_baselines, adk_eval_hard_a_usage);
mnesia_config(phase) ->
    base_mnesia_config(adk_eval_hard_p_sets, adk_eval_hard_p_jobs,
                       adk_eval_hard_p_baselines, adk_eval_hard_p_usage);
mnesia_config(recovery_probe) ->
    base_mnesia_config(adk_eval_hard_rp_sets, adk_eval_hard_rp_jobs,
                       adk_eval_hard_rp_baselines, adk_eval_hard_rp_usage);
mnesia_config(recovery_full) ->
    base_mnesia_config(adk_eval_hard_rf_sets, adk_eval_hard_rf_jobs,
                       adk_eval_hard_rf_baselines, adk_eval_hard_rf_usage);
mnesia_config(concurrent) ->
    base_mnesia_config(adk_eval_hard_c_sets, adk_eval_hard_c_jobs,
                       adk_eval_hard_c_baselines, adk_eval_hard_c_usage);
mnesia_config(quota_probe) ->
    base_mnesia_config(adk_eval_hard_qp_sets, adk_eval_hard_qp_jobs,
                       adk_eval_hard_qp_baselines, adk_eval_hard_qp_usage);
mnesia_config(quota) ->
    base_mnesia_config(adk_eval_hard_q_sets, adk_eval_hard_q_jobs,
                       adk_eval_hard_q_baselines, adk_eval_hard_q_usage);
mnesia_config(bad) ->
    base_mnesia_config(adk_eval_hard_b_sets, adk_eval_hard_b_jobs,
                       adk_eval_hard_b_baselines, adk_eval_hard_b_usage).

base_mnesia_config(Sets, Jobs, Baselines, Usage) ->
    #{sets_table => Sets, jobs_table => Jobs,
      baselines_table => Baselines, usage_table => Usage,
      max_sets => 400, max_jobs => 20, max_baselines => 10,
      max_page_limit => 10, max_prune_limit => 10,
      max_prune_scan => 20, table_wait_ms => 10000}.

reset_all_tables() ->
    Tables = lists:append(
               [[maps:get(sets_table, C), maps:get(jobs_table, C),
                 maps:get(baselines_table, C), maps:get(usage_table, C)]
                || C <- [mnesia_config(main), mnesia_config(reconcile),
                         mnesia_config(atomic), mnesia_config(quota_probe),
                         mnesia_config(quota), mnesia_config(phase),
                         mnesia_config(recovery_probe),
                         mnesia_config(recovery_full),
                         mnesia_config(concurrent),
                         mnesia_config(bad)]]),
    Existing = [Table || Table <- Tables,
                         lists:member(Table, mnesia:system_info(tables))],
    case Existing of
        [] -> ok;
        _ -> _ = mnesia:wait_for_tables(Existing, 10000), ok
    end,
    lists:foreach(fun(Table) -> _ = mnesia:delete_table(Table) end, Existing),
    ok.

mnesia_total_bytes(Config) ->
    Usage = maps:get(usage_table, Config),
    [{adk_eval_store_usage, total, 0, Bytes, undefined}] =
        mnesia:dirty_read(Usage, total),
    Bytes.
