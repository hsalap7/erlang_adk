-module(adk_artifact_ets_test).
-include_lib("eunit/include/eunit.hrl").

-define(SCOPE, {session, <<"artifact-app">>, <<"user-1">>, <<"session-1">>}).

immutable_versions_and_metadata_test() ->
    with_service(
      fun(Pid) ->
          {ok, FirstMeta} = adk_artifact_ets:put(
                              Pid, ?SCOPE, <<"reports/result.txt">>,
                              <<"first">>,
                              #{mime_type => <<"text/plain">>,
                                metadata => #{<<"source">> => <<"test">>}}),
          ?assertEqual(1, maps:get(version, FirstMeta)),
          ?assertEqual(<<"text/plain">>, maps:get(mime_type, FirstMeta)),
          ?assertEqual(5, maps:get(size, FirstMeta)),
          ?assertEqual(
             binary:encode_hex(crypto:hash(sha256, <<"first">>), lowercase),
             maps:get(digest, FirstMeta)),

          {ok, SecondMeta} = adk_artifact_ets:put(
                               Pid, ?SCOPE, <<"reports/result.txt">>,
                               <<"second">>, #{}),
          ?assertEqual(2, maps:get(version, SecondMeta)),
          {ok, First} = adk_artifact_ets:get(
                          Pid, ?SCOPE, <<"reports/result.txt">>, 1),
          {ok, Latest} = adk_artifact_ets:get(
                           Pid, ?SCOPE, <<"reports/result.txt">>, latest),
          ?assertEqual(<<"first">>, maps:get(data, First)),
          ?assertEqual(<<"second">>, maps:get(data, Latest)),
          ?assertEqual(2, maps:get(version, Latest)),
          {ok, Listed} = adk_artifact_ets:list(Pid, ?SCOPE),
          ?assertEqual([1, 2], [maps:get(version, Item) || Item <- Listed]),
          ?assert(lists:all(
                    fun(Item) -> not maps:is_key(data, Item) end, Listed))
      end).

scope_isolation_test() ->
    with_service(
      fun(Pid) ->
          OtherScope = {session, <<"artifact-app">>, <<"user-2">>,
                        <<"session-1">>},
          {ok, _} = adk_artifact_ets:put(
                      Pid, ?SCOPE, <<"same.bin">>, <<1>>, #{}),
          {ok, _} = adk_artifact_ets:put(
                      Pid, OtherScope, <<"same.bin">>, <<2>>, #{}),
          {ok, ThisArtifact} = adk_artifact_ets:get(
                                 Pid, ?SCOPE, <<"same.bin">>, latest),
          {ok, OtherArtifact} = adk_artifact_ets:get(
                                  Pid, OtherScope, <<"same.bin">>, latest),
          ?assertEqual(<<1>>, maps:get(data, ThisArtifact)),
          ?assertEqual(<<2>>, maps:get(data, OtherArtifact)),
          {ok, [_]} = adk_artifact_ets:list(Pid, ?SCOPE),
          {ok, [_]} = adk_artifact_ets:list(Pid, OtherScope)
      end).

delete_does_not_reuse_versions_test() ->
    with_service(
      fun(Pid) ->
          Name = <<"versioned.bin">>,
          {ok, _} = adk_artifact_ets:put(Pid, ?SCOPE, Name, <<1>>, #{}),
          {ok, _} = adk_artifact_ets:put(Pid, ?SCOPE, Name, <<2>>, #{}),
          ok = adk_artifact_ets:delete(Pid, ?SCOPE, Name, latest),
          {ok, Latest} = adk_artifact_ets:get(Pid, ?SCOPE, Name, latest),
          ?assertEqual(1, maps:get(version, Latest)),
          ok = adk_artifact_ets:delete(Pid, ?SCOPE, Name, all),
          ?assertEqual({error, not_found},
                       adk_artifact_ets:get(Pid, ?SCOPE, Name, latest)),
          {ok, NewMeta} = adk_artifact_ets:put(
                            Pid, ?SCOPE, Name, <<3>>, #{}),
          ?assertEqual(3, maps:get(version, NewMeta))
      end).

concurrent_puts_receive_unique_versions_test() ->
    with_service(
      fun(Pid) ->
          Parent = self(),
          Name = <<"concurrent.bin">>,
          Count = 32,
          [spawn(fun() ->
                     Result = adk_artifact_ets:put(
                                Pid, ?SCOPE, Name,
                                integer_to_binary(Index), #{}),
                     Parent ! {artifact_put, Result}
                 end) || Index <- lists:seq(1, Count)],
          Versions = [receive
                          {artifact_put, {ok, Meta}} -> maps:get(version, Meta)
                      after 2000 -> timeout
                      end || _ <- lists:seq(1, Count)],
          ?assertEqual(lists:seq(1, Count), lists:sort(Versions))
      end).

capabilities_and_paginated_listing_test() ->
    with_service(
      fun(Pid) ->
          {ok, Capabilities} = adk_artifact_ets:capabilities(Pid),
          ?assertEqual(1, maps:get(api_version, Capabilities)),
          ?assertEqual(true, maps:get(deadlines, Capabilities)),
          [begin
               {ok, _} = adk_artifact_ets:put(
                           Pid, ?SCOPE, Name, <<"one">>, #{}),
               {ok, _} = adk_artifact_ets:put(
                           Pid, ?SCOPE, Name, <<"two">>, #{})
           end || Name <- [<<"a.txt">>, <<"b.txt">>, <<"c.txt">>]],
          {ok, #{scope := ?SCOPE,
                 items := [<<"a.txt">>, <<"b.txt">>],
                 next_cursor := <<"b.txt">>}} =
              adk_artifact_ets:list_names(Pid, ?SCOPE, #{limit => 2}),
          {ok, #{scope := ?SCOPE, items := [<<"c.txt">>],
                 next_cursor := undefined}} =
              adk_artifact_ets:list_names(
                Pid, ?SCOPE, #{limit => 2, cursor => <<"b.txt">>}),
          {ok, #{items := [First], next_cursor := 1}} =
              adk_artifact_ets:list_versions(
                Pid, ?SCOPE, <<"a.txt">>, #{limit => 1}),
          ?assertEqual(1, maps:get(version, First)),
          ?assert(not maps:is_key(data, First)),
          {ok, #{items := [Second], next_cursor := undefined}} =
              adk_artifact_ets:list_versions(
                Pid, ?SCOPE, <<"a.txt">>, #{limit => 1, cursor => 1}),
          ?assertEqual(2, maps:get(version, Second)),
          ?assertEqual({error, invalid_limit},
                       adk_artifact_ets:list_names(
                         Pid, ?SCOPE, #{limit => 1001}))
      end).

item_scope_total_and_count_quotas_test() ->
    {ok, Pid} = adk_artifact_ets:start_link(
                  #{max_artifact_bytes => 3,
                    max_scope_bytes => 4,
                    max_total_bytes => 5,
                    max_scope_artifacts => 2,
                    max_total_artifacts => 3}),
    Other = {session, <<"artifact-app">>, <<"user-2">>, <<"session-1">>},
    try
        ?assertEqual({error, artifact_too_large},
                     adk_artifact_ets:put(
                       Pid, ?SCOPE, <<"large">>, <<1, 2, 3, 4>>, #{})),
        {ok, _} = adk_artifact_ets:put(
                    Pid, ?SCOPE, <<"one">>, <<1, 2, 3>>, #{}),
        ?assertEqual({error, {quota_exceeded, max_scope_bytes}},
                     adk_artifact_ets:put(
                       Pid, ?SCOPE, <<"two">>, <<4, 5>>, #{})),
        {ok, _} = adk_artifact_ets:put(
                    Pid, Other, <<"other">>, <<4, 5>>, #{}),
        ?assertEqual({error, {quota_exceeded, max_total_bytes}},
                     adk_artifact_ets:put(
                       Pid, Other, <<"more">>, <<6>>, #{})),
        ok = adk_artifact_ets:delete(Pid, ?SCOPE, <<"one">>, all),
        {ok, _} = adk_artifact_ets:put(
                    Pid, Other, <<"more">>, <<6>>, #{}),
        ?assertEqual({error, {quota_exceeded, max_scope_artifacts}},
                     adk_artifact_ets:put(
                       Pid, Other, <<"third">>, <<>>, #{}))
    after
        _ = adk_artifact_ets:stop(Pid)
    end.

legacy_list_is_explicitly_bounded_test() ->
    {ok, Pid} = adk_artifact_ets:start_link(#{legacy_list_limit => 1}),
    try
        {ok, _} = adk_artifact_ets:put(Pid, ?SCOPE, <<"a">>, <<>>, #{}),
        {ok, _} = adk_artifact_ets:put(Pid, ?SCOPE, <<"b">>, <<>>, #{}),
        ?assertEqual({error, result_limit_exceeded},
                     adk_artifact_ets:list(Pid, ?SCOPE)),
        {ok, #{scope := ?SCOPE, items := [<<"a">>],
               next_cursor := <<"a">>}} =
            adk_artifact_ets:list_names(Pid, ?SCOPE, #{limit => 1})
    after
        _ = adk_artifact_ets:stop(Pid)
    end.

expired_queued_put_never_commits_test() ->
    with_service(
      fun(Pid) ->
          ok = sys:suspend(Pid),
          try
              ?assertEqual({error, timeout},
                           adk_artifact_ets:put(
                             Pid, ?SCOPE, <<"late.bin">>, <<"late">>, #{},
                             #{timeout_ms => 20}))
          after
              ok = sys:resume(Pid)
          end,
          ?assertEqual({error, not_found},
                       adk_artifact_ets:get(
                         Pid, ?SCOPE, <<"late.bin">>, latest)),
          {ok, #{version := 1}} = adk_artifact_ets:put(
                                     Pid, ?SCOPE, <<"late.bin">>,
                                     <<"on-time">>, #{})
      end).

strict_structural_limits_test() ->
    with_service(
      fun(Pid) ->
          LongName = binary:copy(<<"n">>, 1025),
          LongScope = {app, binary:copy(<<"a">>, 257)},
          LargeMetadata = #{<<"value">> => binary:copy(<<"x">>, 17000)},
          ManyMetadata = maps:from_list(
                           [{integer_to_binary(I), I}
                            || I <- lists:seq(1, 129)]),
          ?assertEqual({error, invalid_name},
                       adk_artifact_ets:put(
                         Pid, ?SCOPE, LongName, <<>>, #{})),
          ?assertMatch({error, {invalid_scope_part, app_name}},
                       adk_artifact_ets:put(
                         Pid, LongScope, <<"name">>, <<>>, #{})),
          ?assertEqual({error, invalid_metadata},
                       adk_artifact_ets:put(
                         Pid, ?SCOPE, <<"large-meta">>, <<>>,
                         #{metadata => LargeMetadata})),
          ?assertEqual({error, invalid_metadata},
                       adk_artifact_ets:put(
                         Pid, ?SCOPE, <<"many-meta">>, <<>>,
                         #{metadata => ManyMetadata}))
      end).

invalid_inputs_and_dead_handle_are_bounded_test() ->
    {ok, Pid} = adk_artifact_ets:start_link(#{}),
    ?assertEqual({error, invalid_scope},
                 adk_artifact_ets:put(
                   Pid, invalid, <<"name">>, <<>>, #{})),
    ?assertEqual({error, invalid_name},
                 adk_artifact_ets:put(
                   Pid, ?SCOPE, <<"../escape">>, <<>>, #{})),
    ?assertEqual({error, invalid_mime_type},
                 adk_artifact_ets:put(
                   Pid, ?SCOPE, <<"name">>, <<>>,
                   #{mime_type => <<"bad\r\nvalue">>})),
    ?assertEqual({error, invalid_metadata},
                 adk_artifact_ets:put(
                   Pid, ?SCOPE, <<"name">>, <<>>,
                   #{metadata => #{atom_key => value}})),
    ?assert(is_process_alive(Pid)),
    ok = adk_artifact_ets:stop(Pid),
    ?assertEqual({error, unavailable},
                 adk_artifact_ets:get(
                   Pid, ?SCOPE, <<"name">>, latest)).

with_service(Test) ->
    {ok, Pid} = adk_artifact_ets:start_link(#{}),
    try Test(Pid)
    after
        _ = adk_artifact_ets:stop(Pid)
    end.
