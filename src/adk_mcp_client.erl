%% @doc adk_mcp_client - Client for connecting to Model Context Protocol servers.
-module(adk_mcp_client).
-behaviour(gen_server).

-export([connect/2, list_tools/1, execute_tool/3, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Connect to an MCP server.
-spec connect(Transport :: binary(), Target :: binary()) -> {ok, pid()} | {error, term()}.
connect(<<"stdio">>, Command) ->
    gen_server:start_link(?MODULE, {stdio, Command}, []);
connect(<<"sse">>, Url) ->
    %% Simplified gun sse connect placeholder
    logger:info("Connecting to MCP server via SSE: ~p", [Url]),
    {ok, self()}.

%% @doc List tools available on the connected server.
-spec list_tools(Client :: pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Client) ->
    gen_server:call(Client, list_tools, 5000).

%% @doc Execute a tool on the remote server.
-spec execute_tool(Client :: pid(), ToolName :: binary(), Args :: map()) -> {ok, term()} | {error, term()}.
execute_tool(Client, ToolName, Args) ->
    gen_server:call(Client, {execute, ToolName, Args}, 30000).

%% @doc Close the connection.
-spec close(Client :: pid()) -> ok.
close(Client) ->
    gen_server:stop(Client).

%% --- gen_server callbacks ---

init({stdio, <<"dummy">>}) ->
    {ok, #{req_id => 1, pending => #{}, dummy => true}};
init({stdio, Command}) ->
    Port = erlang:open_port({spawn, binary_to_list(Command)}, [binary, {line, 8192}]),
    {ok, #{port => Port, req_id => 1, pending => #{}}}.

handle_call(list_tools, From, State) ->
    case maps:get(dummy, State, false) of
        true -> {reply, {ok, []}, State};
        false ->
            Id = maps:get(req_id, State),
            Port = maps:get(port, State),
            Pending = maps:get(pending, State),
            Req = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => <<"tools/list">>, <<"params">> => #{}},
            port_command(Port, [jsx:encode(Req), <<"\n">>]),
            {noreply, State#{req_id => Id + 1, pending => maps:put(Id, From, Pending)}}
    end;

handle_call({execute, ToolName, Args}, From, State) ->
    case maps:get(dummy, State, false) of
        true -> {reply, {error, {unknown_tool, ToolName}}, State};
        false ->
            Id = maps:get(req_id, State),
            Port = maps:get(port, State),
            Pending = maps:get(pending, State),
            Req = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => <<"tools/call">>, 
                    <<"params">> => #{<<"name">> => ToolName, <<"arguments">> => Args}},
            port_command(Port, [jsx:encode(Req), <<"\n">>]),
            {noreply, State#{req_id => Id + 1, pending => maps:put(Id, From, Pending)}}
    end.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({Port, {data, {eol, Data}}}, State) ->
    case maps:get(port, State, undefined) of
        Port ->
            try jsx:decode(Data, [return_maps]) of
                #{<<"id">> := Id, <<"result">> := Result} ->
                    case maps:take(Id, maps:get(pending, State)) of
                        {From, NewPending} ->
                            gen_server:reply(From, {ok, Result}),
                            {noreply, State#{pending => NewPending}};
                        error -> {noreply, State}
                    end;
                #{<<"id">> := Id, <<"error">> := Error} ->
                    case maps:take(Id, maps:get(pending, State)) of
                        {From, NewPending} ->
                            gen_server:reply(From, {error, Error}),
                            {noreply, State#{pending => NewPending}};
                        error -> {noreply, State}
                    end;
                _ -> {noreply, State}
            catch
                _:_ -> {noreply, State}
            end;
        _ -> {noreply, State}
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) -> 
    case maps:is_key(port, State) of
        true -> port_close(maps:get(port, State));
        false -> ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
