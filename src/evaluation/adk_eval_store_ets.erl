%% @doc Bounded in-memory implementation of `adk_eval_store'.
-module(adk_eval_store_ets).
-behaviour(adk_eval_store).
-behaviour(gen_server).

-export([start_link/1, stop/1, ownership_identity/1, capabilities/1,
         put_set/3, get_set/4, list_sets/3,
         create_job/3, create_evaluation/4,
         transition_job/6, get_job/3, list_jobs/3,
         put_baseline/4, get_baseline/3, recover_active/2, prune/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_MAX_SETS, 10000).
-define(DEFAULT_MAX_JOBS, 100000).
-define(DEFAULT_MAX_BASELINES, 10000).
-define(DEFAULT_MAX_PAGE_LIMIT, 100).
-define(DEFAULT_MAX_RECORD_BYTES, 16777216).
-define(DEFAULT_MAX_TOTAL_BYTES, 1073741824).
-define(DEFAULT_MAX_SCOPE_BYTES, 268435456).
-define(DEFAULT_MAX_PRUNE_LIMIT, 100).
-define(JOB_TERMINAL_HEADROOM_BYTES, 4608).
-define(MAX_PAGE_LIMIT, 1000).
-define(MAX_PRUNE_LIMIT, 10000).
-define(RECOVERY_BATCH_SIZE, 100).
-define(CALL_TIMEOUT, 30000).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) when is_map(Config) ->
    gen_server:start_link(?MODULE, Config, []);
start_link(_Config) ->
    {error, invalid_eval_store_config}.

-spec stop(pid()) -> ok.
stop(Store) -> gen_server:stop(Store).

-spec ownership_identity(term()) -> {ok, term()} | defer.
ownership_identity(Store) when is_pid(Store) ->
    {ok, {adk_eval_store_ets, Store}};
ownership_identity(Config) when is_map(Config) -> defer;
ownership_identity(_Store) -> defer.

-spec capabilities(pid()) -> map().
capabilities(Store) -> call(Store, capabilities).

-spec put_set(pid(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
put_set(Store, Scope, Set) -> call(Store, {put_set, Scope, Set}).

-spec get_set(pid(), adk_eval_store:scope(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
get_set(Store, Scope, Id, Version) ->
    call(Store, {get_set, Scope, Id, Version}).

-spec list_sets(pid(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
list_sets(Store, Scope, Options) -> call(Store, {list_sets, Scope, Options}).

-spec create_job(pid(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
create_job(Store, Scope, Job) -> call(Store, {create_job, Scope, Job}).

-spec create_evaluation(pid(), adk_eval_store:scope(), map(), map()) ->
    {ok, map()} | {error, term()}.
create_evaluation(Store, Scope, Set, Job) ->
    call(Store, {create_evaluation, Scope, Set, Job}).

-spec transition_job(pid(), adk_eval_store:scope(), binary(), [atom()],
                     atom(), map()) -> {ok, map()} | {error, term()}.
transition_job(Store, Scope, JobId, Expected, Phase, Patch) ->
    call(Store, {transition_job, Scope, JobId, Expected, Phase, Patch}).

-spec get_job(pid(), adk_eval_store:scope(), binary()) ->
    {ok, map()} | {error, term()}.
get_job(Store, Scope, JobId) -> call(Store, {get_job, Scope, JobId}).

-spec list_jobs(pid(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
list_jobs(Store, Scope, Options) -> call(Store, {list_jobs, Scope, Options}).

-spec put_baseline(pid(), adk_eval_store:scope(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
put_baseline(Store, Scope, Name, JobId) ->
    call(Store, {put_baseline, Scope, Name, JobId}).

-spec get_baseline(pid(), adk_eval_store:scope(), binary()) ->
    {ok, map()} | {error, term()}.
get_baseline(Store, Scope, Name) ->
    call(Store, {get_baseline, Scope, Name}).

-spec recover_active(pid(), binary()) ->
    {ok, non_neg_integer()} | {error, term()}.
recover_active(Store, Reason) -> call(Store, {recover_active, Reason}).

-spec prune(pid(), adk_eval_store:scope(), map()) ->
    {ok, map()} | {error, term()}.
prune(Store, Scope, Options) -> call(Store, {prune, Scope, Options}).

init(Config) ->
    case normalize_config(Config) of
        {ok, Limits} ->
            {ok, #{sets => #{}, jobs => #{}, baselines => #{},
                   set_index => #{}, job_index => #{},
                   set_prune_index => #{}, job_prune_index => #{},
                   baseline_prune_index => #{},
                   set_refs => #{}, job_refs => #{},
                   job_charges => #{},
                   usage => #{total_bytes => 0, scopes => #{}},
                   limits => Limits}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call(capabilities, _From, State) ->
    Limits = maps:get(limits, State),
    Reply = #{contract_version => 1, durable => false,
              immutable_set_revisions => true,
              atomic_job_transitions => true,
              atomic_evaluation_creation => true,
              baselines => true, pruning => true, limits => Limits,
              usage => public_usage(State)},
    {reply, Reply, State};
handle_call({put_set, Scope, Set0}, _From, State0) ->
    case prepare_set(Scope, Set0) of
        {ok, Key, Set, Metadata} ->
            Sets = maps:get(sets, State0),
            MetadataDigest = maps:get(digest, Metadata),
            case maps:find(Key, Sets) of
                {ok, #{digest := Digest} = Existing}
                  when Digest =:= MetadataDigest ->
                    {reply, {ok, public_set(Existing)}, State0};
                {ok, _} ->
                    {reply, {error, eval_set_revision_conflict}, State0};
                error ->
                    case map_size(Sets) < limit(max_sets, State0) of
                        true ->
                            Row = Metadata#{set => Set},
                            Size = stored_bytes(Row),
                            case reserve_bytes(Scope, Size, State0) of
                                {ok, State1} ->
                                    State2 = put_set_indexes(
                                               Key, Row,
                                               State1#{sets =>
                                                           Sets#{Key => Row}}),
                                    {reply, {ok, public_set(Row)}, State2};
                                {error, _} = Error ->
                                    {reply, Error, State0}
                            end;
                        false ->
                            {reply, {error, eval_set_capacity_reached}, State0}
                    end
            end;
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({get_set, Scope, Id, Version}, _From, State) ->
    Reply = case valid_lookup(Scope, Id, Version) of
        true ->
            case maps:find({Scope, Id, Version}, maps:get(sets, State)) of
                {ok, Row} -> {ok, maps:get(set, Row)};
                error -> {error, not_found}
            end;
        false -> {error, invalid_eval_set_lookup}
    end,
    {reply, Reply, State};
handle_call({list_sets, Scope, Options}, _From, State) ->
    Reply = list_rows(set, Scope, Options, State),
    {reply, Reply, State};
handle_call({create_job, Scope, Job0}, _From, State0) ->
    case prepare_job(Scope, Job0) of
        {ok, Key, Job} ->
            Jobs = maps:get(jobs, State0),
            case {maps:is_key(Key, Jobs),
                  maps:is_key(job_set_key(Job), maps:get(sets, State0))} of
                {true, _} -> {reply, {error, already_exists}, State0};
                {false, false} ->
                    {reply, {error, eval_set_not_found}, State0};
                {false, true} ->
                    case map_size(Jobs) < limit(max_jobs, State0) of
                        true ->
                            case reserve_job_bytes(Scope, Key, Job, State0) of
                                {ok, State1} ->
                                    State2 = put_job_indexes(
                                               Key, Job,
                                               State1#{jobs =>
                                                           Jobs#{Key => Job}}),
                                    State3 = increment_set_ref(Job, State2),
                                    {reply,
                                     {ok, adk_eval_store:public_job(Job)},
                                     State3};
                                {error, _} = Error ->
                                    {reply, Error, State0}
                            end;
                        false ->
                            {reply, {error, eval_job_capacity_reached}, State0}
                    end
            end;
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({create_evaluation, Scope, Set0, Job0}, _From, State0) ->
    case prepare_evaluation(Scope, Set0, Job0) of
        {ok, SetKey, Set, SetMetadata, JobKey, Job} ->
            case create_evaluation_rows(
                   Scope, SetKey, Set, SetMetadata, JobKey, Job, State0) of
                {ok, Reply, State} -> {reply, {ok, Reply}, State};
                {error, _} = Error -> {reply, Error, State0}
            end;
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({transition_job, Scope, JobId, Expected, Phase, Patch},
            _From, State0) ->
    case prepare_transition(Scope, JobId, Expected, Phase, Patch) of
        {ok, Key, SafePatch} ->
            Jobs0 = maps:get(jobs, State0),
            case maps:find(Key, Jobs0) of
                error -> {reply, {error, not_found}, State0};
                {ok, Job0} ->
                    Current = maps:get(phase, Job0),
                    case lists:member(Current, Expected) of
                        false -> {reply, {error, stale_phase}, State0};
                        true ->
                            case legal_transition(Current, Phase) of
                                false ->
                                    {reply,
                                     {error, invalid_eval_job_transition},
                                     State0};
                                true ->
                                    Job = apply_transition(
                                            Job0, Phase, SafePatch),
                                    case replace_job_bytes(
                                           Key, Scope, Job, State0) of
                                        {ok, State1} ->
                                            Jobs = Jobs0#{Key => Job},
                                            State2 = maybe_index_terminal_job(
                                                       Key, Job,
                                                       State1#{jobs => Jobs}),
                                            {reply,
                                             {ok,
                                              adk_eval_store:public_job(Job)},
                                             State2};
                                        {error, _} = Error ->
                                            {reply, Error, State0}
                                    end
                            end
                    end
            end;
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call({get_job, Scope, JobId}, _From, State) ->
    Reply = case valid_job_lookup(Scope, JobId) of
        true ->
            case maps:find({Scope, JobId}, maps:get(jobs, State)) of
                {ok, Job} -> {ok, Job};
                error -> {error, not_found}
            end;
        false -> {error, invalid_eval_job_lookup}
    end,
    {reply, Reply, State};
handle_call({list_jobs, Scope, Options}, _From, State) ->
    {reply, list_rows(job, Scope, Options, State), State};
handle_call({put_baseline, Scope, Name, JobId}, _From, State0) ->
    case valid_baseline_lookup(Scope, Name, JobId) of
        false -> {reply, {error, invalid_eval_baseline}, State0};
        true -> put_baseline_row(Scope, Name, JobId, State0)
    end;
handle_call({get_baseline, Scope, Name}, _From, State) ->
    Reply = case adk_eval_store:validate_scope(Scope) =:= ok andalso
                 adk_eval_store:valid_name(Name) of
        true ->
            case maps:find({Scope, Name}, maps:get(baselines, State)) of
                {ok, Baseline} -> {ok, Baseline};
                error -> {error, not_found}
            end;
        false -> {error, invalid_eval_baseline}
    end,
    {reply, Reply, State};
handle_call({recover_active, Reason}, From, State0) ->
    case valid_reason(Reason) of
        false -> {reply, {error, invalid_eval_recovery_reason}, State0};
        true ->
            Recovery = #{from => From, reason => Reason,
                         iterator => maps:iterator(maps:get(jobs, State0)),
                         count => 0, original_state => State0},
            {noreply, State0, {continue, {recover_active, Recovery}}}
    end;
handle_call({prune, Scope, Options}, _From, State0) ->
    case prune_options(Scope, Options, State0) of
        {ok, Before, Limit, Cursor, IncludeBaselines} ->
            {Reply, State} = prune_rows(
                               Scope, Before, Limit, Cursor,
                               IncludeBaselines, State0),
            {reply, {ok, Reply}, State};
        {error, _} = Error -> {reply, Error, State0}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_eval_store_call}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_continue({recover_active, Recovery0}, State0) ->
    Iterator = maps:get(iterator, Recovery0),
    Reason = maps:get(reason, Recovery0),
    Count0 = maps:get(count, Recovery0),
    case recover_jobs_batch(
           Iterator, Reason, State0, Count0, ?RECOVERY_BATCH_SIZE) of
        {more, Next, State, Count} ->
            Recovery = Recovery0#{iterator => Next, count => Count},
            {noreply, State, {continue, {recover_active, Recovery}}};
        {done, State, Count} ->
            gen_server:reply(maps:get(from, Recovery0), {ok, Count}),
            {noreply, State};
        {error, _} = Error ->
            gen_server:reply(maps:get(from, Recovery0), Error),
            {noreply, maps:get(original_state, Recovery0)}
    end.

handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              #{sets => map_size(maps:get(sets, State, #{})),
                jobs => map_size(maps:get(jobs, State, #{})),
                baselines => map_size(maps:get(baselines, State, #{})),
                usage => public_usage(State)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).

call(Store, Request) ->
    try gen_server:call(Store, Request, ?CALL_TIMEOUT) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:Reason -> {error, {eval_store_unavailable, safe_reason(Reason)}}
    end.

normalize_config(Config) ->
    Defaults = #{max_sets => ?DEFAULT_MAX_SETS,
                 max_jobs => ?DEFAULT_MAX_JOBS,
                 max_baselines => ?DEFAULT_MAX_BASELINES,
                 max_page_limit => ?DEFAULT_MAX_PAGE_LIMIT,
                 max_record_bytes => ?DEFAULT_MAX_RECORD_BYTES,
                 max_total_bytes => ?DEFAULT_MAX_TOTAL_BYTES,
                 max_scope_bytes => ?DEFAULT_MAX_SCOPE_BYTES,
                 max_prune_limit => ?DEFAULT_MAX_PRUNE_LIMIT},
    Unknown = maps:keys(maps:without(maps:keys(Defaults), Config)),
    Merged = maps:merge(Defaults, Config),
    case {Unknown, valid_limits(Merged)} of
        {[], true} -> {ok, Merged};
        {[_ | _], _} -> {error, {unknown_eval_store_options, lists:sort(Unknown)}};
        {_, false} -> {error, invalid_eval_store_limits}
    end.

valid_limits(Limits) ->
    lists:all(
      fun({Key, Ceiling}) ->
          Value = maps:get(Key, Limits),
          is_integer(Value) andalso Value > 0 andalso Value =< Ceiling
      end,
      [{max_sets, 1000000}, {max_jobs, 1000000},
       {max_baselines, 1000000}, {max_page_limit, ?MAX_PAGE_LIMIT},
       {max_record_bytes, 1099511627776},
       {max_total_bytes, 1099511627776},
       {max_scope_bytes, 1099511627776},
       {max_prune_limit, ?MAX_PRUNE_LIMIT}]) andalso
    maps:get(max_scope_bytes, Limits) =< maps:get(max_total_bytes, Limits) andalso
    maps:get(max_record_bytes, Limits) =< maps:get(max_scope_bytes, Limits).

limit(Key, State) -> maps:get(Key, maps:get(limits, State)).

prepare_set(Scope, Set0) ->
    case {adk_eval_store:validate_scope(Scope),
          adk_eval_store:prepare_set(Set0)} of
        {ok, {ok, Set, Id, Version, Digest}} ->
            Now = now_ms(),
            {ok, {Scope, Id, Version}, Set,
             #{scope => Scope, id => Id, version => Version,
               digest => Digest, created_at => Now}};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

public_set(Row) -> maps:without([set], Row).

valid_lookup(Scope, Id, Version) ->
    adk_eval_store:validate_scope(Scope) =:= ok andalso
    adk_eval_store:valid_name(Id) andalso adk_eval_store:valid_name(Version).

prepare_job(Scope, Job0) when is_map(Job0) ->
    JobId = maps:get(job_id, Job0, undefined),
    SetId = maps:get(eval_set_id, Job0, undefined),
    SetVersion = maps:get(eval_set_version, Job0, undefined),
    Metadata0 = maps:get(metadata, Job0, #{}),
    case {adk_eval_store:validate_scope(Scope),
          adk_eval_store:valid_job_id(JobId),
          adk_eval_store:valid_name(SetId),
          adk_eval_store:valid_name(SetVersion),
          adk_eval_store:prepare_metadata(Metadata0),
          maps:keys(maps:without(
                      [job_id, eval_set_id, eval_set_version, metadata], Job0))} of
        {ok, true, true, true, {ok, Metadata}, []} ->
            Now = now_ms(),
            Job = #{job_id => JobId, scope => Scope,
                    eval_set_id => SetId, eval_set_version => SetVersion,
                    metadata => Metadata, phase => queued, revision => 0,
                    created_at => Now, updated_at => Now,
                    started_at => undefined, finished_at => undefined,
                    reason => undefined},
            {ok, {Scope, JobId}, Job};
        {{error, _} = Error, _, _, _, _, _} -> Error;
        {_, _, _, _, {error, _} = Error, _} -> Error;
        _ -> {error, invalid_eval_job}
    end;
prepare_job(_Scope, _Job) -> {error, invalid_eval_job}.

prepare_evaluation(Scope, Set0, Job0) ->
    case {prepare_set(Scope, Set0), prepare_job(Scope, Job0)} of
        {{ok, SetKey, Set, SetMetadata}, {ok, JobKey, Job}} ->
            {_Scope, SetId, SetVersion} = SetKey,
            case {maps:get(eval_set_id, Job),
                  maps:get(eval_set_version, Job)} of
                {SetId, SetVersion} ->
                    {ok, SetKey, Set, SetMetadata, JobKey, Job};
                _ -> {error, eval_job_set_mismatch}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

create_evaluation_rows(Scope, SetKey, Set, SetMetadata, JobKey, Job,
                       State0) ->
    Sets0 = maps:get(sets, State0),
    Jobs0 = maps:get(jobs, State0),
    SetDigest = maps:get(digest, SetMetadata),
    SetStatus = case maps:find(SetKey, Sets0) of
        {ok, #{digest := SetDigest} = Existing} -> {existing, Existing};
        {ok, _} -> conflict;
        error -> new
    end,
    case {SetStatus, maps:is_key(JobKey, Jobs0),
          map_size(Jobs0) < limit(max_jobs, State0),
          SetStatus =/= new orelse
              map_size(Sets0) < limit(max_sets, State0)} of
        {conflict, _, _, _} -> {error, eval_set_revision_conflict};
        {_, true, _, _} -> {error, already_exists};
        {_, _, false, _} -> {error, eval_job_capacity_reached};
        {_, _, _, false} -> {error, eval_set_capacity_reached};
        _ ->
            case maybe_insert_eval_set(
                   Scope, SetStatus, SetKey, Set, SetMetadata, State0) of
                {ok, PublicSet, State1} ->
                    case reserve_job_bytes(
                           Scope, JobKey, Job, State1) of
                        {ok, State2} ->
                            Jobs = (maps:get(jobs, State2))#{JobKey => Job},
                            State3 = put_job_indexes(
                                       JobKey, Job, State2#{jobs => Jobs}),
                            State4 = increment_set_ref(Job, State3),
                            {ok, #{set => PublicSet,
                                   job => adk_eval_store:public_job(Job)},
                             State4};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

maybe_insert_eval_set(_Scope, {existing, Existing}, _Key, _Set,
                      _Metadata, State) ->
    {ok, public_set(Existing), State};
maybe_insert_eval_set(Scope, new, Key, Set, Metadata, State0) ->
    Row = Metadata#{set => Set},
    case reserve_bytes(Scope, stored_bytes(Row), State0) of
        {ok, State1} ->
            Sets = (maps:get(sets, State1))#{Key => Row},
            State = put_set_indexes(Key, Row, State1#{sets => Sets}),
            {ok, public_set(Row), State};
        {error, _} = Error -> Error
    end.

prepare_transition(Scope, JobId, Expected, Phase, Patch) ->
    case {valid_job_lookup(Scope, JobId), valid_expected(Expected),
          valid_phase(Phase), prepare_patch(Phase, Patch)} of
        {true, true, true, {ok, SafePatch}} ->
            {ok, {Scope, JobId}, SafePatch};
        {_, _, _, {error, _} = Error} -> Error;
        _ -> {error, invalid_eval_job_transition}
    end.

valid_job_lookup(Scope, JobId) ->
    adk_eval_store:validate_scope(Scope) =:= ok andalso
    adk_eval_store:valid_job_id(JobId).

valid_expected(Expected) when is_list(Expected), Expected =/= [] ->
    lists:all(fun valid_phase/1, Expected) andalso
    length(Expected) =:= length(lists:usort(Expected));
valid_expected(_) -> false.

valid_phase(queued) -> true;
valid_phase(running) -> true;
valid_phase(completed) -> true;
valid_phase(failed) -> true;
valid_phase(timed_out) -> true;
valid_phase(cancelled) -> true;
valid_phase(_) -> false.

legal_transition(queued, running) -> true;
legal_transition(queued, failed) -> true;
legal_transition(queued, cancelled) -> true;
legal_transition(running, completed) -> true;
legal_transition(running, failed) -> true;
legal_transition(running, timed_out) -> true;
legal_transition(running, cancelled) -> true;
legal_transition(_Current, _Next) -> false.

prepare_patch(completed, Patch0) when is_map(Patch0) ->
    case {maps:find(result, Patch0), maps:find(finished_at, Patch0),
          patch_keys(Patch0, [result, finished_at])} of
        {{ok, Result0}, {ok, Finished}, true}
          when is_integer(Finished), Finished >= 0 ->
            case adk_eval_set:decode_result(Result0) of
                {ok, Result} ->
                    {ok, #{result => Result, finished_at => Finished}};
                {error, _} -> {error, invalid_eval_job_result}
            end;
        _ -> {error, invalid_eval_job_result}
    end;
prepare_patch(running, Patch0) when is_map(Patch0) ->
    Started = maps:get(started_at, Patch0, undefined),
    TaskRef = maps:get(task_ref, Patch0, undefined),
    case patch_keys(Patch0, [task_ref, started_at]) andalso
         is_integer(Started) andalso Started >= 0 andalso
         valid_optional_binary(TaskRef) of
        true -> {ok, #{started_at => Started}};
        false -> {error, invalid_eval_job_patch}
    end;
prepare_patch(Phase, Patch0) when is_map(Patch0),
                                  (Phase =:= failed orelse
                                   Phase =:= timed_out orelse
                                   Phase =:= cancelled) ->
    Finished = maps:get(finished_at, Patch0, undefined),
    Reason0 = maps:get(reason, Patch0, undefined),
    case {patch_keys(Patch0, [finished_at, reason]),
          is_integer(Finished) andalso Finished >= 0,
          prepare_reason(Reason0)} of
        {true, true, {ok, Reason}} when Reason =/= undefined ->
            {ok, #{finished_at => Finished, reason => Reason}};
        _ -> {error, invalid_eval_job_patch}
    end;
prepare_patch(_Phase, _Patch) -> {error, invalid_eval_job_patch}.

patch_keys(Patch, Allowed) ->
    maps:keys(maps:without(Allowed, Patch)) =:= [].

prepare_reason(undefined) -> {ok, undefined};
prepare_reason(Reason) when is_binary(Reason), byte_size(Reason) > 0,
                            byte_size(Reason) =< 4096 ->
    case unicode:characters_to_binary(Reason, utf8, utf8) of
        Reason -> {ok, Reason};
        _ -> {error, invalid_reason}
    end;
prepare_reason(Reason) ->
    Safe = safe_reason(Reason),
    {ok, Safe}.

valid_optional_binary(undefined) -> true;
valid_optional_binary(Value) -> adk_eval_store:valid_name(Value).

apply_transition(Job0, Phase, Patch) ->
    Job1 = maps:remove(task_ref, maps:merge(Job0, Patch)),
    Job1#{phase => Phase,
          revision => maps:get(revision, Job0) + 1,
          updated_at => now_ms()}.

valid_baseline_lookup(Scope, Name, JobId) ->
    adk_eval_store:validate_scope(Scope) =:= ok andalso
    adk_eval_store:valid_name(Name) andalso
    adk_eval_store:valid_job_id(JobId).

put_baseline_row(Scope, Name, JobId, State0) ->
    Jobs = maps:get(jobs, State0),
    case maps:find({Scope, JobId}, Jobs) of
        error -> {reply, {error, not_found}, State0};
        {ok, #{phase := completed, result := Result}} ->
            Baselines0 = maps:get(baselines, State0),
            Key = {Scope, Name},
            case maps:is_key(Key, Baselines0) orelse
                 map_size(Baselines0) < limit(max_baselines, State0) of
                true ->
                    Baseline = #{scope => Scope, name => Name,
                                 job_id => JobId,
                                 result_digest => adk_eval_store:digest(Result),
                                 result => Result, updated_at => now_ms()},
                    Old = maps:get(Key, Baselines0, undefined),
                    OldBytes = case Old of
                        undefined -> 0;
                        _ -> stored_bytes(Old)
                    end,
                    case replace_record_bytes(
                           Scope, OldBytes, stored_bytes(Baseline), State0) of
                        {ok, State1} ->
                            State2 = update_baseline_refs(
                                       Old, Baseline,
                                       State1#{baselines =>
                                                   Baselines0#{Key =>
                                                                   Baseline}}),
                            State3 = update_baseline_index(
                                       Key, Old, Baseline, State2),
                            {reply, {ok, Baseline}, State3};
                        {error, _} = Error ->
                            {reply, Error, State0}
                    end;
                false ->
                    {reply, {error, eval_baseline_capacity_reached}, State0}
            end;
        {ok, _Job} -> {reply, {error, job_not_completed}, State0}
    end.

list_rows(Kind, Scope, Options, State) ->
    case {adk_eval_store:validate_scope(Scope),
          page_options(Kind, Options, State)} of
        {ok, {ok, Limit, Cursor}} ->
            Indexes = case Kind of
                set -> maps:get(set_index, State);
                job -> maps:get(job_index, State)
            end,
            Index = maps:get(Scope, Indexes, gb_sets:empty()),
            Iter = gb_sets:iterator_from({Cursor, 0}, Index),
            Items = collect_index_page(Kind, Scope, Cursor, Limit + 1,
                                       Iter, State, []),
            {Page, Next} = take_page(Kind, Items, Limit),
            {ok, #{scope => Scope, items => Page, next_cursor => Next}};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

page_options(Kind, Options, State) when is_map(Options) ->
    Unknown = maps:keys(maps:without([limit, cursor], Options)),
    Limit = maps:get(limit, Options, limit(max_page_limit, State)),
    Cursor = maps:get(cursor, Options, <<>>),
    case Unknown =:= [] andalso is_integer(Limit) andalso Limit > 0 andalso
         Limit =< limit(max_page_limit, State) andalso is_binary(Cursor) of
        true ->
            case byte_size(Cursor) =< max_page_cursor_bytes(Kind) of
                true -> {ok, Limit, Cursor};
                false -> {error, invalid_eval_store_page_options}
            end;
        false -> {error, invalid_eval_store_page_options}
    end;
page_options(_Kind, _Options, _State) ->
    {error, invalid_eval_store_page_options}.

max_page_cursor_bytes(set) -> 1032;
max_page_cursor_bytes(job) -> 512.

row_cursor(set, Row) ->
    Id = maps:get(id, Row),
    Version = maps:get(version, Row),
    binary:encode_hex(
      <<(byte_size(Id)):16/unsigned-big, Id/binary,
        (byte_size(Version)):16/unsigned-big, Version/binary>>,
      lowercase);
row_cursor(job, Row) ->
    binary:encode_hex(maps:get(job_id, Row), lowercase).

collect_index_page(_Kind, _Scope, _Cursor, 0, _Iter, _State, Acc) ->
    lists:reverse(Acc);
collect_index_page(Kind, Scope, Cursor, Remaining, Iter0, State, Acc) ->
    case gb_sets:next(Iter0) of
        none -> lists:reverse(Acc);
        {{RowCursor, _Key}, Iter} when RowCursor =< Cursor ->
            collect_index_page(Kind, Scope, Cursor, Remaining,
                               Iter, State, Acc);
        {{_RowCursor, Key}, Iter} ->
            Item = case Kind of
                set -> public_set(maps:get(Key, maps:get(sets, State)));
                job -> adk_eval_store:public_job(
                         maps:get(Key, maps:get(jobs, State)))
            end,
            collect_index_page(Kind, Scope, Cursor, Remaining - 1,
                               Iter, State, [Item | Acc])
    end.

take_page(Kind, Items, Limit) ->
    case length(Items) > Limit of
        true ->
            Page = lists:sublist(Items, Limit),
            {Page, row_cursor(Kind, lists:last(Page))};
        false -> {Items, undefined}
    end.

%% Indexes and quota accounting

put_set_indexes({Scope, Id, Version} = Key, Row, State0) ->
    Cursor = row_cursor(set, Row),
    State1 = add_scope_index(set_index, Scope, {Cursor, Key}, State0),
    case maps:get(Key, maps:get(set_refs, State1), 0) of
        0 -> add_scope_index(
               set_prune_index, Scope,
               {maps:get(created_at, Row), Id, Version}, State1);
        _ -> State1
    end.

put_job_indexes({Scope, _JobId} = Key, Job, State0) ->
    Cursor = row_cursor(job, Job),
    add_scope_index(job_index, Scope, {Cursor, Key}, State0).

maybe_index_terminal_job({Scope, JobId} = Key, Job, State0) ->
    case adk_eval_store:terminal_phase(maps:get(phase, Job)) andalso
         maps:get(Key, maps:get(job_refs, State0), 0) =:= 0 of
        true -> add_scope_index(job_prune_index, Scope,
                                {maps:get(updated_at, Job), JobId}, State0);
        false -> State0
    end.

add_scope_index(Name, Scope, Element, State0) ->
    Indexes0 = maps:get(Name, State0),
    Index0 = maps:get(Scope, Indexes0, gb_sets:empty()),
    State0#{Name => Indexes0#{Scope => gb_sets:add(Element, Index0)}}.

remove_scope_index(Name, Scope, Element, State0) ->
    Indexes0 = maps:get(Name, State0),
    case maps:find(Scope, Indexes0) of
        error -> State0;
        {ok, Index0} ->
            Index = gb_sets:delete_any(Element, Index0),
            Indexes = case gb_sets:is_empty(Index) of
                true -> maps:remove(Scope, Indexes0);
                false -> Indexes0#{Scope => Index}
            end,
            State0#{Name => Indexes}
    end.

increment_set_ref(Job, State0) ->
    Scope = maps:get(scope, Job),
    Key = {Scope, maps:get(eval_set_id, Job),
           maps:get(eval_set_version, Job)},
    Refs0 = maps:get(set_refs, State0),
    Count = maps:get(Key, Refs0, 0),
    State1 = State0#{set_refs => Refs0#{Key => Count + 1}},
    case maps:find(Key, maps:get(sets, State1)) of
        {ok, Row} ->
            remove_scope_index(
              set_prune_index, Scope,
              {maps:get(created_at, Row), maps:get(id, Row),
               maps:get(version, Row)}, State1);
        error -> State1
    end.

job_set_key(Job) ->
    {maps:get(scope, Job), maps:get(eval_set_id, Job),
     maps:get(eval_set_version, Job)}.

decrement_set_ref(Job, State0) ->
    Scope = maps:get(scope, Job),
    Key = {Scope, maps:get(eval_set_id, Job),
           maps:get(eval_set_version, Job)},
    Refs0 = maps:get(set_refs, State0),
    Count = maps:get(Key, Refs0, 0),
    Refs = case Count =< 1 of
        true -> maps:remove(Key, Refs0);
        false -> Refs0#{Key => Count - 1}
    end,
    State1 = State0#{set_refs => Refs},
    case {Count =< 1, maps:find(Key, maps:get(sets, State1))} of
        {true, {ok, Row}} ->
            add_scope_index(
              set_prune_index, Scope,
              {maps:get(created_at, Row), maps:get(id, Row),
               maps:get(version, Row)}, State1);
        _ -> State1
    end.

update_baseline_refs(undefined, Baseline, State) ->
    increment_job_ref(Baseline, State);
update_baseline_refs(Old, Baseline, State) ->
    case maps:get(job_id, Old) =:= maps:get(job_id, Baseline) of
        true -> State;
        false -> increment_job_ref(
                   Baseline, decrement_job_ref(Old, State))
    end.

update_baseline_index({Scope, _Name}, Old, Baseline, State0) ->
    State1 = case Old of
        undefined -> State0;
        _ -> remove_scope_index(
               baseline_prune_index, Scope,
               {maps:get(updated_at, Old), maps:get(name, Old)}, State0)
    end,
    add_scope_index(
      baseline_prune_index, Scope,
      {maps:get(updated_at, Baseline), maps:get(name, Baseline)}, State1).

increment_job_ref(Baseline, State0) ->
    Scope = maps:get(scope, Baseline),
    JobId = maps:get(job_id, Baseline),
    Key = {Scope, JobId},
    Refs0 = maps:get(job_refs, State0),
    Count = maps:get(Key, Refs0, 0),
    State1 = State0#{job_refs => Refs0#{Key => Count + 1}},
    case maps:find(Key, maps:get(jobs, State1)) of
        {ok, Job} -> remove_scope_index(
                       job_prune_index, Scope,
                       {maps:get(updated_at, Job), JobId}, State1);
        error -> State1
    end.

decrement_job_ref(Baseline, State0) ->
    Scope = maps:get(scope, Baseline),
    JobId = maps:get(job_id, Baseline),
    Key = {Scope, JobId},
    Refs0 = maps:get(job_refs, State0),
    Count = maps:get(Key, Refs0, 0),
    Refs = case Count =< 1 of
        true -> maps:remove(Key, Refs0);
        false -> Refs0#{Key => Count - 1}
    end,
    State1 = State0#{job_refs => Refs},
    case {Count =< 1, maps:find(Key, maps:get(jobs, State1))} of
        {true, {ok, Job}} -> maybe_index_terminal_job(Key, Job, State1);
        _ -> State1
    end.

stored_bytes(Value) -> erlang:external_size(Value).

reserve_job_bytes(Scope, Key, Job, State0) ->
    Charge = stored_bytes(Job) + ?JOB_TERMINAL_HEADROOM_BYTES,
    case Charge =< limit(max_record_bytes, State0) of
        false -> {error, eval_record_byte_capacity_reached};
        true ->
            case adjust_bytes(Scope, Charge, State0) of
                {ok, State1} ->
                    Charges = maps:get(job_charges, State1),
                    {ok, State1#{job_charges => Charges#{Key => Charge}}};
                {error, _} = Error -> Error
            end
    end.

replace_job_bytes(Key, Scope, Job, State0) ->
    Size = stored_bytes(Job),
    OldCharge = maps:get(Key, maps:get(job_charges, State0), Size),
    NewCharge = case adk_eval_store:terminal_phase(maps:get(phase, Job)) of
        true -> Size;
        false -> OldCharge
    end,
    case Size =< limit(max_record_bytes, State0) andalso
         NewCharge =< limit(max_record_bytes, State0) of
        false -> {error, eval_record_byte_capacity_reached};
        true ->
            case adjust_bytes(Scope, NewCharge - OldCharge, State0) of
                {ok, State1} ->
                    Charges = maps:get(job_charges, State1),
                    {ok, State1#{job_charges => Charges#{Key => NewCharge}}};
                {error, _} = Error -> Error
            end
    end.

reserve_bytes(Scope, Size, State) ->
    replace_record_bytes(Scope, 0, Size, State).

replace_record_bytes(Scope, OldSize, NewSize, State) ->
    case NewSize =< limit(max_record_bytes, State) of
        true -> adjust_bytes(Scope, NewSize - OldSize, State);
        false -> {error, eval_record_byte_capacity_reached}
    end.

adjust_bytes(Scope, Delta, State0) ->
    Usage0 = maps:get(usage, State0),
    Total = maps:get(total_bytes, Usage0) + Delta,
    Scopes0 = maps:get(scopes, Usage0),
    ScopeBytes = maps:get(Scope, Scopes0, 0) + Delta,
    case {Total >= 0, ScopeBytes >= 0,
          Total =< limit(max_total_bytes, State0),
          ScopeBytes =< limit(max_scope_bytes, State0)} of
        {true, true, true, true} ->
            Scopes = case ScopeBytes of
                0 -> maps:remove(Scope, Scopes0);
                _ -> Scopes0#{Scope => ScopeBytes}
            end,
            {ok, State0#{usage => #{total_bytes => Total,
                                    scopes => Scopes}}};
        {_, _, false, _} ->
            {error, eval_store_total_byte_capacity_reached};
        {_, _, _, false} ->
            {error, eval_scope_byte_capacity_reached};
        _ -> {error, eval_store_usage_corrupt}
    end.

public_usage(State) ->
    Usage = maps:get(usage, State, #{total_bytes => 0, scopes => #{}}),
    #{total_bytes => maps:get(total_bytes, Usage),
      scope_count => map_size(maps:get(scopes, Usage))}.

%% Bounded retention.  Only terminal jobs without a baseline and set
%% revisions without any job reference enter the chronological indexes.

prune_options(Scope, Options, State) when is_map(Options) ->
    Unknown = maps:keys(maps:without(
                         [before, limit, cursor, include_baselines], Options)),
    Before = maps:get(before, Options, undefined),
    Limit = maps:get(limit, Options, limit(max_prune_limit, State)),
    Cursor = maps:get(cursor, Options, <<>>),
    IncludeBaselines = maps:get(include_baselines, Options, false),
    Decoded = case is_binary(Cursor) andalso byte_size(Cursor) =< 525 of
        true -> decode_prune_cursor(Cursor);
        false -> error
    end,
    case {adk_eval_store:validate_scope(Scope), Unknown,
          is_integer(Before) andalso Before >= 0,
          is_integer(Limit) andalso Limit > 0 andalso
              Limit =< limit(max_prune_limit, State),
          is_boolean(IncludeBaselines), Decoded} of
        {ok, [], true, true, true, {ok, CursorValue0}} ->
            CursorValue = case {IncludeBaselines, Cursor, CursorValue0} of
                {true, <<>>, _} -> {baseline, {0, <<>>}};
                _ -> CursorValue0
            end,
            case not (element(1, CursorValue) =:= baseline andalso
                      not IncludeBaselines) of
                true -> {ok, Before, Limit, CursorValue,
                         IncludeBaselines};
                false -> {error, invalid_eval_prune_options}
            end;
        {ok, [_ | _], _, _, _, _} ->
            {error, {unknown_eval_prune_options, lists:sort(Unknown)}};
        {{error, _} = Error, _, _, _, _, _} -> Error;
        _ -> {error, invalid_eval_prune_options}
    end;
prune_options(_Scope, _Options, _State) ->
    {error, invalid_eval_prune_options}.

decode_prune_cursor(<<>>) -> {ok, {job, {0, <<>>}}};
decode_prune_cursor(<<$b, Time:64/unsigned-big, Len:16/unsigned-big,
                      Name:Len/binary>>) ->
    case adk_eval_store:valid_name(Name) of
        true -> {ok, {baseline, {Time, Name}}};
        false -> error
    end;
decode_prune_cursor(<<$j, Time:64/unsigned-big, Len:16/unsigned-big,
                      JobId:Len/binary>>) ->
    case adk_eval_store:valid_job_id(JobId) of
        true -> {ok, {job, {Time, JobId}}};
        false -> error
    end;
decode_prune_cursor(<<$s, Time:64/unsigned-big, IdLen:16/unsigned-big,
                      Id:IdLen/binary, VersionLen:16/unsigned-big,
                      Version:VersionLen/binary>>) ->
    case adk_eval_store:valid_name(Id) andalso
         adk_eval_store:valid_name(Version) of
        true -> {ok, {set, {Time, Id, Version}}};
        false -> error
    end;
decode_prune_cursor(_Cursor) -> error.

encode_prune_cursor({job, {Time, JobId}}) ->
    <<$j, Time:64/unsigned-big, (byte_size(JobId)):16/unsigned-big,
      JobId/binary>>;
encode_prune_cursor({baseline, {Time, Name}}) ->
    <<$b, Time:64/unsigned-big, (byte_size(Name)):16/unsigned-big,
      Name/binary>>;
encode_prune_cursor({set, {Time, Id, Version}}) ->
    <<$s, Time:64/unsigned-big, (byte_size(Id)):16/unsigned-big, Id/binary,
      (byte_size(Version)):16/unsigned-big, Version/binary>>.

prune_rows(Scope, Before, Limit, {baseline, Marker}, true, State0) ->
    {State1, Baselines, BaseBytes, Scanned1, Remaining, Last, Done} =
        prune_baseline_rows(Scope, Before, Limit, Marker, State0),
    case Done andalso Remaining > 0 of
        true ->
            {Reply0, State} = prune_rows(
                                Scope, Before, Remaining,
                                {job, {0, <<>>}}, true, State1),
            Reply = Reply0#{
                      baselines_deleted =>
                          maps:get(baselines_deleted, Reply0) + Baselines,
                      bytes_reclaimed =>
                          maps:get(bytes_reclaimed, Reply0) + BaseBytes,
                      scanned => maps:get(scanned, Reply0) + Scanned1},
            {Reply, State};
        false ->
            Cursor = case {Done, Remaining} of
                {true, 0} -> encode_prune_cursor({baseline, Last});
                _ -> next_prune_cursor(Done, Remaining, baseline, Last)
            end,
            {prune_reply(Baselines, 0, 0, BaseBytes, Scanned1, Cursor),
             State1}
    end;
prune_rows(Scope, Before, Limit, {job, Marker}, _IncludeBaselines, State0) ->
    {State1, Jobs, JobBytes, Scanned1, Remaining, LastJob, JobsDone} =
        prune_job_rows(Scope, Before, Limit, Marker, State0),
    case {JobsDone, Remaining > 0} of
        {true, true} ->
            {State2, Sets, SetBytes, Scanned2, Remaining2, LastSet,
             SetsDone} = prune_set_rows(
                           Scope, Before, Remaining, {0, <<>>, <<>>}, State1),
            Cursor = next_prune_cursor(
                       SetsDone, Remaining2, set, LastSet),
            {prune_reply(0, Jobs, Sets, JobBytes + SetBytes,
                         Scanned1 + Scanned2, Cursor), State2};
        _ ->
            Cursor = case {JobsDone, Remaining} of
                {true, 0} -> encode_prune_cursor({job, LastJob});
                _ -> next_prune_cursor(
                       JobsDone, Remaining, job, LastJob)
            end,
            {prune_reply(0, Jobs, 0, JobBytes, Scanned1, Cursor), State1}
    end;
prune_rows(Scope, Before, Limit, {set, Marker}, _IncludeBaselines, State0) ->
    {State, Sets, Bytes, Scanned, Remaining, Last, Done} =
        prune_set_rows(Scope, Before, Limit, Marker, State0),
    Cursor = next_prune_cursor(Done, Remaining, set, Last),
    {prune_reply(0, 0, Sets, Bytes, Scanned, Cursor), State}.

next_prune_cursor(true, _Remaining, _Kind, _Last) -> undefined;
next_prune_cursor(false, _Remaining, Kind, Last) ->
    encode_prune_cursor({Kind, Last}).

prune_reply(Baselines, Jobs, Sets, Bytes, Scanned, Cursor) ->
    #{baselines_deleted => Baselines, jobs_deleted => Jobs,
      set_revisions_deleted => Sets,
      bytes_reclaimed => Bytes, scanned => Scanned,
      next_cursor => Cursor, has_more => Cursor =/= undefined}.

prune_baseline_rows(Scope, Before, Limit, Marker, State0) ->
    Index = maps:get(Scope, maps:get(baseline_prune_index, State0),
                     gb_sets:empty()),
    Iter = gb_sets:iterator_from(Marker, Index),
    prune_baseline_iter(Iter, Scope, Before, Limit, Marker,
                        State0, 0, 0, 0).

prune_baseline_iter(_Iter, _Scope, _Before, 0, Last, State,
                    Count, Bytes, Scanned) ->
    {State, Count, Bytes, Scanned, 0, Last, false};
prune_baseline_iter(Iter0, Scope, Before, Remaining, Last, State0,
                    Count, Bytes, Scanned) ->
    case gb_sets:next(Iter0) of
        none -> {State0, Count, Bytes, Scanned, Remaining, Last, true};
        {Element, Iter} when Element =< Last ->
            prune_baseline_iter(Iter, Scope, Before, Remaining, Last,
                                State0, Count, Bytes, Scanned + 1);
        {{Time, _Name}, _Iter} when Time > Before ->
            {State0, Count, Bytes, Scanned + 1, Remaining, Last, true};
        {{_Time, Name} = Element, Iter} ->
            {Size, State} = delete_baseline({Scope, Name}, State0),
            prune_baseline_iter(
              Iter, Scope, Before, Remaining - 1, Element,
              State, Count + 1, Bytes + Size, Scanned + 1)
    end.

prune_job_rows(Scope, Before, Limit, Marker, State0) ->
    Index = maps:get(Scope, maps:get(job_prune_index, State0),
                     gb_sets:empty()),
    Iter = gb_sets:iterator_from(Marker, Index),
    prune_job_iter(Iter, Scope, Before, Limit, Marker,
                   State0, 0, 0, 0).

prune_job_iter(_Iter, _Scope, _Before, 0, Last, State,
               Count, Bytes, Scanned) ->
    {State, Count, Bytes, Scanned, 0, Last, false};
prune_job_iter(Iter0, Scope, Before, Remaining, Last, State0,
               Count, Bytes, Scanned) ->
    case gb_sets:next(Iter0) of
        none -> {State0, Count, Bytes, Scanned, Remaining, Last, true};
        {Element, Iter} when Element =< Last ->
            prune_job_iter(Iter, Scope, Before, Remaining, Last,
                           State0, Count, Bytes, Scanned + 1);
        {{Time, _JobId}, _Iter} when Time > Before ->
            {State0, Count, Bytes, Scanned + 1, Remaining, Last, true};
        {{_Time, JobId} = Element, Iter} ->
            {Size, State} = delete_job({Scope, JobId}, State0),
            prune_job_iter(Iter, Scope, Before, Remaining - 1, Element,
                           State, Count + 1, Bytes + Size, Scanned + 1)
    end.

prune_set_rows(Scope, Before, Limit, Marker, State0) ->
    Index = maps:get(Scope, maps:get(set_prune_index, State0),
                     gb_sets:empty()),
    Iter = gb_sets:iterator_from(Marker, Index),
    prune_set_iter(Iter, Scope, Before, Limit, Marker,
                   State0, 0, 0, 0).

prune_set_iter(_Iter, _Scope, _Before, 0, Last, State,
               Count, Bytes, Scanned) ->
    {State, Count, Bytes, Scanned, 0, Last, false};
prune_set_iter(Iter0, Scope, Before, Remaining, Last, State0,
               Count, Bytes, Scanned) ->
    case gb_sets:next(Iter0) of
        none -> {State0, Count, Bytes, Scanned, Remaining, Last, true};
        {Element, Iter} when Element =< Last ->
            prune_set_iter(Iter, Scope, Before, Remaining, Last,
                           State0, Count, Bytes, Scanned + 1);
        {{Time, _Id, _Version}, _Iter} when Time > Before ->
            {State0, Count, Bytes, Scanned + 1, Remaining, Last, true};
        {{_Time, Id, Version} = Element, Iter} ->
            {Size, State} = delete_set({Scope, Id, Version}, State0),
            prune_set_iter(Iter, Scope, Before, Remaining - 1, Element,
                           State, Count + 1, Bytes + Size, Scanned + 1)
    end.

delete_baseline({Scope, Name} = Key, State0) ->
    Baselines0 = maps:get(baselines, State0),
    Baseline = maps:get(Key, Baselines0),
    Size = stored_bytes(Baseline),
    State1 = remove_scope_index(
               baseline_prune_index, Scope,
               {maps:get(updated_at, Baseline), Name},
               State0#{baselines => maps:remove(Key, Baselines0)}),
    {ok, State2} = adjust_bytes(Scope, -Size, State1),
    {Size, decrement_job_ref(Baseline, State2)}.

delete_job({Scope, JobId} = Key, State0) ->
    Jobs0 = maps:get(jobs, State0),
    Job = maps:get(Key, Jobs0),
    Size = maps:get(Key, maps:get(job_charges, State0), stored_bytes(Job)),
    Charges = maps:remove(Key, maps:get(job_charges, State0)),
    State1 = remove_scope_index(
               job_index, Scope, {row_cursor(job, Job), Key},
               State0#{jobs => maps:remove(Key, Jobs0),
                       job_charges => Charges}),
    State2 = remove_scope_index(
               job_prune_index, Scope,
               {maps:get(updated_at, Job), JobId}, State1),
    {ok, State3} = adjust_bytes(Scope, -Size, State2),
    {Size, decrement_set_ref(Job, State3)}.

delete_set({Scope, _Id, _Version} = Key, State0) ->
    Sets0 = maps:get(sets, State0),
    Row = maps:get(Key, Sets0),
    Size = stored_bytes(Row),
    State1 = remove_scope_index(
               set_index, Scope, {row_cursor(set, Row), Key},
               State0#{sets => maps:remove(Key, Sets0)}),
    State2 = remove_scope_index(
               set_prune_index, Scope,
               {maps:get(created_at, Row), maps:get(id, Row),
                maps:get(version, Row)}, State1),
    {ok, State3} = adjust_bytes(Scope, -Size, State2),
    {Size, State3}.

recover_jobs_batch(Iterator, _Reason, State, Count, 0) ->
    {more, Iterator, State, Count};
recover_jobs_batch(Iterator0, Reason, State0, Count, Remaining) ->
    case maps:next(Iterator0) of
        none -> {done, State0, Count};
        {Key, Job0, Iterator} ->
            case maps:get(phase, Job0) of
                Phase when Phase =:= queued; Phase =:= running ->
                    Job = apply_transition(
                            Job0, failed,
                            #{reason => Reason, finished_at => now_ms()}),
                    Scope = maps:get(scope, Job),
                    case replace_job_bytes(Key, Scope, Job, State0) of
                        {ok, State1} ->
                            Jobs = (maps:get(jobs, State1))#{Key => Job},
                            State2 = maybe_index_terminal_job(
                                       Key, Job, State1#{jobs => Jobs}),
                            recover_jobs_batch(
                              Iterator, Reason, State2, Count + 1,
                              Remaining - 1);
                        {error, _} = Error -> Error
                    end;
                _ ->
                    recover_jobs_batch(
                      Iterator, Reason, State0, Count, Remaining - 1)
            end
    end.

valid_reason(Reason) ->
    is_binary(Reason) andalso byte_size(Reason) > 0 andalso
    byte_size(Reason) =< 4096.

safe_reason(Reason) ->
    Redacted = adk_secret_redactor:redact(Reason),
    case adk_json:normalize(Redacted) of
        {ok, Binary} when is_binary(Binary), byte_size(Binary) =< 4096 -> Binary;
        {ok, Value} ->
            Encoded = iolist_to_binary(io_lib:format("~0p", [Value])),
            binary:part(Encoded, 0, min(byte_size(Encoded), 4096));
        {error, _} -> <<"evaluation_failed">>
    end.

now_ms() -> erlang:system_time(millisecond).
