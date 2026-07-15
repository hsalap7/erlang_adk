%% @doc adk_agent_tool - Wraps an agent as a tool.
%%
%% This module allows exposing one agent as a tool to another agent, enabling
%% agent-to-agent delegation in multi-agent systems.
-module(adk_agent_tool).

-export([schema/1, execute/3]).

%% @doc Define the schema for the agent tool.
-spec schema(AgentConfig :: map()) -> map().
schema(AgentConfig) ->
    Name = maps:get(name, AgentConfig, <<"AgentTool">>),
    Desc = maps:get(description, AgentConfig, <<"Delegates a task to another agent.">>),
    #{
        <<"name">> => Name,
        <<"description">> => Desc,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"prompt">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"The task instruction for the agent.">>
                }
            },
            <<"required">> => [<<"prompt">>]
        }
    }.

%% @doc Execute the agent as a tool.
-spec execute(AgentRef :: pid() | atom() | binary() | string(),
              Args :: map(), Opts :: map()) ->
    {ok, term()} | {error, term()}.
execute(AgentRef, Args, Opts) when is_map(Args), is_map(Opts) ->
    case maps:get(<<"prompt">>, Args, undefined) of
        undefined ->
            {error, <<"Missing required parameter 'prompt'">>};
        Prompt when is_binary(Prompt) ->
            execute_invocation(AgentRef, Prompt, invocation_context(Opts));
        _Prompt ->
            {error, <<"Invalid prompt type">>}
    end;
execute(_AgentRef, _Args, _Opts) ->
    {error, invalid_agent_tool_arguments}.

execute_invocation(AgentRef, Prompt, Context) ->
    case resolve_agent(AgentRef) of
        {ok, AgentPid} ->
            try erlang_adk:invoke(AgentPid, Prompt, Context) of
                {ok, Response} -> {ok, Response};
                {error, Reason} -> {error, Reason}
            catch
                Class:Reason ->
                    {error, adk_failure:exception(
                              agent_tool, invoke, Class, Reason)}
            end;
        {error, _} = Error -> Error
    end.

resolve_agent(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> {ok, Pid};
        false -> {error, agent_unavailable}
    end;
resolve_agent(Name) when is_atom(Name); is_binary(Name); is_list(Name) ->
    case adk_agent_registry:lookup(Name) of
        {ok, Pid} -> {ok, Pid};
        {error, not_found} -> {error, agent_unavailable}
    end;
resolve_agent(_Other) ->
    {error, invalid_agent_reference}.

%% AgentTool is an invocation boundary.  Only safe, explicitly scoped runtime
%% data crosses it; provider configuration, credentials, and compatibility
%% conversation memory remain owned by the target agent.
invocation_context(Opts) ->
    maps:with(
      [state, app_name, user_id, session_id, invocation_id,
       state_ref, artifact_service, artifact_scope, memory_service,
       '$adk_agent_path', '$adk_inherited_global_instruction',
       '$adk_plugin_runtime'], Opts).
