-module(erlang_adk_orchestrator).

-export([sequential/2, parallel/2, loop/4]).

%% @doc sequential takes a list of Agent Pids and an Initial Prompt.
%% It passes the prompt to the first agent, takes its response,
%% and feeds it to the next agent, returning the final agent's response.
sequential([], Prompt) ->
    {ok, Prompt};
sequential([Pid | Rest], Prompt) ->
    case erlang_adk:prompt(Pid, Prompt) of
        {ok, Response} ->
            sequential(Rest, Response);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc parallel takes a list of Agent Pids and a Prompt.
%% It prompts all agents concurrently and gathers their responses.
%% Returns a list of {Pid, Response}.
parallel(Pids, Prompt) ->
    %% Spawn a temporary process for each agent to fetch the response
    Parent = self(),
    Refs = lists:map(fun(Pid) ->
        Ref = make_ref(),
        spawn(fun() ->
            Res = erlang_adk:prompt(Pid, Prompt),
            Parent ! {Ref, Pid, Res}
        end),
        Ref
    end, Pids),
    
    %% Gather results
    lists:map(fun(Ref) ->
        receive
            {Ref, Pid, {ok, Response}} -> {Pid, Response};
            {Ref, Pid, {error, Reason}} -> {Pid, {error, Reason}}
        end
    end, Refs).

%% @doc loop runs a worker agent and a reviewer agent iteratively.
%% MaxIterations prevents infinite loops.
loop(_WorkerPid, _ReviewerPid, LastDraft, 0) ->
    {ok, LastDraft};
loop(WorkerPid, ReviewerPid, Prompt, IterationsLeft) ->
    case erlang_adk:prompt(WorkerPid, Prompt) of
        {ok, Draft} ->
            case erlang_adk:prompt(ReviewerPid, "Review this draft and reply with 'APPROVED' if it meets all requirements. Otherwise provide a critique:\n" ++ Draft) of
                {ok, ReviewBin} ->
                    ReviewStr = case is_binary(ReviewBin) of
                        true -> binary_to_list(ReviewBin);
                        false -> ReviewBin
                    end,
                    %% Simple string match for 'APPROVED'
                    case string:find(string:to_lower(ReviewStr), "approved") of
                        nomatch ->
                            loop(WorkerPid, ReviewerPid, "Please revise your draft based on this critique:\n" ++ ReviewStr, IterationsLeft - 1);
                        _ ->
                            {ok, Draft}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
