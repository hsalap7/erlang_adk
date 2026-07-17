%% @doc Bounded MCP 2025-11-25 Streamable HTTP server.
%%
%% The server deliberately implements JSON responses to POST and returns 405
%% for the optional GET/SSE channel. Tool/resource/prompt work runs in monitored
%% lightweight processes behind a global concurrency and deadline bound.
-module(adk_mcp_server).
-behaviour(gen_server).

-export([start/2, start_link/1, stop/1, endpoint/1,
         register_tool/2, register_resource/2, register_prompt/2,
         handle_http/5, handle_http/6,
         delete_session/3, delete_session/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(LATEST_PROTOCOL_VERSION, <<"2025-11-25">>).
-define(SUPPORTED_PROTOCOL_VERSIONS,
        [?LATEST_PROTOCOL_VERSION, <<"2025-06-18">>]).
-define(DEFAULT_MAX_BODY_BYTES, 1048576).
-define(DEFAULT_MAX_RESPONSE_BYTES, 4194304).
-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_MAX_CONCURRENCY, 32).
-define(DEFAULT_MAX_SESSIONS, 1024).
-define(DEFAULT_MAX_SESSION_REQUESTS, 10000).
-define(DEFAULT_SESSION_TTL_MS, 3600000).
-define(DEFAULT_CALLBACK_TIMEOUT, 5000).
-define(MAX_CALLBACK_TIMEOUT, 30000).
-define(DEFAULT_CALLBACK_MAX_HEAP_WORDS, 262144).
-define(MIN_CALLBACK_MAX_HEAP_WORDS, 1024).
-define(MAX_CALLBACK_MAX_HEAP_WORDS, 4194304).
-define(MIN_RESPONSE_BYTES, 256).
-define(SERVER_REPLY_GRACE_MS, 1000).

-spec start(binary(), map() | [module()]) ->
    {ok, pid()} | {error, term()}.
start(<<"streamable_http">>, Config) when is_map(Config) ->
    case normalize_config(Config) of
        {ok, Normalized, Registries} ->
            case application:ensure_all_started(cowboy) of
                {ok, _} ->
                    gen_server:start(
                      ?MODULE, {normalized, Normalized, Registries}, []);
                {error, Reason} ->
                    {error, {mcp_http_runtime_start_failed, Reason}}
            end;
        {error, Reason} -> {error, Reason}
    end;
start(<<"streamable_http">>, Tools) when is_list(Tools) ->
    start(<<"streamable_http">>, #{tools => Tools});
start(<<"http">>, Config) ->
    start(<<"streamable_http">>, Config);
start(<<"stdio">>, _Config) ->
    {error, {unsupported_transport, server_stdio}};
start(<<"sse">>, _Config) ->
    {error, {unsupported_transport, sse_deprecated_use_streamable_http}};
start(Transport, _Config) ->
    {error, {unsupported_transport, Transport}}.

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) when is_map(Config) ->
    case normalize_config(Config) of
        {ok, Normalized, Registries} ->
            gen_server:start_link(
              ?MODULE, {normalized, Normalized, Registries}, []);
        {error, Reason} -> {error, Reason}
    end;
start_link(_Config) -> {error, invalid_mcp_server_config}.

-spec stop(pid()) -> ok.
stop(Server) -> gen_server:stop(Server).

-spec endpoint(pid()) -> {ok, map()} | {error, term()}.
endpoint(Server) -> gen_server:call(Server, endpoint).

-spec register_tool(pid(), module() | map()) -> ok | {error, term()}.
register_tool(Server, Tool) -> gen_server:call(Server, {register, tool, Tool}).

-spec register_resource(pid(), map()) -> ok | {error, term()}.
register_resource(Server, Resource) ->
    gen_server:call(Server, {register, resource, Resource}).

-spec register_prompt(pid(), map()) -> ok | {error, term()}.
register_prompt(Server, Prompt) ->
    gen_server:call(Server, {register, prompt, Prompt}).

%% Internal transport boundary called by adk_mcp_http_handler.
-spec handle_http(pid(), undefined | binary(), undefined | binary(),
                  map(), timeout()) -> term().
handle_http(Server, Session, Version, Message, Timeout) ->
    handle_http(Server, Session, Version, Message, legacy, Timeout).

%% The HTTP boundary supplies a normalized authentication context. Only its
%% opaque scope is retained by the session state; credentials and raw headers
%% never cross into the server process.
-spec handle_http(pid(), undefined | binary(), undefined | binary(),
                  map(), legacy | map(), timeout()) -> term().
handle_http(Server, Session, Version, Message, AuthContext, Timeout) ->
    gen_server:call(Server,
                    {http, Session, Version, Message, AuthContext}, Timeout).

-spec delete_session(pid(), undefined | binary(), undefined | binary()) ->
    ok | {error, term()}.
delete_session(Server, Session, Version) ->
    delete_session(Server, Session, Version, legacy).

-spec delete_session(pid(), undefined | binary(), undefined | binary(),
                     legacy | map()) -> ok | {error, term()}.
delete_session(Server, Session, Version, AuthContext) ->
    gen_server:call(Server,
                    {delete_session, Session, Version, AuthContext}).

init({normalized, Config, Registries}) ->
    process_flag(trap_exit, true),
    init_listener(Config, Registries);
init(Config0) ->
    process_flag(trap_exit, true),
    case normalize_config(Config0) of
        {ok, Config, Registries} -> init_listener(Config, Registries);
        {error, Reason} -> {stop, Reason}
    end.

init_listener(Config, Registries) ->
    Listener = {?MODULE, make_ref()},
    RouteState = route_config(Config, self()),
    Dispatch = cowboy_router:compile([{'_', routes(Config, RouteState)}]),
    Transport = #{socket_opts => [{ip, maps:get(ip, Config)},
                                   {port, maps:get(port, Config)}] ++
                                  tls_socket_options(Config),
                  num_acceptors => maps:get(num_acceptors, Config),
                  max_connections => maps:get(max_connections, Config)},
    Protocol = #{env => #{dispatch => Dispatch},
                 idle_timeout => maps:get(idle_timeout, Config),
                 request_timeout => maps:get(http_request_timeout, Config),
                 max_keepalive => maps:get(max_keepalive, Config)},
    case start_cowboy(Listener, Config, Transport, Protocol) of
        {ok, ListenerPid} ->
            Monitor = erlang:monitor(process, ListenerPid),
            Port = apply(ranch, get_port, [Listener]),
            Cleanup = schedule_cleanup(Config),
            {ok, Registries#{config => Config,
                             listener => Listener,
                             listener_pid => ListenerPid,
                             listener_monitor => Monitor,
                             port => Port,
                             sessions => #{},
                             pending => #{},
                             active => 0,
                             cleanup_timer => Cleanup}};
        {error, Reason} ->
            {stop, {mcp_listener_start_failed, Reason}}
    end.

handle_call(endpoint, _From, State) ->
    Config = maps:get(config, State),
    Host = endpoint_host(maps:get(ip, Config)),
    Port = maps:get(port, State),
    Path = maps:get(path, Config),
    Scheme = endpoint_scheme(Config),
    Url = <<Scheme/binary, "://", Host/binary, ":",
            (integer_to_binary(Port))/binary, Path/binary>>,
    {reply, {ok, #{url => Url, scheme => Scheme, host => Host,
                   port => Port, path => Path}},
     State};
handle_call({register, Kind, Value}, _From, State) ->
    case normalize_registry_item(Kind, Value) of
        {ok, Key, Item} ->
            Field = registry_field(Kind),
            Registry = maps:get(Field, State),
            {reply, ok, State#{Field => Registry#{Key => Item}}};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({delete_session, undefined, _Version, _Auth}, _From, State) ->
    {reply, {error, missing_session}, State};
handle_call({delete_session, Session, Version, AuthContext}, _From, State) ->
    Sessions = maps:get(sessions, State),
    case {AuthContext, auth_scope(AuthContext), maps:find(Session, Sessions)} of
        {legacy, _Scope, {ok, #{version := Version}}} ->
            {reply, ok, State#{sessions => maps:remove(Session, Sessions)}};
        {legacy, _Scope, {ok, _}} ->
            {reply, {error, invalid_protocol_version}, State};
        {legacy, _Scope, error} ->
            {reply, {error, unknown_session}, State};
        {_, {ok, Scope}, {ok, #{version := Version, auth_scope := Scope}}} ->
            {reply, ok, State#{sessions => maps:remove(Session, Sessions)}};
        {_, {ok, Scope}, {ok, #{auth_scope := Scope}}} ->
            {reply, {error, invalid_protocol_version}, State};
        {_, {ok, _OtherScope}, {ok, _}} ->
            %% Do not disclose whether another principal owns the session.
            {reply, {error, unknown_session}, State};
        {_, {ok, _}, error} -> {reply, {error, unknown_session}, State};
        {_, error, _} -> {reply, {error, unknown_session}, State}
    end;
handle_call({http, Session, Version, Message}, From, State0) ->
    handle_call({http, Session, Version, Message, legacy}, From, State0);
handle_call({http, Session, Version, Message, AuthContext}, From, State0) ->
    State = expire_sessions(State0),
    case auth_scope(AuthContext) of
        {ok, Scope} ->
            case classify_message(Message) of
                {initialize, Id, Params} ->
                    handle_initialize(Session, Id, Params, Scope, State);
                {notification, <<"notifications/initialized">>, _Params} ->
                    handle_initialized(Session, Version, Scope, State);
                {notification, _Method, _Params} ->
                    handle_notification(Session, Version, Scope, State);
                {request, Id, Method, Params} ->
                    handle_operation(Session, Version, Scope, Id, Method,
                                     Params, From, State);
                invalid ->
                    Error = error_response(null, -32600,
                                           <<"Invalid Request">>),
                    {reply, {json, 400, [], Error}, State}
            end;
        error ->
            {reply, {http_error, 401, []}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({mcp_worker_result, Ref, CompletedAt, Response0}, State) ->
    case maps:take(Ref, maps:get(pending, State)) of
        {Pending, Rest} ->
            case CompletedAt =< maps:get(deadline, Pending) of
                true -> complete_operation(Pending, Rest, Response0, State);
                false -> timeout_operation(Pending, Rest, State)
            end;
        error -> {noreply, State}
    end;
handle_info({mcp_worker_timeout, Ref}, State) ->
    case maps:take(Ref, maps:get(pending, State)) of
        {Pending, Rest} -> timeout_operation(Pending, Rest, State);
        error -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _Pid, Reason}, State) ->
    case pending_by_monitor(Monitor, maps:get(pending, State)) of
        {ok, Ref, Pending} ->
            erlang:cancel_timer(maps:get(timer, Pending)),
            _ = erlang:unalias(maps:get(reply_alias, Pending)),
            Rest = maps:remove(Ref, maps:get(pending, State)),
            Response0 = error_response(maps:get(id, Pending), -32603,
                                       safe_worker_error(Reason)),
            Response = enforce_response_bound(Response0, State),
            gen_server:reply(maps:get(from, Pending),
                             {json, 200, [], Response}),
            {noreply, State#{pending => Rest,
                             active => maps:get(active, State) - 1}};
        error ->
            case Monitor =:= maps:get(listener_monitor, State) of
                true -> {stop, {mcp_listener_terminated, Reason}, State};
                false -> {noreply, State}
            end
    end;
handle_info(cleanup_sessions, State0) ->
    State = expire_sessions(State0),
    Config = maps:get(config, State),
    {noreply, State#{cleanup_timer => schedule_cleanup(Config)}};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    case maps:find(cleanup_timer, State) of
        {ok, Timer} -> erlang:cancel_timer(Timer);
        error -> ok
    end,
    case maps:find(listener_monitor, State) of
        {ok, Monitor} -> erlang:demonitor(Monitor, [flush]);
        error -> ok
    end,
    case maps:find(listener, State) of
        {ok, Listener} -> _ = catch cowboy:stop_listener(Listener);
        error -> ok
    end,
    maps:foreach(
      fun(_Ref, Pending) ->
          _ = erlang:unalias(maps:get(reply_alias, Pending)),
          erlang:cancel_timer(maps:get(timer, Pending)),
          exit(maps:get(pid, Pending), kill),
          _ = erlang:demonitor(maps:get(monitor, Pending), [flush]),
          ok
      end, maps:get(pending, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              Config0 = maps:get(config, State, #{}),
              Auth = case maps:get(auth, Config0, none) of
                  {hook, _} -> hook_configured;
                  {bearer_sha256, _Digest} -> bearer_digest_configured;
                  none -> none
              end,
              Authorization = case maps:get(authorization, Config0, none) of
                  {hook, _} -> hook_configured;
                  none -> none
              end,
              Config = Config0#{auth => Auth,
                                authorization => Authorization},
              Sessions = maps:get(sessions, State, #{}),
              SafeState = State#{config => Config,
                                 sessions =>
                                     #{active_count => map_size(Sessions)}},
              maps:without([pending], SafeState);
         (message, Message) -> adk_secret_redactor:redact(Message);
         (log, _Log) -> [];
         (reason, Reason) -> adk_secret_redactor:redact(Reason);
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

handle_initialize(Session, Id, Params, AuthScope, State) ->
    Requested = maps:get(<<"protocolVersion">>, Params, undefined),
    ClientInfo = maps:get(<<"clientInfo">>, Params, invalid),
    Capabilities = maps:get(<<"capabilities">>, Params, invalid),
    Sessions = maps:get(sessions, State),
    Config = maps:get(config, State),
    MaxSessions = maps:get(max_sessions, Config),
    case Session of
        Value when Value =/= undefined ->
            {reply, {http_error, 400, []}, State};
        _ when not is_binary(Requested) ->
            Error = error_response(
                      Id, -32602, <<"Unsupported protocol version">>,
                      #{<<"supported">> => ?SUPPORTED_PROTOCOL_VERSIONS,
                        <<"requested">> => safe_json(Requested)}),
            {reply, {json, 200, [], Error}, State};
        _ when not is_map(ClientInfo); not is_map(Capabilities) ->
            Error = error_response(Id, -32602,
                                   <<"Invalid initialize parameters">>),
            {reply, {json, 200, [], Error}, State};
        _ when map_size(Sessions) >= MaxSessions ->
            Error = error_response(Id, -32000,
                                   <<"Session capacity reached">>),
            {reply, {json, 200, [], Error}, State};
        _ ->
            %% MCP lifecycle negotiation requires the server to select a
            %% supported version when the client's proposal is unsupported.
            Negotiated = case lists:member(
                                Requested, ?SUPPORTED_PROTOCOL_VERSIONS) of
                true -> Requested;
                false -> ?LATEST_PROTOCOL_VERSION
            end,
            create_session(Id, Negotiated, AuthScope, Sessions, State)
    end.

create_session(Id, Requested, AuthScope, Sessions, State) ->
            SessionId = new_session_id(),
            Now = erlang:monotonic_time(millisecond),
            SessionState = #{phase => initializing,
                             version => Requested,
                             auth_scope => AuthScope,
                             seen_ids => #{Id => true},
                             request_count => 1,
                             last_seen => Now},
            Result = initialize_result(State, Requested),
            Response = result_response(Id, Result),
            Headers = [{<<"mcp-session-id">>, SessionId}],
            {reply, {json, 200, Headers, Response},
             State#{sessions => Sessions#{SessionId => SessionState}}}.

handle_initialized(Session, Version, AuthScope, State) ->
    case session_check(Session, Version, AuthScope, initializing, State) of
        {ok, SessionState} ->
            Sessions = maps:get(sessions, State),
            Updated = touch_session(SessionState#{phase => ready}),
            {reply, {accepted, []},
             State#{sessions => Sessions#{Session => Updated}}};
        {error, Status} -> {reply, {http_error, Status, []}, State}
    end.

handle_notification(Session, Version, AuthScope, State) ->
    case session_check(Session, Version, AuthScope, ready, State) of
        {ok, SessionState} ->
            Sessions = maps:get(sessions, State),
            {reply, {accepted, []},
             State#{sessions => Sessions#{Session =>
                                              touch_session(SessionState)}}};
        {error, Status} -> {reply, {http_error, Status, []}, State}
    end.

handle_operation(Session, Version, AuthScope, Id, Method, Params, From,
                 State) ->
    case session_check(Session, Version, AuthScope, ready, State) of
        {error, Status} -> {reply, {http_error, Status, []}, State};
        {ok, SessionState} ->
            Config = maps:get(config, State),
            Count = maps:get(request_count, SessionState),
            Seen = maps:get(seen_ids, SessionState),
            Active = maps:get(active, State),
            MaxConcurrency = maps:get(max_concurrency, Config),
            case maps:is_key(Id, Seen) orelse
                 Count >= maps:get(max_session_requests, Config) of
                true ->
                    Error = error_response(Id, -32600,
                                           <<"Duplicate or exhausted request id">>),
                    {reply, {json, 200, [], Error}, State};
                false when Active >= MaxConcurrency ->
                    Error = error_response(Id, -32000,
                                           <<"Server busy">>),
                    {reply, {json, 200, [], Error}, State};
                false ->
                    Updated = touch_session(
                                SessionState#{seen_ids => Seen#{Id => true},
                                              request_count => Count + 1}),
                    Sessions = maps:get(sessions, State),
                    State1 = State#{sessions => Sessions#{Session => Updated}},
                    start_operation(Id, Method, Params, From, State1)
            end
    end.

start_operation(Id, Method, Params, From, State) ->
    Ref = make_ref(),
    Owner = self(),
    ReplyAlias = erlang:alias([explicit_unalias]),
    Config = maps:get(config, State),
    MaxResponseBytes = maps:get(max_response_bytes, Config),
    Timeout = maps:get(request_timeout, Config),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Work = fun() ->
        start_operation_owner_watchdog(Owner, self()),
        Outcome = execute_method(Method, Params, State),
        Response = bounded_operation_response(Id, Outcome, MaxResponseBytes),
        CompletedAt = erlang:monotonic_time(millisecond),
        _ = erlang:send(ReplyAlias,
                        {mcp_worker_result, Ref, CompletedAt, Response},
                        [noconnect, nosuspend]),
        ok
    end,
    MaxHeap = maps:get(callback_max_heap_words, Config),
    SpawnOptions =
        [monitor, {message_queue_data, off_heap},
         {max_heap_size,
          #{size => MaxHeap, kill => true, error_logger => false,
            include_shared_binaries => true}}],
    try erlang:spawn_opt(Work, SpawnOptions) of
        {Pid, Monitor} ->
            Timer = erlang:send_after(
                      remaining_time(Deadline), self(),
                      {mcp_worker_timeout, Ref}),
            Pending0 = maps:get(pending, State),
            Pending = #{from => From, id => Id, pid => Pid,
                        monitor => Monitor, timer => Timer,
                        reply_alias => ReplyAlias, deadline => Deadline},
            {noreply, State#{pending => Pending0#{Ref => Pending},
                             active => maps:get(active, State) + 1}}
    catch
        _:_ ->
            _ = erlang:unalias(ReplyAlias),
            Response = error_response(null, -32603,
                                      <<"Callback worker unavailable">>),
            {reply, {json, 200, [], Response}, State}
    end.

complete_operation(Pending, Rest, Response0, State) ->
    erlang:cancel_timer(maps:get(timer, Pending)),
    _ = erlang:unalias(maps:get(reply_alias, Pending)),
    erlang:demonitor(maps:get(monitor, Pending), [flush]),
    Response = enforce_response_bound(Response0, State),
    gen_server:reply(maps:get(from, Pending), {json, 200, [], Response}),
    {noreply, State#{pending => Rest,
                     active => maps:get(active, State) - 1}}.

timeout_operation(Pending, Rest, State) ->
    erlang:cancel_timer(maps:get(timer, Pending)),
    _ = erlang:unalias(maps:get(reply_alias, Pending)),
    exit(maps:get(pid, Pending), kill),
    erlang:demonitor(maps:get(monitor, Pending), [flush]),
    Response0 = error_response(maps:get(id, Pending), -32603,
                               <<"Request timed out">>),
    Response = enforce_response_bound(Response0, State),
    gen_server:reply(maps:get(from, Pending), {json, 200, [], Response}),
    {noreply, State#{pending => Rest,
                     active => maps:get(active, State) - 1}}.

remaining_time(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

start_operation_owner_watchdog(Owner, Worker) ->
    Watchdog = fun() -> operation_owner_watchdog(Owner, Worker) end,
    _ = spawn_opt(
          Watchdog,
          [{message_queue_data, off_heap},
           {max_heap_size,
            #{size => 8192, kill => true, error_logger => false,
              include_shared_binaries => true}}]),
    ok.

operation_owner_watchdog(Owner, Worker) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    WorkerMonitor = erlang:monitor(process, Worker),
    receive
        {'DOWN', OwnerMonitor, process, Owner, _OpaqueReason} ->
            exit(Worker, kill),
            _ = erlang:demonitor(WorkerMonitor, [flush]),
            ok;
        {'DOWN', WorkerMonitor, process, Worker, _OpaqueReason} ->
            _ = erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

execute_method(<<"tools/list">>, _Params, State) ->
    Tools = [maps:get(public, Item)
             || {_Name, Item} <- lists:sort(maps:to_list(maps:get(tools,
                                                                 State)))],
    {ok, #{<<"tools">> => Tools}};
execute_method(<<"tools/call">>, Params, State) ->
    execute_tool(Params, State);
execute_method(<<"resources/list">>, _Params, State) ->
    Resources = [maps:get(public, Item)
                 || {_Uri, Item} <- lists:sort(
                                      maps:to_list(maps:get(resources,
                                                            State)))],
    {ok, #{<<"resources">> => Resources}};
execute_method(<<"resources/read">>, Params, State) ->
    execute_resource(Params, State);
execute_method(<<"prompts/list">>, _Params, State) ->
    Prompts = [maps:get(public, Item)
               || {_Name, Item} <- lists:sort(
                                    maps:to_list(maps:get(prompts, State)))],
    {ok, #{<<"prompts">> => Prompts}};
execute_method(<<"prompts/get">>, Params, State) ->
    execute_prompt(Params, State);
execute_method(_Method, _Params, _State) ->
    {protocol_error, -32601, <<"Method not found">>}.

execute_tool(Params, State) ->
    Name = maps:get(<<"name">>, Params, undefined),
    Args = maps:get(<<"arguments">>, Params, #{}),
    case {maps:find(Name, maps:get(tools, State)), is_map(Args)} of
        {{ok, Tool}, true} ->
            Raw = invoke_executor(maps:get(executor, Tool), Args,
                                  #{mcp => #{transport => streamable_http}}),
            normalize_tool_result(Raw);
        {error, _} -> {protocol_error, -32602, <<"Unknown tool">>};
        {_, false} -> {protocol_error, -32602, <<"Invalid tool arguments">>}
    end.

execute_resource(Params, State) ->
    Uri = maps:get(<<"uri">>, Params, undefined),
    case maps:find(Uri, maps:get(resources, State)) of
        {ok, Resource} ->
            Raw = invoke_reader(maps:get(reader, Resource), Uri),
            normalize_resource_result(Raw, Resource);
        error -> {protocol_error, -32002, <<"Resource not found">>}
    end.

execute_prompt(Params, State) ->
    Name = maps:get(<<"name">>, Params, undefined),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    case {maps:find(Name, maps:get(prompts, State)), is_map(Arguments)} of
        {{ok, Prompt}, true} ->
            Raw = invoke_prompt(maps:get(getter, Prompt), Arguments),
            normalize_prompt_result(Raw);
        {error, _} -> {protocol_error, -32602, <<"Unknown prompt">>};
        {_, false} -> {protocol_error, -32602, <<"Invalid prompt arguments">>}
    end.

invoke_executor({module, Module}, Args, Context) ->
    try Module:execute(Args, Context) of Value -> Value
    catch _:_ -> {error, tool_execution_failed}
    end;
invoke_executor({fun2, Fun}, Args, Context) ->
    try Fun(Args, Context) of Value -> Value
    catch _:_ -> {error, tool_execution_failed}
    end.

invoke_reader({fun0, Fun}, _Uri) ->
    try Fun() of Value -> Value catch _:_ -> {error, resource_read_failed} end;
invoke_reader({fun1, Fun}, Uri) ->
    try Fun(Uri) of Value -> Value catch _:_ -> {error, resource_read_failed} end.

invoke_prompt({fun1, Fun}, Args) ->
    try Fun(Args) of Value -> Value catch _:_ -> {error, prompt_get_failed} end.

normalize_tool_result({ok, #{<<"content">> := _} = Result}) ->
    normalize_success(Result);
normalize_tool_result({ok, Value}) when is_map(Value) ->
    case adk_json:normalize(Value) of
        {ok, Json} ->
            Text = jsx:encode(Json),
            {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                        <<"text">> => Text}],
                   <<"structuredContent">> => Json,
                   <<"isError">> => false}};
        {error, _} -> normalize_tool_error(invalid_tool_result)
    end;
normalize_tool_result({ok, Value}) ->
    case adk_json:normalize(Value) of
        {ok, Json} ->
            Text = case Json of
                Binary when is_binary(Binary) -> Binary;
                _ -> jsx:encode(Json)
            end,
            {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                        <<"text">> => Text}],
                   <<"isError">> => false}};
        {error, _} -> normalize_tool_error(invalid_tool_result)
    end;
normalize_tool_result({error, Reason}) -> normalize_tool_error(Reason);
normalize_tool_result(Other) -> normalize_tool_error({invalid_return, Other}).

normalize_success(Result) ->
    case adk_json:normalize(Result) of
        {ok, Json} -> {ok, Json};
        {error, _} -> normalize_tool_error(invalid_tool_result)
    end.

normalize_tool_error(Reason) ->
    Safe = safe_error_text(Reason),
    {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                <<"text">> => Safe}],
           <<"isError">> => true}}.

normalize_resource_result({ok, #{<<"contents">> := _} = Result}, _Resource) ->
    normalize_success(Result);
normalize_resource_result({ok, Text}, Resource) when is_binary(Text) ->
    Public = maps:get(public, Resource),
    Content0 = #{<<"uri">> => maps:get(<<"uri">>, Public),
                 <<"text">> => Text},
    Content = case maps:find(<<"mimeType">>, Public) of
        {ok, Mime} -> Content0#{<<"mimeType">> => Mime};
        error -> Content0
    end,
    {ok, #{<<"contents">> => [Content]}};
normalize_resource_result({error, _Reason}, _Resource) ->
    {protocol_error, -32603, <<"Resource read failed">>};
normalize_resource_result(_, _Resource) ->
    {protocol_error, -32603, <<"Invalid resource result">>}.

normalize_prompt_result({ok, #{<<"messages">> := _} = Result}) ->
    normalize_success(Result);
normalize_prompt_result({ok, Messages}) when is_list(Messages) ->
    normalize_success(#{<<"messages">> => Messages});
normalize_prompt_result({error, _Reason}) ->
    {protocol_error, -32603, <<"Prompt rendering failed">>};
normalize_prompt_result(_) ->
    {protocol_error, -32603, <<"Invalid prompt result">>}.

outcome_response(Id, {ok, Result}) -> result_response(Id, Result);
outcome_response(Id, {protocol_error, Code, Message}) ->
    error_response(Id, Code, Message).

%% Normalize and encode inside the short-lived callback worker.  Only a
%% protocol response whose encoded representation fits the configured limit is
%% copied into the long-lived server process.
bounded_operation_response(Id, Outcome, MaxBytes) ->
    Response = outcome_response(Id, Outcome),
    try jsx:encode(Response) of
        Encoded when byte_size(Encoded) =< MaxBytes -> Response;
        _ -> error_response(null, -32603, <<"Response exceeds limit">>)
    catch
        _:_ -> error_response(null, -32603, <<"Internal error">>)
    end.

enforce_response_bound(Response, State) ->
    Max = maps:get(max_response_bytes, maps:get(config, State)),
    case byte_size(jsx:encode(Response)) =< Max of
        true -> Response;
        false -> error_response(null, -32603, <<"Response exceeds limit">>)
    end.

classify_message(#{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
                   <<"method">> := <<"initialize">>,
                   <<"params">> := Params})
  when (is_integer(Id) orelse is_binary(Id)), is_map(Params) ->
    {initialize, Id, Params};
classify_message(#{<<"jsonrpc">> := <<"2.0">>, <<"id">> := Id,
                   <<"method">> := Method} = Message)
  when (is_integer(Id) orelse is_binary(Id)), is_binary(Method) ->
    Params = maps:get(<<"params">>, Message, #{}),
    case is_map(Params) of
        true -> {request, Id, Method, Params};
        false -> invalid
    end;
classify_message(#{<<"jsonrpc">> := <<"2.0">>,
                   <<"method">> := Method} = Message)
  when is_binary(Method) ->
    Params = maps:get(<<"params">>, Message, #{}),
    case is_map(Params) of
        true -> {notification, Method, Params};
        false -> invalid
    end;
classify_message(_) -> invalid.

session_check(undefined, _Version, _Scope, _Phase, _State) -> {error, 400};
session_check(Session, Version, Scope, Phase, State) ->
    case maps:find(Session, maps:get(sessions, State)) of
        {ok, #{phase := Phase, version := Version,
               auth_scope := Scope} = SessionState} ->
            {ok, SessionState};
        {ok, #{auth_scope := OtherScope}} when OtherScope =/= Scope ->
            %% A stolen session id is intentionally indistinguishable from an
            %% expired or otherwise unknown session id.
            {error, 404};
        {ok, _WrongPhase} -> {error, 400};
        error -> {error, 404}
    end.

auth_scope(legacy) -> {ok, legacy};
auth_scope(#{scope := Scope}) when is_binary(Scope), byte_size(Scope) =:= 32 ->
    {ok, Scope};
auth_scope(_) -> error.

initialize_result(State, Version) ->
    Cap0 = #{},
    Cap1 = case map_size(maps:get(tools, State)) of
        0 -> Cap0;
        _ -> Cap0#{<<"tools">> => #{<<"listChanged">> => false}}
    end,
    Cap2 = case map_size(maps:get(resources, State)) of
        0 -> Cap1;
        _ -> Cap1#{<<"resources">> => #{<<"subscribe">> => false,
                                           <<"listChanged">> => false}}
    end,
    Cap3 = case map_size(maps:get(prompts, State)) of
        0 -> Cap2;
        _ -> Cap2#{<<"prompts">> => #{<<"listChanged">> => false}}
    end,
    #{<<"protocolVersion">> => Version,
      <<"capabilities">> => Cap3,
      <<"serverInfo">> => #{<<"name">> => <<"erlang_adk">>,
                             <<"version">> => application_version()}}.

application_version() ->
    _ = application:load(erlang_adk),
    case application:get_key(erlang_adk, vsn) of
        {ok, Version} when is_list(Version) ->
            unicode:characters_to_binary(Version);
        {ok, Version} when is_binary(Version) -> Version;
        _ -> <<"unknown">>
    end.

normalize_config(Config0) when is_map(Config0) ->
    Config1 = #{ip => maps:get(ip, Config0, {127, 0, 0, 1}),
                port => maps:get(port, Config0, 0),
                path => maps:get(path, Config0, <<"/mcp">>),
                max_body_bytes => maps:get(max_body_bytes, Config0,
                                            ?DEFAULT_MAX_BODY_BYTES),
                max_response_bytes => maps:get(max_response_bytes, Config0,
                                                ?DEFAULT_MAX_RESPONSE_BYTES),
                request_timeout => maps:get(request_timeout, Config0,
                                            ?DEFAULT_REQUEST_TIMEOUT),
                max_concurrency => maps:get(max_concurrency, Config0,
                                            ?DEFAULT_MAX_CONCURRENCY),
                max_sessions => maps:get(max_sessions, Config0,
                                          ?DEFAULT_MAX_SESSIONS),
                max_session_requests => maps:get(max_session_requests, Config0,
                                                  ?DEFAULT_MAX_SESSION_REQUESTS),
                session_ttl_ms => maps:get(session_ttl_ms, Config0,
                                           ?DEFAULT_SESSION_TTL_MS),
                num_acceptors => maps:get(num_acceptors, Config0, 10),
                max_connections => maps:get(max_connections, Config0, 1024),
                idle_timeout => maps:get(idle_timeout, Config0, 60000),
                http_request_timeout => maps:get(http_request_timeout, Config0,
                                                 10000),
                callback_timeout => maps:get(callback_timeout, Config0,
                                             ?DEFAULT_CALLBACK_TIMEOUT),
                callback_max_heap_words =>
                    maps:get(callback_max_heap_words, Config0,
                             ?DEFAULT_CALLBACK_MAX_HEAP_WORDS),
                max_keepalive => maps:get(max_keepalive, Config0, 100),
                allow_non_loopback => maps:get(allow_non_loopback,
                                               Config0, false),
                trusted_tls_proxy => maps:get(trusted_tls_proxy,
                                              Config0, false),
                tls_options => maps:get(tls_options, Config0, undefined),
                allowed_origins => normalize_origins(
                                     maps:get(allowed_origins, Config0, [])),
                authorization => normalize_authorization(
                                   maps:get(authorization_fun, Config0,
                                            none)),
                oauth_protected_resource =>
                    normalize_oauth_protected_resource(
                      maps:get(oauth_protected_resource, Config0, none))},
    case normalize_auth(Config0) of
        {ok, Auth} ->
            Config = Config1#{auth => Auth},
            case valid_config(Config) of
                true -> normalize_registries(Config0, Config);
                false -> {error, invalid_mcp_server_config}
            end;
        {error, _} = Error -> Error
    end;
normalize_config(_) -> {error, invalid_mcp_server_config}.

normalize_auth(Config) ->
    case {maps:find(auth_token, Config), maps:find(auth_fun, Config)} of
        {{ok, Token}, error} when is_binary(Token), byte_size(Token) >= 16 ->
            {ok, {bearer_sha256, crypto:hash(sha256, Token)}};
        {error, {ok, Fun}} when is_function(Fun, 1) -> {ok, {hook, Fun}};
        {error, error} -> {ok, none};
        _ -> {error, invalid_mcp_server_auth}
    end.

normalize_authorization(none) -> none;
normalize_authorization(Fun) when is_function(Fun, 3) -> {hook, Fun};
normalize_authorization(_) -> invalid.

normalize_origins(Origins) when is_list(Origins) ->
    [lower(Value) || Value <- Origins, is_binary(Value)];
normalize_origins(_) -> invalid.

normalize_oauth_protected_resource(none) -> none;
normalize_oauth_protected_resource(Metadata) when is_map(Metadata) ->
    Resource = maps:get(resource, Metadata, undefined),
    AuthorizationServers = maps:get(authorization_servers, Metadata, invalid),
    Scopes = maps:get(scopes_supported, Metadata, []),
    RequiredScopes = maps:get(required_scopes, Metadata, []),
    MetadataPath = case maps:get(metadata_path, Metadata, undefined) of
        undefined -> default_metadata_path(Resource);
        ConfiguredPath -> ConfiguredPath
    end,
    MetadataUrl0 = maps:get(resource_metadata_url, Metadata, undefined),
    MetadataUrl = case MetadataUrl0 of
        undefined -> derive_metadata_url(Resource, MetadataPath);
        _ -> MetadataUrl0
    end,
    case valid_absolute_http_uri(Resource) andalso
         valid_uri_list(AuthorizationServers) andalso
         valid_scope_list(Scopes) andalso
         valid_scope_list(RequiredScopes) andalso
         lists:all(fun(Scope) -> lists:member(Scope, Scopes) end,
                   RequiredScopes) andalso
         valid_path(MetadataPath) andalso
         valid_absolute_http_uri(MetadataUrl) of
        true ->
            Document = #{<<"resource">> => Resource,
                         <<"authorization_servers">> =>
                             AuthorizationServers,
                         <<"scopes_supported">> => Scopes},
            #{resource => Resource,
              authorization_servers => AuthorizationServers,
              scopes_supported => Scopes,
              required_scopes => RequiredScopes,
              metadata_path => MetadataPath,
              resource_metadata_url => MetadataUrl,
              document => Document};
        false -> invalid
    end;
normalize_oauth_protected_resource(_) -> invalid.

default_metadata_path(Resource) when is_binary(Resource) ->
    try uri_string:parse(Resource) of
        Parsed when is_map(Parsed) ->
            Base = <<"/.well-known/oauth-protected-resource">>,
            case maps:get(path, Parsed, <<>>) of
                <<>> -> Base;
                <<"/">> -> Base;
                <<"/", Rest/binary>> -> <<Base/binary, "/", Rest/binary>>;
                _ -> invalid
            end;
        _ -> invalid
    catch _:_ -> invalid
    end;
default_metadata_path(_) -> invalid.

derive_metadata_url(Resource, MetadataPath)
  when is_binary(Resource), is_binary(MetadataPath) ->
    try uri_string:parse(Resource) of
        Parsed when is_map(Parsed) ->
            Base = maps:without([path, query, fragment, userinfo], Parsed),
            unicode:characters_to_binary(
              uri_string:recompose(Base#{path => MetadataPath}));
        _ -> invalid
    catch _:_ -> invalid
    end;
derive_metadata_url(_, _) -> invalid.

valid_uri_list(Values) when is_list(Values), Values =/= [] ->
    lists:all(fun valid_absolute_http_uri/1, Values);
valid_uri_list(_) -> false.

valid_absolute_http_uri(Value) when is_binary(Value), byte_size(Value) > 0 ->
    try uri_string:parse(Value) of
        #{scheme := Scheme, host := Host} = Parsed ->
            (Scheme =:= <<"https">> orelse
             (Scheme =:= <<"http">> andalso loopback_host(Host))) andalso
            is_binary(Host) andalso byte_size(Host) > 0 andalso
            not maps:is_key(userinfo, Parsed) andalso
            not maps:is_key(fragment, Parsed) andalso
            valid_header_quoted_value(Value);
        _ -> false
    catch _:_ -> false
    end;
valid_absolute_http_uri(_) -> false.

loopback_host(<<"localhost">>) -> true;
loopback_host(<<"127.0.0.1">>) -> true;
loopback_host(<<"::1">>) -> true;
loopback_host(_) -> false.

valid_scope_list(Scopes) when is_list(Scopes) ->
    length(Scopes) =:= length(lists:usort(Scopes)) andalso
    lists:all(fun valid_scope/1, Scopes);
valid_scope_list(_) -> false.

valid_scope(Scope) when is_binary(Scope), byte_size(Scope) > 0,
                        byte_size(Scope) =< 256 ->
    lists:all(fun(C) ->
                      C =:= 16#21 orelse
                      (C >= 16#23 andalso C =< 16#5b) orelse
                      (C >= 16#5d andalso C =< 16#7e)
              end, binary_to_list(Scope));
valid_scope(_) -> false.

valid_header_quoted_value(Value) ->
    lists:all(fun(C) -> C >= 16#20 andalso C =< 16#7e andalso
                          C =/= $" andalso C =/= $\\
              end, binary_to_list(Value)).

valid_config(Config) ->
    valid_ip(maps:get(ip, Config)) andalso
    is_boolean(maps:get(allow_non_loopback, Config)) andalso
    is_boolean(maps:get(trusted_tls_proxy, Config)) andalso
    valid_tls_options(maps:get(tls_options, Config)) andalso
    secure_bind(maps:get(ip, Config), maps:get(auth, Config),
                maps:get(allow_non_loopback, Config),
                maps:get(tls_options, Config),
                maps:get(trusted_tls_proxy, Config)) andalso
    is_integer(maps:get(port, Config)) andalso maps:get(port, Config) >= 0 andalso
    maps:get(port, Config) =< 65535 andalso
    valid_path(maps:get(path, Config)) andalso
    valid_oauth_protected_resource(
      maps:get(oauth_protected_resource, Config), maps:get(path, Config)) andalso
    oauth_auth_compatible(maps:get(oauth_protected_resource, Config),
                          maps:get(auth, Config),
                          maps:get(authorization, Config)) andalso
    maps:get(authorization, Config) =/= invalid andalso
    maps:get(allowed_origins, Config) =/= invalid andalso
    maps:get(max_response_bytes, Config) >= ?MIN_RESPONSE_BYTES andalso
    lists:all(fun positive/1,
              [maps:get(max_body_bytes, Config),
               maps:get(max_response_bytes, Config),
               maps:get(request_timeout, Config),
               maps:get(max_concurrency, Config),
               maps:get(max_sessions, Config),
               maps:get(max_session_requests, Config),
               maps:get(session_ttl_ms, Config),
               maps:get(num_acceptors, Config),
               maps:get(max_connections, Config),
               maps:get(idle_timeout, Config),
               maps:get(http_request_timeout, Config)]) andalso
    bounded_positive(maps:get(callback_timeout, Config),
                     ?MAX_CALLBACK_TIMEOUT) andalso
    bounded_range(maps:get(callback_max_heap_words, Config),
                  ?MIN_CALLBACK_MAX_HEAP_WORDS,
                  ?MAX_CALLBACK_MAX_HEAP_WORDS) andalso
    is_integer(maps:get(max_keepalive, Config)) andalso
    maps:get(max_keepalive, Config) >= 0.

valid_oauth_protected_resource(none, _McpPath) -> true;
valid_oauth_protected_resource(
  #{metadata_path := MetadataPath, document := Document}, McpPath) ->
    MetadataPath =/= McpPath andalso is_map(Document);
valid_oauth_protected_resource(_, _) -> false.

oauth_auth_compatible(none, _Auth, _Authorization) -> true;
oauth_auth_compatible(_Metadata, {hook, _Fun}, {hook, _Authorization}) -> true;
oauth_auth_compatible(_Metadata, _Auth, _Authorization) -> false.

normalize_registries(Config0, Config) ->
    case normalize_items(tool, maps:get(tools, Config0, []), #{}) of
        {ok, Tools} ->
            case normalize_items(resource, maps:get(resources, Config0, []), #{}) of
                {ok, Resources} ->
                    case normalize_items(prompt, maps:get(prompts, Config0, []), #{}) of
                        {ok, Prompts} ->
                            {ok, Config, #{tools => Tools,
                                           resources => Resources,
                                           prompts => Prompts}};
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

normalize_items(_Kind, [], Acc) -> {ok, Acc};
normalize_items(Kind, [Value | Rest], Acc) ->
    case normalize_registry_item(Kind, Value) of
        {ok, Key, Item} -> normalize_items(Kind, Rest, Acc#{Key => Item});
        Error -> Error
    end;
normalize_items(_Kind, _Invalid, _Acc) -> {error, invalid_mcp_registry}.

normalize_registry_item(tool, Module) when is_atom(Module) ->
    try Module:schema() of Schema -> normalize_tool(Module, Schema)
    catch _:_ -> {error, {invalid_mcp_tool, Module}}
    end;
normalize_registry_item(tool, #{execute := Fun} = Descriptor)
  when is_function(Fun, 2) ->
    Schema = maps:get(schema, Descriptor, maps:remove(execute, Descriptor)),
    normalize_tool({fun2, Fun}, Schema);
normalize_registry_item(resource, Descriptor) when is_map(Descriptor) ->
    normalize_resource(Descriptor);
normalize_registry_item(prompt, Descriptor) when is_map(Descriptor) ->
    normalize_prompt(Descriptor);
normalize_registry_item(Kind, _Value) ->
    {error, {invalid_mcp_registry_item, Kind}}.

normalize_tool(Module, Schema0) when is_atom(Module) ->
    normalize_tool({module, Module}, Schema0);
normalize_tool(Executor, Schema0) when is_map(Schema0) ->
    case adk_json:normalize(Schema0) of
        {ok, Schema} ->
            Name = maps:get(<<"name">>, Schema, undefined),
            Input = maps:get(<<"inputSchema">>, Schema,
                             maps:get(<<"parameters">>, Schema,
                                      #{<<"type">> => <<"object">>})),
            Public0 = maps:remove(<<"parameters">>, Schema),
            Public = Public0#{<<"inputSchema">> => Input},
            case is_binary(Name) andalso byte_size(Name) > 0 andalso
                 is_map(Input) of
                true -> {ok, Name, #{public => Public, executor => Executor}};
                false -> {error, invalid_mcp_tool_schema}
            end;
        {error, _} -> {error, invalid_mcp_tool_schema}
    end;
normalize_tool(_, _) -> {error, invalid_mcp_tool_schema}.

normalize_resource(Descriptor) ->
    Uri = get_any(uri, <<"uri">>, Descriptor),
    Name = get_any(name, <<"name">>, Descriptor),
    Read = maps:get(read, Descriptor, undefined),
    Reader = case Read of
        Fun when is_function(Fun, 0) -> {fun0, Fun};
        Fun when is_function(Fun, 1) -> {fun1, Fun};
        _ -> invalid
    end,
    case valid_resource_uri(Uri) andalso
         is_binary(Name) andalso byte_size(Name) > 0 andalso
         Reader =/= invalid of
        true ->
            Public0 = #{<<"uri">> => Uri, <<"name">> => Name},
            Public = copy_optional(Descriptor, Public0,
                                   [{title, <<"title">>},
                                    {description, <<"description">>},
                                    {mime_type, <<"mimeType">>},
                                    {size, <<"size">>}]),
            {ok, Uri, #{public => Public, reader => Reader}};
        false -> {error, invalid_mcp_resource}
    end.

normalize_prompt(Descriptor) ->
    Name = get_any(name, <<"name">>, Descriptor),
    Get = maps:get(get, Descriptor, undefined),
    case is_binary(Name) andalso byte_size(Name) > 0 andalso
         is_function(Get, 1) of
        true ->
            Public0 = #{<<"name">> => Name},
            Public = copy_optional(Descriptor, Public0,
                                   [{title, <<"title">>},
                                    {description, <<"description">>},
                                    {arguments, <<"arguments">>}]),
            case adk_json:normalize(Public) of
                {ok, SafePublic} ->
                    {ok, Name, #{public => SafePublic,
                                 getter => {fun1, Get}}};
                {error, _} -> {error, invalid_mcp_prompt}
            end;
        false -> {error, invalid_mcp_prompt}
    end.

get_any(Atom, Binary, Map) -> maps:get(Atom, Map, maps:get(Binary, Map, undefined)).

copy_optional(_Source, Target, []) -> Target;
copy_optional(Source, Target, [{Atom, Binary} | Rest]) ->
    Value = get_any(Atom, Binary, Source),
    Next = case Value of undefined -> Target; _ -> Target#{Binary => Value} end,
    copy_optional(Source, Next, Rest).

registry_field(tool) -> tools;
registry_field(resource) -> resources;
registry_field(prompt) -> prompts.

route_config(Config, Server) ->
    RouteConfig = maps:with(
                    [path, max_body_bytes, callback_timeout,
                     callback_max_heap_words, allowed_origins, auth,
                     authorization, oauth_protected_resource], Config),
    %% The operation worker is killed at the configured request_timeout.  Give
    %% that worker's small JSON-RPC timeout reply a bounded delivery margin so
    %% Cowboy does not race it and replace the protocol error with HTTP 504.
    RouteConfig#{server => Server,
                 request_timeout => maps:get(request_timeout, Config) +
                                    ?SERVER_REPLY_GRACE_MS}.

routes(Config, RouteState) ->
    Mcp = {maps:get(path, Config), adk_mcp_http_handler, RouteState},
    case maps:get(oauth_protected_resource, Config) of
        none -> [Mcp];
        #{metadata_path := Path, document := Document} ->
            [{Path, adk_mcp_oauth_metadata_handler, Document}, Mcp]
    end.

schedule_cleanup(Config) ->
    Interval = erlang:min(maps:get(session_ttl_ms, Config), 60000),
    erlang:send_after(Interval, self(), cleanup_sessions).

expire_sessions(State) ->
    Config = maps:get(config, State),
    Cutoff = erlang:monotonic_time(millisecond) -
             maps:get(session_ttl_ms, Config),
    Sessions = maps:filter(fun(_Id, Session) ->
                                   maps:get(last_seen, Session) >= Cutoff
                           end, maps:get(sessions, State)),
    State#{sessions => Sessions}.

touch_session(Session) ->
    Session#{last_seen => erlang:monotonic_time(millisecond)}.

pending_by_monitor(Monitor, Pending) ->
    case [{Ref, Value} || {Ref, Value} <- maps:to_list(Pending),
                          maps:get(monitor, Value) =:= Monitor] of
        [{Ref, Value}] -> {ok, Ref, Value};
        [] -> error
    end.

new_session_id() ->
    base64:encode(crypto:strong_rand_bytes(24),
                  #{mode => urlsafe, padding => false}).

result_response(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"result">> => Result}.

error_response(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code, <<"message">> => Message}}.

error_response(Id, Code, Message, Data) ->
    Base = error_response(Id, Code, Message),
    Error = maps:get(<<"error">>, Base),
    Base#{<<"error">> => Error#{<<"data">> => Data}}.

safe_json(Value) ->
    case adk_json:normalize(Value) of {ok, Json} -> Json; _ -> null end.

safe_error_text(Reason) ->
    Redacted = adk_secret_redactor:redact(Reason),
    case adk_json:normalize(Redacted) of
        {ok, Binary} when is_binary(Binary) -> Binary;
        {ok, Json} -> jsx:encode(Json);
        _ -> <<"Tool execution failed">>
    end.

safe_worker_error(normal) -> <<"Worker exited before replying">>;
safe_worker_error(_) -> <<"Worker failed">>.

endpoint_host({127, 0, 0, 1}) -> <<"127.0.0.1">>;
endpoint_host({A, B, C, D}) ->
    iolist_to_binary(inet:ntoa({A, B, C, D}));
endpoint_host({A, B, C, D, E, F, G, H}) ->
    Address = iolist_to_binary(inet:ntoa({A, B, C, D, E, F, G, H})),
    <<"[", Address/binary, "]">>;
endpoint_host(_) -> <<"localhost">>.

start_cowboy(Listener, #{tls_options := undefined}, Transport, Protocol) ->
    cowboy:start_clear(Listener, Transport, Protocol);
start_cowboy(Listener, _Config, Transport, Protocol) ->
    cowboy:start_tls(Listener, Transport, Protocol).

tls_socket_options(#{tls_options := undefined}) -> [];
tls_socket_options(#{tls_options := Options}) -> Options.

endpoint_scheme(#{tls_options := undefined}) -> <<"http">>;
endpoint_scheme(_Config) -> <<"https">>.

valid_tls_options(undefined) -> true;
valid_tls_options(Options) when is_list(Options), Options =/= [] ->
    lists:all(fun(Option) -> is_tuple(Option) andalso tuple_size(Option) =:= 2
              end, Options) andalso
    not lists:keymember(ip, 1, Options) andalso
    not lists:keymember(port, 1, Options) andalso
    has_tls_identity(Options);
valid_tls_options(_) -> false.

has_tls_identity(Options) ->
    (lists:keymember(certfile, 1, Options) andalso
     lists:keymember(keyfile, 1, Options)) orelse
    (lists:keymember(cert, 1, Options) andalso
     lists:keymember(key, 1, Options)).

valid_path(<<"/", _/binary>>) -> true;
valid_path(_) -> false.
valid_resource_uri(Uri) when is_binary(Uri), byte_size(Uri) > 0 ->
    try uri_string:parse(Uri) of
        Parsed when is_map(Parsed) ->
            Scheme = maps:get(scheme, Parsed, undefined),
            is_binary(Scheme) andalso byte_size(Scheme) > 0 andalso
            lists:all(fun(C) -> C >= 16#21 andalso C =/= 16#7f end,
                      binary_to_list(Uri));
        _ -> false
    catch _:_ -> false
    end;
valid_resource_uri(_) -> false.
positive(Value) -> is_integer(Value) andalso Value > 0.

bounded_positive(Value, Ceiling) ->
    positive(Value) andalso Value =< Ceiling.

bounded_range(Value, Floor, Ceiling) ->
    is_integer(Value) andalso Value >= Floor andalso Value =< Ceiling.

valid_ip({A, B, C, D}) ->
    lists:all(fun(V) -> is_integer(V) andalso V >= 0 andalso V =< 255 end,
              [A, B, C, D]);
valid_ip({A, B, C, D, E, F, G, H}) ->
    lists:all(fun(V) -> is_integer(V) andalso V >= 0 andalso V =< 16#ffff end,
              [A, B, C, D, E, F, G, H]);
valid_ip(_) -> false.
secure_bind({127, _B, _C, _D}, _Auth, _Allow, _Tls, _Proxy) -> true;
secure_bind({0, 0, 0, 0, 0, 0, 0, 1}, _Auth, _Allow, _Tls, _Proxy) -> true;
secure_bind(_Ip, none, _Allow, _Tls, _Proxy) -> false;
secure_bind(_Ip, _Auth, false, _Tls, _Proxy) -> false;
secure_bind(_Ip, _Auth, true, undefined, false) -> false;
secure_bind(_Ip, _Auth, true, _Tls, _Proxy) -> true.
lower(Value) -> list_to_binary(string:lowercase(binary_to_list(Value))).
