-module(adk_graph_foundation_test).
-include_lib("eunit/include/eunit.hrl").

graph_foundation_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun legacy_builder_lowers_to_workflow_runtime/0,
      fun legacy_canonical_name_collisions_are_rejected/0,
      fun descriptor_is_deterministic_json_and_secret_safe/0,
      fun structural_warnings_are_inspectable/0,
      fun fork_join_must_be_a_typed_join/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_Setup) -> ok.

legacy_builder_lowers_to_workflow_runtime() ->
    G0 = adk_graph:new(),
    G1 = adk_graph:add_node(
           G0, first,
           fun(_State) -> #{<<"first">> => true} end),
    G2 = adk_graph:add_node(
           G1, <<"second">>,
           fun(State) ->
               true = maps:get(<<"first">>, State),
               #{<<"second">> => true}
           end),
    G3 = adk_graph:add_edge(G2, first, <<"second">>),
    G4 = adk_graph:set_entry_point(G3, first),
    {ok, Compiled} = adk_graph:compile(G4),
    {ok, Workflow} = adk_graph:to_workflow(Compiled),
    ?assert(adk_workflow:is_compiled(Workflow)),
    ?assertEqual(graph, maps:get(kind, Workflow)),
    ?assertMatch({ok, #{<<"first">> := true,
                        <<"second">> := true}},
                 adk_graph:run(Compiled, #{},
                               #{runtime => workflow})),
    {ok, Descriptor} = adk_graph:describe(Compiled),
    ?assertEqual([<<"first">>, <<"second">>],
                 maps:get(<<"node_order">>, Descriptor)).

legacy_canonical_name_collisions_are_rejected() ->
    G0 = adk_graph:new(),
    G1 = adk_graph:add_node(G0, same, fun(_) -> #{} end),
    G2 = adk_graph:add_node(G1, <<"same">>, fun(_) -> #{} end),
    G3 = adk_graph:set_entry_point(G2, same),
    ?assertEqual({error, {canonical_name_collision, <<"same">>}},
                 adk_graph:compile(G3)).

descriptor_is_deterministic_json_and_secret_safe() ->
    Secret = <<"descriptor-must-not-contain-this-secret">>,
    Spec = graph_spec(
             <<"tool">>,
             [#{id => <<"tool">>, type => tool,
                module => ?MODULE,
                args => #{<<"credential">> => Secret},
                result_key => <<"result">>}],
             #{<<"tool">> => end_node}),
    {ok, Compiled} = adk_workflow:compile(Spec),
    {ok, Descriptor1} = adk_graph_inspect:describe(Compiled),
    {ok, Descriptor2} = adk_graph_inspect:describe(Compiled),
    ?assertEqual(Descriptor1, Descriptor2),
    ?assertEqual({ok, Descriptor1}, adk_json:normalize(Descriptor1)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Descriptor1), Secret)),
    {ok, Dot1} = adk_graph_inspect:to_dot(Compiled),
    {ok, Dot2} = adk_graph_inspect:to_dot(Compiled),
    {ok, Mermaid1} = adk_graph_inspect:to_mermaid(Compiled),
    {ok, Mermaid2} = adk_graph_inspect:to_mermaid(Compiled),
    ?assertEqual(Dot1, Dot2),
    ?assertEqual(Mermaid1, Mermaid2),
    ?assertMatch({_, _}, binary:match(Dot1, <<"digraph adk_graph">>)),
    ?assertMatch({_, _}, binary:match(Mermaid1, <<"flowchart TD">>)),
    ?assertEqual(nomatch, binary:match(Dot1, Secret)),
    ?assertEqual(nomatch, binary:match(Mermaid1, Secret)).

structural_warnings_are_inspectable() ->
    Spec = graph_spec(
             <<"entry">>,
             [action_node(<<"entry">>),
              action_node(<<"orphan-cycle">>)],
             #{<<"entry">> => end_node,
               <<"orphan-cycle">> => <<"orphan-cycle">>}),
    {ok, Compiled} = adk_workflow:compile(Spec),
    {ok, Descriptor} = adk_graph_inspect:describe(Compiled),
    Analysis = maps:get(<<"analysis">>, Descriptor),
    Warnings = maps:get(<<"warnings">>, Analysis),
    Codes = [maps:get(<<"code">>, Warning) || Warning <- Warnings],
    ?assert(lists:member(<<"unreachable_node">>, Codes)),
    ?assert(lists:member(
              <<"cycle_relies_on_global_max_steps">>, Codes)),
    ?assertEqual([<<"orphan-cycle">>],
                 maps:get(<<"unreachable">>, Analysis)),
    ?assertEqual(
       [#{<<"explicit_loop">> => false,
          <<"nodes">> => [<<"orphan-cycle">>]}],
       maps:get(<<"cycles">>, Analysis)),

    Cycle = graph_spec(
              <<"cycle">>, [action_node(<<"cycle">>)],
              #{<<"cycle">> => <<"cycle">>}),
    {ok, CycleCompiled} = adk_workflow:compile(Cycle),
    {ok, CycleDescriptor} = adk_graph_inspect:describe(CycleCompiled),
    CycleWarnings = maps:get(
                      <<"warnings">>,
                      maps:get(<<"analysis">>, CycleDescriptor)),
    CycleCodes = [maps:get(<<"code">>, Warning)
                  || Warning <- CycleWarnings],
    ?assert(lists:member(<<"no_static_terminal_path">>, CycleCodes)).

fork_join_must_be_a_typed_join() ->
    Spec = graph_spec(
             <<"fork">>,
             [#{id => <<"fork">>, type => fork,
                branches => [<<"branch">>], join => <<"not-join">>,
                max_concurrency => 1},
              action_node(<<"branch">>),
              action_node(<<"not-join">>)],
             #{<<"branch">> => <<"not-join">>,
               <<"not-join">> => end_node}),
    ?assertEqual(
       {error,
        {invalid_workflow, [nodes, <<"fork">>, join],
         join_must_reference_join_node}},
       adk_workflow:compile(Spec)),

    ValidSpec = graph_spec(
                  <<"fork">>,
                  [#{id => <<"fork">>, type => fork,
                     branches => [<<"branch">>], join => <<"join">>,
                     join_policy => {quorum, 1}, max_concurrency => 1},
                   action_node(<<"branch">>),
                   #{id => <<"join">>, type => join}],
                  #{<<"branch">> => <<"join">>,
                    <<"join">> => end_node}),
    {ok, ValidCompiled} = adk_workflow:compile(ValidSpec),
    {ok, Descriptor} = adk_graph_inspect:describe(ValidCompiled),
    [ForkDescriptor] =
        [Node || Node <- maps:get(<<"nodes">>, Descriptor),
                 maps:get(<<"id">>, Node) =:= <<"fork">>],
    ?assertEqual(#{<<"type">> => <<"quorum">>, <<"count">> => 1},
                 maps:get(<<"join_policy">>, ForkDescriptor)).

graph_spec(Entry, Nodes, Edges) ->
    #{version => 1,
      id => <<"graph-foundation-test">>,
      kind => graph,
      entry => Entry,
      nodes => Nodes,
      edges => Edges,
      max_steps => 20}.

action_node(Id) ->
    #{id => Id, run => fun(_State) -> {ok, #{}} end}.
