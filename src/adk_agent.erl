-module(adk_agent).
-behaviour(gen_server).

-export([start_link/3, prompt/2, delegate/2, delegate/3, run_with_events/3, get_tools/1, format_result/1]).
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

%% API
start_link(Name, LLMConfig, Tools) ->
    gen_server:start_link({local, list_to_atom(Name)}, ?MODULE, [Name, LLMConfig, Tools], []).

prompt(Pid, Message) ->
    %% Using a 60-second timeout for LLM calls
    gen_server:call(Pid, {prompt, Message}, 60000).

delegate(Pid, Message) ->
    gen_server:cast(Pid, {delegate, Message, undefined}).

delegate(Pid, Message, ReplyToPid) ->
    gen_server:cast(Pid, {delegate, Message, ReplyToPid}).

%% @doc Run the agent using the new Event-based architecture.
run_with_events(Pid, HistoryEvents, InvocationId) ->
    gen_server:call(Pid, {run_with_events, HistoryEvents, InvocationId}, 60000).

%% @doc Get the tools and sub-agents registered with this agent.
-spec get_tools(Pid :: pid()) -> {ok, [module()], map()}.
get_tools(Pid) ->
    gen_server:call(Pid, get_tools, 5000).

%% Gen Server Callbacks
init([Name, LLMConfig, Tools]) ->
    SessionId = maps:get(session_id, LLMConfig, undefined),
    SessionStore = maps:get(session_store, LLMConfig, erlang_adk_session),
    
    Memory = case SessionId of
        undefined -> adk_memory:new();
        Id -> 
            case SessionStore:load(Id) of
                [] -> adk_memory:new();
                Loaded -> Loaded
            end
    end,
    
    Memory1 = case Memory of
        [] ->
            Instructions = maps:get(instructions, LLMConfig, "You are a helpful assistant."),
            adk_memory:add_message(Memory, system, Instructions);
        _ -> Memory
    end,
    
    if SessionId =/= undefined -> SessionStore:save(SessionId, Memory1); true -> ok end,

    SubAgents = maps:get(sub_agents, LLMConfig, #{}),
    {ok, #state{name = Name, llm_config = LLMConfig, tools = Tools, session_id = SessionId, session_store = SessionStore, memory = Memory1, sub_agents = SubAgents}}.

handle_call({prompt, Message}, _From, State) ->
    telemetry:execute([erlang_adk, agent, prompt, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),

    Memory1 = adk_memory:add_message(State#state.memory, user, Message),
    
    {Response, Memory2} = run_agent_loop(State#state.llm_config, Memory1, State#state.tools, State),
    
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, prompt, stop], #{duration => Duration}, #{agent => State#state.name}),
    
    if State#state.session_id =/= undefined ->
        Store = State#state.session_store,
        Store:save(State#state.session_id, Memory2);
    true -> ok end,
    
    {reply, {ok, Response}, State#state{memory = Memory2}};

handle_call({run_with_events, HistoryEvents, InvocationId}, _From, State) ->
    telemetry:execute([erlang_adk, agent, run_with_events, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),
    
    %% Convert incoming events to legacy history format for the LLM
    LegacyHistory = adk_memory:from_events(HistoryEvents),
    
    Result = case adk_llm:generate(State#state.llm_config, adk_memory:get_history(LegacyHistory), State#state.tools) of
        {ok, Text} ->
            ResponseText = unicode:characters_to_list(Text),
            FinalEvent = adk_event:new(list_to_binary(State#state.name), ResponseText, #{
                invocation_id => InvocationId, 
                is_final => true
            }),
            {ok, FinalEvent};
        {tool_calls, Calls} ->
            AgentEvent = adk_event:new(list_to_binary(State#state.name), {tool_calls, Calls}, #{
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

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({delegate, Message, ReplyToPid}, State) ->
    telemetry:execute([erlang_adk, agent, delegate, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),

    Memory1 = adk_memory:add_message(State#state.memory, user, Message),
    
    {Response, Memory2} = run_agent_loop(State#state.llm_config, Memory1, State#state.tools, State),
    
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, delegate, stop], #{duration => Duration}, #{agent => State#state.name}),
    
    if State#state.session_id =/= undefined ->
        Store = State#state.session_store,
        Store:save(State#state.session_id, Memory2);
    true -> ok end,
    
    %% Notify caller if ReplyToPid is provided
    if ReplyToPid =/= undefined ->
        ReplyToPid ! {agent_response, self(), Response};
    true -> ok end,
    
    {noreply, State#state{memory = Memory2}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal Functions
run_agent_loop(Config, Memory, Tools, State) ->
    Handlers = maps:get(callbacks, Config, []),
    adk_callbacks:execute(Handlers, before_model, [Config, Memory, Tools]),
    
    Result = case adk_llm:generate(Config, adk_memory:get_history(Memory), Tools) of
        {ok, Text} ->
            ResponseText = unicode:characters_to_list(Text),
            Memory1 = adk_memory:add_message(Memory, agent, ResponseText),
            {ResponseText, Memory1};
        {tool_calls, Calls} ->
            Memory1 = adk_memory:add_message(Memory, agent, {tool_calls, Calls}),
            Memory2 = execute_tools(Calls, Tools, Memory1, State),
            run_agent_loop(Config, Memory2, Tools, State);
        {error, Reason} ->
            ResponseText = lists:flatten(io_lib:format("LLM Error: ~p", [Reason])),
            Memory1 = adk_memory:add_message(Memory, agent, ResponseText),
            {ResponseText, Memory1}
    end,
    
    adk_callbacks:execute(Handlers, after_model, [Config, Result]),
    Result.

execute_tools([], _ToolsList, MemoryAcc, _State) ->
    MemoryAcc;
execute_tools([{NameBin, ArgsMap} | Rest], ToolsList, MemoryAcc, State) ->
    execute_tools_inner(NameBin, ArgsMap, undefined, Rest, ToolsList, MemoryAcc, State);
execute_tools([{NameBin, ArgsMap, Sig} | Rest], ToolsList, MemoryAcc, State) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, Rest, ToolsList, MemoryAcc, State).

execute_tools_inner(NameBin, ArgsMap, Sig, Rest, ToolsList, MemoryAcc, State) ->
    FoundTool = lists:search(
        fun(Mod) ->
            Schema = Mod:schema(),
            maps:get(<<"name">>, Schema, atom_to_binary(Mod, utf8)) == NameBin
        end, ToolsList),
    
    Result = case FoundTool of
        {value, Mod} ->
            Context = #{session_id => State#state.session_id, user_id => undefined, state_ref => State#state.session_store},
            case Mod:execute(ArgsMap, Context) of
                {ok, Res} -> #{<<"success">> => true, <<"result">> => format_result(Res)};
                {error, Reason} -> #{<<"success">> => false, <<"error">> => format_result(Reason)}
            end;
        false ->
            case maps:find(NameBin, State#state.sub_agents) of
                {ok, SubPid} ->
                    SubPrompt = maps:get(<<"prompt">>, ArgsMap, <<"">>),
                    case prompt(SubPid, binary_to_list(SubPrompt)) of
                        {ok, SubRes} -> #{<<"success">> => true, <<"result">> => format_result(SubRes)};
                        {error, SubErr} -> #{<<"success">> => false, <<"error">> => format_result(SubErr)}
                    end;
                error ->
                    #{<<"success">> => false, <<"error">> => <<"Tool not found">>}
            end
    end,
    Memory1 = adk_memory:add_message(MemoryAcc, tool, {tool_response, NameBin, Result, Sig}),
    execute_tools(Rest, ToolsList, Memory1, State).

%% @doc Format a tool execution result into a standard map.
-spec format_result(Res :: term()) -> map().
format_result(Res) when is_map(Res) -> Res;
format_result(Res) when is_binary(Res) -> #{<<"result">> => Res};
format_result(Res) -> #{<<"result">> => list_to_binary(io_lib:format("~p", [Res]))}.
