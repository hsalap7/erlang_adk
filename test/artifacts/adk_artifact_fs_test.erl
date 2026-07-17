-module(adk_artifact_fs_test).
-include_lib("eunit/include/eunit.hrl").

-define(SCOPE, {session, <<"artifact-app">>, <<"user-1">>, <<"session-1">>}).

durable_immutable_versions_test() ->
    with_root(
      fun(Root) ->
          {ok, First} = start(Root),
          {ok, Meta1} = adk_artifact_fs:put(
                          First, ?SCOPE, <<"reports/result.txt">>, <<"first">>,
                          #{mime_type => <<"text/plain">>,
                            metadata => #{<<"source">> => <<"test">>}}),
          ?assertEqual(1, maps:get(version, Meta1)),
          ok = adk_artifact_fs:stop(First),
          {ok, Second} = start(Root),
          {ok, Meta2} = adk_artifact_fs:put(
                          Second, ?SCOPE, <<"reports/result.txt">>, <<"second">>,
                          #{}),
          ?assertEqual(2, maps:get(version, Meta2)),
          {ok, One} = adk_artifact_fs:get(
                        Second, ?SCOPE, <<"reports/result.txt">>, 1),
          {ok, Latest} = adk_artifact_fs:get(
                           Second, ?SCOPE, <<"reports/result.txt">>, latest),
          ?assertEqual(<<"first">>, maps:get(data, One)),
          ?assertEqual(<<"second">>, maps:get(data, Latest)),
          {ok, Listed} = adk_artifact_fs:list(Second, ?SCOPE),
          ?assertEqual([1, 2], [maps:get(version, Item) || Item <- Listed]),
          ?assert(lists:all(fun(Item) -> not maps:is_key(data, Item) end,
                            Listed)),
          ok = adk_artifact_fs:stop(Second)
      end).

delete_never_reuses_a_version_test() ->
    with_service(
      fun(Pid, Root) ->
          Name = <<"versioned.bin">>,
          {ok, _} = adk_artifact_fs:put(Pid, ?SCOPE, Name, <<1>>, #{}),
          {ok, _} = adk_artifact_fs:put(Pid, ?SCOPE, Name, <<2>>, #{}),
          ok = adk_artifact_fs:delete(Pid, ?SCOPE, Name, latest),
          {ok, Remaining} = adk_artifact_fs:get(Pid, ?SCOPE, Name, latest),
          ?assertEqual(1, maps:get(version, Remaining)),
          ok = adk_artifact_fs:delete(Pid, ?SCOPE, Name, all),
          ?assertEqual({error, not_found},
                       adk_artifact_fs:get(Pid, ?SCOPE, Name, latest)),
          ok = adk_artifact_fs:stop(Pid),
          {ok, Restarted} = start(Root),
          {ok, NewMeta} = adk_artifact_fs:put(
                            Restarted, ?SCOPE, Name, <<3>>, #{}),
          ?assertEqual(3, maps:get(version, NewMeta)),
          ok = adk_artifact_fs:stop(Restarted)
      end, no_auto_stop).

scope_and_path_isolation_test() ->
    with_service(
      fun(Pid, _Root) ->
          Other = {session, <<"artifact-app">>, <<"user-2">>, <<"session-1">>},
          Name = <<"nested/café.txt"/utf8>>,
          {ok, _} = adk_artifact_fs:put(Pid, ?SCOPE, Name, <<1>>, #{}),
          {ok, _} = adk_artifact_fs:put(Pid, Other, Name, <<2>>, #{}),
          {ok, This} = adk_artifact_fs:get(Pid, ?SCOPE, Name, latest),
          {ok, That} = adk_artifact_fs:get(Pid, Other, Name, latest),
          ?assertEqual(<<1>>, maps:get(data, This)),
          ?assertEqual(<<2>>, maps:get(data, That)),
          ?assertEqual({error, invalid_name},
                       adk_artifact_fs:put(Pid, ?SCOPE, <<"../escape">>,
                                           <<>>, #{}))
      end).

two_instances_allocate_unique_versions_test() ->
    with_root(
      fun(Root) ->
          {ok, Left} = start(Root),
          {ok, Right} = start(Root),
          Parent = self(),
          Count = 40,
          [spawn(fun() ->
                     Service = case Index rem 2 of 0 -> Left; _ -> Right end,
                     Result = adk_artifact_fs:put(
                                Service, ?SCOPE, <<"concurrent.bin">>,
                                integer_to_binary(Index), #{}),
                     Parent ! {put_result, Result}
                 end) || Index <- lists:seq(1, Count)],
          Versions = [receive
                          {put_result, {ok, Meta}} -> maps:get(version, Meta)
                      after 5000 -> timeout
                      end || _ <- lists:seq(1, Count)],
          ?assertEqual(lists:seq(1, Count), lists:sort(Versions)),
          ok = adk_artifact_fs:stop(Left),
          ok = adk_artifact_fs:stop(Right)
      end).

two_instances_share_strict_name_capacity_test() ->
    with_root(
      fun(Root) ->
          Config = #{root => Root, max_scan_entries => 4,
                     max_page_limit => 4, legacy_list_limit => 4},
          {ok, Left} = adk_artifact_fs:start_link(Config),
          {ok, Right} = adk_artifact_fs:start_link(Config),
          Parent = self(),
          Calls = [{Left, <<"alpha">>},
                   {Right, <<"beta">>},
                   {Left, <<"gamma">>}],
          [spawn(fun() ->
               Parent ! {capacity_put,
                         adk_artifact_fs:put(
                           Service, ?SCOPE, Name, Name, #{})}
           end) || {Service, Name} <- Calls],
          Results = [receive
                         {capacity_put, Result} -> Result
                     after 2000 -> timeout
                     end || _ <- Calls],
          try
              ?assertEqual(2, length([ok || {ok, _} <- Results])),
              ?assertEqual(
                 1,
                 length([capacity ||
                            {error, artifact_name_capacity_reached}
                                <- Results])),
              {ok, #{scope := ?SCOPE, items := Names,
                     next_cursor := undefined}} =
                  adk_artifact_fs:list_names(
                    Right, ?SCOPE, #{limit => 4}),
              ?assertEqual(2, length(Names))
          after
              _ = adk_artifact_fs:stop(Left),
              _ = adk_artifact_fs:stop(Right)
          end
      end).

capabilities_and_paginated_listing_test() ->
    with_service(
      fun(Pid, _Root) ->
          {ok, Capabilities} = adk_artifact_fs:capabilities(Pid),
          ?assertEqual(1, maps:get(api_version, Capabilities)),
          ?assertEqual(metadata_rename,
                       maps:get(atomic_publication, Capabilities)),
          [begin
               {ok, _} = adk_artifact_fs:put(Pid, ?SCOPE, Name, <<1>>, #{}),
               {ok, _} = adk_artifact_fs:put(Pid, ?SCOPE, Name, <<2>>, #{})
           end || Name <- [<<"a.txt">>, <<"b.txt">>, <<"c.txt">>]],
          {ok, #{scope := ?SCOPE,
                 items := [<<"a.txt">>, <<"b.txt">>],
                 next_cursor := <<"b.txt">>}} =
              adk_artifact_fs:list_names(Pid, ?SCOPE, #{limit => 2}),
          {ok, #{scope := ?SCOPE, items := [<<"c.txt">>],
                 next_cursor := undefined}} =
              adk_artifact_fs:list_names(
                Pid, ?SCOPE, #{limit => 2, cursor => <<"b.txt">>}),
          {ok, #{items := [First], next_cursor := 1}} =
              adk_artifact_fs:list_versions(
                Pid, ?SCOPE, <<"a.txt">>, #{limit => 1}),
          ?assertEqual(1, maps:get(version, First)),
          ?assert(not maps:is_key(data, First)),
          {ok, #{items := [Second], next_cursor := undefined}} =
              adk_artifact_fs:list_versions(
                Pid, ?SCOPE, <<"a.txt">>, #{limit => 1, cursor => 1}),
          ?assertEqual(2, maps:get(version, Second))
      end).

legacy_list_is_explicitly_bounded_test() ->
    with_root(
      fun(Root) ->
          {ok, Pid} = adk_artifact_fs:start_link(
                        #{root => Root, legacy_list_limit => 1}),
          try
              {ok, _} = adk_artifact_fs:put(
                          Pid, ?SCOPE, <<"a">>, <<>>, #{}),
              {ok, _} = adk_artifact_fs:put(
                          Pid, ?SCOPE, <<"b">>, <<>>, #{}),
              ?assertEqual({error, result_limit_exceeded},
                           adk_artifact_fs:list(Pid, ?SCOPE)),
              {ok, #{scope := ?SCOPE, items := [<<"a">>],
                     next_cursor := <<"a">>}} =
                  adk_artifact_fs:list_names(Pid, ?SCOPE, #{limit => 1})
          after
              _ = adk_artifact_fs:stop(Pid)
          end
      end).

expired_queued_put_never_publishes_test() ->
    with_service(
      fun(Pid, _Root) ->
          ok = sys:suspend(Pid),
          ?assertEqual({error, timeout},
                       adk_artifact_fs:put(
                         Pid, ?SCOPE, <<"late.bin">>, <<"late">>, #{},
                         #{timeout_ms => 20})),
          ok = sys:resume(Pid),
          timer:sleep(20),
          ?assertEqual({error, not_found},
                       adk_artifact_fs:get(
                         Pid, ?SCOPE, <<"late.bin">>, latest)),
          {ok, #{version := 1}} = adk_artifact_fs:put(
                                     Pid, ?SCOPE, <<"late.bin">>,
                                     <<"on-time">>, #{})
      end).

interrupted_staging_is_invisible_and_repairable_test() ->
    with_service(
      fun(Pid, Root) ->
          Name = <<"crash.bin">>,
          {ok, #{version := 1}} = adk_artifact_fs:put(
                                     Pid, ?SCOPE, Name, <<"committed">>, #{}),
          Reserve = artifact_path(Root, ?SCOPE, Name, 2, ".reserve"),
          Data = artifact_path(Root, ?SCOPE, Name, 2, ".data"),
          MetaTemp = artifact_path(
                       Root, ?SCOPE, Name, 2, ".meta.tmp-crashed-writer"),
          ok = file:write_file(Reserve, <<>>, [binary, exclusive, sync]),
          ok = file:write_file(Data, <<"orphan">>, [binary, exclusive, sync]),
          ok = file:write_file(MetaTemp, <<"partial">>,
                               [binary, exclusive, sync]),
          {ok, #{version := 1}} = adk_artifact_fs:get(
                                    Pid, ?SCOPE, Name, latest),
          {ok, #{items := [Only], next_cursor := undefined}} =
              adk_artifact_fs:list_versions(Pid, ?SCOPE, Name, #{}),
          ?assertEqual(1, maps:get(version, Only)),
          {ok, Repair} = adk_artifact_fs:repair(
                           Pid, #{limit => 100, min_age_ms => 0}),
          ?assertEqual(2, maps:get(removed, Repair)),
          ?assert(maps:get(reservations_preserved, Repair) >= 2),
          ?assertEqual(false, filelib:is_regular(Data)),
          ?assertEqual(false, filelib:is_regular(MetaTemp)),
          ?assertEqual(true, filelib:is_regular(Reserve)),
          {ok, #{version := 3}} = adk_artifact_fs:put(
                                     Pid, ?SCOPE, Name, <<"after-crash">>, #{})
      end).

strict_structural_limits_test() ->
    with_service(
      fun(Pid, _Root) ->
          LongName = binary:copy(<<"n">>, 1025),
          LongScope = {app, binary:copy(<<"a">>, 257)},
          LargeMetadata = #{<<"value">> => binary:copy(<<"x">>, 17000)},
          ?assertEqual({error, invalid_name},
                       adk_artifact_fs:put(
                         Pid, ?SCOPE, LongName, <<>>, #{})),
          ?assertMatch({error, {invalid_scope_part, app_name}},
                       adk_artifact_fs:put(
                         Pid, LongScope, <<"name">>, <<>>, #{})),
          ?assertEqual({error, invalid_metadata},
                       adk_artifact_fs:put(
                         Pid, ?SCOPE, <<"large-meta">>, <<>>,
                         #{metadata => LargeMetadata}))
      end).

lifetime_version_capacity_fails_before_scan_exhaustion_test() ->
    with_root(
      fun(Root) ->
          Config = #{root => Root, max_scan_entries => 6,
                     max_page_limit => 2, legacy_list_limit => 2},
          {ok, Pid} = adk_artifact_fs:start_link(Config),
          Name = <<"bounded-history.bin">>,
          try
              {ok, #{version := 1}} = adk_artifact_fs:put(
                                         Pid, ?SCOPE, Name, <<"one">>, #{}),
              {ok, #{version := 2}} = adk_artifact_fs:put(
                                         Pid, ?SCOPE, Name, <<"two">>, #{}),
              ?assertEqual(
                 {error, artifact_version_capacity_reached},
                 adk_artifact_fs:put(
                   Pid, ?SCOPE, Name, <<"three">>, #{})),
              {ok, Capabilities} = adk_artifact_fs:capabilities(Pid),
              ?assertEqual(
                 2,
                 maps:get(max_lifetime_versions_per_name,
                          maps:get(quotas, Capabilities))),
              ok = adk_artifact_fs:delete(Pid, ?SCOPE, Name, all),
              ?assertEqual(
                 {error, artifact_version_capacity_reached},
                 adk_artifact_fs:put(
                   Pid, ?SCOPE, Name, <<"not-reused">>, #{}))
          after
              _ = adk_artifact_fs:stop(Pid)
          end,
          {ok, Restarted} = adk_artifact_fs:start_link(Config),
          try
              ?assertEqual(
                 {error, artifact_version_capacity_reached},
                 adk_artifact_fs:put(
                   Restarted, ?SCOPE, Name, <<"still-bounded">>, #{}))
          after
              _ = adk_artifact_fs:stop(Restarted)
          end
      end).

lifetime_scope_and_name_capacity_preserve_bounded_listing_test() ->
    with_root(
      fun(Root) ->
          Config = #{root => Root, max_scan_entries => 4,
                     max_page_limit => 4, legacy_list_limit => 4},
          {ok, Pid} = adk_artifact_fs:start_link(Config),
          ScopeTwo = {session, <<"fs-app">>, <<"fs-user">>, <<"two">>},
          ScopeThree = {session, <<"fs-app">>, <<"fs-user">>, <<"three">>},
          try
              {ok, _} = adk_artifact_fs:put(
                          Pid, ?SCOPE, <<"first">>, <<"one">>, #{}),
              {ok, _} = adk_artifact_fs:put(
                          Pid, ?SCOPE, <<"second">>, <<"two">>, #{}),
              ?assertEqual(
                 {error, artifact_name_capacity_reached},
                 adk_artifact_fs:put(
                   Pid, ?SCOPE, <<"third">>, <<"three">>, #{})),
              {ok, #{scope := ?SCOPE, items := Names}} =
                  adk_artifact_fs:list_names(
                    Pid, ?SCOPE, #{limit => 4}),
              ?assertEqual([<<"first">>, <<"second">>], Names),
              {ok, _} = adk_artifact_fs:put(
                          Pid, ScopeTwo, <<"only">>, <<"two">>, #{}),
              ?assertEqual(
                 {error, artifact_scope_capacity_reached},
                 adk_artifact_fs:put(
                   Pid, ScopeThree, <<"only">>, <<"three">>, #{})),
              {ok, Capabilities} = adk_artifact_fs:capabilities(Pid),
              Quotas = maps:get(quotas, Capabilities),
              ?assertEqual(2, maps:get(max_lifetime_scopes, Quotas)),
              ?assertEqual(2,
                           maps:get(max_lifetime_names_per_scope, Quotas))
          after
              _ = adk_artifact_fs:stop(Pid)
          end,
          {ok, Restarted} = adk_artifact_fs:start_link(Config),
          try
              ?assertEqual(
                 {error, artifact_name_capacity_reached},
                 adk_artifact_fs:put(
                   Restarted, ?SCOPE, <<"still-third">>, <<>>, #{})),
              ?assertEqual(
                 {error, artifact_scope_capacity_reached},
                 adk_artifact_fs:put(
                   Restarted, ScopeThree, <<"still-third">>, <<>>, #{}))
          after
              _ = adk_artifact_fs:stop(Restarted)
          end
      end).

size_config_and_invalid_input_test() ->
    with_root(
      fun(Root) ->
          {ok, Pid} = adk_artifact_fs:start_link(
                        #{root => Root, max_artifact_bytes => 2}),
          ?assertEqual({error, artifact_too_large},
                       adk_artifact_fs:put(Pid, ?SCOPE, <<"large.bin">>,
                                           <<1, 2, 3>>, #{})),
          ?assertEqual({error, invalid_scope},
                       adk_artifact_fs:put(Pid, invalid, <<"a">>, <<>>, #{})),
          ?assertEqual({error, invalid_metadata},
                       adk_artifact_fs:put(
                         Pid, ?SCOPE, <<"a">>, <<>>,
                         #{metadata => #{atom_key => unsafe}})),
          ok = adk_artifact_fs:stop(Pid),
          ?assertEqual({error, unavailable},
                       adk_artifact_fs:get(Pid, ?SCOPE, <<"a">>, latest))
      end).

tampered_data_fails_closed_test() ->
    with_service(
      fun(Pid, Root) ->
          Name = <<"tamper.bin">>,
          {ok, #{version := 1}} = adk_artifact_fs:put(
                                     Pid, ?SCOPE, Name, <<"authentic">>, #{}),
          DataPath = artifact_path(Root, ?SCOPE, Name, 1, ".data"),
          ok = file:write_file(DataPath, <<"tampered">>, [binary]),
          ?assertEqual({error, corrupt_artifact},
                       adk_artifact_fs:get(Pid, ?SCOPE, Name, 1)),
          MetaPath = artifact_path(Root, ?SCOPE, Name, 1, ".meta"),
          ok = file:write_file(MetaPath, <<"not-an-erlang-term">>, [binary]),
          ?assertEqual({error, corrupt_artifact},
                       adk_artifact_fs:list(Pid, ?SCOPE))
      end).

symlink_root_is_rejected_test() ->
    with_root(
      fun(Root) ->
          Target = Root ++ "-target",
          ok = file:make_dir(Target),
          Link = Root ++ "-link",
          ok = file:make_symlink(Target, Link),
          Result = adk_artifact_fs:start_link(#{root => Link}),
          ?assertMatch({error, _}, Result),
          ok = file:delete(Link),
          ok = file:del_dir(Target)
      end).

start(Root) ->
    adk_artifact_fs:start_link(#{root => Root}).

with_service(Test) ->
    with_service(Test, auto_stop).

with_service(Test, StopMode) ->
    with_root(
      fun(Root) ->
          {ok, Pid} = start(Root),
          try Test(Pid, Root)
          after
              case StopMode of
                  auto_stop -> _ = adk_artifact_fs:stop(Pid);
                  no_auto_stop -> ok
              end
          end
      end).

with_root(Test) ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Root = filename:join(
             Base, "erlang-adk-artifact-" ++
                   integer_to_list(erlang:unique_integer([positive]))),
    try Test(Root)
    after
        _ = file:del_dir_r(Root),
        _ = file:del_dir_r(Root ++ "-target"),
        _ = file:delete(Root ++ "-link")
    end.

artifact_path(Root, Scope, Name, Version, Suffix) ->
    ScopeHash = hash_term(Scope),
    NameHash = hash_term(Name),
    filename:join([Root, "v1", "scopes", ScopeHash, "names", NameHash,
                   "v-" ++ integer_to_list(Version) ++ Suffix]).

hash_term(Term) ->
    binary_to_list(binary:encode_hex(
                     crypto:hash(sha256, term_to_binary(Term)), lowercase)).
