-module(erlang_adk).

-export([spawn_agent/3, prompt/2, delegate/2, delegate/3, sequential/2, parallel/2, loop/4]).

%% @doc Spawn a new agent.
spawn_agent(Name, LLMConfig, Tools) ->
    adk_agent_sup:start_agent(Name, LLMConfig, Tools).

%% @doc Synchronously prompt an agent.
prompt(AgentPid, Message) ->
    adk_agent:prompt(AgentPid, Message).

%% @doc Asynchronously delegate a task to an agent (fire and forget).
delegate(Pid, Message) ->
    adk_agent:delegate(Pid, Message).

%% @doc Asynchronously delegate a task to an agent and receive a message when done.
delegate(Pid, Message, ReplyToPid) ->
    adk_agent:delegate(Pid, Message, ReplyToPid).

%% Orchestrators
sequential(Pids, Prompt) ->
    erlang_adk_orchestrator:sequential(Pids, Prompt).

parallel(Pids, Prompt) ->
    erlang_adk_orchestrator:parallel(Pids, Prompt).

loop(WorkerPid, ReviewerPid, Prompt, MaxIterations) ->
    erlang_adk_orchestrator:loop(WorkerPid, ReviewerPid, Prompt, MaxIterations).
