%% @doc Fluent compatibility builder for the canonical workflow graph.
%%
%% The original `adk_graph' API returns `{ok, State}' and accepts atom node
%% names. Compilation now lowers that representation into a canonical
%% `adk_workflow' graph while preserving those public result forms. `run/3'
%% keeps the old term-friendly executor by default and accepts
%% `runtime => workflow' as an explicit JSON-safe migration boundary. New
%% applications which need typed nodes, fork/join, pause or durable invocation
%% should build a `kind => graph' workflow specification directly; the
%% inspection functions work for either compiled form.
-module(adk_graph).

-export([new/0, add_node/3, add_edge/3, add_conditional_edge/3,
         set_entry_point/2]).
-export([compile/1, run/2, run/3, to_workflow/1,
         describe/1, to_dot/1, to_mermaid/1]).

-type node_name() :: atom() | binary().
-type node_fn() :: fun((map()) -> term()).
-type edge_condition() :: fun((map()) -> node_name() | end_node).

-record(graph, {
    nodes = #{} :: #{node_name() => node_fn()},
    edges = #{} :: #{node_name() => node_name() | edge_condition()},
    entry_point :: node_name() | undefined
}).

-record(compiled_graph, {
    nodes :: #{node_name() => node_fn()},
    edges :: #{node_name() => node_name() | edge_condition()},
    entry_point :: node_name(),
    workflow :: map()
}).

-type graph() :: #graph{}.
-type compiled_graph() :: #compiled_graph{}.

%% @doc Initialize a new, empty graph.
-spec new() -> graph().
new() -> #graph{}.

%% @doc Add or replace a computation node.
-spec add_node(graph(), node_name(), node_fn()) -> graph().
add_node(Graph, Name, NodeFn) ->
    Nodes = Graph#graph.nodes,
    Graph#graph{nodes = Nodes#{Name => NodeFn}}.

%% @doc Add or replace a deterministic edge.
-spec add_edge(graph(), node_name(), node_name() | end_node) -> graph().
add_edge(Graph, From, To) ->
    Edges = Graph#graph.edges,
    Graph#graph{edges = Edges#{From => To}}.

%% @doc Add or replace a state-dependent edge.
-spec add_conditional_edge(graph(), node_name(), edge_condition()) -> graph().
add_conditional_edge(Graph, From, ConditionFn) ->
    Edges = Graph#graph.edges,
    Graph#graph{edges = Edges#{From => ConditionFn}}.

%% @doc Set the starting node.
-spec set_entry_point(graph(), node_name()) -> graph().
set_entry_point(Graph, Entry) -> Graph#graph{entry_point = Entry}.

%% @doc Compile into a compatibility handle backed by `adk_workflow'.
-spec compile(graph()) -> {ok, compiled_graph()} | {error, term()}.
compile(Graph) ->
    case Graph#graph.entry_point of
        undefined -> {error, missing_entry_point};
        Entry ->
            case validate_graph(Entry, Graph#graph.nodes,
                                Graph#graph.edges) of
                ok -> compile_canonical(Graph);
                {error, _} = Error -> Error
            end
    end.

%% @doc Return the canonical compiled workflow behind a compatibility graph.
-spec to_workflow(graph() | compiled_graph() | map()) ->
    {ok, map()} | {error, term()}.
to_workflow(#compiled_graph{workflow = Workflow}) -> {ok, Workflow};
to_workflow(Graph = #graph{}) ->
    case compile(Graph) of
        {ok, Compiled} -> to_workflow(Compiled);
        {error, _} = Error -> Error
    end;
to_workflow(#{'$adk_workflow_compiled' := true,
              kind := graph, data := Data} = Workflow)
  when is_map(Data) ->
    {ok, Workflow};
to_workflow(_Other) -> {error, invalid_graph}.

%% @doc Execute with the legacy result form and term-compatible default.
-spec run(compiled_graph(), map()) -> {ok, map()} | {error, term()}.
run(CompiledGraph, InitialState) -> run(CompiledGraph, InitialState, #{}).

%% @doc Execute with a positive `max_steps' bound. Set `runtime => workflow'
%% to use the supervised JSON-safe workflow engine.
-spec run(compiled_graph(), map(), map()) ->
    {ok, map()} | {error, term()}.
run(#compiled_graph{workflow = Workflow}, InitialState, Opts)
  when is_map(Opts) ->
    MaxSteps = maps:get(max_steps, Opts, 10000),
    case is_integer(MaxSteps) andalso MaxSteps > 0 of
        false -> {error, {invalid_max_steps, MaxSteps}};
        true ->
            case maps:get(runtime, Opts, legacy) of
                workflow ->
                    Outcome = adk_workflow:run(
                                Workflow, InitialState,
                                #{max_steps => MaxSteps,
                                  timeout => infinity,
                                  retention_ms => 1000}),
                    compatibility_outcome(Outcome, MaxSteps);
                _CompatibilityRuntime ->
                    %% Legacy graphs historically accepted arbitrary Erlang
                    %% terms, including pids used by the orchestration helper.
                    %% The durable runtime intentionally requires JSON-safe
                    %% state, so changing the default would silently narrow the
                    %% compatibility contract.  `runtime => workflow' is the
                    %% explicit migration boundary.
                    execute_legacy(Workflow, InitialState, MaxSteps)
            end
    end.

%% @doc Return a deterministic JSON-safe descriptor without callbacks or args.
-spec describe(graph() | compiled_graph() | map()) ->
    {ok, map()} | {error, term()}.
describe(Value) -> with_workflow(Value, fun adk_graph_inspect:describe/1).

%% @doc Render the graph as deterministic Graphviz DOT.
-spec to_dot(graph() | compiled_graph() | map()) ->
    {ok, binary()} | {error, term()}.
to_dot(Value) -> with_workflow(Value, fun adk_graph_inspect:to_dot/1).

%% @doc Render the graph as deterministic Mermaid flowchart source.
-spec to_mermaid(graph() | compiled_graph() | map()) ->
    {ok, binary()} | {error, term()}.
to_mermaid(Value) ->
    with_workflow(Value, fun adk_graph_inspect:to_mermaid/1).

with_workflow(Value, Fun) ->
    case to_workflow(Value) of
        {ok, Workflow} -> Fun(Workflow);
        {error, _} = Error -> Error
    end.

compile_canonical(#graph{nodes = Nodes0, edges = Edges0,
                         entry_point = Entry0}) ->
    case canonical_names(maps:keys(Nodes0)) of
        {error, _} = Error -> Error;
        {ok, Names} ->
            Entry = maps:get(Entry0, Names),
            OrderedNames = lists:sort(
                             fun(Left, Right) ->
                                     maps:get(Left, Names)
                                         < maps:get(Right, Names)
                             end, maps:keys(Nodes0)),
            Nodes = [#{id => maps:get(Name, Names),
                       run => wrap_node(maps:get(Name, Nodes0))}
                     || Name <- OrderedNames],
            Edges = maps:from_list(
                      [{maps:get(Name, Names),
                        canonical_edge(maps:get(Name, Edges0, end_node),
                                       Names)}
                       || Name <- OrderedNames]),
            WorkflowId = legacy_workflow_id(Entry, OrderedNames,
                                            Edges0, Names),
            Spec = #{version => 1,
                     id => WorkflowId,
                     kind => graph,
                     entry => Entry,
                     nodes => Nodes,
                     edges => Edges,
                     max_steps => 10000},
            case adk_workflow:compile(Spec) of
                {ok, Workflow} ->
                    {ok, #compiled_graph{nodes = Nodes0,
                                         edges = Edges0,
                                         entry_point = Entry0,
                                         workflow = Workflow}};
                {error, _} = Error -> Error
            end
    end.

canonical_names(Names) -> canonical_names(Names, #{}, #{}).

canonical_names([], ByOriginal, _ByCanonical) -> {ok, ByOriginal};
canonical_names([Name | Rest], ByOriginal, ByCanonical) ->
    case canonical_name(Name) of
        {error, _} = Error -> Error;
        {ok, Canonical} ->
            case maps:find(Canonical, ByCanonical) of
                {ok, _Other} ->
                    {error, {canonical_name_collision, Canonical}};
                error ->
                    canonical_names(Rest,
                                    ByOriginal#{Name => Canonical},
                                    ByCanonical#{Canonical => Name})
            end
    end.

canonical_name(end_node) -> {error, {reserved_node_name, end_node}};
canonical_name(<<"$end">>) -> {error, {reserved_node_name, <<"$end">>}};
canonical_name(Name) when is_atom(Name) ->
    {ok, atom_to_binary(Name, utf8)};
canonical_name(Name) when is_binary(Name) -> {ok, Name};
canonical_name(Name) -> {error, {invalid_node_name, Name}}.

wrap_node(NodeFn) ->
    fun(State, _Context) ->
        try NodeFn(State) of
            Delta when is_map(Delta) -> {ok, Delta};
            _Other -> erlang:error(invalid_legacy_graph_node_result)
        catch
            Class:Reason:Stack -> erlang:raise(Class, Reason, Stack)
        end
    end.

canonical_edge(end_node, _Names) -> end_node;
canonical_edge(ConditionFn, Names) when is_function(ConditionFn, 1) ->
    {route,
     fun(State, _Context) ->
         canonical_runtime_target(ConditionFn(State), Names)
     end};
canonical_edge(Target, Names) -> maps:get(Target, Names).

canonical_runtime_target(end_node, _Names) -> end_node;
canonical_runtime_target(Target, Names) ->
    case maps:find(Target, Names) of
        {ok, Canonical} -> Canonical;
        error ->
            case canonical_name(Target) of
                {ok, Canonical} -> Canonical;
                {error, _} -> Target
            end
    end.

legacy_workflow_id(Entry, OrderedNames, Edges, Names) ->
    EdgeShape =
        [{maps:get(Name, Names),
          edge_shape(maps:get(Name, Edges, end_node), Names)}
         || Name <- OrderedNames],
    Hash = crypto:hash(sha256,
                       term_to_binary({Entry, EdgeShape}, [deterministic])),
    Hex = binary:encode_hex(Hash),
    <<Prefix:24/binary, _/binary>> = Hex,
    <<"legacy-graph-", Prefix/binary>>.

edge_shape(end_node, _Names) -> end_node;
edge_shape(Condition, _Names) when is_function(Condition, 1) -> dynamic;
edge_shape(Target, Names) -> maps:get(Target, Names).

compatibility_outcome({completed, State, _Checkpoint}, _MaxSteps) ->
    {ok, State};
compatibility_outcome({failed, {budget_exhausted, steps}, _Checkpoint},
                      MaxSteps) ->
    {error, {max_steps_exceeded, MaxSteps}};
compatibility_outcome({failed, {node_failed, _Id, Reason}, _Checkpoint},
                      _MaxSteps) ->
    {error, Reason};
compatibility_outcome({failed, Reason, _Checkpoint}, _MaxSteps) ->
    {error, Reason};
compatibility_outcome({timed_out, _Checkpoint}, _MaxSteps) ->
    {error, timeout};
compatibility_outcome({cancelled, Reason, _Checkpoint}, _MaxSteps) ->
    {error, Reason};
compatibility_outcome({paused, Details, _Checkpoint}, _MaxSteps) ->
    {error, {paused, Details}};
compatibility_outcome({error, _} = Error, _MaxSteps) -> Error.

execute_legacy(Workflow, InitialState, MaxSteps) ->
    Data = maps:get(data, Workflow),
    execute_legacy_node(maps:get(nodes, Data), maps:get(edges, Data),
                        maps:get(entry, Data), InitialState, 0, MaxSteps).

execute_legacy_node(_Nodes, _Edges, end_node, State, _Steps, _MaxSteps) ->
    {ok, State};
execute_legacy_node(_Nodes, _Edges, _NodeId, _State, Steps, MaxSteps)
  when Steps >= MaxSteps ->
    {error, {max_steps_exceeded, MaxSteps}};
execute_legacy_node(Nodes, Edges, NodeId, State, Steps, MaxSteps) ->
    case maps:find(NodeId, Nodes) of
        error -> {error, {unknown_node, NodeId}};
        {ok, Node} ->
            try
                Delta = invoke_legacy_wrapper(maps:get(run, Node), State),
                NewState = maps:merge(State, Delta),
                Next = legacy_next(maps:get(NodeId, Edges), NewState),
                execute_legacy_node(Nodes, Edges, Next, NewState,
                                    Steps + 1, MaxSteps)
            catch
                Class:Reason:_Stack ->
                    Failure = adk_failure:exception(
                                graph, execute_node, Class, Reason),
                    logger:error("Graph node execution failed: ~p",
                                 [Failure]),
                    {error, Failure}
            end
    end.

invoke_legacy_wrapper(Wrapper, State) ->
    case Wrapper(State, #{}) of
        {ok, Delta} when is_map(Delta) -> Delta;
        _Other -> erlang:error(invalid_legacy_graph_node_result)
    end.

legacy_next(end_node, _State) -> end_node;
legacy_next(Target, _State) when is_binary(Target) -> Target;
legacy_next({route, Route}, State) -> Route(State, #{}).

validate_graph(Entry, Nodes, Edges) ->
    case maps:is_key(Entry, Nodes) of
        false -> {error, {unknown_entry_point, Entry}};
        true ->
            maps:fold(
              fun(From, Target, Acc) ->
                      case Acc of
                          ok -> validate_edge(From, Target, Nodes);
                          {error, _} = Error -> Error
                      end
              end, ok, Edges)
    end.

validate_edge(From, _Target, Nodes) when not is_map_key(From, Nodes) ->
    {error, {unknown_edge_source, From}};
validate_edge(_From, Target, _Nodes) when is_function(Target, 1) -> ok;
validate_edge(_From, end_node, _Nodes) -> ok;
validate_edge(_From, Target, Nodes) ->
    case maps:is_key(Target, Nodes) of
        true -> ok;
        false -> {error, {unknown_edge_target, Target}}
    end.
