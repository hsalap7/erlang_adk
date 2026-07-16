-module(adk_v05_stress_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([thousand_scoped_storage_mutations/1,
         cache_single_flight_contention_and_cleanup/1]).

-define(APP, <<"adk_v05_stress">>).
-define(SESSION, <<"bounded-concurrency">>).
-define(SCOPE_COUNT, 16).
-define(MIXED_ITEMS, 500).
-define(MIXED_BATCH_SIZE, 40).
-define(CACHE_SCOPES, 4).
-define(CACHE_CALLERS, 128).

all() ->
    [thousand_scoped_storage_mutations,
     cache_single_flight_contention_and_cleanup].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Config.

end_per_suite(_Config) ->
    ok.

%% Five hundred work items each commit one artifact and one memory entry.  The
%% calls run in bounded batches so the test exercises mailbox contention
%% without making success depend on an unbounded client-side message burst.
thousand_scoped_storage_mutations(_Config) ->
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    {ok, MemoryPid} = adk_memory_ets:start_link(#{}),
    try
        Results = run_batched(
                    lists:seq(1, ?MIXED_ITEMS), ?MIXED_BATCH_SIZE,
                    fun(Id) ->
                        write_scoped_item(ArtifactPid, MemoryPid, Id)
                    end),
        ?MIXED_ITEMS = length(Results),
        lists:foreach(fun assert_scoped_write/1, Results),
        lists:foreach(
          fun(Index) ->
              verify_scope(ArtifactPid, MemoryPid, Index)
          end, lists:seq(1, ?SCOPE_COUNT)),
        WrongArtifactScope = artifact_scope(2),
        {error, not_found} = adk_artifact_ets:get(
                               ArtifactPid, WrongArtifactScope,
                               artifact_name(1), latest),
        {ok, []} = adk_memory_ets:search(
                     MemoryPid, memory_scope(2),
                     <<"exclusive_scope_one_marker">>, #{limit => 50}),
        ok
    after
        ok = adk_memory_ets:stop(MemoryPid),
        ok = adk_artifact_ets:stop(ArtifactPid)
    end.

cache_single_flight_contention_and_cleanup(_Config) ->
    ok = adk_context_cache_fake_provider:reset({delay, 75}),
    {ok, Cache} = adk_context_cache:start_link(
                    #{max_entries => 8,
                      max_waiters_per_key => 64,
                      create_timeout_ms => 2000,
                      delete_timeout_ms => 1000}),
    try
        Results = run_batched(
                    lists:seq(1, ?CACHE_CALLERS), ?CACHE_CALLERS,
                    fun(Index) ->
                        ScopeIndex = ((Index - 1) rem ?CACHE_SCOPES) + 1,
                        adk_context_cache:acquire(
                          Cache, adk_context_cache_fake_provider,
                          cache_scope(ScopeIndex), cache_prefix(),
                          #{deadline_ms =>
                                erlang:monotonic_time(millisecond) + 5000})
                    end),
        Leases = [Lease || {ok, Lease, _Metadata} <- Results],
        ?CACHE_CALLERS = length(Leases),
        ?CACHE_SCOPES = length(lists:usort(Leases)),
        #{creates := ?CACHE_SCOPES} =
            adk_context_cache_fake_provider:stats(),
        {ok, #{<<"entries">> := ?CACHE_SCOPES,
               <<"in_flight">> := 0,
               <<"waiters">> := 0}} = adk_context_cache:status(Cache),

        %% Explicit shutdown owns provider cleanup.  Resource names stay
        %% private, while the fake provider lets this test count deletions.
        ok = adk_context_cache:stop(Cache),
        ok = await_provider_deletes(?CACHE_SCOPES, 2000),
        #{creates := ?CACHE_SCOPES, deletes := ?CACHE_SCOPES} =
            adk_context_cache_fake_provider:stats(),
        ok
    after
        case is_process_alive(Cache) of
            true -> _ = catch adk_context_cache:stop(Cache);
            false -> ok
        end
    end.

write_scoped_item(ArtifactPid, MemoryPid, Id) ->
    ScopeIndex = ((Id - 1) rem ?SCOPE_COUNT) + 1,
    Data = item_content(Id),
    ArtifactResult = adk_artifact_ets:put(
                       ArtifactPid, artifact_scope(ScopeIndex),
                       artifact_name(Id), Data,
                       #{mime_type => <<"text/plain">>}),
    MemoryResult = adk_memory_ets:add_entry(
                     MemoryPid, memory_scope(ScopeIndex),
                     #{content => Data,
                       metadata => #{<<"scope_index">> => ScopeIndex}},
                     #{idempotency_key =>
                           <<"stress-entry-", (integer_to_binary(Id))/binary>>}),
    {Id, ScopeIndex, ArtifactResult, MemoryResult}.

assert_scoped_write(
  {_Id, _ScopeIndex,
   {ok, #{version := 1}},
   {ok, #{id := Id, scope := {user, ?APP, _User}}}}) when is_binary(Id) ->
    ok;
assert_scoped_write(Unexpected) ->
    ct:fail({unexpected_scoped_write_result, Unexpected}).

verify_scope(ArtifactPid, MemoryPid, ScopeIndex) ->
    Expected = expected_items(ScopeIndex),
    ArtifactScope = artifact_scope(ScopeIndex),
    {ok, #{scope := ArtifactScope, items := Names,
           next_cursor := undefined}} =
        adk_artifact_ets:list_names(
          ArtifactPid, ArtifactScope, #{limit => 1000}),
    Expected = length(Names),
    {ok, Hits} = adk_memory_ets:search(
                   MemoryPid, memory_scope(ScopeIndex),
                   <<"stress_token">>, #{limit => 50}),
    Expected = length(Hits),
    true = lists:all(
             fun(#{scope := Scope}) -> Scope =:= memory_scope(ScopeIndex) end,
             Hits),
    ok.

expected_items(ScopeIndex) ->
    length([Id || Id <- lists:seq(1, ?MIXED_ITEMS),
                  ((Id - 1) rem ?SCOPE_COUNT) + 1 =:= ScopeIndex]).

artifact_scope(ScopeIndex) ->
    {session, ?APP, user(ScopeIndex), ?SESSION}.

memory_scope(ScopeIndex) ->
    {user, ?APP, user(ScopeIndex)}.

cache_scope(ScopeIndex) ->
    #{app => ?APP,
      user => user(ScopeIndex),
      model => <<"gemini-3.1-flash-lite">>,
      policy => #{mode => stress, version => 1}}.

cache_prefix() ->
    #{<<"system_instruction">> => <<"Stable bounded stress prefix">>,
      <<"contents">> =>
          [#{<<"role">> => <<"user">>,
             <<"parts">> => [#{<<"text">> => <<"shared prefix">>}]}]}.

artifact_name(Id) ->
    <<"items/item-", (integer_to_binary(Id))/binary, ".txt">>.

item_content(1) ->
    <<"stress_token exclusive_scope_one_marker item_1">>;
item_content(Id) ->
    <<"stress_token item_", (integer_to_binary(Id))/binary>>.

user(Index) ->
    <<"stress-user-", (integer_to_binary(Index))/binary>>.

run_batched([], _BatchSize, _Fun) ->
    [];
run_batched(Items, BatchSize, Fun) ->
    {Batch, Rest} = lists:split(min(BatchSize, length(Items)), Items),
    Parent = self(),
    Refs = [begin
                Ref = make_ref(),
                spawn(fun() ->
                    Result = try Fun(Item) of
                        Value -> Value
                    catch
                        Class:Reason:Stacktrace ->
                            {worker_exception, Class, Reason, Stacktrace}
                    end,
                    Parent ! {Ref, Result}
                end),
                Ref
            end || Item <- Batch],
    Results = [receive
                   {Ref, Result} -> Result
               after 15000 ->
                   ct:fail({stress_worker_timeout, Ref})
               end || Ref <- Refs],
    Results ++ run_batched(Rest, BatchSize, Fun).

await_provider_deletes(Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_provider_deletes_until(Expected, Deadline).

await_provider_deletes_until(Expected, Deadline) ->
    case adk_context_cache_fake_provider:stats() of
        #{deletes := Expected} -> ok;
        #{deletes := Actual} when Actual < Expected ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, {provider_cleanup_timeout, Expected, Actual}};
                false ->
                    receive after 10 -> ok end,
                    await_provider_deletes_until(Expected, Deadline)
            end;
        #{deletes := Actual} ->
            {error, {unexpected_provider_delete_count, Expected, Actual}}
    end.
