%% @doc adk_graph - Graph-based workflow engine for ADK 2.0.
%%
%% This module allows constructing stateful execution graphs where nodes can be 
%% agents, functions, or sub-graphs, and edges define the conditional routing.
-module(adk_graph).

-export([new/0, add_node/3, add_edge/3, add_conditional_edge/3, set_entry_point/2]).
-export([compile/1, run/2]).

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
            %% In a full implementation, we would validate that all edges point to valid nodes.
            %% For brevity, we assume the graph is valid.
            {ok, #compiled_graph{
                nodes = Graph#graph.nodes,
                edges = Graph#graph.edges,
                entry_point = Entry
            }}
    end.

%% @doc Execute the compiled graph with an initial state.
-spec run(CompiledGraph :: compiled_graph(), InitialState :: map()) -> {ok, map()} | {error, term()}.
run(CompiledGraph, InitialState) ->
    Entry = CompiledGraph#compiled_graph.entry_point,
    execute_node(CompiledGraph, Entry, InitialState).

%% Internal Functions

execute_node(_CompiledGraph, end_node, State) ->
    {ok, State};
execute_node(CompiledGraph, NodeName, State) ->
    case maps:find(NodeName, CompiledGraph#compiled_graph.nodes) of
        {ok, NodeFn} ->
            try
                %% 1. Execute the node function, merging state
                NewState = maps:merge(State, NodeFn(State)),
                
                %% 2. Determine the next node based on edges
                NextNode = determine_next_node(CompiledGraph, NodeName, NewState),
                
                %% 3. Recurse
                execute_node(CompiledGraph, NextNode, NewState)
            catch
                E:R:S ->
                    logger:error("Graph execution error at ~p: ~p:~p~n~p", [NodeName, E, R, S]),
                    {error, {node_execution_failed, NodeName, R}}
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
