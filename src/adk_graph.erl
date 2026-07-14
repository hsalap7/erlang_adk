%% @doc adk_graph - Graph-based workflow engine for Erlang ADK.
%%
%% This module allows constructing stateful execution graphs where nodes can be 
%% agents, functions, or sub-graphs, and edges define the conditional routing.
-module(adk_graph).

-export([new/0, add_node/3, add_edge/3, add_conditional_edge/3, set_entry_point/2]).
-export([compile/1, run/2, run/3]).

-type node_name() :: atom() | binary().
-type node_fn() :: fun((map()) -> map()).
-type edge_condition() :: fun((map()) -> node_name() | end_node).

-record(graph, {
    nodes = #{} :: #{node_name() => node_fn()},
    edges = #{} :: #{node_name() => node_name() | edge_condition()},
    entry_point :: node_name() | undefined
}).

-record(compiled_graph, {
    nodes :: #{node_name() => node_fn()},
    edges :: #{node_name() => node_name() | edge_condition()},
    entry_point :: node_name()
}).

-type graph() :: #graph{}.
-type compiled_graph() :: #compiled_graph{}.

%% @doc Initialize a new, empty graph.
-spec new() -> graph().
new() ->
    #graph{}.

%% @doc Add a computation node to the graph.
-spec add_node(Graph :: graph(), Name :: node_name(), NodeFn :: node_fn()) -> graph().
add_node(Graph, Name, NodeFn) ->
    Nodes = Graph#graph.nodes,
    Graph#graph{nodes = Nodes#{Name => NodeFn}}.

%% @doc Add a deterministic edge from one node to another.
-spec add_edge(Graph :: graph(), From :: node_name(), To :: node_name() | end_node) -> graph().
add_edge(Graph, From, To) ->
    Edges = Graph#graph.edges,
    Graph#graph{edges = Edges#{From => To}}.

%% @doc Add a conditional edge that decides the next node based on state.
-spec add_conditional_edge(Graph :: graph(), From :: node_name(), ConditionFn :: edge_condition()) -> graph().
add_conditional_edge(Graph, From, ConditionFn) ->
    Edges = Graph#graph.edges,
    Graph#graph{edges = Edges#{From => ConditionFn}}.

%% @doc Set the entry point (starting node) of the graph.
-spec set_entry_point(Graph :: graph(), Entry :: node_name()) -> graph().
set_entry_point(Graph, Entry) ->
    Graph#graph{entry_point = Entry}.

%% @doc Compile the graph, verifying it is well-formed.
-spec compile(Graph :: graph()) -> {ok, compiled_graph()} | {error, term()}.
compile(Graph) ->
    case Graph#graph.entry_point of
        undefined -> {error, missing_entry_point};
        Entry ->
            case validate_graph(Entry, Graph#graph.nodes, Graph#graph.edges) of
                ok ->
                    {ok, #compiled_graph{
                        nodes = Graph#graph.nodes,
                        edges = Graph#graph.edges,
                        entry_point = Entry
                    }};
                Error -> Error
            end
    end.

%% @doc Execute the compiled graph with an initial state.
-spec run(CompiledGraph :: compiled_graph(), InitialState :: map()) -> {ok, map()} | {error, term()}.
run(CompiledGraph, InitialState) ->
    run(CompiledGraph, InitialState, #{}).

%% @doc Execute with a configurable safety bound for cyclic graphs.
-spec run(CompiledGraph :: compiled_graph(), InitialState :: map(), Opts :: map()) ->
    {ok, map()} | {error, term()}.
run(CompiledGraph, InitialState, Opts) ->
    Entry = CompiledGraph#compiled_graph.entry_point,
    MaxSteps = maps:get(max_steps, Opts, 10000),
    case is_integer(MaxSteps) andalso MaxSteps > 0 of
        true -> execute_node(CompiledGraph, Entry, InitialState, 0, MaxSteps);
        false -> {error, {invalid_max_steps, MaxSteps}}
    end.

%% Internal Functions

execute_node(_CompiledGraph, end_node, State, _Steps, _MaxSteps) ->
    {ok, State};
execute_node(_CompiledGraph, _NodeName, _State, Steps, MaxSteps)
  when Steps >= MaxSteps ->
    {error, {max_steps_exceeded, MaxSteps}};
execute_node(CompiledGraph, NodeName, State, Steps, MaxSteps) ->
    case maps:find(NodeName, CompiledGraph#compiled_graph.nodes) of
        {ok, NodeFn} ->
            try
                %% 1. Execute the node function, merging state
                NewState = maps:merge(State, NodeFn(State)),
                
                %% 2. Determine the next node based on edges
                NextNode = determine_next_node(CompiledGraph, NodeName, NewState),
                
                %% 3. Recurse
                execute_node(CompiledGraph, NextNode, NewState,
                             Steps + 1, MaxSteps)
            catch
                Class:Reason:_Stack ->
                    Failure = adk_failure:exception(
                                graph, execute_node, Class, Reason),
                    logger:error("Graph node execution failed: ~p",
                                 [Failure]),
                    {error, Failure}
            end;
        error ->
            {error, {unknown_node, NodeName}}
    end.

determine_next_node(CompiledGraph, NodeName, State) ->
    case maps:find(NodeName, CompiledGraph#compiled_graph.edges) of
        {ok, Target} when is_atom(Target) orelse is_binary(Target) -> 
            Target;
        {ok, ConditionFn} when is_function(ConditionFn) ->
            ConditionFn(State);
        error ->
            %% If no edge is defined, implicitly end
            end_node
    end.

validate_graph(Entry, Nodes, Edges) ->
    case maps:is_key(Entry, Nodes) of
        false -> {error, {unknown_entry_point, Entry}};
        true ->
            maps:fold(fun(From, Target, Acc) ->
                case Acc of
                    ok -> validate_edge(From, Target, Nodes);
                    Error -> Error
                end
            end, ok, Edges)
    end.

validate_edge(From, _Target, Nodes) when not is_map_key(From, Nodes) ->
    {error, {unknown_edge_source, From}};
validate_edge(_From, Target, _Nodes) when is_function(Target, 1) ->
    ok;
validate_edge(_From, end_node, _Nodes) ->
    ok;
validate_edge(_From, Target, Nodes) ->
    case maps:is_key(Target, Nodes) of
        true -> ok;
        false -> {error, {unknown_edge_target, Target}}
    end.
