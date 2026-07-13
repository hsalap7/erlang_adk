-module(erlang_adk).

-export([spawn_agent/3, stop_agent/1, prompt/2, delegate/2, delegate/3,
         delegate/4, sequential/2, parallel/2, parallel/3, loop/4]).

%% @doc Spawn a new agent.
spawn_agent(Name, LLMConfig, Tools) ->
    adk_agent_sup:start_agent(Name, LLMConfig, Tools).

%% @doc Stop an agent gracefully so its name can be reused.
stop_agent(AgentPid) ->
    adk_agent:stop(AgentPid).

%% @doc Synchronously prompt an agent.
prompt(AgentPid, Message) ->
    adk_agent:prompt(AgentPid, Message).

%% @doc Asynchronously delegate a task to an agent (fire and forget).
delegate(Pid, Message) ->
    adk_agent:delegate(Pid, Message).

%% @doc Asynchronously delegate a task to an agent and receive a message when done.
delegate(Pid, Message, ReplyToPid) ->
    adk_agent:delegate(Pid, Message, ReplyToPid).

%% @doc Asynchronously delegate and correlate the reply with Ref.
delegate(Pid, Message, ReplyToPid, Ref) ->
    adk_agent:delegate(Pid, Message, ReplyToPid, Ref).

%% Orchestrators
sequential(Pids, Prompt) ->
    erlang_adk_orchestrator:sequential(Pids, Prompt).

parallel(Pids, Prompt) ->
    erlang_adk_orchestrator:parallel(Pids, Prompt).

parallel(Pids, Prompt, Timeout) ->
    erlang_adk_orchestrator:parallel(Pids, Prompt, Timeout).

loop(WorkerPid, ReviewerPid, Prompt, MaxIterations) ->
    erlang_adk_orchestrator:loop(WorkerPid, ReviewerPid, Prompt, MaxIterations).
