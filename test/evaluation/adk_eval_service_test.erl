-module(adk_eval_service_test).
-include_lib("eunit/include/eunit.hrl").

eval_store_and_service_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun immutable_scoped_store_case/0,
      fun set_paging_cursor_is_injective_case/0,
      fun service_completes_and_saves_baseline_case/0,
      fun queued_job_can_be_cancelled_case/0,
      fun startup_recovers_non_terminal_jobs_case/0,
      fun persistence_failure_stops_service_case/0,
      fun atomic_submit_and_service_prune_case/0,
      fun shared_store_has_single_service_owner_case/0,
      fun mnesia_owned_store_operational_options_share_lock_case/0,
      fun bounded_request_validation_keeps_service_responsive_case/0,
      fun missing_task_cancel_clears_active_case/0,
      fun queued_cancel_persistence_failure_stops_service_case/0,
      fun admission_compensation_failure_stops_service_case/0,
      fun mnesia_result_survives_new_handle_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_Setup) ->
    ok.

immutable_scoped_store_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(
                    #{max_sets => 2, max_jobs => 4,
                      max_baselines => 2, max_page_limit => 1}),
    unlink(Store),
    Scope = scope(<<"store">>),
    OtherScope = scope(<<"other">>),
    Set1 = eval_set(<<"suite">>, <<"1">>, <<"one">>),
    Set2 = eval_set(<<"suite">>, <<"2">>, <<"two">>),
    try
        {ok, Revision} = adk_eval_store_ets:put_set(Store, Scope, Set1),
        {ok, Revision} = adk_eval_store_ets:put_set(Store, Scope, Set1),
        Conflicting = eval_set(<<"suite">>, <<"1">>, <<"changed">>),
        ?assertEqual(
           {error, eval_set_revision_conflict},
           adk_eval_store_ets:put_set(Store, Scope, Conflicting)),
        {ok, _} = adk_eval_store_ets:put_set(Store, Scope, Set2),
        ?assertEqual(
           {error, eval_set_capacity_reached},
           adk_eval_store_ets:put_set(
             Store, Scope, eval_set(<<"suite">>, <<"3">>, <<"three">>))),
        {ok, FirstPage} = adk_eval_store_ets:list_sets(
                            Store, Scope, #{limit => 1}),
        ?assertEqual(1, length(maps:get(items, FirstPage))),
        Cursor = maps:get(next_cursor, FirstPage),
        ?assert(is_binary(Cursor)),
        {ok, SecondPage} = adk_eval_store_ets:list_sets(
                             Store, Scope, #{limit => 1, cursor => Cursor}),
        ?assertEqual(1, length(maps:get(items, SecondPage))),
        ?assertEqual(undefined, maps:get(next_cursor, SecondPage)),
        ?assertEqual(
           {error, not_found},
           adk_eval_store_ets:get_set(
             Store, OtherScope, <<"suite">>, <<"1">>)),
        {ok, _} = adk_eval_store_ets:create_job(
                    Store, Scope,
                    #{job_id => <<"terminal-job">>,
                      eval_set_id => <<"suite">>,
                      eval_set_version => <<"1">>, metadata => #{}}),
        {ok, #{phase := cancelled}} =
            adk_eval_store_ets:transition_job(
              Store, Scope, <<"terminal-job">>, [queued], cancelled,
              #{reason => <<"cancelled">>, finished_at => 1}),
        ?assertEqual(
           {error, invalid_eval_job_transition},
           adk_eval_store_ets:transition_job(
             Store, Scope, <<"terminal-job">>, [cancelled], running,
             #{task_ref => <<"late-task">>, started_at => 2}))
    after
        ok = adk_eval_store_ets:stop(Store)
    end.

set_paging_cursor_is_injective_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(
                    #{max_sets => 4, max_jobs => 4,
                      max_baselines => 2, max_page_limit => 1}),
    unlink(Store),
    Scope = scope(<<"cursor">>),
    First = eval_set(<<"a">>, <<0, "b">>, <<"one">>),
    Second = eval_set(<<"a", 0>>, <<"b">>, <<"two">>),
    try
        {ok, _} = adk_eval_store_ets:put_set(Store, Scope, First),
        {ok, _} = adk_eval_store_ets:put_set(Store, Scope, Second),
        {ok, Page1} = adk_eval_store_ets:list_sets(
                        Store, Scope, #{limit => 1}),
        Cursor = maps:get(next_cursor, Page1),
        {ok, Page2} = adk_eval_store_ets:list_sets(
                        Store, Scope, #{limit => 1, cursor => Cursor}),
        Items = maps:get(items, Page1) ++ maps:get(items, Page2),
        ?assertEqual(2, length(Items)),
        ?assertEqual(
           2, length(lists:usort(
                       [{maps:get(id, Item), maps:get(version, Item)}
                        || Item <- Items])))
    after
        ok = adk_eval_store_ets:stop(Store)
    end.

service_completes_and_saves_baseline_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = start_service(Store, #{}),
    unlink(Service),
    Scope = scope(<<"complete">>),
    try
        {ok, Submitted} = adk_eval_service:submit(
                            Service, Scope,
                            request(eval_set(<<"service">>, <<"1">>,
                                             <<"expected">>), 0)),
        JobId = maps:get(job_id, Submitted),
        {ok, Completed} = await_phase(Service, Scope, JobId, completed, 3000),
        ?assertEqual(2, maps:get(revision, Completed)),
        {ok, Result} = adk_eval_service:result(Service, Scope, JobId),
        ?assertEqual(true, maps:get(<<"passed">>, Result)),
        {ok, Baseline} = adk_eval_service:put_baseline(
                           Service, Scope, <<"main">>, JobId),
        ?assertEqual(JobId, maps:get(job_id, Baseline)),
        ?assertEqual(
           {ok, Baseline},
           adk_eval_service:get_baseline(Service, Scope, <<"main">>)),
        ?assertEqual(
           {error, not_found},
           adk_eval_service:status(Service, scope(<<"isolated">>), JobId))
    after
        ok = adk_eval_service:stop(Service),
        ok = adk_eval_store_ets:stop(Store)
    end.

queued_job_can_be_cancelled_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = start_service(
                      Store, #{max_concurrency => 1, max_queue => 1}),
    unlink(Service),
    Scope = scope(<<"queue">>),
    Slow = request(eval_set(<<"queue">>, <<"1">>, <<"slow">>), 250),
    try
        {ok, First} = adk_eval_service:submit(Service, Scope, Slow),
        {ok, Second} = adk_eval_service:submit(Service, Scope, Slow),
        ?assertEqual(
           {error, evaluation_queue_full},
           adk_eval_service:submit(Service, Scope, Slow)),
        {ok, BeforeCancel} = adk_eval_service:list_jobs(
                               Service, Scope, #{limit => 10}),
        ?assertEqual(2, length(maps:get(items, BeforeCancel))),
        SecondId = maps:get(job_id, Second),
        {ok, #{phase := queued}} = adk_eval_service:status(
                                     Service, Scope, SecondId),
        ok = adk_eval_service:cancel(Service, Scope, SecondId),
        {ok, Cancelled} = adk_eval_service:status(Service, Scope, SecondId),
        ?assertEqual(cancelled, maps:get(phase, Cancelled)),
        ?assertMatch(
           {error, {evaluation_job_terminal, cancelled, _}},
           adk_eval_service:result(Service, Scope, SecondId)),
        FirstId = maps:get(job_id, First),
        {ok, _} = await_phase(Service, Scope, FirstId, completed, 3000)
    after
        ok = adk_eval_service:stop(Service),
        ok = adk_eval_store_ets:stop(Store)
    end.

startup_recovers_non_terminal_jobs_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    Scope = scope(<<"recovery">>),
    Set = eval_set(<<"recovery">>, <<"1">>, <<"value">>),
    {ok, _} = adk_eval_store_ets:put_set(Store, Scope, Set),
    {ok, _} = adk_eval_store_ets:create_job(
                Store, Scope, job(<<"queued-job">>)),
    {ok, _} = adk_eval_store_ets:create_job(
                Store, Scope, job(<<"running-job">>)),
    {ok, _} = adk_eval_store_ets:transition_job(
                Store, Scope, <<"running-job">>, [queued], running,
                #{task_ref => <<"old-task">>, started_at => 1}),
    {ok, Service} = start_service(Store, #{}),
    unlink(Service),
    try
        {ok, Capabilities} = adk_eval_service:capabilities(Service),
        ?assertEqual(2, maps:get(recovered_jobs, Capabilities)),
        lists:foreach(
          fun(JobId) ->
              {ok, Status} = adk_eval_service:status(Service, Scope, JobId),
              ?assertEqual(failed, maps:get(phase, Status)),
              ?assertEqual(<<"evaluation_service_restarted">>,
                           maps:get(reason, Status))
          end, [<<"queued-job">>, <<"running-job">>])
    after
        ok = adk_eval_service:stop(Service),
        ok = adk_eval_store_ets:stop(Store)
    end.

persistence_failure_stops_service_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = adk_eval_service:start_link(
                      #{store => {adk_eval_store_failing, Store},
                        max_concurrency => 1, max_queue => 1,
                        task_timeout_ms => 3000,
                        task_retention_ms => 100}),
    unlink(Service),
    Monitor = erlang:monitor(process, Service),
    Scope = scope(<<"persist-failure">>),
    {ok, Submitted} = adk_eval_service:submit(
                        Service, Scope,
                        request(eval_set(<<"persist-failure">>, <<"1">>,
                                         <<"expected">>), 0)),
    JobId = maps:get(job_id, Submitted),
    receive
        {'DOWN', Monitor, process, Service,
         {evaluation_result_persistence_failed, _Reason}} -> ok
    after 3000 ->
        erlang:error(evaluation_service_did_not_fail_closed)
    end,
    {ok, #{phase := running}} =
        adk_eval_store_ets:get_job(Store, Scope, JobId),
    ok = adk_eval_store_ets:stop(Store).

atomic_submit_and_service_prune_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(
                    #{max_sets => 3, max_jobs => 1}),
    unlink(Store),
    {ok, Service} = start_service(Store, #{}),
    unlink(Service),
    Scope = scope(<<"atomic-prune">>),
    FirstSet = eval_set(<<"first">>, <<"1">>, <<"one">>),
    SecondSet = eval_set(<<"orphan">>, <<"1">>, <<"two">>),
    try
        {ok, First} = adk_eval_service:submit(
                        Service, Scope, request(FirstSet, 0)),
        {ok, _} = await_phase(
                    Service, Scope, maps:get(job_id, First), completed, 3000),
        ?assertEqual(
           {error, eval_job_capacity_reached},
           adk_eval_service:submit(Service, Scope, request(SecondSet, 0))),
        ?assertEqual(
           {error, not_found},
           adk_eval_service:get_set(Service, Scope, <<"orphan">>, <<"1">>)),
        {ok, Pruned} = adk_eval_service:prune(
                         Service, Scope,
                         #{before => erlang:system_time(millisecond) + 1000,
                           limit => 10}),
        ?assertEqual(1, maps:get(jobs_deleted, Pruned)),
        ?assertEqual(1, maps:get(set_revisions_deleted, Pruned)),
        {ok, _} = adk_eval_service:submit(
                    Service, Scope, request(SecondSet, 0))
    after
        ok = adk_eval_service:stop(Service),
        ok = adk_eval_store_ets:stop(Store)
    end.

shared_store_has_single_service_owner_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, First} = start_service(Store, #{}),
    unlink(First),
    try
        Trap = process_flag(trap_exit, true),
        ?assertEqual(
           {error, eval_store_already_owned},
           start_service(Store, #{})),
        ?assertEqual(
           {error, eval_store_already_owned},
           adk_eval_service:start_link(
             #{store => {adk_eval_store_failing, {Store, completed}},
               max_concurrency => 1, max_queue => 1,
               task_timeout_ms => 3000,
               task_retention_ms => 100})),
        receive
            {'EXIT', _Pid, eval_store_already_owned} -> ok
        after 0 -> ok
        end,
        receive
            {'EXIT', _Pid2, eval_store_already_owned} -> ok
        after 0 -> ok
        end,
        _ = process_flag(trap_exit, Trap)
    after
        ok = adk_eval_service:stop(First),
        ok = adk_eval_store_ets:stop(Store)
    end.

mnesia_owned_store_operational_options_share_lock_case() ->
    Config = mnesia_lock_config(),
    reset_mnesia_tables(Config),
    {ok, First} = adk_eval_service:start_link(
                    #{store => {owned, adk_eval_store_mnesia, Config},
                      max_concurrency => 1, max_queue => 1,
                      task_timeout_ms => 3000,
                      task_retention_ms => 100}),
    unlink(First),
    Scope = scope(<<"mnesia-owner">>),
    try
        {ok, Submitted} = adk_eval_service:submit(
                            First, Scope,
                            request(eval_set(<<"mnesia-owner">>, <<"1">>,
                                             <<"expected">>), 500)),
        JobId = maps:get(job_id, Submitted),
        {ok, _} = await_phase(First, Scope, JobId, running, 3000),
        Trap = process_flag(trap_exit, true),
        SecondConfig = Config#{repair_usage => true, table_wait_ms => 1},
        ?assertEqual(
           {error, eval_store_already_owned},
           adk_eval_service:start_link(
             #{store => {owned, adk_eval_store_mnesia, SecondConfig},
               max_concurrency => 1, max_queue => 1,
               task_timeout_ms => 3000,
               task_retention_ms => 100})),
        receive
            {'EXIT', _Pid, eval_store_already_owned} -> ok
        after 0 -> ok
        end,
        _ = process_flag(trap_exit, Trap),
        ?assert(is_process_alive(First)),
        {ok, _} = await_phase(First, Scope, JobId, completed, 3000)
    after
        case is_process_alive(First) of
            true -> ok = adk_eval_service:stop(First);
            false -> ok
        end,
        reset_mnesia_tables(Config)
    end.

bounded_request_validation_keeps_service_responsive_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = start_service(Store, #{}),
    unlink(Service),
    Scope = scope(<<"bounded-validation">>),
    ProbeSet = eval_set(<<"validation-probe">>, <<"1">>, <<"ok">>),
    ProbeJobId = <<"validation-probe-job">>,
    {ok, _} = adk_eval_store_ets:create_evaluation(
                Store, Scope, ProbeSet,
                job_for_set(ProbeJobId, <<"validation-probe">>, <<"1">>)),
    Huge = lists:duplicate(500000, <<"x">>),
    Base = request(ProbeSet, 0),
    Requests = [Base#{metrics => Huge},
                Base#{metadata => #{<<"huge">> => Huge}},
                Base#{metrics => [#{id => <<"metric">>} | improper]}],
    try
        lists:foreach(
          fun(Request0) ->
              assert_rejected_while_responsive(
                Service, Scope, ProbeJobId, Request0)
          end, Requests),
        ?assert(is_process_alive(Service))
    after
        ok = adk_eval_service:stop(Service),
        ok = adk_eval_store_ets:stop(Store)
    end.

missing_task_cancel_clears_active_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = start_service(Store, #{}),
    unlink(Service),
    Scope = scope(<<"missing-task">>),
    JobId = <<"missing-task-job">>,
    FakeRef = <<"task-does-not-exist">>,
    {ok, _} = adk_eval_store_ets:create_evaluation(
                Store, Scope,
                eval_set(<<"missing-task">>, <<"1">>, <<"value">>),
                job_for_set(JobId, <<"missing-task">>, <<"1">>)),
    {ok, _} = adk_eval_store_ets:transition_job(
                Store, Scope, JobId, [queued], running,
                #{started_at => 1}),
    _ = sys:replace_state(
          Service,
          fun(State) ->
              State#{active =>
                         #{FakeRef => #{scope => Scope, job_id => JobId,
                                       bytes => 0}}}
          end),
    try
        ok = adk_eval_service:cancel(Service, Scope, JobId),
        {ok, Caps} = adk_eval_service:capabilities(Service),
        ?assertEqual(0, maps:get(active_jobs, Caps)),
        {ok, #{phase := cancelled}} = adk_eval_service:status(
                                       Service, Scope, JobId),
        Service ! {adk_task_terminal, FakeRef,
                   {completed, {error, late_terminal}}},
        timer:sleep(10),
        ?assert(is_process_alive(Service))
    after
        ok = adk_eval_service:stop(Service),
        ok = adk_eval_store_ets:stop(Store)
    end.

queued_cancel_persistence_failure_stops_service_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = adk_eval_service:start_link(
                      #{store => {adk_eval_store_failing,
                                  {Store, cancelled}},
                        max_concurrency => 1, max_queue => 1,
                        task_timeout_ms => 3000,
                        task_retention_ms => 100}),
    unlink(Service),
    Monitor = erlang:monitor(process, Service),
    Scope = scope(<<"cancel-persist">>),
    Slow = request(eval_set(<<"cancel-persist">>, <<"1">>, <<"x">>), 500),
    {ok, _First} = adk_eval_service:submit(Service, Scope, Slow),
    {ok, Second} = adk_eval_service:submit(Service, Scope, Slow),
    SecondId = maps:get(job_id, Second),
    ?assertMatch(
       {error, {evaluation_cancel_persistence_failed, _}},
       adk_eval_service:cancel(Service, Scope, SecondId)),
    receive
        {'DOWN', Monitor, process, Service,
         {evaluation_cancel_persistence_failed, _}} -> ok
    after 3000 -> erlang:error(cancel_persistence_did_not_fail_closed)
    end,
    {ok, #{phase := queued}} = adk_eval_store_ets:get_job(
                               Store, Scope, SecondId),
    ok = adk_eval_store_ets:stop(Store).

admission_compensation_failure_stops_service_case() ->
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = adk_eval_service:start_link(
                      #{store => {adk_eval_store_failing,
                                  {Store, running_and_failed}},
                        max_concurrency => 1, max_queue => 1,
                        task_timeout_ms => 3000,
                        task_retention_ms => 100}),
    unlink(Service),
    Monitor = erlang:monitor(process, Service),
    Scope = scope(<<"compensation">>),
    Reply = adk_eval_service:submit(
              Service, Scope,
              request(eval_set(<<"compensation">>, <<"1">>, <<"x">>), 0)),
    ?assertMatch(
       {error, {evaluation_job_admission_failed, _, _}}, Reply),
    {error, {evaluation_job_admission_failed, JobId, _}} = Reply,
    receive
        {'DOWN', Monitor, process, Service,
         {evaluation_compensation_failed, _}} -> ok
    after 3000 -> erlang:error(compensation_failure_did_not_fail_closed)
    end,
    {ok, #{phase := queued}} = adk_eval_store_ets:get_job(
                               Store, Scope, JobId),
    ok = adk_eval_store_ets:stop(Store).

mnesia_result_survives_new_handle_case() ->
    Config = mnesia_config(),
    reset_mnesia_tables(Config),
    {ok, Handle0} = adk_eval_store_mnesia:init(Config),
    clear_mnesia_tables(Handle0),
    {ok, Handle} = adk_eval_store_mnesia:init(Config),
    Scope = scope(<<"durable">>),
    {ok, Service} = adk_eval_service:start_link(
                      #{store => {adk_eval_store_mnesia, Handle},
                        max_concurrency => 1, max_queue => 1,
                        task_timeout_ms => 3000, task_retention_ms => 100}),
    unlink(Service),
    try
        {ok, Submitted} = adk_eval_service:submit(
                            Service, Scope,
                            request(eval_set(<<"durable">>, <<"1">>,
                                             <<"saved">>), 0)),
        JobId = maps:get(job_id, Submitted),
        {ok, _} = await_phase(Service, Scope, JobId, completed, 3000),
        {ok, _} = adk_eval_service:put_baseline(
                    Service, Scope, <<"release">>, JobId),
        ok = adk_eval_service:stop(Service),
        {ok, Reopened} = adk_eval_store_mnesia:init(Config),
        {ok, #{phase := completed, result := Result}} =
            adk_eval_store_mnesia:get_job(Reopened, Scope, JobId),
        ?assertEqual(true, maps:get(<<"passed">>, Result)),
        ?assertEqual(
           {error, invalid_eval_job_transition},
           adk_eval_store_mnesia:transition_job(
             Reopened, Scope, JobId, [completed], running,
             #{task_ref => <<"late-task">>, started_at => 2})),
        {ok, Baseline} = adk_eval_store_mnesia:get_baseline(
                           Reopened, Scope, <<"release">>),
        ?assertEqual(JobId, maps:get(job_id, Baseline)),
        CursorScope = scope(<<"durable-cursor">>),
        {ok, _} = adk_eval_store_mnesia:put_set(
                    Reopened, CursorScope,
                    eval_set(<<"a">>, <<0, "b">>, <<"one">>)),
        {ok, _} = adk_eval_store_mnesia:put_set(
                    Reopened, CursorScope,
                    eval_set(<<"a", 0>>, <<"b">>, <<"two">>)),
        {ok, DurablePage1} = adk_eval_store_mnesia:list_sets(
                               Reopened, CursorScope, #{limit => 1}),
        DurableCursor = maps:get(next_cursor, DurablePage1),
        {ok, DurablePage2} = adk_eval_store_mnesia:list_sets(
                               Reopened, CursorScope,
                               #{limit => 1, cursor => DurableCursor}),
        ?assertEqual(
           2, length(maps:get(items, DurablePage1) ++
                     maps:get(items, DurablePage2)))
    after
        case is_process_alive(Service) of
            true -> ok = adk_eval_service:stop(Service);
            false -> ok
        end,
        clear_mnesia_tables(Handle)
    end.

start_service(Store, Extra) ->
    adk_eval_service:start_link(
      maps:merge(#{store => {adk_eval_store_ets, Store},
                   max_concurrency => 1, max_queue => 4,
                   task_timeout_ms => 3000, task_retention_ms => 100},
                 Extra)).

request(Set, DelayMs) ->
    #{set => Set,
      adapter => #{module => adk_eval_set_test_adapter,
                   target => ignored,
                   config => #{mode => echo_expected,
                               delay_ms => DelayMs}},
      metrics => [#{id => <<"exact">>,
                    module => adk_eval_set_exact_metric,
                    kind => metric, threshold => 1.0, config => #{}}],
      options => #{concurrency => 1},
      metadata => #{<<"suite">> => <<"service">>}}.

eval_set(Id, Version, Expected) ->
    {ok, Set} = adk_eval_set:new(
                  Id, Version,
                  [#{id => <<"case">>, input => <<"input">>,
                     expected => Expected}]),
    Set.

job(JobId) ->
    #{job_id => JobId, eval_set_id => <<"recovery">>,
      eval_set_version => <<"1">>, metadata => #{}}.

job_for_set(JobId, SetId, SetVersion) ->
    #{job_id => JobId, eval_set_id => SetId,
      eval_set_version => SetVersion, metadata => #{}}.

scope(Suffix) ->
    {app, <<"eval-service-test-", Suffix/binary>>}.

await_phase(Service, Scope, JobId, Phase, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_phase_until(Service, Scope, JobId, Phase, Deadline).

await_phase_until(Service, Scope, JobId, Phase, Deadline) ->
    case adk_eval_service:status(Service, Scope, JobId) of
        {ok, #{phase := Phase} = Status} -> {ok, Status};
        {ok, #{phase := Current}} ->
            case adk_eval_store:terminal_phase(Current) of
                true -> {error, {unexpected_terminal_phase, Current}};
                false ->
                    case erlang:monotonic_time(millisecond) < Deadline of
                        true -> timer:sleep(10),
                                await_phase_until(Service, Scope, JobId,
                                                  Phase, Deadline);
                        false -> {error, evaluation_wait_timeout}
                    end
            end;
        {error, _} = Error -> Error
    end.

assert_rejected_while_responsive(Service, Scope, JobId, Request0) ->
    Parent = self(),
    Ref = make_ref(),
    {Submitter, Monitor} = spawn_monitor(
                           fun() ->
                               Parent ! {Ref, adk_eval_service:submit(
                                                Service, Scope, Request0)}
                           end),
    timer:sleep(5),
    Started = erlang:monotonic_time(millisecond),
    {ok, _} = adk_eval_service:status(Service, Scope, JobId),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assert(Elapsed < 500),
    receive
        {Ref, Reply} -> ?assertMatch({error, _}, Reply)
    after 3000 -> erlang:error(validation_submit_timeout)
    end,
    receive
        {'DOWN', Monitor, process, Submitter, normal} -> ok
    after 1000 -> erlang:error(validation_submitter_did_not_exit)
    end.

mnesia_config() ->
    #{sets_table => adk_eval_service_test_sets,
      jobs_table => adk_eval_service_test_jobs,
      baselines_table => adk_eval_service_test_baselines,
      usage_table => adk_eval_service_test_usage,
      max_sets => 10, max_jobs => 10, max_baselines => 10,
      max_page_limit => 10, table_wait_ms => 10000}.

mnesia_lock_config() ->
    #{sets_table => adk_eval_service_lock_test_sets,
      jobs_table => adk_eval_service_lock_test_jobs,
      baselines_table => adk_eval_service_lock_test_baselines,
      usage_table => adk_eval_service_lock_test_usage,
      max_sets => 10, max_jobs => 10, max_baselines => 10,
      max_page_limit => 10, table_wait_ms => 10000}.

clear_mnesia_tables(Handle) ->
    lists:foreach(
      fun(Table) ->
          case mnesia:clear_table(Table) of
              {atomic, ok} -> ok;
              {aborted, {no_exists, Table}} -> ok
          end
      end, adk_eval_store_mnesia:table_names(Handle)),
    ok.

reset_mnesia_tables(Config) ->
    {ok, _} = application:ensure_all_started(mnesia),
    Tables = [maps:get(sets_table, Config), maps:get(jobs_table, Config),
              maps:get(baselines_table, Config),
              maps:get(usage_table, Config)],
    Existing = [Table || Table <- Tables,
                         lists:member(Table, mnesia:system_info(tables))],
    case Existing of
        [] -> ok;
        _ -> _ = mnesia:wait_for_tables(Existing, 10000), ok
    end,
    lists:foreach(fun(Table) -> _ = mnesia:delete_table(Table) end, Existing),
    ok.
