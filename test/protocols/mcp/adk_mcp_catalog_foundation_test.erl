-module(adk_mcp_catalog_foundation_test).

-include_lib("eunit/include/eunit.hrl").

catalog_replacement_is_generation_atomic_and_snapshots_are_immutable_test() ->
    {ok, Catalog1} = adk_mcp_catalog:new(definitions(<<"old">>)),
    {ok, Snapshot1} = adk_mcp_catalog:snapshot(Catalog1),
    ?assertEqual({ok, 1}, adk_mcp_catalog:generation(Snapshot1)),
    {ok, Catalog2} = adk_mcp_catalog:replace(
                       Catalog1, definitions(<<"new">>)),
    ?assertEqual({ok, 2}, adk_mcp_catalog:generation(Catalog2)),
    ?assertEqual(<<"old">>, revision(Snapshot1, tools, <<"alpha">>)),
    ?assertEqual(<<"new">>, revision(Catalog2, tools, <<"alpha">>)),
    ?assertEqual(<<"old">>,
                 revision(Snapshot1, resources, <<"file:///alpha">>)),
    ?assertEqual(<<"new">>,
                 revision(Catalog2, resources, <<"file:///alpha">>)),
    ?assertEqual(<<"old">>, revision(Snapshot1, prompts, <<"alpha">>)),
    ?assertEqual(<<"new">>, revision(Catalog2, prompts, <<"alpha">>)),
    {ok, Change} = adk_mcp_catalog:list_changed(Catalog1, Catalog2),
    ?assertEqual(#{tools => true, resources => true, prompts => true},
                 maps:get(changed, Change)),
    ?assertEqual(
       [<<"notifications/tools/list_changed">>,
        <<"notifications/resources/list_changed">>,
        <<"notifications/prompts/list_changed">>],
       maps:get(notifications, Change)).

catalog_order_and_cursors_are_deterministic_and_generation_bound_test() ->
    Definitions =
        #{tools => [tool(<<"zeta">>, <<"v1">>),
                    tool(<<"alpha">>, <<"v1">>),
                    tool(<<"middle">>, <<"v1">>)]},
    {ok, Catalog1} = adk_mcp_catalog:new(Definitions),
    {ok, FirstPage1} = adk_mcp_catalog:list(Catalog1, tools, undefined, 2),
    {ok, FirstPage2} = adk_mcp_catalog:list(Catalog1, tools, undefined, 2),
    ?assertEqual(maps:get(items, FirstPage1), maps:get(items, FirstPage2)),
    Cursor = maps:get(next_cursor, FirstPage1),
    ?assertEqual(Cursor, maps:get(next_cursor, FirstPage2)),
    [Alpha, Middle] = maps:get(items, FirstPage1),
    ?assertEqual(<<"alpha">>, maps:get(<<"name">>, Alpha)),
    ?assertEqual(<<"middle">>, maps:get(<<"name">>, Middle)),
    {ok, LastPage} = adk_mcp_catalog:list(Catalog1, tools, Cursor, 2),
    [Zeta] = maps:get(items, LastPage),
    ?assertEqual(<<"zeta">>, maps:get(<<"name">>, Zeta)),
    ?assertNot(maps:is_key(next_cursor, LastPage)),
    {ok, Catalog2} = adk_mcp_catalog:replace(Catalog1, Definitions),
    ?assertEqual(
       {error, stale_mcp_catalog_cursor},
       adk_mcp_catalog:list(Catalog2, tools, Cursor, 2)),
    {ok, NoChange} = adk_mcp_catalog:list_changed(Catalog1, Catalog2),
    ?assertEqual(#{tools => false, resources => false, prompts => false},
                 maps:get(changed, NoChange)),
    ?assertEqual([], maps:get(notifications, NoChange)).

catalog_rejects_duplicate_executable_and_unbounded_entries_test() ->
    Duplicate = #{tools => [tool(<<"same">>, <<"a">>),
                              tool(<<"same">>, <<"b">>)]},
    ?assertEqual(
       {error, {duplicate_mcp_catalog_entry, tools}},
       adk_mcp_catalog:new(Duplicate)),
    Executable = #{tools =>
                       [#{<<"name">> => <<"unsafe">>,
                          <<"handler">> => fun() -> ok end}]},
    ?assertEqual(
       {error, invalid_mcp_json_type},
       adk_mcp_catalog:new(Executable)),
    TooMany =
        #{tools =>
              [tool(<<"tool-", (integer_to_binary(N))/binary>>, <<"v">>)
               || N <- lists:seq(1, 1025)]},
    ?assertEqual(
       {error, {mcp_catalog_capacity_exceeded, tools}},
       adk_mcp_catalog:new(TooMany)),
    ?assertEqual(
       {error, unknown_mcp_catalog_keys},
       adk_mcp_catalog:new(#{handlers => []})).

catalog_store_failed_replacement_is_non_mutating_test() ->
    {ok, Store} = adk_mcp_catalog_store:start_link(definitions(<<"old">>)),
    try
        {ok, Before} = adk_mcp_catalog_store:snapshot(Store),
        ?assertEqual(
           {error, {duplicate_mcp_catalog_entry, tools}},
           adk_mcp_catalog_store:replace_all(
             Store,
             #{tools => [tool(<<"same">>, <<"a">>),
                         tool(<<"same">>, <<"b">>)]})),
        {ok, AfterFailure} = adk_mcp_catalog_store:snapshot(Store),
        ?assertEqual({ok, 1}, adk_mcp_catalog:generation(AfterFailure)),
        ?assertEqual(<<"old">>,
                     revision(AfterFailure, tools, <<"alpha">>)),
        ?assertEqual(Before, AfterFailure),
        {ok, Change} = adk_mcp_catalog_store:replace_all(
                         Store, definitions(<<"new">>)),
        ?assertEqual(2, maps:get(to_generation, Change)),
        {ok, AfterSuccess} = adk_mcp_catalog_store:snapshot(Store),
        ?assertEqual(<<"new">>,
                     revision(AfterSuccess, prompts, <<"alpha">>))
    after
        ok = gen_server:stop(Store)
    end.

catalog_store_status_is_content_free_test() ->
    Secret = <<"catalog-description-secret-must-not-leak">>,
    Definitions =
        #{tools =>
              [#{<<"name">> => <<"alpha">>,
                 <<"description">> => Secret,
                 <<"inputSchema">> => #{<<"type">> => <<"object">>}}]},
    {ok, Store} = adk_mcp_catalog_store:start_link(Definitions),
    try
        EncodedStatus = term_to_binary(sys:get_status(Store)),
        ?assertEqual(nomatch, binary:match(EncodedStatus, Secret)),
        {ok, Description} = adk_mcp_catalog_store:describe(Store),
        ?assertEqual(1, maps:get(tools, maps:get(counts, Description))),
        ?assertEqual(nomatch, binary:match(term_to_binary(Description), Secret))
    after
        ok = gen_server:stop(Store)
    end.

catalog_store_snapshots_never_mix_replacement_generations_test() ->
    {ok, Store} = adk_mcp_catalog_store:start_link(definitions(<<"old">>)),
    Parent = self(),
    Readers =
        [spawn_monitor(
           fun() ->
               receive go -> ok end,
               {ok, Snapshot} = adk_mcp_catalog_store:snapshot(Store),
               Revisions = [revision(Snapshot, Kind, catalog_id(Kind))
                            || Kind <- adk_mcp_catalog:kinds()],
               Parent ! {catalog_revisions, Revisions}
           end)
         || _ <- lists:seq(1, 32)],
    try
        lists:foreach(fun({Pid, _Ref}) -> Pid ! go end, Readers),
        {ok, _Change} = adk_mcp_catalog_store:replace_all(
                          Store, definitions(<<"new">>)),
        Results = gather_revisions(32, []),
        ?assert(
           lists:all(
             fun([Revision, Revision, Revision]) ->
                     Revision =:= <<"old">> orelse Revision =:= <<"new">>
             end, Results)),
        lists:foreach(
          fun({_Pid, Ref}) ->
              receive {'DOWN', Ref, process, _Reader, normal} -> ok
              after 1000 -> ?assert(false)
              end
          end, Readers)
    after
        ok = gen_server:stop(Store)
    end.

catalog_store_public_api_and_lifecycle_contract_test() ->
    ?assertEqual(
       {error, invalid_mcp_catalog_definitions},
       adk_mcp_catalog_store:start_link(not_a_map)),
    Spec = adk_mcp_catalog_store:child_spec(#{}),
    ?assertEqual(worker, maps:get(type, Spec)),
    ?assertEqual(permanent, maps:get(restart, Spec)),
    {ok, Empty} = adk_mcp_catalog_store:start_link(),
    try
        {ok, #{items := [], generation := 1}} =
            adk_mcp_catalog_store:list(Empty, tools, undefined, 10),
        ?assertEqual({error, mcp_catalog_entry_not_found},
                     adk_mcp_catalog_store:lookup(
                       Empty, tools, <<"missing">>)),
        ?assertEqual(
           {error, invalid_mcp_catalog_store_request},
           gen_server:call(Empty, unsupported)),
        gen_server:cast(Empty, ignored),
        Empty ! ignored,
        {ok, _Description} = adk_mcp_catalog_store:describe(Empty),
        {ok, _Snapshot} = adk_mcp_catalog_store:snapshot(Empty)
    after
        ok = gen_server:stop(Empty)
    end,
    ?assertEqual(
       {error, mcp_catalog_store_unavailable},
       adk_mcp_catalog_store:snapshot(Empty)),
    ?assertEqual(
       {error, mcp_catalog_store_unavailable},
       adk_mcp_catalog_store:replace_all(Empty, #{})).

definitions(Revision) ->
    #{tools => [tool(<<"alpha">>, Revision)],
      resources =>
          [#{<<"uri">> => <<"file:///alpha">>,
             <<"name">> => <<"Alpha resource">>,
             <<"revision">> => Revision}],
      prompts =>
          [#{<<"name">> => <<"alpha">>,
             <<"description">> => <<"Alpha prompt">>,
             <<"revision">> => Revision}]}.

tool(Name, Revision) ->
    #{<<"name">> => Name,
      <<"description">> => <<"Tool descriptor">>,
      <<"inputSchema">> => #{<<"type">> => <<"object">>},
      <<"revision">> => Revision}.

revision(Catalog, Kind, Id) ->
    {ok, Descriptor} = adk_mcp_catalog:lookup(Catalog, Kind, Id),
    maps:get(<<"revision">>, Descriptor).

catalog_id(tools) -> <<"alpha">>;
catalog_id(resources) -> <<"file:///alpha">>;
catalog_id(prompts) -> <<"alpha">>.

gather_revisions(0, Acc) -> lists:reverse(Acc);
gather_revisions(Count, Acc) ->
    receive
        {catalog_revisions, Revisions} ->
            gather_revisions(Count - 1, [Revisions | Acc])
    after 2000 ->
        ?assert(false)
    end.
