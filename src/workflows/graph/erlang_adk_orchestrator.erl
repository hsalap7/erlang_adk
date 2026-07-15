-module(erlang_adk_orchestrator).

-export([sequential/2, parallel/2, parallel/3, loop/4]).

%% @doc sequential takes a list of Agent Pids and an Initial Prompt.
%% It constructs a sequential graph of the agents and executes it.
sequential([], Prompt) ->
    {ok, to_binary(Prompt)};
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
    NodeName = <<"agent_", (integer_to_binary(Index))/binary>>,

    NodeFn = fun(State) ->
        Input = maps:get(<<"prompt">>, State),
        case adk_agent:prompt(Pid, Input) of
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
    parallel(Pids, Prompt, 60000).

%% @doc Prompt agents concurrently with one overall deadline. Results retain
%% the input PID order and contain `{error, Reason}' for failed branches.
parallel(Pids, Prompt, Timeout) when is_integer(Timeout), Timeout > 0 ->
    G0 = adk_graph:new(),

    ParallelNodeFn = fun(State) ->
        Input = maps:get(<<"prompt">>, State),
        Parent = self(),
        Jobs = lists:map(fun(Pid) ->
            Ref = make_ref(),
            {Worker, Monitor} = spawn_monitor(fun() ->
                Result = try adk_agent:prompt(Pid, Input) of
                    Value -> Value
                catch
                    Class:Reason -> {error, {Class, Reason}}
                end,
                Parent ! {Ref, Pid, Result}
            end),
            {Ref, Pid, Worker, Monitor}
        end, Pids),
        Deadline = erlang:monotonic_time(millisecond) + Timeout,
        Results = collect_parallel(Jobs, Deadline, []),
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
    {ok, to_binary(LastDraft)};
loop(_WorkerPid, _ReviewerPid, _Prompt, MaxIterations)
  when MaxIterations < 0 ->
    {error, invalid_max_iterations};
loop(WorkerPid, ReviewerPid, Prompt, IterationsLeft) ->
    G0 = adk_graph:new(),

    WorkerNode = fun(State) ->
        Input = maps:get(<<"prompt">>, State),
        case adk_agent:prompt(WorkerPid, Input) of
            {ok, Draft} -> #{<<"draft">> => Draft};
            {error, Reason} -> erlang:error(Reason)
        end
    end,

    ReviewerNode = fun(State) ->
        Draft = maps:get(<<"draft">>, State),
        Iters = maps:get(<<"iters">>, State),
        ReviewPrompt =
            <<"Review this draft and reply with exactly 'APPROVED' if it meets "
              "all requirements. Otherwise provide a critique:\n",
              (to_binary(Draft))/binary>>,
        case adk_agent:prompt(ReviewerPid, ReviewPrompt) of
            {ok, ReviewBin} ->
                ReviewText = to_binary(ReviewBin),
                case string:uppercase(string:trim(ReviewText)) of
                    <<"APPROVED">> ->
                        #{<<"approved">> => true};
                    _ ->
                        #{<<"prompt">> =>
                              <<"Please revise your draft based on this critique:\n",
                                ReviewText/binary>>,
                          <<"approved">> => false,
                          <<"iters">> => Iters - 1}
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

collect_parallel([], _Deadline, Acc) ->
    lists:reverse(Acc);
collect_parallel([{Ref, Pid, Worker, Monitor} | Rest], Deadline, Acc) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, Pid, {ok, Response}} ->
            erlang:demonitor(Monitor, [flush]),
            collect_parallel(Rest, Deadline, [{Pid, Response} | Acc]);
        {Ref, Pid, {error, Reason}} ->
            erlang:demonitor(Monitor, [flush]),
            collect_parallel(Rest, Deadline, [{Pid, {error, Reason}} | Acc]);
        {'DOWN', Monitor, process, Worker, Reason} ->
            collect_parallel(Rest, Deadline,
                             [{Pid, {error, {worker_down, Reason}}} | Acc])
    after Remaining ->
        exit(Worker, kill),
        erlang:demonitor(Monitor, [flush]),
        collect_parallel(Rest, Deadline, [{Pid, {error, timeout}} | Acc])
    end.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value).
