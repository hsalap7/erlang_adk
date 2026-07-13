%% @doc adk_mcp_client - Client for connecting to Model Context Protocol servers.
-module(adk_mcp_client).
-behaviour(gen_server).

-export([connect/2, list_tools/1, execute_tool/3, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Connect to an MCP server.
-spec connect(Transport :: binary(), Target :: binary()) -> {ok, pid()} | {error, term()}.
connect(<<"stdio">>, Command) ->
    case gen_server:start(?MODULE, {stdio, Command}, []) of
        {ok, Client} ->
            InitializeResult = try gen_server:call(Client, initialize, 10000) of
                Value -> Value
            catch
                exit:{timeout, _} -> {error, initialize_timeout};
                exit:CallExitReason ->
                    {error, {initialize_failed, CallExitReason}}
            end,
            case InitializeResult of
                ok -> {ok, Client};
                {error, Reason} ->
                    _ = catch gen_server:stop(Client),
                    {error, Reason}
            end;
        Error -> Error
    end;
connect(<<"sse">>, _Url) ->
    {error, {unsupported_transport, sse}}.

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
    {ok, #{req_id => 1, pending => #{}, dummy => true,
           initialized => false}};
init({stdio, Command}) ->
    process_flag(trap_exit, true),
    try erlang:open_port({spawn, binary_to_list(Command)},
                         [binary, {line, 1048576}, exit_status,
                          stderr_to_stdout]) of
        Port ->
            {ok, #{port => Port, req_id => 1, pending => #{},
                   initialized => false}}
    catch
        error:Reason -> {stop, {port_open_failed, Reason}}
    end.

handle_call(initialize, From, State) ->
    case maps:get(dummy, State, false) of
        true -> {reply, ok, State#{initialized => true}};
        false ->
            send_request(From, <<"initialize">>, #{
                <<"protocolVersion">> => <<"2025-06-18">>,
                <<"capabilities">> => #{},
                <<"clientInfo">> => #{
                    <<"name">> => <<"erlang_adk">>,
                    <<"version">> => <<"0.2.4">>
                }
            }, initialize, State)
    end;

handle_call(list_tools, From, State) ->
    case maps:get(dummy, State, false) of
        true -> {reply, {ok, []}, State};
        false ->
            case maps:get(initialized, State, false) of
                false -> {reply, {error, not_initialized}, State};
                true -> send_request(From, <<"tools/list">>, #{}, list_tools, State)
            end
    end;

handle_call({execute, ToolName, Args}, From, State) ->
    case maps:get(dummy, State, false) of
        true -> {reply, {error, {unknown_tool, ToolName}}, State};
        false ->
            case maps:get(initialized, State, false) of
                false -> {reply, {error, not_initialized}, State};
                true -> send_request(From, <<"tools/call">>,
                                     #{<<"name">> => ToolName,
                                       <<"arguments">> => Args},
                                     execute_tool, State)
            end
    end.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({Port, {data, {eol, Data}}}, State) ->
    case maps:get(port, State, undefined) of
        Port ->
            try jsx:decode(Data, [return_maps]) of
                #{<<"id">> := Id, <<"result">> := Result} ->
                    case maps:take(Id, maps:get(pending, State)) of
                        {{initialize, From}, NewPending} ->
                            send_initialized_notification(maps:get(port, State)),
                            gen_server:reply(From, ok),
                            {noreply, State#{pending => NewPending,
                                             initialized => true,
                                             server_info => Result}};
                        {{list_tools, From}, NewPending} ->
                            gen_server:reply(From,
                                             {ok, maps:get(<<"tools">>, Result, [])}),
                            {noreply, State#{pending => NewPending}};
                        {{execute_tool, From}, NewPending} ->
                            gen_server:reply(From, {ok, Result}),
                            {noreply, State#{pending => NewPending}};
                        error -> {noreply, State}
                    end;
                #{<<"id">> := Id, <<"error">> := Error} ->
                    case maps:take(Id, maps:get(pending, State)) of
                        {{_Kind, From}, NewPending} ->
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
handle_info({Port, {exit_status, Status}}, State = #{port := Port}) ->
    Reason = {mcp_server_exited, Status},
    reply_all_pending(maps:get(pending, State), Reason),
    {noreply, State#{pending => #{}, port_closed => true}};
handle_info({'EXIT', Port, Reason}, State = #{port := Port}) ->
    reply_all_pending(maps:get(pending, State), {mcp_server_exited, Reason}),
    {noreply, State#{pending => #{}, port_closed => true}};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) -> 
    case maps:find(port, State) of
        {ok, Port} ->
            case erlang:port_info(Port) of
                undefined -> ok;
                _ -> _ = catch port_close(Port), ok
            end;
        error -> ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

send_request(_From, _Method, _Params, _Kind,
             State = #{port_closed := true}) ->
    {reply, {error, port_closed}, State};
send_request(From, Method, Params, Kind, State) ->
    Id = maps:get(req_id, State),
    Port = maps:get(port, State),
    Pending = maps:get(pending, State),
    Request = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                <<"method">> => Method, <<"params">> => Params},
    try erlang:port_command(Port, [jsx:encode(Request), <<"\n">>]) of
        true ->
            {noreply, State#{req_id => Id + 1,
                             pending => maps:put(Id, {Kind, From}, Pending)}}
    catch
        error:badarg ->
            {reply, {error, port_closed}, State#{port_closed => true}}
    end.

send_initialized_notification(Port) ->
    Notification = #{<<"jsonrpc">> => <<"2.0">>,
                     <<"method">> => <<"notifications/initialized">>},
    _ = erlang:port_command(Port, [jsx:encode(Notification), <<"\n">>]),
    ok.

reply_all_pending(Pending, Reason) ->
    maps:foreach(fun(_Id, {_Kind, From}) ->
        gen_server:reply(From, {error, Reason})
    end, Pending).
