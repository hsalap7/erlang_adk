-module(adk_agent).
-behaviour(gen_server).

-export([start_link/3, stop/1, prompt/2, delegate/2, delegate/3, delegate/4,
         run_with_events/3, get_tools/1, get_runtime/1, format_result/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    name :: string(),
    llm_config :: map(),
    tools :: [module()],
    session_id :: term(),
    session_store :: module(),
    memory :: list(),
    sub_agents :: map()
}).

-define(DEFAULT_CALL_TIMEOUT, 60000).

%% API
start_link(Name, LLMConfig, Tools) ->
    gen_server:start_link({via, adk_agent_registry, Name}, ?MODULE,
                          [Name, LLMConfig, Tools], []).

stop(Pid) ->
    gen_server:stop(Pid, normal, 5000).

prompt(Pid, Message) ->
    gen_server:call(Pid, {prompt, Message}, agent_call_timeout()).

delegate(Pid, Message) ->
    gen_server:cast(Pid, {delegate, Message, undefined}).

delegate(Pid, Message, ReplyToPid) ->
    gen_server:cast(Pid, {delegate, Message, ReplyToPid}).

%% @doc Delegate with an explicit caller-supplied correlation reference.
delegate(Pid, Message, ReplyToPid, Ref) ->
    gen_server:cast(Pid, {delegate, Message, {ReplyToPid, Ref}}).

%% @doc Run the agent using the new Event-based architecture.
run_with_events(Pid, HistoryEvents, InvocationId) ->
    gen_server:call(Pid, {run_with_events, HistoryEvents, InvocationId},
                    agent_call_timeout()).

%% @doc Get the tools and sub-agents registered with this agent.
-spec get_tools(Pid :: pid()) -> {ok, [module()], map()}.
get_tools(Pid) ->
    gen_server:call(Pid, get_tools, 5000).

%% @doc Return the immutable runtime configuration needed by Runner lifecycle
%% hooks. Kept separate from get_tools/1 for backward compatibility.
get_runtime(Pid) ->
    gen_server:call(Pid, get_runtime, 5000).

agent_call_timeout() ->
    case application:get_env(erlang_adk, agent_call_timeout,
                             ?DEFAULT_CALL_TIMEOUT) of
        infinity -> infinity;
        Timeout when is_integer(Timeout), Timeout >= 0 -> Timeout;
        Invalid -> erlang:error({invalid_agent_call_timeout, Invalid})
    end.

%% Gen Server Callbacks
init([Name, LLMConfig, Tools]) ->
    SessionId = maps:get(session_id, LLMConfig, undefined),
    SessionStore = maps:get(session_store, LLMConfig, erlang_adk_session),
    ok = ensure_session_store(SessionStore),
    
    Memory = case SessionId of
        undefined -> adk_memory:new();
        Id -> 
            case SessionStore:load(Id) of
                [] -> adk_memory:new();
                Loaded -> Loaded
            end
    end,
    
    %% A restored legacy session may predate system-message persistence. Always
    %% make sure configured instructions are present, even when history exists.
    Memory1 = ensure_system_instruction(Memory, LLMConfig),
    
    if SessionId =/= undefined -> SessionStore:save(SessionId, Memory1); true -> ok end,

    SubAgents = maps:get(sub_agents, LLMConfig, #{}),
    {ok, #state{name = Name, llm_config = LLMConfig, tools = Tools, session_id = SessionId, session_store = SessionStore, memory = Memory1, sub_agents = SubAgents}}.

handle_call({prompt, Message}, _From, State) ->
    telemetry:execute([erlang_adk, agent, prompt, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),

    Memory1 = adk_memory:add_message(State#state.memory, user, Message),
    RunResult = run_agent_invocation(State, Message, Memory1),
    {Reply, Memory2} = case RunResult of
        {ok, Response, UpdatedMemory} ->
            {{ok, Response}, UpdatedMemory};
        {error, Reason, UpdatedMemory} ->
            {{error, Reason}, UpdatedMemory}
    end,
    
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, prompt, stop], #{duration => Duration}, #{agent => State#state.name}),
    
    if State#state.session_id =/= undefined ->
        Store = State#state.session_store,
        Store:save(State#state.session_id, Memory2);
    true -> ok end,
    
    {reply, Reply, State#state{memory = Memory2}};

handle_call({run_with_events, HistoryEvents, InvocationId}, _From, State) ->
    telemetry:execute([erlang_adk, agent, run_with_events, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),
    
    %% Convert incoming events to legacy history format for the LLM
    LegacyHistory0 = adk_memory:from_events(HistoryEvents),
    LegacyHistory = ensure_system_instruction(LegacyHistory0,
                                              State#state.llm_config),
    ModelTools = model_tools(State#state.tools, State#state.sub_agents),
    
    Result = case generate_with_callbacks(State#state.llm_config,
                                          LegacyHistory,
                                          ModelTools) of
        {ok, Text} ->
            ResponseText = to_binary(Text),
            FinalEvent = adk_event:new(to_binary(State#state.name), ResponseText, #{
                invocation_id => InvocationId, 
                is_final => true
            }),
            {ok, FinalEvent};
        {tool_calls, Calls} ->
            AgentEvent = adk_event:new(to_binary(State#state.name), {tool_calls, Calls}, #{
                invocation_id => InvocationId
            }),
            {tool_calls, AgentEvent, Calls};
        {error, Reason} ->
            {error, Reason}
    end,
    
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, run_with_events, stop], #{duration => Duration}, #{agent => State#state.name}),
    
    {reply, Result, State};

handle_call(get_tools, _From, State) ->
    {reply, {ok, State#state.tools, State#state.sub_agents}, State};

handle_call(get_runtime, _From, State) ->
    {reply, {ok, State#state.name, State#state.llm_config,
             State#state.tools, State#state.sub_agents}, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({delegate, Message, ReplyToPid}, State) ->
    telemetry:execute([erlang_adk, agent, delegate, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),

    Memory1 = adk_memory:add_message(State#state.memory, user, Message),
    RunResult = run_agent_invocation(State, Message, Memory1),
    {Response, Memory2} = case RunResult of
        {ok, Value, UpdatedMemory} -> {{ok, Value}, UpdatedMemory};
        {error, Reason, UpdatedMemory} -> {{error, Reason}, UpdatedMemory}
    end,
    
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, delegate, stop], #{duration => Duration}, #{agent => State#state.name}),
    
    if State#state.session_id =/= undefined ->
        Store = State#state.session_store,
        Store:save(State#state.session_id, Memory2);
    true -> ok end,
    
    %% Notify caller if ReplyToPid is provided. The four-argument API carries
    %% an explicit Ref so concurrent delegations can be correlated.
    case ReplyToPid of
        undefined -> ok;
        {TargetPid, Ref} ->
            TargetPid ! {agent_response, Ref, self(), Response};
        TargetPid when is_pid(TargetPid) ->
            TargetPid ! {agent_response, self(), unwrap_response(Response)}
    end,
    
    {noreply, State#state{memory = Memory2}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(stop, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal Functions
run_agent_loop(Config, Memory, Tools, State, Round) ->
    MaxRounds = maps:get(max_tool_rounds, Config, 16),
    case Round >= MaxRounds of
        true ->
            {error, {max_tool_rounds_exceeded, MaxRounds}, Memory};
        false ->
            ModelTools = model_tools(Tools, State#state.sub_agents),
            ModelResult = generate_with_callbacks(Config, Memory, ModelTools),
            case ModelResult of
                {ok, Text} ->
                    ResponseText = to_binary(Text),
                    Memory1 = adk_memory:add_message(Memory, agent, ResponseText),
                    {ok, ResponseText, Memory1};
                {tool_calls, Calls} ->
                    Memory1 = adk_memory:add_message(Memory, agent,
                                                     {tool_calls, Calls}),
                    Memory2 = execute_tools(Calls, Tools, Memory1, State),
                    run_agent_loop(Config, Memory2, Tools, State, Round + 1);
                {error, Reason} ->
                    {error, Reason, Memory};
                Other ->
                    {error, {invalid_model_result, Other}, Memory}
            end
    end.

execute_tools([], _ToolsList, MemoryAcc, _State) ->
    MemoryAcc;
execute_tools([{NameBin, ArgsMap} | Rest], ToolsList, MemoryAcc, State) ->
    execute_tools_inner(NameBin, ArgsMap, undefined, undefined, Rest,
                        ToolsList, MemoryAcc, State);
execute_tools([{NameBin, ArgsMap, Sig} | Rest], ToolsList, MemoryAcc, State) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, undefined, Rest,
                        ToolsList, MemoryAcc, State);
execute_tools([{NameBin, ArgsMap, Sig, CallId} | Rest], ToolsList,
              MemoryAcc, State) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, CallId, Rest,
                        ToolsList, MemoryAcc, State).

execute_tools_inner(NameBin, ArgsMap, Sig, CallId, Rest, ToolsList,
                    MemoryAcc, State) ->
    FoundTool = lists:search(
        fun(Mod) when is_atom(Mod) ->
            Schema = Mod:schema(),
            maps:get(<<"name">>, Schema, atom_to_binary(Mod, utf8)) == NameBin;
           (_) -> false
        end, ToolsList),
    
    Context = #{app_name => maps:get(app_name, State#state.llm_config,
                                     undefined),
                session_id => State#state.session_id,
                user_id => maps:get(user_id, State#state.llm_config,
                                    undefined),
                invocation_id => undefined,
                call_id => CallId,
                state_ref => State#state.session_store},
    Handlers = maps:get(callbacks, State#state.llm_config, []),
    Result = case FoundTool of
        {value, Mod} ->
            execute_tool_with_callbacks(
              Mod, NameBin, ArgsMap, Context, Handlers);
        false ->
            execute_sub_agent_with_callbacks(
              NameBin, ArgsMap, Context, State#state.sub_agents, Handlers)
    end,
    Memory1 = adk_memory:add_message(
                MemoryAcc, tool,
                tool_response(NameBin, Result, Sig, CallId)),
    execute_tools(Rest, ToolsList, Memory1, State).

tool_response(Name, Result, Sig, undefined) ->
    {tool_response, Name, Result, Sig};
tool_response(Name, Result, Sig, CallId) ->
    {tool_response, Name, Result, Sig, CallId}.

%% @doc Format a tool execution result into a standard map.
-spec format_result(Res :: term()) -> map().
format_result(Res) when is_map(Res) -> Res;
format_result(Res) when is_binary(Res) -> #{<<"result">> => Res};
format_result(Res) ->
    #{<<"result">> => unicode:characters_to_binary(io_lib:format("~p", [Res]))}.

execute_tool_with_callbacks(Mod, NameBin, ArgsMap, Context, Handlers) ->
    adk_callbacks:execute(Handlers, on_tool_start, [NameBin, ArgsMap]),
    RawResult = case adk_callbacks:run(Handlers, before_tool,
                                       [NameBin, ArgsMap, Context]) of
        {halt, Replacement} -> {ok, Replacement};
        {replace, Replacement} -> {ok, Replacement};
        _ ->
            try Mod:execute(ArgsMap, Context) of
                ToolResult -> ToolResult
            catch
                Class:ToolFailure:Stack ->
                    logger:error("Tool ~p failed: ~p:~p~n~p",
                                 [NameBin, Class, ToolFailure, Stack]),
                    {error, {Class, ToolFailure}}
            end
    end,
    FinalResult = case adk_callbacks:run(Handlers, after_tool,
                                         [NameBin, ArgsMap, Context, RawResult]) of
        {replace, ReplacementResult} -> {ok, ReplacementResult};
        {halt, ReplacementResult} -> {ok, ReplacementResult};
        _ -> RawResult
    end,
    adk_callbacks:execute(Handlers, on_tool_end, [NameBin, FinalResult]),
    case FinalResult of
        {ok, Res} -> #{<<"success">> => true, <<"result">> => format_result(Res)};
        {error, ToolError} ->
            #{<<"success">> => false, <<"error">> => format_result(ToolError)};
        Other ->
            #{<<"success">> => false,
              <<"error">> => format_result({invalid_tool_result, Other})}
    end.

execute_sub_agent_with_callbacks(NameBin, ArgsMap, Context,
                                 SubAgents, Handlers) ->
    adk_callbacks:execute(Handlers, on_tool_start, [NameBin, ArgsMap]),
    RawResult = case adk_callbacks:run(Handlers, before_tool,
                                       [NameBin, ArgsMap, Context]) of
        {halt, Replacement} -> {ok, Replacement};
        {replace, Replacement} -> {ok, Replacement};
        _ -> execute_sub_agent(NameBin, ArgsMap, SubAgents)
    end,
    FinalResult = case adk_callbacks:run(
                         Handlers, after_tool,
                         [NameBin, ArgsMap, Context, RawResult]) of
        {replace, ReplacementResult} -> {ok, ReplacementResult};
        {halt, ReplacementResult} -> {ok, ReplacementResult};
        _ -> RawResult
    end,
    adk_callbacks:execute(Handlers, on_tool_end,
                          [NameBin, FinalResult]),
    case FinalResult of
        {ok, SubResult} ->
            #{<<"success">> => true,
              <<"result">> => format_result(SubResult)};
        {error, SubError} ->
            #{<<"success">> => false,
              <<"error">> => format_result(SubError)};
        Other ->
            #{<<"success">> => false,
              <<"error">> => format_result({invalid_tool_result, Other})}
    end.

execute_sub_agent(NameBin, ArgsMap, SubAgents) ->
    case maps:find(NameBin, SubAgents) of
        {ok, SubSpec} ->
            SubPrompt = maps:get(<<"prompt">>, ArgsMap, <<>>),
            case sub_agent_pid(NameBin, SubSpec) of
                {ok, SubPid} -> safe_sub_agent_prompt(SubPid, SubPrompt);
                error -> {error, invalid_sub_agent_configuration}
            end;
        error ->
            {error, tool_not_found}
    end.

safe_generate(Config, History, Tools) ->
    try adk_llm:generate(Config, History, Tools) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            logger:error("LLM provider failed: ~p:~p~n~p", [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

generate_with_callbacks(Config, Memory, ModelTools) ->
    Handlers = maps:get(callbacks, Config, []),
    RawResult = case adk_callbacks:run(Handlers, before_model,
                                       [Config, Memory, ModelTools]) of
        {halt, Replacement} -> Replacement;
        {replace, Replacement} -> Replacement;
        _ -> safe_generate(Config, adk_memory:get_history(Memory), ModelTools)
    end,
    case adk_callbacks:run(Handlers, after_model, [Config, RawResult]) of
        {replace, ReplacementResult} -> ReplacementResult;
        {halt, ReplacementResult} -> ReplacementResult;
        _ -> RawResult
    end.

run_agent_invocation(State, Message, Memory) ->
    Config = State#state.llm_config,
    Handlers = maps:get(callbacks, Config, []),
    AgentName = State#state.name,
    adk_callbacks:execute(Handlers, on_agent_start,
                          [to_binary(AgentName), Message]),
    Result0 = case adk_callbacks:run(Handlers, before_agent,
                                     [AgentName, Message]) of
        {halt, Value} -> {ok, Value, Memory};
        {replace, Value} -> {ok, Value, Memory};
        _ -> run_agent_loop(Config, Memory, State#state.tools, State, 0)
    end,
    case Result0 of
        {ok, Response0, UpdatedMemory} ->
            Response0a = case adk_callbacks:run(Handlers, after_agent,
                                                [AgentName, Response0]) of
                {replace, Replacement} -> Replacement;
                {halt, Replacement} -> Replacement;
                _ -> Response0
            end,
            %% Text returned by the public agent APIs is always a UTF-8
            %% binary. Erlang charlists are lists of integer code points and
            %% are often rendered as [69,114,...] by shells and loggers.
            Response = normalize_response(Response0a),
            FinalMemory = persist_agent_response(
                            Memory, UpdatedMemory, Response0, Response),
            adk_callbacks:execute(Handlers, on_agent_end,
                                  [to_binary(AgentName), Response]),
            {ok, Response, FinalMemory};
        {error, Reason, UpdatedMemory} ->
            adk_callbacks:execute(Handlers, on_error, [Reason]),
            {error, Reason, UpdatedMemory}
    end.

%% Keep the conversation visible to the next model turn identical to the
%% response returned to the caller. A before_agent short-circuit has not yet
%% added an agent message; an after_agent replacement updates the final one.
persist_agent_response(InputMemory, InputMemory, _Original, Response) ->
    adk_memory:add_message(InputMemory, agent, Response);
persist_agent_response(_InputMemory, UpdatedMemory, Response, Response) ->
    UpdatedMemory;
persist_agent_response(_InputMemory, UpdatedMemory, _Original, Response) ->
    replace_latest_agent_response(UpdatedMemory, Response).

replace_latest_agent_response([#{role := agent} = Message | Rest], Response) ->
    [Message#{content => Response} | Rest];
replace_latest_agent_response([Message | Rest], Response) ->
    [Message | replace_latest_agent_response(Rest, Response)];
replace_latest_agent_response([], Response) ->
    adk_memory:add_message([], agent, Response).

ensure_system_instruction(Memory, Config) ->
    case lists:any(fun(#{role := system}) -> true; (_) -> false end, Memory) of
        true -> Memory;
        false ->
            Instructions = maps:get(instructions, Config,
                                    "You are a helpful assistant."),
            SystemMessage = #{role => system, content => Instructions,
                              timestamp => erlang:system_time(millisecond)},
            %% Memory is stored newest-first, so append the oldest system item.
            Memory ++ [SystemMessage]
    end.

model_tools(Tools, SubAgents) ->
    Tools ++ [sub_agent_schema(Name, Spec)
              || {Name, Spec} <- maps:to_list(SubAgents)].

sub_agent_schema(Name, Spec) ->
    Description = case Spec of
        #{description := Desc} -> Desc;
        _ -> <<"Delegate a task to this specialist agent.">>
    end,
    adk_agent_tool:schema(#{name => to_binary(Name),
                            description => to_binary(Description)}).

sub_agent_pid(Name, #{pid := Pid}) ->
    resolve_sub_agent(Name, Pid);
sub_agent_pid(Name, Pid) ->
    resolve_sub_agent(Name, Pid).

resolve_sub_agent(Name, Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> {ok, Pid};
        false -> lookup_sub_agent(Name)
    end;
resolve_sub_agent(Name, _StaleRef) ->
    lookup_sub_agent(Name).

lookup_sub_agent(Name) ->
    case adk_agent_registry:lookup(Name) of
        {ok, Pid} -> {ok, Pid};
        {error, not_found} -> error
    end.

safe_sub_agent_prompt(SubPid, SubPrompt) ->
    try prompt(SubPid, SubPrompt) of
        Result -> Result
    catch
        Class:Reason -> {error, {sub_agent_unavailable, Class, Reason}}
    end.

unwrap_response({ok, Value}) -> Value;
unwrap_response({error, Reason}) -> {error, Reason}.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

normalize_response(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
normalize_response(Value) ->
    Value.

ensure_session_store(Store) ->
    case code:ensure_loaded(Store) of
        {module, Store} ->
            case erlang:function_exported(Store, init, 0) of
                true ->
                    case Store:init() of
                        ok -> ok;
                        {atomic, ok} -> ok;
                        {error, Reason} -> exit({session_store_init_failed, Reason});
                        _ -> ok
                    end;
                false -> ok
            end;
        {error, Reason} -> exit({session_store_unavailable, Store, Reason})
    end.
