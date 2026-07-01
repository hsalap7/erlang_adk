-module(adk_agent).
-behaviour(gen_server).

-export([start_link/3, prompt/2, delegate/2, delegate/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    name :: string(),
    llm_config :: map(),
    tools :: [module()],
    session_id :: term(),
    session_store :: module(),
    memory :: list()
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

    {ok, #state{name = Name, llm_config = LLMConfig, tools = Tools, session_id = SessionId, session_store = SessionStore, memory = Memory1}}.

handle_call({prompt, Message}, _From, State) ->
    telemetry:execute([erlang_adk, agent, prompt, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),

    Memory1 = adk_memory:add_message(State#state.memory, user, Message),
    
    {Response, Memory2} = run_agent_loop(State#state.llm_config, Memory1, State#state.tools),
    
    Duration = erlang:monotonic_time(millisecond) - StartTime,
    telemetry:execute([erlang_adk, agent, prompt, stop], #{duration => Duration}, #{agent => State#state.name}),
    
    if State#state.session_id =/= undefined ->
        Store = State#state.session_store,
        Store:save(State#state.session_id, Memory2);
    true -> ok end,
    
    {reply, {ok, Response}, State#state{memory = Memory2}};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({delegate, Message, ReplyToPid}, State) ->
    telemetry:execute([erlang_adk, agent, delegate, start], #{}, #{agent => State#state.name}),
    StartTime = erlang:monotonic_time(millisecond),

    Memory1 = adk_memory:add_message(State#state.memory, user, Message),
    
    {Response, Memory2} = run_agent_loop(State#state.llm_config, Memory1, State#state.tools),
    
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
run_agent_loop(Config, Memory, Tools) ->
    case adk_llm:generate(Config, adk_memory:get_history(Memory), Tools) of
        {ok, Text} ->
            ResponseText = unicode:characters_to_list(Text),
            Memory1 = adk_memory:add_message(Memory, agent, ResponseText),
            {ResponseText, Memory1};
        {tool_calls, Calls} ->
            Memory1 = adk_memory:add_message(Memory, agent, {tool_calls, Calls}),
            Memory2 = execute_tools(Calls, Tools, Memory1),
            run_agent_loop(Config, Memory2, Tools);
        {error, Reason} ->
            ResponseText = lists:flatten(io_lib:format("LLM Error: ~p", [Reason])),
            Memory1 = adk_memory:add_message(Memory, agent, ResponseText),
            {ResponseText, Memory1}
    end.

execute_tools([], _ToolsList, MemoryAcc) ->
    MemoryAcc;
execute_tools([{NameBin, ArgsMap} | Rest], ToolsList, MemoryAcc) ->
    execute_tools_inner(NameBin, ArgsMap, undefined, Rest, ToolsList, MemoryAcc);
execute_tools([{NameBin, ArgsMap, Sig} | Rest], ToolsList, MemoryAcc) ->
    execute_tools_inner(NameBin, ArgsMap, Sig, Rest, ToolsList, MemoryAcc).

execute_tools_inner(NameBin, ArgsMap, Sig, Rest, ToolsList, MemoryAcc) ->
    FoundTool = lists:search(
        fun(Mod) ->
            Schema = Mod:schema(),
            maps:get(<<"name">>, Schema, atom_to_binary(Mod, utf8)) == NameBin
        end, ToolsList),
    
    Result = case FoundTool of
        {value, Mod} ->
            case Mod:execute(ArgsMap) of
                {ok, Res} -> #{<<"success">> => true, <<"result">> => format_result(Res)};
                {error, Reason} -> #{<<"success">> => false, <<"error">> => format_result(Reason)}
            end;
        false ->
            #{<<"success">> => false, <<"error">> => <<"Tool not found">>}
    end,
    Memory1 = adk_memory:add_message(MemoryAcc, tool, {tool_response, NameBin, Result, Sig}),
    execute_tools(Rest, ToolsList, Memory1).

format_result(Res) when is_map(Res) -> Res;
format_result(Res) when is_binary(Res) -> #{<<"result">> => Res};
format_result(Res) -> #{<<"result">> => list_to_binary(io_lib:format("~p", [Res]))}.
