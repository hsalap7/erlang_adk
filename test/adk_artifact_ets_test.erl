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
