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
-define(MAX_TIMEOUT, 120000).
-define(PUBLIC_CALL_TIMEOUT, 125000).
-define(CALL_REPLY_GRACE_MS, 1000).
-define(MAX_HEADER_BYTES, 8192).
-define(DEFAULT_CALLBACK_MAX_HEAP_WORDS, 262144).
-define(MIN_CALLBACK_MAX_HEAP_WORDS, 1024).
-define(MAX_CALLBACK_MAX_HEAP_WORDS, 4194304).
-define(DEFAULT_MAX_RESOLVED_ADDRESSES, 64).
-define(MAX_RESOLVED_ADDRESSES, 256).

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
                    Result = safe_call(Client, initialize,
                                       Timeout + ?CALL_REPLY_GRACE_MS,
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
    case safe_call(Client, Request, ?PUBLIC_CALL_TIMEOUT, request) of
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
                            <<"version">> => application_version()}),
    Capabilities = maps:get(capabilities, Options, #{}),
    Headers = maps:get(headers, Options, []),
    AuthFun = maps:get(auth_fun, Options, undefined),
    TlsOpts = maps:get(tls_opts, Options, default),
    AllowHttpLoopback = maps:get(allow_http_loopback, Options, false),
    AllowedHosts0 = maps:get(allowed_hosts, Options, any),
    AllowedPrivate0 = maps:get(allowed_private_hosts, Options, []),
    ResolverFun = maps:get(resolver_fun, Options, undefined),
    CallbackMaxHeapWords = maps:get(
                             callback_max_heap_words, Options,
                             ?DEFAULT_CALLBACK_MAX_HEAP_WORDS),
    MaxResolvedAddresses = maps:get(
                             max_resolved_addresses, Options,
                             ?DEFAULT_MAX_RESOLVED_ADDRESSES),
    case valid_timeout(InitializeTimeout) andalso
         valid_timeout(RequestTimeout) andalso
         valid_timeout(ConnectTimeout) andalso
         is_integer(MaxBytes) andalso MaxBytes > 0 andalso
         is_map(ClientInfo) andalso is_map(Capabilities) andalso
         valid_static_headers(Headers) andalso
         valid_auth_fun(AuthFun) andalso
         valid_tls_opts(TlsOpts) andalso
         is_boolean(AllowHttpLoopback) andalso
         valid_host_policy(AllowedHosts0) andalso
         valid_host_list(AllowedPrivate0) andalso
         (ResolverFun =:= undefined orelse is_function(ResolverFun, 1)) andalso
         bounded_range(CallbackMaxHeapWords,
                       ?MIN_CALLBACK_MAX_HEAP_WORDS,
                       ?MAX_CALLBACK_MAX_HEAP_WORDS) andalso
         bounded_positive(MaxResolvedAddresses,
                          ?MAX_RESOLVED_ADDRESSES) of
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
                   allow_http_loopback => AllowHttpLoopback,
                   allowed_hosts => normalize_host_policy(AllowedHosts0),
                   allowed_private_hosts => normalize_hosts(AllowedPrivate0),
                   resolver_fun => ResolverFun,
                   callback_max_heap_words => CallbackMaxHeapWords,
                   max_resolved_addresses => MaxResolvedAddresses,
                   protocol_versions => ?SUPPORTED_PROTOCOL_VERSIONS}};
        false -> {error, invalid_mcp_client_options}
    end.

valid_timeout(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< ?MAX_TIMEOUT.

bounded_positive(Value, Ceiling) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Ceiling.

bounded_range(Value, Floor, Ceiling) ->
    is_integer(Value) andalso Value >= Floor andalso Value =< Ceiling.

valid_tls_opts(default) -> true;
valid_tls_opts(Options) when is_list(Options) ->
    lists:all(fun(Option) -> is_tuple(Option) andalso tuple_size(Option) =:= 2
              end, Options) andalso
    not lists:member({verify, verify_none}, Options);
valid_tls_opts(_) -> false.

application_version() ->
    _ = application:load(erlang_adk),
    case application:get_key(erlang_adk, vsn) of
        {ok, Version} when is_list(Version) ->
            unicode:characters_to_binary(Version);
        {ok, Version} when is_binary(Version) -> Version;
        _ -> <<"unknown">>
    end.

valid_auth_fun(undefined) -> true;
valid_auth_fun(Fun) -> is_function(Fun, 0).

valid_static_headers(Headers) when is_list(Headers) ->
    lists:all(
      fun({Name, Value}) when is_binary(Name), is_binary(Value) ->
              Header = lower(Name),
              byte_size(Name) > 0 andalso
              byte_size(Name) =< 256 andalso
              byte_size(Value) =< ?MAX_HEADER_BYTES andalso
              no_controls(Name) andalso no_controls(Value) andalso
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
            Deadline = deadline(maps:get(connect_timeout, Config)),
            case resolve_endpoint(Endpoint, Config, Deadline) of
                {ok, ResolvedEndpoint} ->
                    case open_http(ResolvedEndpoint, Config, Deadline) of
                        {ok, Conn, Monitor} ->
                    {ok, (base_state(http, Config))#{endpoint => ResolvedEndpoint,
                                                     conn => Conn,
                                                     conn_monitor => Monitor}};
                        {error, Reason} ->
                            {ok, (base_state(http, Config))#{startup_error =>
                                                                 Reason}}
                    end;
                {error, Reason} ->
                    {ok, (base_state(http, Config))#{startup_error => Reason}}
            end;
        {error, Reason} ->
            {ok, (base_state(http, Config))#{startup_error => Reason}}
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
handle_call(initialize, _From,
            State = #{transport := http, startup_error := Reason}) ->
    {reply, {error, Reason}, State};
handle_call(initialize, _From, State = #{transport := http}) ->
    Deadline = deadline(maps:get(initialize_timeout, maps:get(config, State))),
    case initialize_http(State, Deadline) of
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
            Deadline = deadline(maps:get(request_timeout,
                                         maps:get(config, State))),
            case http_operation(Method, Params, State, true, Deadline) of
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
              Resolver = case maps:get(resolver_fun, Config0, undefined) of
                  undefined -> undefined;
                  _ -> configured
              end,
              Config = Config0#{auth_fun => Auth, resolver_fun => Resolver},
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
            Timeout = stdio_request_timeout(Kind, maps:get(config, State)),
            Timer = erlang:send_after(Timeout, self(),
                                      {stdio_request_timeout, Id}),
            {noreply, State#{req_id => Id + 1,
                             pending => Pending#{Id => {Kind, From, Timer}}}}
    catch
        error:badarg ->
            {reply, {error, port_closed}, State#{port_closed => true}}
    end.

stdio_request_timeout(initialize, Config) ->
    maps:get(initialize_timeout, Config);
stdio_request_timeout(_Operation, Config) ->
    maps:get(request_timeout, Config).

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

initialize_http(State0, Deadline) ->
    Id = maps:get(req_id, State0),
    Message = request_message(Id, <<"initialize">>,
                              initialize_params(State0)),
    State1 = maps:remove(session_id, State0),
    case http_send(Message, initialize, State1#{req_id => Id + 1}, Deadline) of
        {ok, 200, Headers, Body, State2} ->
            case decode_rpc_response(Headers, Body, Id) of
                {ok, Outcome} ->
                    case validate_initialize(Outcome, State2) of
                        {ok, Result} ->
                            case response_session_id(Headers) of
                                {ok, SessionId} ->
                                    State3 = maybe_put_session(SessionId,
                                                               State2),
                                    case send_http_initialized(State3,
                                                               Deadline) of
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

send_http_initialized(State, Deadline) ->
    Message = notification_message(<<"notifications/initialized">>, #{}),
    case http_send(Message, notification, State, Deadline) of
        {ok, 202, _Headers, _Body, NewState} -> {ok, NewState};
        {ok, Status, _Headers, _Body, NewState} ->
            {error, {invalid_notification_status, Status}, NewState};
        {error, Reason, NewState} -> {error, Reason, NewState}
    end.

http_operation(Method, Params, State0, RetrySession, Deadline) ->
    Id = maps:get(req_id, State0),
    Message = request_message(Id, Method, Params),
    State1 = State0#{req_id => Id + 1},
    case http_send(Message, operation, State1, Deadline) of
        {ok, 200, Headers, Body, State2} ->
            case decode_rpc_response(Headers, Body, Id) of
                {ok, {ok, Result}} -> {ok, Result, State2};
                {ok, {error, Error}} -> {error, Error, State2};
                {error, Reason} -> {error, Reason, State2}
            end;
        {ok, 404, _Headers, _Body, State2}
          when RetrySession, is_map_key(session_id, State0) ->
            case initialize_http(maps:remove(session_id,
                                             State2#{initialized => false}),
                                 Deadline) of
                {ok, State3} ->
                    case retryable_after_session_loss(Method) of
                        true ->
                            http_operation(Method, Params, State3, false,
                                           Deadline);
                        false ->
                            %% The server may have observed a mutating request
                            %% before reporting a lost session. Replaying it
                            %% could duplicate an external side effect. The
                            %% new session is retained for the caller's next
                            %% explicit operation, but this call is uncertain.
                            {error,
                             {mcp_session_lost, request_not_replayed},
                             State3}
                    end;
                {error, Reason, State3} -> {error, Reason, State3}
            end;
        {ok, Status, _Headers, _Body, State2} ->
            {error, {http_status, Status}, State2};
        {error, Reason, State2} -> {error, Reason, State2}
    end.

retryable_after_session_loss(<<"tools/list">>) -> true;
retryable_after_session_loss(<<"resources/list">>) -> true;
retryable_after_session_loss(<<"resources/read">>) -> true;
retryable_after_session_loss(<<"prompts/list">>) -> true;
retryable_after_session_loss(<<"prompts/get">>) -> true;
retryable_after_session_loss(<<"ping">>) -> true;
retryable_after_session_loss(_Method) -> false.

http_send(Message, Kind, State, Deadline) ->
    case request_headers(Kind, State, Deadline) of
        {ok, Headers} ->
            case remaining(Deadline) of
                0 -> {error, timeout, State};
                _ ->
                    Body = jsx:encode(Message),
                    Conn = maps:get(conn, State),
                    Path = maps:get(path, maps:get(endpoint, State)),
                    Ref = gun:request(Conn, <<"POST">>, Path, Headers, Body),
                    await_http(Conn, Ref, State, Deadline)
            end;
        {error, Reason} -> {error, Reason, State}
    end.

await_http(Conn, Ref, State, Deadline) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {inform, _Status, _Headers} ->
            await_http(Conn, Ref, State, Deadline);
        {response, IsFin, Status, _Headers}
          when Status >= 300, Status =< 399 ->
            case IsFin of
                nofin -> _ = catch gun:cancel(Conn, Ref);
                fin -> ok
            end,
            {error, {redirect_rejected, Status}, State};
        {response, fin, Status, Headers} ->
            {ok, Status, Headers, <<>>, State};
        {response, nofin, Status, Headers} ->
            Max = maps:get(max_response_bytes, maps:get(config, State)),
            case await_http_body(Conn, Ref, Deadline, Max, [], 0) of
                {ok, Body} -> {ok, Status, Headers, Body, State};
                {error, Reason} -> {error, Reason, State}
            end;
        {error, timeout} -> {error, timeout, State};
        {error, Reason} -> {error, {http_transport, Reason}, State};
        Other -> {error, {invalid_http_response, safe_term(Other)}, State}
    end.

await_http_body(Conn, Ref, Deadline, Max, Acc, Size) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {data, IsFin, Data} when is_binary(Data) ->
            NewSize = Size + byte_size(Data),
            case NewSize =< Max of
                false ->
                    _ = catch gun:cancel(Conn, Ref),
                    {error, response_too_large};
                true when IsFin =:= fin ->
                    {ok, iolist_to_binary(lists:reverse([Data | Acc]))};
                true ->
                    await_http_body(Conn, Ref, Deadline, Max,
                                    [Data | Acc], NewSize)
            end;
        {trailers, _Headers} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, timeout} -> {error, timeout};
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

request_headers(Kind, State, Deadline) ->
    Config = maps:get(config, State),
    Static = maps:get(headers, Config),
    case dynamic_auth_headers(maps:get(auth_fun, Config), Config, Deadline) of
        {ok, Auth} ->
            Endpoint = maps:get(endpoint, State),
            Base = [{<<"host">>, host_header(Endpoint)},
                    {<<"accept">>,
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

dynamic_auth_headers(undefined, _Config, _Deadline) -> {ok, []};
dynamic_auth_headers(Fun, Config, Deadline) ->
    MaxHeap = maps:get(callback_max_heap_words, Config),
    case run_callback_worker(auth, fun() -> invoke_auth_fun(Fun) end,
                             MaxHeap, Deadline) of
        {ok, Result} -> Result;
        timeout -> {error, timeout};
        failed -> {error, auth_provider_failed}
    end.

invoke_auth_fun(Fun) ->
    try Fun() of
        Headers when is_list(Headers) -> normalize_auth_headers(Headers);
        _ -> {error, invalid_auth_headers}
    catch
        _:_ -> {error, auth_provider_failed}
    end.

normalize_auth_headers(Headers) ->
    case lists:all(fun valid_dynamic_header/1, Headers) andalso
         length(Headers) =< 1 of
        true -> {ok, [{<<"authorization">>, Value}
                      || {_Name, Value} <- Headers]};
        false -> {error, invalid_auth_headers}
    end.

valid_dynamic_header({Name, Value}) ->
    is_binary(Name) andalso is_binary(Value) andalso
    lower(Name) =:= <<"authorization">> andalso
    byte_size(Value) > 0 andalso byte_size(Value) =< ?MAX_HEADER_BYTES andalso
    no_controls(Name) andalso no_controls(Value);
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
            Deadline = deadline(1000),
            case request_headers(operation, State, Deadline) of
                {ok, Headers} ->
                    Path = maps:get(path, maps:get(endpoint, State)),
                    try gun:request(Conn, <<"DELETE">>, Path, Headers, <<>>) of
                        Ref -> _ = catch gun:await(Conn, Ref,
                                                  remaining(Deadline)), ok
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
    Scheme = lower(to_binary(maps:get(scheme, Parsed, <<>>))),
    Host = canonical_host(to_binary(maps:get(host, Parsed, <<>>))),
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

resolve_endpoint(Endpoint, Config, Deadline) ->
    Host = maps:get(host, Endpoint),
    case exact_host_allowed(Host, maps:get(allowed_hosts, Config)) of
        false -> {error, mcp_destination_not_allowed};
        true ->
            case resolve_addresses(Host, Config, Deadline) of
                {ok, Addresses} ->
                    validate_resolved_endpoint(Endpoint, Addresses, Config);
                {error, _} = Error -> Error
            end
    end.

resolve_addresses(Host, Config, Deadline) ->
    Resolver = maps:get(resolver_fun, Config),
    MaxAddresses = maps:get(max_resolved_addresses, Config),
    MaxHeap = maps:get(callback_max_heap_words, Config),
    Work = fun() -> resolved_addresses(Host, Resolver, MaxAddresses) end,
    case run_callback_worker(resolver, Work, MaxHeap, Deadline) of
        {ok, {ok, []}} -> {error, mcp_dns_resolution_failed};
        {ok, {ok, Addresses}} -> {ok, Addresses};
        {ok, error} -> {error, mcp_dns_resolution_failed};
        timeout -> {error, mcp_connect_timeout};
        failed -> {error, mcp_dns_resolution_failed}
    end.

resolved_addresses(Host, undefined, MaxAddresses) ->
    HostString = binary_to_list(Host),
    normalize_addresses(resolve_family(HostString, inet) ++
                        resolve_family(HostString, inet6), MaxAddresses);
resolved_addresses(Host, Resolver, MaxAddresses) ->
    try Resolver(Host) of
        {ok, Addresses} -> normalize_addresses(Addresses, MaxAddresses);
        Addresses when is_list(Addresses) ->
            normalize_addresses(Addresses, MaxAddresses);
        _ -> error
    catch _:_ -> error
    end.

resolve_family(Host, Family) ->
    case inet:getaddrs(Host, Family) of
        {ok, Addresses} -> Addresses;
        {error, _} -> []
    end.

normalize_addresses(Addresses, MaxAddresses) when is_list(Addresses) ->
    bounded_addresses(Addresses, MaxAddresses, []);
normalize_addresses(_, _MaxAddresses) -> error.

bounded_addresses([], _Remaining, Acc) ->
    {ok, lists:usort(Acc)};
bounded_addresses(_Addresses, 0, _Acc) -> error;
bounded_addresses([Address | Rest], Remaining, Acc) ->
    case valid_ip_address(Address) of
        true -> bounded_addresses(Rest, Remaining - 1, [Address | Acc]);
        false -> error
    end;
bounded_addresses(_Improper, _Remaining, _Acc) -> error.

%% Authentication and custom DNS callbacks are application code.  Normalize
%% their results in an off-heap, heap-limited process and address replies via a
%% process alias, so a timed-out callback cannot leave a late message in the
%% long-lived MCP client mailbox.
run_callback_worker(Kind, Work, MaxHeap, Deadline) ->
    case remaining(Deadline) of
        0 -> timeout;
        _ -> start_callback_worker(Kind, Work, MaxHeap, Deadline)
    end.

start_callback_worker(Kind, Work, MaxHeap, Deadline) ->
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Ref = make_ref(),
    Worker = fun() ->
        start_callback_owner_watchdog(Owner, self()),
        Result = Work(),
        CompletedAt = erlang:monotonic_time(millisecond),
        _ = erlang:send(
              ReplyAlias,
              {mcp_client_callback_result, Kind, Ref, self(),
               CompletedAt, Result},
              [noconnect, nosuspend]),
        ok
    end,
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => MaxHeap, kill => true, error_logger => false,
            include_shared_binaries => true}}],
    try erlang:spawn_opt(Worker, SpawnOptions) of
        {Pid, Monitor} ->
            await_callback_worker(Kind, Pid, Monitor, ReplyAlias, Ref,
                                  Deadline)
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            failed
    end.

await_callback_worker(Kind, Pid, Monitor, ReplyAlias, Ref, Deadline) ->
    receive
        {mcp_client_callback_result, Kind, Ref, Pid, CompletedAt, Result}
          when CompletedAt =< Deadline ->
            callback_worker_complete(ReplyAlias, Monitor),
            {ok, Result};
        {mcp_client_callback_result, Kind, Ref, Pid,
         _CompletedAt, _LateResult} ->
            _ = erlang:unalias(ReplyAlias),
            exit(Pid, kill),
            await_callback_worker_down(Pid, Monitor),
            timeout;
        {'DOWN', Monitor, process, Pid, _OpaqueReason} ->
            _ = erlang:unalias(ReplyAlias),
            flush_callback_worker_result(Kind, Ref, Pid),
            failed
    after remaining(Deadline) ->
        _ = erlang:unalias(ReplyAlias),
        exit(Pid, kill),
        await_callback_worker_down(Pid, Monitor),
        flush_callback_worker_result(Kind, Ref, Pid),
        timeout
    end.

callback_worker_complete(ReplyAlias, Monitor) ->
    _ = erlang:unalias(ReplyAlias),
    _ = erlang:demonitor(Monitor, [flush]),
    ok.

flush_callback_worker_result(Kind, Ref, Pid) ->
    receive
        {mcp_client_callback_result, Kind, Ref, Pid,
         _CompletedAt, _Result} -> ok
    after 0 -> ok
    end.

await_callback_worker_down(Pid, Monitor) ->
    receive
        {'DOWN', Monitor, process, Pid, _OpaqueReason} -> ok
    after 100 ->
        _ = erlang:demonitor(Monitor, [flush]),
        ok
    end.

start_callback_owner_watchdog(Owner, Callback) ->
    Watchdog = fun() -> callback_owner_watchdog(Owner, Callback) end,
    _ = spawn_opt(
          Watchdog,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]),
    ok.

callback_owner_watchdog(Owner, Callback) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    CallbackMonitor = erlang:monitor(process, Callback),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(Callback, kill),
            _ = erlang:demonitor(CallbackMonitor, [flush]),
            ok;
        {'DOWN', CallbackMonitor, process, Callback, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

validate_resolved_endpoint(Endpoint, Addresses, Config) ->
    Scheme = maps:get(scheme, Endpoint),
    Host = maps:get(host, Endpoint),
    AllLoopback = lists:all(fun is_loopback_address/1, Addresses),
    AllPublic = lists:all(fun is_public_address/1, Addresses),
    PrivateAllowed = lists:member(
                       Host, maps:get(allowed_private_hosts, Config)),
    Allowed = case Scheme of
        <<"http">> -> maps:get(allow_http_loopback, Config) andalso AllLoopback;
        <<"https">> -> AllPublic orelse PrivateAllowed
    end,
    case Allowed of
        true -> {ok, Endpoint#{address => hd(Addresses),
                              all_loopback => AllLoopback}};
        false when Scheme =:= <<"http">> ->
            {error, insecure_mcp_destination};
        false -> {error, mcp_private_destination_rejected}
    end.

open_http(Endpoint, Config, Deadline) ->
    Address = maps:get(address, Endpoint),
    Port = maps:get(port, Endpoint),
    GunOptions = gun_options(Endpoint, Config, Deadline),
    case remaining(Deadline) of
        0 -> {error, mcp_connect_timeout};
        _ -> open_http_connection(Address, Port, GunOptions, Deadline)
    end.

open_http_connection(Address, Port, GunOptions, Deadline) ->
    case gun:open(Address, Port, GunOptions) of
        {ok, Conn} ->
            case gun:await_up(Conn, remaining(Deadline)) of
                {ok, _Protocol} ->
                    Monitor = erlang:monitor(process, Conn),
                    {ok, Conn, Monitor};
                {error, timeout} ->
                    _ = catch gun:close(Conn),
                    {error, mcp_connect_timeout};
                {error, Reason} ->
                    _ = catch gun:close(Conn),
                    {error, {mcp_http_connect_failed, Reason}}
            end;
        {error, Reason} -> {error, {mcp_http_connect_failed, Reason}}
    end.

gun_options(#{scheme := <<"http">>}, _Config, Deadline) ->
    #{transport => tcp, protocols => [http], retry => 0,
      connect_timeout => remaining(Deadline)};
gun_options(#{scheme := <<"https">>, host := Host}, Config, Deadline) ->
    #{transport => tls, protocols => [http], retry => 0,
      connect_timeout => remaining(Deadline),
      tls_handshake_timeout => remaining(Deadline),
      tls_opts => secure_tls_opts(Host, maps:get(tls_opts, Config))}.

secure_tls_opts(Host, Configured) ->
    Extra0 = case Configured of default -> []; Value -> Value end,
    Extra = lists:filter(
              fun({Key, _Value}) ->
                      not lists:member(Key,
                                       [verify, verify_fun, partial_chain,
                                        server_name_indication,
                                        customize_hostname_check]);
                 (_) -> false
              end, Extra0),
    Trust = case lists:keymember(cacerts, 1, Extra) orelse
                 lists:keymember(cacertfile, 1, Extra) of
        true -> [];
        false -> [{cacerts, public_key:cacerts_get()}]
    end,
    [{verify, verify_peer},
     {server_name_indication, binary_to_list(Host)},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
    ++ Trust ++ Extra.

host_header(#{scheme := <<"https">>, host := Host, port := 443}) ->
    authority_host(Host);
host_header(#{scheme := <<"http">>, host := Host, port := 80}) ->
    authority_host(Host);
host_header(#{host := Host, port := Port}) ->
    AuthorityHost = authority_host(Host),
    <<AuthorityHost/binary, ":", (integer_to_binary(Port))/binary>>.

authority_host(Host) ->
    case inet:parse_ipv6_address(binary_to_list(Host)) of
        {ok, _} -> <<"[", Host/binary, "]">>;
        {error, _} -> Host
    end.

valid_host_policy(any) -> true;
valid_host_policy(Hosts) -> valid_host_list(Hosts).

valid_host_list(Hosts) when is_list(Hosts) ->
    length(Hosts) =< 256 andalso
    lists:all(
      fun(Host0) ->
          Host = canonical_host(to_binary(Host0)),
          byte_size(Host) > 0 andalso byte_size(Host) =< 253 andalso
          no_controls(Host)
      end, Hosts);
valid_host_list(_) -> false.

normalize_host_policy(any) -> any;
normalize_host_policy(Hosts) -> normalize_hosts(Hosts).

normalize_hosts(Hosts) ->
    lists:usort([canonical_host(to_binary(Host)) || Host <- Hosts]).

exact_host_allowed(_Host, any) -> true;
exact_host_allowed(Host, Hosts) -> lists:member(Host, Hosts).

canonical_host(Host) -> lower(Host).

deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

valid_ip_address({A, B, C, D}) ->
    lists:all(fun(V) -> is_integer(V) andalso V >= 0 andalso V =< 255 end,
              [A, B, C, D]);
valid_ip_address({A, B, C, D, E, F, G, H}) ->
    lists:all(fun(V) -> is_integer(V) andalso V >= 0 andalso V =< 16#ffff end,
              [A, B, C, D, E, F, G, H]);
valid_ip_address(_) -> false.

is_loopback_address({127, _B, _C, _D}) -> true;
is_loopback_address({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback_address({0, 0, 0, 0, 0, 16#ffff, C, D}) ->
    is_loopback_address({C bsr 8, C band 16#ff,
                         D bsr 8, D band 16#ff});
is_loopback_address(_) -> false.

%% Reject loopback, link-local, private, carrier-grade NAT, documentation,
%% benchmarking, protocol-assignment, multicast, and reserved destinations.
is_public_address({A, _B, _C, _D}) when A =:= 0; A =:= 10; A =:= 127 -> false;
is_public_address({100, B, _C, _D}) when B >= 64, B =< 127 -> false;
is_public_address({169, 254, _C, _D}) -> false;
is_public_address({172, B, _C, _D}) when B >= 16, B =< 31 -> false;
is_public_address({192, 0, 0, _D}) -> false;
is_public_address({192, 0, 2, _D}) -> false;
is_public_address({192, 31, 196, _D}) -> false;
is_public_address({192, 52, 193, _D}) -> false;
is_public_address({192, 88, 99, _D}) -> false;
is_public_address({192, 168, _C, _D}) -> false;
is_public_address({198, B, _C, _D}) when B =:= 18; B =:= 19 -> false;
is_public_address({198, 51, 100, _D}) -> false;
is_public_address({203, 0, 113, _D}) -> false;
is_public_address({A, _B, _C, _D}) when A >= 224 -> false;
is_public_address({_A, _B, _C, _D}) -> true;
is_public_address({0, 0, 0, 0, 0, 16#ffff, C, D}) ->
    is_public_address({C bsr 8, C band 16#ff,
                       D bsr 8, D band 16#ff});
is_public_address({0, _B, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#0100, 0, 0, 0, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 0, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 2, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, 16#0db8, _C, _D, _E, _F, _G, _H}) -> false;
is_public_address({16#2001, A, _C, _D, _E, _F, _G, _H})
  when A >= 16#0010, A =< 16#002f -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#fe00) =:= 16#fc00 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fe80 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ffc0) =:= 16#fec0 -> false;
is_public_address({A, _B, _C, _D, _E, _F, _G, _H})
  when (A band 16#ff00) =:= 16#ff00 -> false;
is_public_address({_A, _B, _C, _D, _E, _F, _G, _H}) -> true;
is_public_address(_) -> false.

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

no_controls(Binary) ->
    lists:all(fun(C) -> C >= 16#20 andalso C =/= 16#7f end,
              binary_to_list(Binary)).

lower(Value) when is_binary(Value) ->
    list_to_binary(string:lowercase(binary_to_list(Value))).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

safe_term(Value) when is_integer(Value); is_binary(Value); is_atom(Value) -> Value;
safe_term(_) -> invalid.
