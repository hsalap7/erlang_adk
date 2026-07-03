-module(erlang_adk_orchestrator).

-export([sequential/2, parallel/2, loop/4]).

%% @doc sequential takes a list of Agent Pids and an Initial Prompt.
%% It constructs a sequential graph of the agents and executes it.
sequential([], Prompt) ->
    {ok, Prompt};
sequential(Pids, Prompt) ->
    G0 = adk_graph:new(),
    
    %% Create nodes and edges
    {GFinal, EntryNode, _LastNode} = build_seq_graph(G0, Pids, 1, undefined, undefined),
    
    GReady = adk_graph:set_entry_point(GFinal, EntryNode),
    {ok, Compiled} = adk_graph:compile(GReady),
    
    %% Run the graph
    case adk_graph:run(Compiled, #{<<"prompt">> => Prompt}) of
        {ok, FinalState} -> {ok, maps:get(<<"prompt">>, FinalState)};
        {error, Reason} -> {error, Reason}
    end.

build_seq_graph(G, [], _Index, EntryNode, LastNode) ->
    %% Add edge from last node to end_node
    G1 = adk_graph:add_edge(G, LastNode, end_node),
    {G1, EntryNode, LastNode};
build_seq_graph(G, [Pid | Rest], Index, EntryNode, LastNode) ->
    NodeName = list_to_atom("agent_" ++ integer_to_list(Index)),
    
    NodeFn = fun(State) ->
        Input = maps:get(<<"prompt">>, State),
        case erlang_adk:prompt(Pid, Input) of
            {ok, Response} -> #{<<"prompt">> => Response};
            {error, Reason} -> erlang:error(Reason)
        end
    end,
    
    G1 = adk_graph:add_node(G, NodeName, NodeFn),
    
    G2 = case LastNode of
        undefined -> G1;
        _ -> adk_graph:add_edge(G1, LastNode, NodeName)
    end,
    
    EntryNode1 = case EntryNode of
        undefined -> NodeName;
        _ -> EntryNode
    end,
    
    build_seq_graph(G2, Rest, Index + 1, EntryNode1, NodeName).

%% @doc parallel takes a list of Agent Pids and a Prompt.
%% It prompts all agents concurrently using the graph engine.
parallel(Pids, Prompt) ->
    G0 = adk_graph:new(),
    
    ParallelNodeFn = fun(State) ->
        Input = maps:get(<<"prompt">>, State),
        Parent = self(),
        Refs = lists:map(fun(Pid) ->
            Ref = make_ref(),
            proc_lib:spawn(fun() -> Parent ! {Ref, Pid, erlang_adk:prompt(Pid, Input)} end),
            Ref
        end, Pids),
        
        Results = lists:map(fun(Ref) ->
            receive 
                {Ref, Pid, {ok, Response}} -> {Pid, Response};
                {Ref, Pid, {error, Reason}} -> {Pid, {error, Reason}}
            end
        end, Refs),
        #{<<"results">> => Results}
    end,

    G1 = adk_graph:add_node(G0, parallel_node, ParallelNodeFn),
    G2 = adk_graph:add_edge(G1, parallel_node, end_node),
    G3 = adk_graph:set_entry_point(G2, parallel_node),
    {ok, Compiled} = adk_graph:compile(G3),
    
    {ok, FinalState} = adk_graph:run(Compiled, #{<<"prompt">> => Prompt}),
    maps:get(<<"results">>, FinalState, []).

%% @doc loop runs a worker agent and a reviewer agent iteratively using a graph.
loop(_WorkerPid, _ReviewerPid, LastDraft, 0) ->
    {ok, LastDraft};
loop(WorkerPid, ReviewerPid, Prompt, IterationsLeft) ->
    G0 = adk_graph:new(),
    
    WorkerNode = fun(State) ->
        Input = maps:get(<<"prompt">>, State),
        case erlang_adk:prompt(WorkerPid, Input) of
            {ok, Draft} -> #{<<"draft">> => Draft};
            {error, Reason} -> erlang:error(Reason)
        end
    end,
    
    ReviewerNode = fun(State) ->
        Draft = maps:get(<<"draft">>, State),
        Iters = maps:get(<<"iters">>, State),
        case erlang_adk:prompt(ReviewerPid, "Review this draft and reply with 'APPROVED' if it meets all requirements. Otherwise provide a critique:\n" ++ Draft) of
            {ok, ReviewBin} ->
                ReviewStr = case is_binary(ReviewBin) of
                    true -> binary_to_list(ReviewBin);
                    false -> ReviewBin
                end,
                case string:find(string:to_lower(ReviewStr), "approved") of
                    nomatch ->
                        #{<<"prompt">> => "Please revise your draft based on this critique:\n" ++ ReviewStr,
                          <<"approved">> => false,
                          <<"iters">> => Iters - 1};
                    _ ->
                        #{<<"approved">> => true}
                end;
            {error, Reason} ->
                erlang:error(Reason)
        end
    end,
    
    G1 = adk_graph:add_node(G0, worker, WorkerNode),
    G2 = adk_graph:add_node(G1, reviewer, ReviewerNode),
    
    G3 = adk_graph:add_edge(G2, worker, reviewer),
    
    CondFn = fun(State) ->
        Approved = maps:get(<<"approved">>, State, false),
        Iters = maps:get(<<"iters">>, State),
        if
            Approved -> end_node;
            Iters =< 0 -> end_node;
            true -> worker
        end
    end,
    
    G4 = adk_graph:add_conditional_edge(G3, reviewer, CondFn),
    G5 = adk_graph:set_entry_point(G4, worker),
    
    {ok, Compiled} = adk_graph:compile(G5),
    
    case adk_graph:run(Compiled, #{<<"prompt">> => Prompt, <<"iters">> => IterationsLeft}) of
        {ok, FinalState} -> {ok, maps:get(<<"draft">>, FinalState)};
        {error, Reason} -> {error, Reason}
    end.
