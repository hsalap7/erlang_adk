-module(adk_workflow_data_contract_test).
-include_lib("eunit/include/eunit.hrl").

workflow_data_contract_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Setup) -> ok end,
     [fun invalid_node_schema_is_rejected_at_compile_time/0,
      fun workflow_schemas_are_definition_bound/0,
      fun graph_node_input_schema_is_enforced/0,
      fun graph_node_output_schema_is_enforced/0,
      fun graph_node_schemas_allow_typed_edge_payloads/0,
      fun graph_fork_preserves_typed_predecessor_input/0,
      fun resumed_nested_fork_output_schema_is_enforced/0,
      fun state_reducers_apply_in_commit_order/0,
      fun nested_workflow_reducers_do_not_reapply_parent_state/0,
      fun incompatible_nested_workflow_reducer_fails_structurally/0,
      fun reject_conflict_reducer_fails_closed/0,
      fun sum_reducer_rejects_numeric_overflow/0,
      fun invalid_state_reducer_is_rejected/0,
      fun graph_descriptor_exposes_data_contracts/0]}.

invalid_node_schema_is_rejected_at_compile_time() ->
    Spec = graph_spec(
             [#{id => <<"node">>,
                input_schema => #{<<"type">> => <<"not-a-type">>},
                run => fun(_State) -> {ok, #{}} end}],
             #{<<"node">> => end_node}),
    ?assertMatch(
       {error, {invalid_workflow, [nodes, 1, input_schema], _}},
       adk_workflow:compile(Spec)).

workflow_schemas_are_definition_bound() ->
    Base = #{version => 1,
             id => <<"schema-definition-binding">>,
             kind => sequential,
             definition_revision => 1,
             steps => [#{id => <<"step">>,
                         run => fun(_State) -> {ok, #{}} end}]},
    String = compile_ok(
               Base#{input_schema => #{<<"type">> => <<"object">>},
                     output_schema => #{<<"type">> => <<"string">>}}),
    Number = compile_ok(
               Base#{input_schema => #{<<"type">> => <<"object">>},
                     output_schema => #{<<"type">> => <<"number">>}}),
    ?assertNotEqual(adk_workflow:definition_fingerprint(String),
                    adk_workflow:definition_fingerprint(Number)).

graph_node_input_schema_is_enforced() ->
    Compiled = compile_ok(
                 graph_spec(
                   [#{id => <<"node">>,
                      input_schema => #{<<"type">> => <<"string">>},
                      run => fun(_State) -> {ok, #{}} end}],
                   #{<<"node">> => end_node})),
    ?assertMatch(
       {failed,
        {node_input_schema_validation_failed, <<"node">>,
         {schema_validation_failed, _, _}}, _},
       adk_workflow:run(Compiled, #{})).

graph_node_output_schema_is_enforced() ->
    Compiled = compile_ok(
                 graph_spec(
                   [#{id => <<"node">>,
                      output_schema => #{<<"type">> => <<"string">>},
                      run => fun(_State) ->
                          {output, 42, #{}}
                      end}],
                   #{<<"node">> => end_node})),
    ?assertMatch(
       {failed,
        {node_output_schema_validation_failed, <<"node">>,
         {schema_validation_failed, _, _}}, _},
       adk_workflow:run(Compiled, #{})).

graph_node_schemas_allow_typed_edge_payloads() ->
    StringSchema = #{<<"type">> => <<"string">>},
    Compiled = compile_ok(
                 graph_spec(
                   [#{id => <<"produce">>,
                      output_schema => StringSchema,
                      run => fun(_State) ->
                          {output, <<"typed">>,
                           #{<<"produced">> => true}}
                      end},
                    #{id => <<"consume">>, type => join,
                      input_schema => StringSchema,
                      output_schema => StringSchema}],
                   #{<<"produce">> => <<"consume">>,
                     <<"consume">> => end_node})),
    {completed, State, _Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(true, maps:get(<<"produced">>, State)).

graph_fork_preserves_typed_predecessor_input() ->
    StringSchema = #{<<"type">> => <<"string">>},
    Compiled = compile_ok(
                 graph_spec(
                   [#{id => <<"produce">>,
                      output_schema => StringSchema,
                      run => fun(_State) ->
                          {output, <<"typed-fork-input">>, #{}}
                      end},
                    #{id => <<"fork">>, type => fork,
                      branches => [<<"branch">>], join => <<"join">>,
                      merge => reject_conflicts, max_concurrency => 1},
                    #{id => <<"branch">>,
                      input_schema => StringSchema,
                      output_schema => StringSchema,
                      run => fun(_State, Context) ->
                          Input = maps:get(input, Context),
                          {output, Input, #{<<"branch_input">> => Input}}
                      end},
                    #{id => <<"join">>, type => join}],
                   #{<<"produce">> => <<"fork">>,
                     <<"branch">> => <<"join">>,
                     <<"join">> => end_node})),
    {completed, State, Checkpoint} = adk_workflow:run(Compiled, #{}),
    ?assertEqual(<<"typed-fork-input">>,
                 maps:get(<<"branch_input">>, State)),
    ?assertEqual(
       #{<<"branch">> => <<"typed-fork-input">>},
       maps:get(<<"output">>, Checkpoint)).

resumed_nested_fork_output_schema_is_enforced() ->
    Child = compile_ok(
              #{version => 1,
                id => <<"nested-schema-child">>,
                kind => sequential,
                definition_revision => 1,
                steps =>
                    [#{id => <<"pause">>,
                       run => fun(_State) ->
                           {pause, approval, <<"Approve child">>, #{}}
                       end},
                     #{id => <<"invalid-output">>,
                       run => fun(_State, _Context) ->
                           {output, 42, #{}}
                       end}],
                max_steps => 3}),
    StringSchema = #{<<"type">> => <<"string">>},
    Parent = compile_ok(
               graph_spec(
                 [#{id => <<"fork">>, type => fork,
                    branches => [<<"child">>], join => <<"join">>,
                    merge => reject_conflicts, max_concurrency => 1},
                  #{id => <<"child">>, type => workflow,
                    workflow => Child, output_schema => StringSchema},
                  #{id => <<"join">>, type => join}],
                 #{<<"child">> => <<"join">>,
                   <<"join">> => end_node})),
    {paused, _Details, Checkpoint} = adk_workflow:run(Parent, #{}),
    {ok, Ref} = adk_workflow:resume(
                  Parent, Checkpoint,
                  #{resume_input => <<"approved">>, retention_ms => 1000}),
    ?assertMatch(
       {failed,
        {fork_branch_failed, <<"child">>,
         {output_schema_validation_failed,
          {schema_validation_failed, _, _}}}, _},
       adk_workflow:await(Ref, 1000)).

state_reducers_apply_in_commit_order() ->
    Spec = #{version => 1,
             id => <<"state-reducers">>,
             kind => sequential,
             definition_revision => 1,
             state_reducers => #{<<"count">> => sum,
                                 <<"events">> => append,
                                 <<"status">> => overwrite},
             steps =>
                 [#{id => <<"first">>,
                    run => fun(_State) ->
                        {ok, #{<<"count">> => 2,
                               <<"events">> => [<<"first">>],
                               <<"status">> => <<"working">>}}
                    end},
                  #{id => <<"second">>,
                    run => fun(_State) ->
                        {ok, #{<<"count">> => 3,
                               <<"events">> => [<<"second">>],
                               <<"status">> => <<"done">>}}
                    end}],
             max_steps => 3},
    Compiled = compile_ok(Spec),
    {completed, State, _Checkpoint} = adk_workflow:run(
                                       Compiled,
                                       #{<<"count">> => 10,
                                         <<"events">> => [<<"initial">>]}),
    ?assertEqual(15, maps:get(<<"count">>, State)),
    ?assertEqual([<<"initial">>, <<"first">>, <<"second">>],
                 maps:get(<<"events">>, State)),
    ?assertEqual(<<"done">>, maps:get(<<"status">>, State)).

nested_workflow_reducers_do_not_reapply_parent_state() ->
    Reducers = #{<<"count">> => sum, <<"events">> => append},
    Child = compile_ok(
              #{version => 1,
                id => <<"nested-reducer-child">>,
                kind => sequential,
                definition_revision => 1,
                state_reducers => Reducers,
                steps =>
                    [#{id => <<"child-change">>,
                       run => fun(_State) ->
                           {output, <<"child-complete">>,
                            #{<<"count">> => 2,
                              <<"events">> => [<<"child">>]}}
                       end}],
                max_steps => 2}),
    Parent = compile_ok(
               (graph_spec(
                  [#{id => <<"child">>, type => workflow,
                     workflow => Child}],
                  #{<<"child">> => end_node}))#{
                    id => <<"nested-reducer-parent">>,
                    state_reducers => Reducers}),
    {completed, State, _Checkpoint} =
        adk_workflow:run(
          Parent,
          #{<<"count">> => 10, <<"events">> => [<<"initial">>]}),
    ?assertEqual(12, maps:get(<<"count">>, State)),
    ?assertEqual([<<"initial">>, <<"child">>],
                 maps:get(<<"events">>, State)).

incompatible_nested_workflow_reducer_fails_structurally() ->
    Child = compile_ok(
              #{version => 1,
                id => <<"nested-incompatible-child">>,
                kind => sequential,
                definition_revision => 1,
                steps =>
                    [#{id => <<"replace-count">>,
                       run => fun(_State) ->
                           {ok, #{<<"count">> => <<"not-a-number">>}}
                       end}],
                max_steps => 2}),
    Parent = compile_ok(
               (graph_spec(
                  [#{id => <<"child">>, type => workflow,
                     workflow => Child}],
                  #{<<"child">> => end_node}))#{
                    id => <<"nested-incompatible-parent">>,
                    state_reducers => #{<<"count">> => sum}}),
    ?assertMatch(
       {failed,
        {node_failed, <<"child">>,
         {nested_state_reducer_incompatible, <<"count">>, sum}}, _},
       adk_workflow:run(Parent, #{<<"count">> => 10})).

reject_conflict_reducer_fails_closed() ->
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"state-reducer-conflict">>,
                   kind => sequential,
                   definition_revision => 1,
                   state_reducers =>
                       #{<<"locked">> => reject_conflict},
                   steps =>
                       [#{id => <<"change">>,
                          run => fun(_State) ->
                              {ok, #{<<"locked">> => <<"new">>}}
                          end}],
                   max_steps => 2}),
    ?assertMatch(
       {failed,
        {step_failed, <<"change">>,
         {state_reducer_conflict, <<"locked">>}}, _},
       adk_workflow:run(Compiled, #{<<"locked">> => <<"original">>})).

sum_reducer_rejects_numeric_overflow() ->
    Compiled = compile_ok(
                 #{version => 1,
                   id => <<"state-reducer-overflow">>,
                   kind => sequential,
                   definition_revision => 1,
                   state_reducers => #{<<"total">> => sum},
                   steps =>
                       [#{id => <<"add">>,
                          run => fun(_State) ->
                              {ok, #{<<"total">> => 1.0e308}}
                          end}],
                   max_steps => 2}),
    ?assertMatch(
       {failed,
        {step_failed, <<"add">>,
         {state_reducer_numeric_overflow, <<"total">>}}, _},
       adk_workflow:run(Compiled, #{<<"total">> => 1.0e308})).

invalid_state_reducer_is_rejected() ->
    Spec = #{version => 1,
             id => <<"invalid-state-reducer">>,
             kind => sequential,
             state_reducers => #{<<"field">> => multiply},
             steps => [#{id => <<"step">>,
                         run => fun(_State) -> {ok, #{}} end}]},
    ?assertEqual(
       {error, {invalid_workflow,
                [state_reducers, <<"field">>],
                unsupported_state_reducer}},
       adk_workflow:compile(Spec)).

graph_descriptor_exposes_data_contracts() ->
    Schema = #{<<"type">> => <<"null">>},
    Compiled = compile_ok(
                 (graph_spec(
                    [#{id => <<"node">>, type => join,
                       input_schema => Schema,
                       output_schema => Schema}],
                    #{<<"node">> => end_node}))#{
                     state_reducers => #{<<"count">> => sum}}),
    {ok, Descriptor} = adk_graph_inspect:describe(Compiled),
    ?assertEqual(<<"sum">>,
                 maps:get(<<"count">>,
                          maps:get(<<"state_reducers">>, Descriptor))),
    [Node] = maps:get(<<"nodes">>, Descriptor),
    ?assertEqual(Schema, maps:get(<<"input_schema">>, Node)),
    ?assertEqual(Schema, maps:get(<<"output_schema">>, Node)).

graph_spec(Nodes, Edges) ->
    #{version => 1,
      id => <<"graph-data-contract">>,
      kind => graph,
      definition_revision => 1,
      entry => maps:get(id, hd(Nodes)),
      nodes => Nodes,
      edges => Edges,
      max_steps => 8}.

compile_ok(Spec) ->
    {ok, Compiled} = adk_workflow:compile(Spec),
    Compiled.
