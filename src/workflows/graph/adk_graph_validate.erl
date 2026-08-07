%% @doc Structural analysis for compiled workflow graphs.
%%
%% The workflow compiler remains responsible for validating individual fields
%% and executable descriptors.  This module looks at the graph as a whole.  It
%% deliberately separates hard errors from diagnostics which are useful to a
%% developer but cannot be proved invalid in the presence of trusted route and
%% action callbacks.
-module(adk_graph_validate).

-export([validate/1, analyze/1]).

-type report() :: map().

-spec validate(map()) -> ok | {error, term()}.
validate(Data) ->
    case analyze(Data) of
        {ok, #{errors := []}} -> ok;
        {ok, #{errors := [First | _]}} ->
            {error,
             {invalid_workflow,
              maps:get(path, First, [nodes]),
              maps:get(reason, First, invalid_graph_topology)}};
        {error, _} = Error -> Error
    end.

-spec analyze(map()) -> {ok, report()} | {error, term()}.
analyze(#{entry := Entry, nodes := Nodes, edges := Edges} = Data)
  when is_binary(Entry), is_map(Nodes), is_map(Edges) ->
    Order = node_order(Data, Nodes),
    NodeIds = maps:from_list([{Id, true} || Id <- Order]),
    {Adjacency, DynamicRoutes, TerminalSources} =
        semantic_edges(Order, Nodes, Edges, NodeIds),
    ReachableSet = reachable([Entry], #{}, Adjacency, DynamicRoutes,
                             Order),
    Reachable = [Id || Id <- Order, maps:is_key(Id, ReachableSet)],
    Unreachable = [Id || Id <- Order, not maps:is_key(Id, ReachableSet)],
    Reverse = transpose(Order, Adjacency),
    TerminalSet = reachable(TerminalSources, #{}, Reverse, #{}, Order),
    TerminalReachable =
        [Id || Id <- Order, maps:is_key(Id, TerminalSet)],
    Components = strongly_connected_components(Order, Adjacency),
    Cycles = cycle_descriptors(Components, Adjacency, Nodes),
    Errors = join_type_errors(Order, Nodes),
    Warnings0 = unreachable_warnings(Unreachable),
    Warnings1 = terminal_warnings(Entry, TerminalSet, Warnings0),
    Warnings2 = cycle_warnings(Cycles, Warnings1),
    Warnings3 = join_warnings(Order, Nodes, Adjacency, Warnings2),
    {ok, #{errors => Errors,
           warnings => Warnings3,
           node_order => Order,
           reachable => Reachable,
           unreachable => Unreachable,
           terminal_reachable => TerminalReachable,
           dynamic_routes => ordered_members(Order, DynamicRoutes),
           cycles => Cycles,
           adjacency => Adjacency}};
analyze(_Data) ->
    {error, invalid_compiled_graph_data}.

node_order(Data, Nodes) ->
    Candidate = maps:get(node_order, Data, []),
    case is_list(Candidate)
         andalso length(Candidate) =:= map_size(Nodes)
         andalso length(lists:usort(Candidate)) =:= length(Candidate)
         andalso lists:all(fun(Id) -> maps:is_key(Id, Nodes) end,
                           Candidate) of
        true -> Candidate;
        false -> lists:sort(maps:keys(Nodes))
    end.

semantic_edges(Order, Nodes, Edges, NodeIds) ->
    lists:foldl(
      fun(Id, {Adj0, Dynamic0, Terminal0}) ->
              Node = maps:get(Id, Nodes),
              {Targets0, IsDynamic} = node_targets(Id, Node, Edges),
              Targets = lists:usort(
                          [Target || Target <- Targets0,
                                     maps:is_key(Target, NodeIds)]),
              HasEnd = lists:any(fun is_end/1, Targets0),
              Dynamic = case IsDynamic of
                  true -> Dynamic0#{Id => true};
                  false -> Dynamic0
              end,
              Terminal = case HasEnd orelse IsDynamic of
                  true -> [Id | Terminal0];
                  false -> Terminal0
              end,
              {Adj0#{Id => Targets}, Dynamic, Terminal}
      end, {#{}, #{}, []}, Order).

node_targets(_Id, #{type := fork, branches := Branches}, _Edges) ->
    {Branches, false};
node_targets(_Id, #{type := Type, targets := Targets}, _Edges)
  when Type =:= branch; Type =:= dynamic ->
    {Targets, false};
node_targets(_Id, #{type := loop, body := Body, done := Done}, _Edges) ->
    {[Body, Done], false};
node_targets(Id, _Node, Edges) ->
    case maps:get(Id, Edges, end_node) of
        {route, _Callback} -> {[], true};
        Target -> {[Target], false}
    end.

is_end(end_node) -> true;
is_end(<<"$end">>) -> true;
is_end(_) -> false.

reachable([], Seen, _Adjacency, _Dynamic, _Order) -> Seen;
reachable([Id | Rest], Seen, Adjacency, Dynamic, Order) ->
    case maps:is_key(Id, Seen) of
        true -> reachable(Rest, Seen, Adjacency, Dynamic, Order);
        false ->
            Neighbours = case maps:is_key(Id, Dynamic) of
                true -> Order;
                false -> maps:get(Id, Adjacency, [])
            end,
            reachable(Rest ++ Neighbours, Seen#{Id => true},
                      Adjacency, Dynamic, Order)
    end.

transpose(Order, Adjacency) ->
    Empty = maps:from_list([{Id, []} || Id <- Order]),
    maps:fold(
      fun(From, Targets, Acc0) ->
              lists:foldl(
                fun(To, Acc) ->
                        Acc#{To => [From | maps:get(To, Acc, [])]}
                end, Acc0, Targets)
      end, Empty, Adjacency).

strongly_connected_components(Order, Adjacency) ->
    {_Seen, FinishOrder} =
        lists:foldl(
          fun(Id, {Seen0, Acc0}) ->
                  finish_visit(Id, Adjacency, Seen0, Acc0)
          end, {#{}, []}, Order),
    Reverse = transpose(Order, Adjacency),
    {_Assigned, ComponentsRev} =
        lists:foldl(
          fun(Id, {Assigned0, Acc0}) ->
                  case maps:is_key(Id, Assigned0) of
                      true -> {Assigned0, Acc0};
                      false ->
                          {Assigned, Component0} =
                              collect_component(Id, Reverse,
                                                Assigned0, []),
                          Component = ordered_subset(Order, Component0),
                          {Assigned, [Component | Acc0]}
                  end
          end, {#{}, []}, FinishOrder),
    lists:reverse(ComponentsRev).

finish_visit(Id, Adjacency, Seen, Acc) ->
    case maps:is_key(Id, Seen) of
        true -> {Seen, Acc};
        false ->
            Seen1 = Seen#{Id => true},
            {Seen2, Acc1} =
                lists:foldl(
                  fun(Next, {Seen0, Acc0}) ->
                          finish_visit(Next, Adjacency, Seen0, Acc0)
                  end, {Seen1, Acc}, maps:get(Id, Adjacency, [])),
            {Seen2, [Id | Acc1]}
    end.

collect_component(Id, Adjacency, Seen, Acc) ->
    case maps:is_key(Id, Seen) of
        true -> {Seen, Acc};
        false ->
            Seen1 = Seen#{Id => true},
            lists:foldl(
              fun(Next, {Seen0, Acc0}) ->
                      collect_component(Next, Adjacency, Seen0, Acc0)
              end, {Seen1, [Id | Acc]}, maps:get(Id, Adjacency, []))
    end.

ordered_subset(Order, Members) ->
    Set = maps:from_list([{Id, true} || Id <- Members]),
    [Id || Id <- Order, maps:is_key(Id, Set)].

cycle_descriptors(Components, Adjacency, Nodes) ->
    [#{nodes => Component,
       explicit_loop => lists:any(
                          fun(Id) ->
                                  maps:get(type, maps:get(Id, Nodes), action)
                                      =:= loop
                          end, Component)}
     || Component <- Components,
        is_cycle(Component, Adjacency)].

is_cycle([Id], Adjacency) ->
    lists:member(Id, maps:get(Id, Adjacency, []));
is_cycle(Component, _Adjacency) -> length(Component) > 1.

join_type_errors(Order, Nodes) ->
    lists:foldl(
      fun(Id, Acc) ->
              case maps:get(Id, Nodes) of
                  #{type := fork, join := Join} ->
                      case maps:get(Join, Nodes, undefined) of
                          #{type := join} -> Acc;
                          _ ->
                              Acc ++
                              [diagnostic(
                                 error, fork_join_must_be_join_node,
                                 [nodes, Id, join],
                                 join_must_reference_join_node,
                                 #{node_id => Id, target => Join})]
                      end;
                  _ -> Acc
              end
      end, [], Order).

unreachable_warnings(Unreachable) ->
    [diagnostic(warning, unreachable_node, [nodes, Id],
                unreachable_node, #{node_id => Id})
     || Id <- Unreachable].

terminal_warnings(Entry, TerminalSet, Warnings) ->
    case maps:is_key(Entry, TerminalSet) of
        true -> Warnings;
        false ->
            Warnings ++
            [diagnostic(warning, no_static_terminal_path, [entry],
                        no_static_terminal_path, #{node_id => Entry})]
    end.

cycle_warnings(Cycles, Warnings) ->
    Warnings ++
    [diagnostic(warning, cycle_relies_on_global_max_steps,
                [nodes, hd(maps:get(nodes, Cycle))],
                cycle_relies_on_global_max_steps,
                #{nodes => maps:get(nodes, Cycle)})
     || Cycle <- Cycles,
        maps:get(explicit_loop, Cycle) =:= false].

join_warnings(Order, Nodes, Adjacency, Warnings) ->
    Forks = [{Id, maps:get(branches, Node), maps:get(join, Node)}
             || Id <- Order,
                Node <- [maps:get(Id, Nodes)],
                maps:get(type, Node, action) =:= fork],
    Joins = [Id || Id <- Order,
                   maps:get(type, maps:get(Id, Nodes), action) =:= join],
    Warnings1 = lists:foldl(
      fun(Join, Acc) ->
              Owners = [ForkId || {ForkId, _Branches, Target} <- Forks,
                                  Target =:= Join],
              case Owners of
                  [] ->
                      Acc ++ [diagnostic(
                                warning, orphan_join, [nodes, Join],
                                orphan_join, #{node_id => Join})];
                  [_] -> Acc;
                  _ ->
                      Acc ++ [diagnostic(
                                warning, shared_fork_join,
                                [nodes, Join], shared_fork_join,
                                #{node_id => Join, owners => Owners})]
              end
      end, Warnings, Joins),
    BranchOwners = lists:foldl(
      fun({ForkId, Branches, _Join}, Acc0) ->
              lists:foldl(
                fun(Branch, Acc) ->
                        Acc#{Branch =>
                                 maps:get(Branch, Acc, []) ++ [ForkId]}
                end, Acc0, Branches)
      end, #{}, Forks),
    SharedBranchWarnings =
        [diagnostic(warning, shared_fork_branch,
                    [nodes, Branch], shared_fork_branch,
                    #{node_id => Branch, owners => Owners})
         || Branch <- Order,
            Owners <- [maps:get(Branch, BranchOwners, [])],
            length(Owners) > 1],
    ExternalWarnings =
        lists:foldl(
          fun({ForkId, Branches, Join}, Acc) ->
                  Incoming = [From || From <- Order,
                                      lists:member(
                                        Join,
                                        maps:get(From, Adjacency, []))],
                  External = [From || From <- Incoming,
                                      not lists:member(From, Branches)],
                  case External of
                      [] -> Acc;
                      _ -> Acc ++ [diagnostic(
                                     warning,
                                     join_has_external_predecessors,
                                     [nodes, Join],
                                     join_has_external_predecessors,
                                     #{node_id => Join,
                                       owner => ForkId,
                                       predecessors => External})]
                  end
          end, [], Forks),
    Warnings1 ++ SharedBranchWarnings ++ ExternalWarnings.

diagnostic(Severity, Code, Path, Reason, Details) ->
    Details#{severity => Severity, code => Code,
             path => Path, reason => Reason}.

ordered_members(Order, Set) ->
    [Id || Id <- Order, maps:is_key(Id, Set)].
