%% @doc Bounded MCP 2025-11-25 client for stdio and Streamable HTTP.
%%
%% Each connection is an independent OTP worker. When erlang_adk is running,
%% workers are temporary children of adk_mcp_client_sup; callers are never
%% linked to remote MCP process failures.
-module(adk_mcp_client).
-behaviour(gen_server).

-export([connect/2, connect/3, start_link/1,
         list_tools/1, list_tools/2, execute_tool/3,
         list_resources/1, list_resources/2, read_resource/2,
         list_prompts/1, list_prompts/2, get_prompt/3,
         schemas/1, resolved_call/4,
         server_info/1, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(LATEST_PROTOCOL_VERSION, <<"2025-11-25">>).
-define(SUPPORTED_PROTOCOL_VERSIONS,
        [?LATEST_PROTOCOL_VERSION, <<"2025-06-18">>]).
-define(DEFAULT_INITIALIZE_TIMEOUT, 10000).
-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_CONNECT_TIMEOUT, 10000).
-define(DEFAULT_MAX_RESPONSE_BYTES, 4194304).

-type options() :: map().

-spec connect(binary(), binary()) -> {ok, pid()} | {error, term()}.
connect(Transport, Target) ->
    connect(Transport, Target, #{}).

-spec connect(binary(), binary(), options()) ->
    {ok, pid()} | {error, term()}.
connect(Transport, Target, Options)
  when is_binary(Transport), is_binary(Target), is_map(Options) ->
    case normalize_init(Transport, Target, Options) of
        {ok, Init, Config} ->
            case ensure_transport_started(Transport) of
                {error, _} = RuntimeError -> RuntimeError;
                ok -> case start_client(Init) of
                {ok, Client} ->
                    Timeout = maps:get(initialize_timeout, Config),
                    Result = safe_call(Client, initialize, Timeout,
                                       initialize),
                    case Result of
                        ok -> {ok, Client};
                        {error, Reason} ->
                            _ = catch gen_server:stop(Client),
                            {error, Reason}
                    end;
                Error -> Error
                end
            end;
        {error, _} = Error -> Error
    end;
connect(Transport, Target, Options) ->
    {error, {invalid_mcp_connection, Transport, Target, Options}}.

-spec start_link(term()) -> gen_server:start_ret().
start_link(Init) ->
    gen_server:start_link(?MODULE, Init, []).

-spec list_tools(pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Client) ->
    case call(Client, {request, <<"tools/list">>, #{}, tools}) of
        {ok, Result} -> {ok, maps:get(<<"tools">>, Result, [])};
        Error -> Error
    end.

-spec list_tools(pid(), undefined | binary()) ->
    {ok, map()} | {error, term()}.
list_tools(Client, Cursor) ->
    call(Client, {request, <<"tools/list">>, cursor_params(Cursor), tools}).

-spec execute_tool(pid(), binary(), map()) ->
    {ok, map()} | {error, term()}.
execute_tool(Client, ToolName, Args)
  when is_binary(ToolName), is_map(Args) ->
    call(Client, {request, <<"tools/call">>,
                  #{<<"name">> => ToolName,
                    <<"arguments">> => Args}, tools}).

-spec list_resources(pid()) -> {ok, [map()]} | {error, term()}.
list_resources(Client) ->
    case call(Client, {request, <<"resources/list">>, #{}, resources}) of
        {ok, Result} -> {ok, maps:get(<<"resources">>, Result, [])};
        Error -> Error
    end.

-spec list_resources(pid(), undefined | binary()) ->
    {ok, map()} | {error, term()}.
list_resources(Client, Cursor) ->
    call(Client, {request, <<"resources/list">>,
                  cursor_params(Cursor), resources}).

-spec read_resource(pid(), binary()) -> {ok, map()} | {error, term()}.
read_resource(Client, Uri) when is_binary(Uri) ->
    call(Client, {request, <<"resources/read">>,
                  #{<<"uri">> => Uri}, resources}).

-spec list_prompts(pid()) -> {ok, [map()]} | {error, term()}.
list_prompts(Client) ->
    case call(Client, {request, <<"prompts/list">>, #{}, prompts}) of
        {ok, Result} -> {ok, maps:get(<<"prompts">>, Result, [])};
        Error -> Error
    end.

-spec list_prompts(pid(), undefined | binary()) ->
    {ok, map()} | {error, term()}.
list_prompts(Client, Cursor) ->
    call(Client, {request, <<"prompts/list">>,
                  cursor_params(Cursor), prompts}).

-spec get_prompt(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
get_prompt(Client, Name, Arguments)
  when is_binary(Name), is_map(Arguments) ->
    call(Client, {request, <<"prompts/get">>,
                  #{<<"name">> => Name,
                    <<"arguments">> => Arguments}, prompts}).

%% @doc Return MCP tools in the provider-facing adk_tool schema shape.
%% This callback follows adk_toolset's list contract; discovery failure raises
%% a bounded error which adk_toolset converts to `toolset_unavailable' rather
%% than silently creating an agent with no remote tools.
-spec schemas(pid()) -> [map()].
schemas(Client) ->
    case list_tools(Client) of
        {ok, Tools} -> [provider_tool_schema(Tool) || Tool <- Tools];
        {error, Reason} -> erlang:error({mcp_discovery_failed, Reason})
    end.

%% @doc Build an adk_tool_executor-compatible call. Invocation context is not
%% forwarded to the remote server, preventing scoped state or credential
%% references from becoming MCP arguments accidentally.
-spec resolved_call(pid(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
resolved_call(Client, Name, Args, Context)
  when is_pid(Client), is_binary(Name), is_map(Args), is_map(Context) ->
    case list_tools(Client) of
        {ok, Tools} ->
            case lists:any(fun(Tool) ->
                                   maps:get(<<"name">>, Tool, undefined) =:= Name
                           end, Tools) of
                true ->
                    {ok, #{name => Name,
                           args => Args,
                           execute => fun() -> execute_tool(Client, Name, Args) end,
                           parallel_safe => false,
                           pause_capable => false}};
                false -> {error, unknown_tool}
            end;
        {error, Reason} -> {error, {mcp_discovery_failed, Reason}}
    end;
resolved_call(_Client, _Name, _Args, _Context) ->
    {error, invalid_mcp_tool_call}.

-spec server_info(pid()) -> {ok, map()} | {error, term()}.
server_info(Client) ->
    call(Client, server_info).

-spec close(pid()) -> ok.
close(Client) ->
    gen_server:stop(Client).

call(Client, Request) ->
    %% Transport workers enforce their configured request timeout and issue
    %% MCP cancellation for timed-out stdio requests. Avoid a second,
    %% inconsistent caller-side deadline here.
    case safe_call(Client, Request, infinity, request) of
        {error, {request_failed, {timeout, _}}} -> {error, timeout};
        Result -> Result
    end.

safe_call(Client, Request, Timeout, Kind) ->
    try gen_server:call(Client, Request, Timeout) of
        Value -> Value
    catch
        exit:{timeout, _} -> {error, timeout_reason(Kind)};
        exit:Reason -> {error, {request_failed, Reason}}
    end.

timeout_reason(initialize) -> initialize_timeout;
timeout_reason(_) -> timeout.

cursor_params(undefined) -> #{};
cursor_params(Cursor) when is_binary(Cursor) -> #{<<"cursor">> => Cursor}.

provider_tool_schema(Tool) ->
    Base = #{<<"name">> => maps:get(<<"name">>, Tool),
             <<"parameters">> => maps:get(
                                    <<"inputSchema">>, Tool,
                                    #{<<"type">> => <<"object">>})},
    case maps:find(<<"description">>, Tool) of
        {ok, Description} -> Base#{<<"description">> => Description};
        error -> Base
    end.

start_client(Init) ->
    case whereis(adk_mcp_client_sup) of
        Pid when is_pid(Pid) -> adk_mcp_client_sup:start_client(Init);
        undefined ->
            %% Library users may deliberately use the client without starting
            %% the application. It remains unlinked, but application-managed
            %% connections always use the dynamic supervisor above.
            gen_server:start(?MODULE, Init, [])
    end.

normalize_init(<<"stdio">>, Command, Options) ->
    case normalize_options(Options) of
        {ok, Config} -> {ok, {stdio, Command, Config}, Config};
        Error -> Error
    end;
normalize_init(<<"streamable_http">>, Url, Options) ->
    case normalize_options(Options) of
        {ok, Config} -> {ok, {http, Url, Config}, Config};
        Error -> Error
    end;
normalize_init(<<"http">>, Url, Options) ->
    normalize_init(<<"streamable_http">>, Url, Options);
normalize_init(<<"sse">>, _Target, _Options) ->
    {error, {unsupported_transport, sse_deprecated_use_streamable_http}};
normalize_init(Transport, _Target, _Options) ->
    {error, {unsupported_transport, Transport}}.

normalize_options(Options) ->
    InitializeTimeout = maps:get(initialize_timeout, Options,
                                 ?DEFAULT_INITIALIZE_TIMEOUT),
    RequestTimeout = maps:get(request_timeout, Options,
                              ?DEFAULT_REQUEST_TIMEOUT),
    ConnectTimeout = maps:get(connect_timeout, Options,
                              ?DEFAULT_CONNECT_TIMEOUT),
    MaxBytes = maps:get(max_response_bytes, Options,
                        ?DEFAULT_MAX_RESPONSE_BYTES),
    ClientInfo = maps:get(client_info, Options,
                          #{<<"name">> => <<"erlang_adk">>,
                            <<"version">> => <<"0.3.0">>}),
    Capabilities = maps:get(capabilities, Options, #{}),
    Headers = maps:get(headers, Options, []),
    AuthFun = maps:get(auth_fun, Options, undefined),
    TlsOpts = maps:get(tls_opts, Options, default),
    case valid_timeout(InitializeTimeout) andalso
         valid_timeout(RequestTimeout) andalso
         valid_timeout(ConnectTimeout) andalso
         is_integer(MaxBytes) andalso MaxBytes > 0 andalso
         is_map(ClientInfo) andalso is_map(Capabilities) andalso
         valid_static_headers(Headers) andalso
         valid_auth_fun(AuthFun) andalso
         (TlsOpts =:= default orelse is_list(TlsOpts)) of
        true ->
            {ok, #{initialize_timeout => InitializeTimeout,
                   request_timeout => RequestTimeout,
                   connect_timeout => ConnectTimeout,
                   max_response_bytes => MaxBytes,
                   client_info => ClientInfo,
                   capabilities => Capabilities,
                   headers => Headers,
                   auth_fun => AuthFun,
                   tls_opts => TlsOpts,
                   protocol_versions => ?SUPPORTED_PROTOCOL_VERSIONS}};
        false -> {error, invalid_mcp_client_options}
    end.

valid_timeout(Value) -> is_integer(Value) andalso Value > 0.
valid_auth_fun(undefined) -> true;
valid_auth_fun(Fun) -> is_function(Fun, 0).

valid_static_headers(Headers) when is_list(Headers) ->
    lists:all(
      fun({Name, Value}) when is_binary(Name), is_binary(Value) ->
              Header = lower(Name),
              not sensitive_header(Header) andalso
              not reserved_transport_header(Header);
         (_) -> false
      end, Headers);
valid_static_headers(_) -> false.

sensitive_header(<<"authorization">>) -> true;
sensitive_header(<<"proxy-authorization">>) -> true;
sensitive_header(<<"cookie">>) -> true;
sensitive_header(<<"x-api-key">>) -> true;
sensitive_header(<<"api-key">>) -> true;
sensitive_header(<<"apikey">>) -> true;
sensitive_header(_) -> false.

reserved_transport_header(<<"accept">>) -> true;
reserved_transport_header(<<"content-type">>) -> true;
reserved_transport_header(<<"content-length">>) -> true;
reserved_transport_header(<<"transfer-encoding">>) -> true;
reserved_transport_header(<<"connection">>) -> true;
reserved_transport_header(<<"host">>) -> true;
reserved_transport_header(<<"origin">>) -> true;
reserved_transport_header(<<"mcp-session-id">>) -> true;
reserved_transport_header(<<"mcp-protocol-version">>) -> true;
reserved_transport_header(_) -> false.

init({stdio, <<"dummy">>, Config}) ->
    {ok, (base_state(stdio, Config))#{dummy => true}};
init({stdio, Command, Config}) ->
    process_flag(trap_exit, true),
    MaxLine = maps:get(max_response_bytes, Config),
    try erlang:open_port(
          {spawn, binary_to_list(Command)},
          [binary, {line, MaxLine}, exit_status]) of
        Port -> {ok, (base_state(stdio, Config))#{port => Port}}
    catch
        error:Reason -> {stop, {port_open_failed, Reason}}
    end;
init({http, Url, Config}) ->
    process_flag(trap_exit, true),
    case parse_http_url(Url) of
        {ok, Endpoint} ->
            case open_http(Endpoint, Config) of
                {ok, Conn, Monitor} ->
                    {ok, (base_state(http, Config))#{endpoint => Endpoint,
                                                     conn => Conn,
                                                     conn_monitor => Monitor}};
                {error, Reason} -> {stop, Reason}
            end;
        {error, Reason} -> {stop, Reason}
    end.

base_state(Transport, Config) ->
    #{transport => Transport,
      config => Config,
      req_id => 1,
      pending => #{},
      initialized => false}.

handle_call(initialize, _From, State = #{dummy := true}) ->
    Result = dummy_server_info(),
    {reply, ok, State#{initialized => true, server_info => Result,
                       protocol_version => ?LATEST_PROTOCOL_VERSION}};
handle_call(initialize, From, State = #{transport := stdio}) ->
    Params = initialize_params(State),
    send_stdio_request(From, <<"initialize">>, Params, initialize, State);
handle_call(initialize, _From, State = #{transport := http}) ->
    case initialize_http(State) of
        {ok, NewState} -> {reply, ok, NewState};
        {error, Reason, NewState} -> {reply, {error, Reason}, NewState}
    end;
handle_call(server_info, _From, State) ->
    case maps:find(server_info, State) of
        {ok, Info} -> {reply, {ok, Info}, State};
        error -> {reply, {error, not_initialized}, State}
    end;
handle_call({request, _Method, _Params, _Capability}, _From,
            State = #{dummy := true}) ->
    {reply, {ok, #{}}, State};
handle_call({request, Method, Params, Capability}, From,
            State = #{transport := stdio}) ->
    case ready_for(State, Capability) of
        ok -> send_stdio_request(From, Method, Params,
                                 {operation, Method}, State);
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({request, Method, Params, Capability}, _From,
            State = #{transport := http}) ->
    case ready_for(State, Capability) of
        ok ->
            case http_operation(Method, Params, State, true) of
                {ok, Result, NewState} -> {reply, {ok, Result}, NewState};
                {error, Reason, NewState} ->
                    {reply, {error, Reason}, NewState}
            end;
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({Port, {data, {eol, Data}}}, State = #{port := Port}) ->
    handle_stdio_line(Data, State);
handle_info({Port, {data, {noeol, _Data}}}, State = #{port := Port}) ->
    {noreply, fail_stdio(response_too_large, State)};
handle_info({Port, {exit_status, Status}}, State = #{port := Port}) ->
    {noreply, fail_stdio({mcp_server_exited, Status}, State)};
handle_info({'EXIT', Port, Reason}, State = #{port := Port}) ->
    {noreply, fail_stdio({mcp_server_exited, Reason}, State)};
handle_info({stdio_request_timeout, Id}, State = #{transport := stdio}) ->
    case maps:take(Id, maps:get(pending, State)) of
        {{_Kind, From, _Timer}, Rest} ->
            send_stdio_cancel(Id, maps:get(port, State, undefined)),
            gen_server:reply(From, {error, timeout}),
            {noreply, State#{pending => Rest}};
        error -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, Conn, Reason},
            State = #{conn := Conn, conn_monitor := Monitor}) ->
    {stop, {mcp_http_connection_down, Reason}, State};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State = #{transport := http}) ->
    maybe_delete_session(State),
    case maps:find(conn, State) of
        {ok, Conn} -> _ = catch gun:close(Conn);
        error -> ok
    end,
    ok;
terminate(_Reason, State) ->
    case maps:find(port, State) of
        {ok, Port} -> _ = catch erlang:port_close(Port);
        error -> ok
    end,
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% Suppress authentication callback internals and transport messages from OTP
%% status/crash formatting. A production auth_fun should itself hold only an
%% opaque reference to a private credential/token service.
format_status(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              Config0 = maps:get(config, State, #{}),
              Auth = case maps:get(auth_fun, Config0, undefined) of
                  undefined -> undefined;
                  _ -> configured
              end,
              Config = Config0#{auth_fun => Auth},
              maps:without([pending], State#{config => Config});
         (message, Message) -> adk_secret_redactor:redact(Message);
         (log, _Log) -> [];
         (reason, Reason) -> adk_secret_redactor:redact(Reason);
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

initialize_params(State) ->
    Config = maps:get(config, State),
    #{<<"protocolVersion">> => ?LATEST_PROTOCOL_VERSION,
      <<"capabilities">> => maps:get(capabilities, Config),
      <<"clientInfo">> => maps:get(client_info, Config)}.

ready_for(State, Capability) ->
    case maps:get(port_closed, State, false) of
        true -> {error, port_closed};
        false -> ready_for_initialized(State, Capability)
    end.

ready_for_initialized(State, Capability) ->
    case maps:get(initialized, State, false) of
        false -> {error, not_initialized};
        true ->
            Capabilities = maps:get(<<"capabilities">>,
                                    maps:get(server_info, State, #{}), #{}),
            Key = atom_to_binary(Capability, utf8),
            case maps:is_key(Key, Capabilities) of
                true -> ok;
                false -> {error, {capability_not_negotiated, Capability}}
            end
    end.

ensure_transport_started(<<"streamable_http">>) -> ensure_gun_started();
ensure_transport_started(<<"http">>) -> ensure_gun_started();
ensure_transport_started(_) -> ok.

ensure_gun_started() ->
    case application:ensure_all_started(gun) of
        {ok, _} -> ok;
        {error, Reason} -> {error, {mcp_http_runtime_start_failed, Reason}}
    end.

send_stdio_request(_From, _Method, _Params, _Kind,
                   State = #{port_closed := true}) ->
    {reply, {error, port_closed}, State};
send_stdio_request(From, Method, Params, Kind, State) ->
    Id = maps:get(req_id, State),
    Message = request_message(Id, Method, Params),
    Port = maps:get(port, State),
    try erlang:port_command(Port, [jsx:encode(Message), <<"\n">>]) of
        true ->
            Pending = maps:get(pending, State),
            Timeout = maps:get(request_timeout, maps:get(config, State)),
            Timer = erlang:send_after(Timeout, self(),
                                      {stdio_request_timeout, Id}),
            {noreply, State#{req_id => Id + 1,
                             pending => Pending#{Id => {Kind, From, Timer}}}}
    catch
        error:badarg ->
            {reply, {error, port_closed}, State#{port_closed => true}}
    end.

handle_stdio_line(Data, State) ->
    try jsx:decode(Data, [return_maps]) of
        Message when is_map(Message) -> handle_stdio_message(Message, State)
    catch
        _:_ -> {noreply, fail_stdio(invalid_json, State)}
    end.

handle_stdio_message(#{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
                       <<"result">> := Result}, State) ->
    complete_stdio(Id, {ok, Result}, State);
handle_stdio_message(#{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
                       <<"error">> := Error}, State) when is_map(Error) ->
    complete_stdio(Id, {error, Error}, State);
handle_stdio_message(#{<<"jsonrpc">> := <<"2.0">>,
                       <<"method">> := _Notification}, State) ->
    {noreply, State};
handle_stdio_message(_Message, State) ->
    {noreply, fail_stdio(invalid_jsonrpc_response, State)}.

complete_stdio(Id, Outcome, State) ->
    case maps:take(Id, maps:get(pending, State)) of
        {{initialize, From, Timer}, Pending} ->
            erlang:cancel_timer(Timer),
            case validate_initialize(Outcome, State) of
                {ok, Result} ->
                    send_stdio_initialized(maps:get(port, State)),
                    gen_server:reply(From, ok),
                    {noreply, State#{pending => Pending,
                                     initialized => true,
                                     server_info => Result,
                                     protocol_version => maps:get(
                                       <<"protocolVersion">>, Result)}};
                {error, Reason} ->
                    gen_server:reply(From, {error, Reason}),
                    {noreply, fail_stdio(Reason,
                                         State#{pending => Pending})}
            end;
        {{{operation, _Method}, From, Timer}, Pending} ->
            erlang:cancel_timer(Timer),
            gen_server:reply(From, Outcome),
            {noreply, State#{pending => Pending}};
        error -> {noreply, State}
    end.

validate_initialize({ok, Result}, State) when is_map(Result) ->
    Version = maps:get(<<"protocolVersion">>, Result, undefined),
    Versions = maps:get(protocol_versions, maps:get(config, State)),
    case lists:member(Version, Versions) andalso
         is_map(maps:get(<<"capabilities">>, Result, invalid)) andalso
         is_map(maps:get(<<"serverInfo">>, Result, invalid)) of
        true -> {ok, Result};
        false when is_binary(Version) ->
            {error, {unsupported_protocol_version, Version}};
        false -> {error, invalid_initialize_result}
    end;
validate_initialize({error, Error}, _State) -> {error, Error};
validate_initialize(_, _State) -> {error, invalid_initialize_result}.

send_stdio_initialized(Port) ->
    Notification = notification_message(<<"notifications/initialized">>, #{}),
    _ = erlang:port_command(Port, [jsx:encode(Notification), <<"\n">>]),
    ok.

fail_stdio(Reason, State) ->
    reply_all_pending(maps:get(pending, State), Reason),
    case maps:find(port, State) of
        {ok, Port} -> _ = catch erlang:port_close(Port);
        error -> ok
    end,
    State#{pending => #{}, port_closed => true, initialized => false}.

reply_all_pending(Pending, Reason) ->
    maps:foreach(fun(_Id, {_Kind, From, Timer}) ->
                         erlang:cancel_timer(Timer),
                         gen_server:reply(From, {error, Reason})
                 end, Pending).

send_stdio_cancel(_Id, undefined) -> ok;
send_stdio_cancel(Id, Port) ->
    Params = #{<<"requestId">> => Id,
               <<"reason">> => <<"Client request timeout">>},
    Notification = #{<<"jsonrpc">> => <<"2.0">>,
                     <<"method">> => <<"notifications/cancelled">>,
                     <<"params">> => Params},
    _ = catch erlang:port_command(
                Port, [jsx:encode(Notification), <<"\n">>]),
    ok.

initialize_http(State0) ->
    Id = maps:get(req_id, State0),
    Message = request_message(Id, <<"initialize">>,
                              initialize_params(State0)),
    State1 = maps:remove(session_id, State0),
    case http_send(Message, initialize, State1#{req_id => Id + 1}) of
        {ok, 200, Headers, Body, State2} ->
            case decode_rpc_response(Headers, Body, Id) of
                {ok, Outcome} ->
                    case validate_initialize(Outcome, State2) of
                        {ok, Result} ->
                            case response_session_id(Headers) of
                                {ok, SessionId} ->
                                    State3 = maybe_put_session(SessionId,
                                                               State2),
                                    case send_http_initialized(State3) of
                                        {ok, State4} ->
                                            {ok, State4#{initialized => true,
                                                         server_info => Result,
                                                         protocol_version =>
                                                             maps:get(
                                                               <<"protocolVersion">>,
                                                               Result)}};
                                        {error, Reason, State4} ->
                                            {error, Reason, State4}
                                    end;
                                {error, Reason} ->
                                    {error, Reason, State2}
                            end;
                        {error, Reason} -> {error, Reason, State2}
                    end;
                {error, Reason} -> {error, Reason, State2}
            end;
        {ok, Status, _Headers, _Body, State2} ->
            {error, {http_status, Status}, State2};
        {error, Reason, State2} -> {error, Reason, State2}
    end.

send_http_initialized(State) ->
    Message = notification_message(<<"notifications/initialized">>, #{}),
    case http_send(Message, notification, State) of
        {ok, 202, _Headers, _Body, NewState} -> {ok, NewState};
        {ok, Status, _Headers, _Body, NewState} ->
            {error, {invalid_notification_status, Status}, NewState};
        {error, Reason, NewState} -> {error, Reason, NewState}
    end.

http_operation(Method, Params, State0, RetrySession) ->
    Id = maps:get(req_id, State0),
    Message = request_message(Id, Method, Params),
    State1 = State0#{req_id => Id + 1},
    case http_send(Message, operation, State1) of
        {ok, 200, Headers, Body, State2} ->
            case decode_rpc_response(Headers, Body, Id) of
                {ok, {ok, Result}} -> {ok, Result, State2};
                {ok, {error, Error}} -> {error, Error, State2};
                {error, Reason} -> {error, Reason, State2}
            end;
        {ok, 404, _Headers, _Body, State2}
          when RetrySession, is_map_key(session_id, State0) ->
            case initialize_http(maps:remove(session_id,
                                             State2#{initialized => false})) of
                {ok, State3} -> http_operation(Method, Params, State3, false);
                {error, Reason, State3} -> {error, Reason, State3}
            end;
        {ok, Status, _Headers, _Body, State2} ->
            {error, {http_status, Status}, State2};
        {error, Reason, State2} -> {error, Reason, State2}
    end.

http_send(Message, Kind, State) ->
    case request_headers(Kind, State) of
        {ok, Headers} ->
            Body = jsx:encode(Message),
            Conn = maps:get(conn, State),
            Path = maps:get(path, maps:get(endpoint, State)),
            Ref = gun:request(Conn, <<"POST">>, Path, Headers, Body),
            await_http(Conn, Ref, State);
        {error, Reason} -> {error, Reason, State}
    end.

await_http(Conn, Ref, State) ->
    Timeout = maps:get(request_timeout, maps:get(config, State)),
    case gun:await(Conn, Ref, Timeout) of
        {response, fin, Status, Headers} ->
            {ok, Status, Headers, <<>>, State};
        {response, nofin, Status, Headers} ->
            Max = maps:get(max_response_bytes, maps:get(config, State)),
            case await_http_body(Conn, Ref, Timeout, Max, [], 0) of
                {ok, Body} -> {ok, Status, Headers, Body, State};
                {error, Reason} -> {error, Reason, State}
            end;
        {error, Reason} -> {error, {http_transport, Reason}, State};
        Other -> {error, {invalid_http_response, safe_term(Other)}, State}
    end.

await_http_body(Conn, Ref, Timeout, Max, Acc, Size) ->
    case gun:await(Conn, Ref, Timeout) of
        {data, IsFin, Data} when is_binary(Data) ->
            NewSize = Size + byte_size(Data),
            case NewSize =< Max of
                false ->
                    _ = catch gun:cancel(Conn, Ref),
                    {error, response_too_large};
                true when IsFin =:= fin ->
                    {ok, iolist_to_binary(lists:reverse([Data | Acc]))};
                true ->
                    await_http_body(Conn, Ref, Timeout, Max,
                                    [Data | Acc], NewSize)
            end;
        {trailers, _Headers} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, Reason} -> {error, {http_transport, Reason}};
        Other -> {error, {invalid_http_body, safe_term(Other)}}
    end.

decode_rpc_response(Headers, Body, Id) ->
    case response_content_type(Headers) of
        application_json -> decode_json_response(Body, Id);
        text_event_stream -> decode_sse_response(Body, Id);
        undefined -> {error, missing_response_content_type};
        Other -> {error, {unsupported_response_content_type, Other}}
    end.

decode_json_response(Body, Id) ->
    try jsx:decode(Body, [return_maps]) of
        Message -> validate_rpc_response(Message, Id)
    catch
        _:_ -> {error, invalid_json_response}
    end.

decode_sse_response(Body, Id) ->
    Events = binary:split(normalize_newlines(Body), <<"\n\n">>, [global]),
    find_sse_response(Events, Id).

find_sse_response([], _Id) -> {error, missing_sse_response};
find_sse_response([Event | Rest], Id) ->
    DataLines = [binary:part(Line, 5, byte_size(Line) - 5)
                 || Line <- binary:split(Event, <<"\n">>, [global]),
                    byte_size(Line) >= 5,
                    binary:part(Line, 0, 5) =:= <<"data:">>],
    case DataLines of
        [] -> find_sse_response(Rest, Id);
        _ ->
            Data = iolist_to_binary(lists:join(<<"\n">>,
                                                [trim_left(D) || D <- DataLines])),
            case decode_json_response(Data, Id) of
                {error, {unexpected_response_id, _}} ->
                    find_sse_response(Rest, Id);
                {error, invalid_json_response} -> find_sse_response(Rest, Id);
                Result -> Result
            end
    end.

validate_rpc_response(#{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
                        <<"result">> := Result}, Id) when is_map(Result) ->
    {ok, {ok, Result}};
validate_rpc_response(#{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
                        <<"error">> := Error}, Id) when is_map(Error) ->
    {ok, {error, Error}};
validate_rpc_response(#{<<"id">> := Other}, _Id) ->
    {error, {unexpected_response_id, safe_term(Other)}};
validate_rpc_response(_, _Id) -> {error, invalid_jsonrpc_response}.

request_headers(Kind, State) ->
    Config = maps:get(config, State),
    Static = maps:get(headers, Config),
    case dynamic_auth_headers(maps:get(auth_fun, Config)) of
        {ok, Auth} ->
            Base = [{<<"accept">>,
                     <<"application/json, text/event-stream">>},
                    {<<"content-type">>, <<"application/json">>}],
            Protocol = case Kind of
                initialize -> [];
                _ -> [{<<"mcp-protocol-version">>,
                       maps:get(protocol_version, State,
                                ?LATEST_PROTOCOL_VERSION)}]
            end,
            Session = case maps:find(session_id, State) of
                {ok, Id} -> [{<<"mcp-session-id">>, Id}];
                error -> []
            end,
            {ok, Base ++ Protocol ++ Session ++ Static ++ Auth};
        Error -> Error
    end.

dynamic_auth_headers(undefined) -> {ok, []};
dynamic_auth_headers(Fun) ->
    try Fun() of
        Headers when is_list(Headers) ->
            case lists:all(fun valid_dynamic_header/1, Headers) of
                true -> {ok, Headers};
                false -> {error, invalid_auth_headers}
            end;
        _ -> {error, invalid_auth_headers}
    catch
        _:_ -> {error, auth_provider_failed}
    end.

valid_dynamic_header({Name, Value}) ->
    is_binary(Name) andalso is_binary(Value) andalso
    (lower(Name) =:= <<"authorization">> orelse
     lower(Name) =:= <<"proxy-authorization">>);
valid_dynamic_header(_) -> false.

response_content_type(Headers) ->
    case header_value(<<"content-type">>, Headers) of
        undefined -> undefined;
        Value ->
            Main = lower(hd(binary:split(Value, <<";">>))),
            case Main of
                <<"application/json">> -> application_json;
                <<"text/event-stream">> -> text_event_stream;
                _ -> Main
            end
    end.

response_session_id(Headers) ->
    case header_value(<<"mcp-session-id">>, Headers) of
        undefined -> {ok, undefined};
        Id when byte_size(Id) > 0 ->
            case lists:all(fun(C) -> C >= 16#21 andalso C =< 16#7e end,
                           binary_to_list(Id)) of
                true -> {ok, Id};
                false -> {error, invalid_mcp_session_id}
            end;
        _ -> {error, invalid_mcp_session_id}
    end.

maybe_put_session(undefined, State) -> maps:remove(session_id, State);
maybe_put_session(Id, State) -> State#{session_id => Id}.

header_value(Name, Headers) ->
    case lists:dropwhile(fun({Key, _}) -> lower(Key) =/= Name end, Headers) of
        [{_, Value} | _] -> Value;
        [] -> undefined
    end.

maybe_delete_session(State) ->
    case {maps:find(conn, State), maps:find(session_id, State)} of
        {{ok, Conn}, {ok, _SessionId}} ->
            case request_headers(operation, State) of
                {ok, Headers} ->
                    Path = maps:get(path, maps:get(endpoint, State)),
                    try gun:request(Conn, <<"DELETE">>, Path, Headers, <<>>) of
                        Ref -> _ = catch gun:await(Conn, Ref, 1000), ok
                    catch _:_ -> ok
                    end;
                {error, _} -> ok
            end;
        _ -> ok
    end.

parse_http_url(Url) ->
    try uri_string:parse(Url) of
        Parsed when is_map(Parsed) -> normalize_http_endpoint(Parsed)
    catch
        _:_ -> {error, invalid_mcp_url}
    end.

normalize_http_endpoint(Parsed) ->
    Scheme = to_binary(maps:get(scheme, Parsed, <<>>)),
    Host = to_binary(maps:get(host, Parsed, <<>>)),
    UserInfo = maps:get(userinfo, Parsed, undefined),
    Fragment = maps:get(fragment, Parsed, undefined),
    Query = maps:get(query, Parsed, undefined),
    case (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>) andalso
         byte_size(Host) > 0 andalso UserInfo =:= undefined andalso
         Fragment =:= undefined andalso Query =:= undefined of
        false -> {error, invalid_mcp_url};
        true ->
            DefaultPort = case Scheme of <<"https">> -> 443; _ -> 80 end,
            Port = maps:get(port, Parsed, DefaultPort),
            Path0 = to_binary(maps:get(path, Parsed, <<"/">>)),
            Path1 = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
            case is_integer(Port) andalso Port > 0 andalso Port =< 65535 of
                true -> {ok, #{scheme => Scheme, host => Host,
                               port => Port, path => Path1}};
                false -> {error, invalid_mcp_url}
            end
    end.

open_http(Endpoint, Config) ->
    Host = binary_to_list(maps:get(host, Endpoint)),
    Port = maps:get(port, Endpoint),
    GunOptions = gun_options(maps:get(scheme, Endpoint), Config),
    case gun:open(Host, Port, GunOptions) of
        {ok, Conn} ->
            Timeout = maps:get(connect_timeout, Config),
            case gun:await_up(Conn, Timeout) of
                {ok, _Protocol} ->
                    Monitor = erlang:monitor(process, Conn),
                    {ok, Conn, Monitor};
                {error, Reason} ->
                    _ = catch gun:close(Conn),
                    {error, {mcp_http_connect_failed, Reason}}
            end;
        {error, Reason} -> {error, {mcp_http_connect_failed, Reason}}
    end.

gun_options(<<"http">>, _Config) -> #{transport => tcp};
gun_options(<<"https">>, Config) ->
    TlsOpts = case maps:get(tls_opts, Config) of
        default ->
            [{verify, verify_peer},
             {cacerts, apply(public_key, cacerts_get, [])},
             {customize_hostname_check,
              [{match_fun, apply(public_key,
                                 pkix_verify_hostname_match_fun,
                                 [https])}]}];
        Value -> Value
    end,
    #{transport => tls, tls_opts => TlsOpts}.

request_message(Id, Method, Params) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"method">> => Method, <<"params">> => Params}.

notification_message(Method, _EmptyParams) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => Method}.

dummy_server_info() ->
    #{<<"protocolVersion">> => ?LATEST_PROTOCOL_VERSION,
      <<"capabilities">> => #{<<"tools">> => #{}},
      <<"serverInfo">> => #{<<"name">> => <<"dummy">>,
                             <<"version">> => <<"test">>}}.

normalize_newlines(Binary) ->
    binary:replace(binary:replace(Binary, <<"\r\n">>, <<"\n">>, [global]),
                   <<"\r">>, <<"\n">>, [global]).

trim_left(<<" ", Rest/binary>>) -> Rest;
trim_left(Value) -> Value.

lower(Value) when is_binary(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

safe_term(Value) when is_integer(Value); is_binary(Value); is_atom(Value) -> Value;
safe_term(_) -> invalid.
