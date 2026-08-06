%% @doc Canonical, non-executable projection of a compiled workflow graph.
%%
%% Compiled workflow maps contain trusted callbacks and may contain application
%% arguments.  They must not be returned by inspection APIs.  This module
%% projects only topology, stable identities, public policies, and callback
%% classifications into an exact JSON-safe descriptor.
-module(adk_graph_ir).

-export([from_compiled/1, from_data/2]).

-spec from_compiled(map()) -> {ok, map()} | {error, term()}.
from_compiled(#{'$adk_workflow_compiled' := true,
                kind := graph, data := Data} = Compiled)
  when is_map(Data) ->
    Metadata = #{id => maps:get(id, Compiled, undefined),
                 version => maps:get(version, Compiled, 1),
                 definition_fingerprint =>
                     maps:get(definition_fingerprint, Compiled, undefined),
                 definition_revision =>
                     maps:get(definition_revision, Compiled, undefined),
                 definition_portable =>
                     maps:get(definition_portable, Compiled, false),
                 input_schema => maps:get(input_schema, Compiled, undefined),
                 output_schema => maps:get(output_schema, Compiled,
                                           undefined)},
    from_data(Data, Metadata);
from_compiled(_Compiled) ->
    {error, not_a_compiled_graph_workflow}.

-spec from_data(map(), map()) -> {ok, map()} | {error, term()}.
from_data(#{entry := Entry, nodes := Nodes, edges := Edges} = Data,
          Metadata)
  when is_binary(Entry), is_map(Nodes), is_map(Edges), is_map(Metadata) ->
    case adk_graph_validate:analyze(Data) of
        {error, _} = Error -> Error;
        {ok, Analysis} ->
            Order = maps:get(node_order, Analysis),
            Descriptor0 =
                #{<<"schema_version">> => 1,
                  <<"workflow_id">> => maps:get(id, Metadata, undefined),
                  <<"workflow_version">> =>
                      maps:get(version, Metadata, 1),
                  <<"definition_fingerprint">> =>
                      maps:get(definition_fingerprint, Metadata, undefined),
                  <<"definition_revision">> =>
                      maps:get(definition_revision, Metadata, undefined),
                  <<"definition_portable">> =>
                      maps:get(definition_portable, Metadata, false),
                  <<"kind">> => <<"graph">>,
                  <<"entry">> => Entry,
                  <<"max_steps">> => maps:get(max_steps, Data, null),
                  <<"state_reducers">> =>
                      state_reducers_descriptor(
                        maps:get(state_reducers, Data, #{})),
                  <<"input_schema">> =>
                      maps:get(input_schema, Metadata, undefined),
                  <<"output_schema">> =>
                      maps:get(output_schema, Metadata, undefined),
                  <<"node_order">> => Order,
                  <<"nodes">> =>
                      [node_descriptor(maps:get(Id, Nodes))
                       || Id <- Order],
                  <<"edges">> => graph_edges(Order, Nodes, Edges),
                  <<"analysis">> => analysis_descriptor(Analysis)},
            case adk_json:normalize(Descriptor0) of
                {ok, Descriptor} -> {ok, Descriptor};
                {error, _} -> {error, invalid_graph_inspection_projection}
            end
    end;
from_data(_Data, _Metadata) ->
    {error, invalid_compiled_graph_data}.

node_descriptor(Node) ->
    Type = maps:get(type, Node, action),
    Base0 = #{<<"id">> => maps:get(id, Node),
              <<"type">> => atom_to_binary(Type, utf8),
              <<"input_schema">> =>
                  schema_descriptor(maps:get(input_schema, Node, undefined)),
              <<"output_schema">> =>
                  schema_descriptor(
                    maps:get(output_schema, Node, undefined))},
    Base = maybe_policy(Node, Base0),
    case Type of
        action -> Base#{<<"action">> => action_descriptor(
                                           maps:get(run, Node))};
        agent -> Base#{<<"action">> => action_descriptor(
                                          maps:get(run, Node))};
        tool -> Base#{<<"action">> => action_descriptor(
                                         maps:get(run, Node))};
        workflow -> Base#{<<"action">> => action_descriptor(
                                             maps:get(run, Node))};
        join ->
            case maps:get(run, Node, noop) of
                noop -> Base;
                Run -> Base#{<<"action">> => action_descriptor(Run)}
            end;
        branch -> router_descriptor(Node, Base);
        dynamic -> router_descriptor(Node, Base);
        loop ->
            Base#{<<"body">> => maps:get(body, Node),
                  <<"done">> => end_target(maps:get(done, Node)),
                  <<"max_iterations">> => maps:get(max_iterations, Node),
                  <<"decision">> => callback_descriptor(
                                         maps:get(decide, Node))};
        fork ->
            Base#{<<"branches">> => maps:get(branches, Node),
                  <<"join">> => maps:get(join, Node),
                  <<"join_policy">> =>
                      join_policy_descriptor(
                        maps:get(join_policy, Node, all)),
                  <<"merge">> => merge_descriptor(maps:get(merge, Node)),
                  <<"max_concurrency">> =>
                      maps:get(max_concurrency, Node)}
    end.

maybe_policy(Node, Base) ->
    case maps:find(policy, Node) of
        error -> Base;
        {ok, Policy} ->
            Timeout = case maps:get(timeout, Policy, infinity) of
                infinity -> <<"infinity">>;
                Milliseconds -> Milliseconds
            end,
            Base#{<<"policy">> =>
                      #{<<"timeout">> => Timeout,
                        <<"max_attempts">> =>
                            maps:get(max_attempts, Policy, 1),
                        <<"backoff_ms">> =>
                            maps:get(backoff_ms, Policy, 0)}}
    end.

router_descriptor(Node, Base) ->
    Base#{<<"targets">> => [end_target(Target)
                             || Target <- maps:get(targets, Node)],
          <<"decision">> => callback_descriptor(maps:get(choose, Node))}.

action_descriptor(noop) -> #{<<"kind">> => <<"noop">>};
action_descriptor(Fun) when is_function(Fun) ->
    #{<<"kind">> => <<"function">>,
      <<"arity">> => fun_arity(Fun)};
action_descriptor({agent, Name, Prompt, Decide}) ->
    #{<<"kind">> => <<"agent">>,
      <<"agent">> => Name,
      <<"prompt">> => value_kind(Prompt),
      <<"decision">> => Decide =/= undefined};
action_descriptor({tool, Module, Args, ResultKey}) ->
    #{<<"kind">> => <<"tool">>,
      <<"module">> => atom_to_binary(Module, utf8),
      <<"arguments">> => value_kind(Args),
      <<"result_key">> => case ResultKey of
          undefined -> null;
          _ -> ResultKey
      end};
action_descriptor({workflow, Compiled, _Options}) ->
    #{<<"kind">> => <<"workflow">>,
      <<"workflow_id">> => maps:get(id, Compiled, null),
      <<"workflow_version">> => maps:get(version, Compiled, null),
      <<"workflow_kind">> =>
          atom_to_binary(maps:get(kind, Compiled), utf8)};
action_descriptor({Module, Function, ExtraArgs})
  when is_atom(Module), is_atom(Function), is_list(ExtraArgs) ->
    #{<<"kind">> => <<"mfa">>,
      <<"module">> => atom_to_binary(Module, utf8),
      <<"function">> => atom_to_binary(Function, utf8),
      <<"extra_arity">> => length(ExtraArgs)};
action_descriptor(_Other) ->
    #{<<"kind">> => <<"unknown">>}.

callback_descriptor(Fun) when is_function(Fun) ->
    #{<<"kind">> => <<"function">>, <<"arity">> => fun_arity(Fun)};
callback_descriptor({Module, Function, ExtraArgs})
  when is_atom(Module), is_atom(Function), is_list(ExtraArgs) ->
    #{<<"kind">> => <<"mfa">>,
      <<"module">> => atom_to_binary(Module, utf8),
      <<"function">> => atom_to_binary(Function, utf8),
      <<"extra_arity">> => length(ExtraArgs)};
callback_descriptor(_Other) -> #{<<"kind">> => <<"unknown">>}.

value_kind(Value) when is_map(Value) -> <<"static_map">>;
value_kind(Value) when is_binary(Value); is_list(Value) -> <<"static">>;
value_kind(Value) when is_function(Value) -> <<"function">>;
value_kind({Module, Function, ExtraArgs})
  when is_atom(Module), is_atom(Function), is_list(ExtraArgs) -> <<"mfa">>;
value_kind(_Other) -> <<"unknown">>.

fun_arity(Fun) ->
    {arity, Arity} = erlang:fun_info(Fun, arity),
    Arity.

merge_descriptor(reject_conflicts) -> <<"reject_conflicts">>;
merge_descriptor(ordered_last_wins) -> <<"ordered_last_wins">>;
merge_descriptor({custom, _Fun}) -> <<"custom">>;
merge_descriptor(_Other) -> <<"unknown">>.

join_policy_descriptor(all) -> <<"all">>;
join_policy_descriptor(any) -> <<"any">>;
join_policy_descriptor(first_success) -> <<"first_success">>;
join_policy_descriptor({quorum, Count}) ->
    #{<<"type">> => <<"quorum">>, <<"count">> => Count};
join_policy_descriptor(_Other) -> <<"unknown">>.

schema_descriptor(undefined) -> null;
schema_descriptor(Schema) -> Schema.

state_reducers_descriptor(Reducers) ->
    maps:map(
      fun(_Key, Policy) -> atom_to_binary(Policy, utf8) end,
      Reducers).

graph_edges(Order, Nodes, Edges) ->
    lists:append([node_edges(Id, maps:get(Id, Nodes), Edges)
                  || Id <- Order]).

node_edges(Id, #{type := fork, branches := Branches}, _Edges) ->
    [edge(Id, Target, <<"fork">>, null) || Target <- Branches];
node_edges(Id, #{type := Type, targets := Targets}, _Edges)
  when Type =:= branch; Type =:= dynamic ->
    [edge(Id, Target, <<"route">>, null) || Target <- Targets];
node_edges(Id, #{type := loop, body := Body, done := Done}, _Edges) ->
    [edge(Id, Body, <<"loop">>, <<"continue">>),
     edge(Id, Done, <<"loop">>, <<"done">>)];
node_edges(Id, _Node, Edges) ->
    case maps:get(Id, Edges, end_node) of
        {route, Callback} ->
            [#{<<"from">> => Id,
               <<"to">> => null,
               <<"kind">> => <<"dynamic_route">>,
               <<"label">> => null,
               <<"decision">> => callback_descriptor(Callback)}];
        Target -> [edge(Id, Target, <<"edge">>, null)]
    end.

edge(From, Target, Kind, Label) ->
    #{<<"from">> => From,
      <<"to">> => end_target(Target),
      <<"kind">> => Kind,
      <<"label">> => Label}.

end_target(end_node) -> <<"$end">>;
end_target(<<"$end">>) -> <<"$end">>;
end_target(Target) -> Target.

analysis_descriptor(Analysis) ->
    #{<<"errors">> => diagnostics(maps:get(errors, Analysis)),
      <<"warnings">> => diagnostics(maps:get(warnings, Analysis)),
      <<"reachable">> => maps:get(reachable, Analysis),
      <<"unreachable">> => maps:get(unreachable, Analysis),
      <<"terminal_reachable">> =>
          maps:get(terminal_reachable, Analysis),
      <<"dynamic_routes">> => maps:get(dynamic_routes, Analysis),
      <<"cycles">> =>
          [#{<<"nodes">> => maps:get(nodes, Cycle),
             <<"explicit_loop">> => maps:get(explicit_loop, Cycle)}
           || Cycle <- maps:get(cycles, Analysis)]}.

diagnostics(Items) -> [diagnostic(Item) || Item <- Items].

diagnostic(Item) ->
    Known = maps:with([severity, code, path, reason, node_id, target,
                       nodes, owner, owners, predecessors], Item),
    maps:from_list(
      [{atom_to_binary(Key, utf8), diagnostic_value(Value)}
       || {Key, Value} <- lists:sort(maps:to_list(Known))]).

diagnostic_value(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
diagnostic_value(Value) when is_list(Value) ->
    [diagnostic_value(Item) || Item <- Value];
diagnostic_value(Value) -> Value.
