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
