%% @doc Bounded MCP 2025-11-25 Streamable HTTP server.
%%
%% The server deliberately implements JSON responses to POST and returns 405
%% for the optional GET/SSE channel. Tool/resource/prompt work runs in monitored
%% lightweight processes behind a global concurrency and deadline bound.
-module(adk_mcp_server).
-behaviour(gen_server).

-export([start/2, start_link/1, stop/1, endpoint/1,
         register_tool/2, register_resource/2, register_prompt/2,
         handle_http/5, delete_session/3]).
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
    gen_server:call(Server, {http, Session, Version, Message}, Timeout).

-spec delete_session(pid(), undefined | binary(), undefined | binary()) ->
    ok | {error, term()}.
delete_session(Server, Session, Version) ->
    gen_server:call(Server, {delete_session, Session, Version}).

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
    Dispatch = cowboy_router:compile(
                 [{'_', [{maps:get(path, Config),
                          adk_mcp_http_handler, RouteState}]}]),
    Transport = #{socket_opts => [{ip, maps:get(ip, Config)},
                                   {port, maps:get(port, Config)}],
                  num_acceptors => maps:get(num_acceptors, Config),
                  max_connections => maps:get(max_connections, Config)},
    Protocol = #{env => #{dispatch => Dispatch},
                 idle_timeout => maps:get(idle_timeout, Config),
                 request_timeout => maps:get(http_request_timeout, Config),
                 max_keepalive => maps:get(max_keepalive, Config)},
    case cowboy:start_clear(Listener, Transport, Protocol) of
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
    Url = <<"http://", Host/binary, ":",
            (integer_to_binary(Port))/binary, Path/binary>>,
    {reply, {ok, #{url => Url, host => Host, port => Port, path => Path}},
     State};
handle_call({register, Kind, Value}, _From, State) ->
    case normalize_registry_item(Kind, Value) of
        {ok, Key, Item} ->
            Field = registry_field(Kind),
            Registry = maps:get(Field, State),
            {reply, ok, State#{Field => Registry#{Key => Item}}};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({delete_session, undefined, _Version}, _From, State) ->
    {reply, {error, missing_session}, State};
handle_call({delete_session, Session, Version}, _From, State) ->
    Sessions = maps:get(sessions, State),
    case maps:find(Session, Sessions) of
        {ok, #{version := Version}} ->
            {reply, ok, State#{sessions => maps:remove(Session, Sessions)}};
        {ok, _} -> {reply, {error, invalid_protocol_version}, State};
        error -> {reply, {error, unknown_session}, State}
    end;
handle_call({http, Session, Version, Message}, From, State0) ->
    State = expire_sessions(State0),
    case classify_message(Message) of
        {initialize, Id, Params} ->
            handle_initialize(Session, Id, Params, State);
        {notification, <<"notifications/initialized">>, _Params} ->
            handle_initialized(Session, Version, State);
        {notification, _Method, _Params} ->
            handle_notification(Session, Version, State);
        {request, Id, Method, Params} ->
            handle_operation(Session, Version, Id, Method, Params,
                             From, State);
        invalid ->
            Error = error_response(null, -32600, <<"Invalid Request">>),
            {reply, {json, 400, [], Error}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({mcp_worker_result, Ref, Outcome}, State) ->
    case maps:take(Ref, maps:get(pending, State)) of
        {Pending, Rest} ->
            erlang:cancel_timer(maps:get(timer, Pending)),
            erlang:demonitor(maps:get(monitor, Pending), [flush]),
            Response0 = outcome_response(maps:get(id, Pending), Outcome),
            Response = enforce_response_bound(Response0, State),
            gen_server:reply(maps:get(from, Pending),
                             {json, 200, [], Response}),
            {noreply, State#{pending => Rest,
                             active => maps:get(active, State) - 1}};
        error -> {noreply, State}
    end;
handle_info({mcp_worker_timeout, Ref}, State) ->
    case maps:take(Ref, maps:get(pending, State)) of
        {Pending, Rest} ->
            exit(maps:get(pid, Pending), kill),
            erlang:demonitor(maps:get(monitor, Pending), [flush]),
            Response = error_response(maps:get(id, Pending), -32603,
                                      <<"Request timed out">>),
            gen_server:reply(maps:get(from, Pending),
                             {json, 200, [], Response}),
            {noreply, State#{pending => Rest,
                             active => maps:get(active, State) - 1}};
        error -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _Pid, Reason}, State) ->
    case pending_by_monitor(Monitor, maps:get(pending, State)) of
        {ok, Ref, Pending} ->
            erlang:cancel_timer(maps:get(timer, Pending)),
            Rest = maps:remove(Ref, maps:get(pending, State)),
            Response = error_response(maps:get(id, Pending), -32603,
                                      safe_worker_error(Reason)),
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
              Config = Config0#{auth => Auth},
              maps:without([pending], State#{config => Config});
         (message, Message) -> adk_secret_redactor:redact(Message);
         (log, _Log) -> [];
         (reason, Reason) -> adk_secret_redactor:redact(Reason);
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

handle_initialize(Session, Id, Params, State) ->
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
            case lists:member(Requested, ?SUPPORTED_PROTOCOL_VERSIONS) of
                false ->
                    Error = error_response(
                              Id, -32602,
                              <<"Unsupported protocol version">>,
                              #{<<"supported">> =>
                                    ?SUPPORTED_PROTOCOL_VERSIONS,
                                <<"requested">> => Requested}),
                    {reply, {json, 200, [], Error}, State};
                true -> create_session(Id, Requested, Sessions, State)
            end
    end.

create_session(Id, Requested, Sessions, State) ->
            SessionId = new_session_id(),
            Now = erlang:monotonic_time(millisecond),
            SessionState = #{phase => initializing,
                             version => Requested,
                             seen_ids => #{Id => true},
                             request_count => 1,
                             last_seen => Now},
            Result = initialize_result(State, Requested),
            Response = result_response(Id, Result),
            Headers = [{<<"mcp-session-id">>, SessionId}],
            {reply, {json, 200, Headers, Response},
             State#{sessions => Sessions#{SessionId => SessionState}}}.

handle_initialized(Session, Version, State) ->
    case session_check(Session, Version, initializing, State) of
        {ok, SessionState} ->
            Sessions = maps:get(sessions, State),
            Updated = touch_session(SessionState#{phase => ready}),
            {reply, {accepted, []},
             State#{sessions => Sessions#{Session => Updated}}};
        {error, Status} -> {reply, {http_error, Status, []}, State}
    end.

handle_notification(Session, Version, State) ->
    case session_check(Session, Version, ready, State) of
        {ok, SessionState} ->
            Sessions = maps:get(sessions, State),
            {reply, {accepted, []},
             State#{sessions => Sessions#{Session =>
                                              touch_session(SessionState)}}};
        {error, Status} -> {reply, {http_error, Status, []}, State}
    end.

handle_operation(Session, Version, Id, Method, Params, From, State) ->
    case session_check(Session, Version, ready, State) of
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
    Parent = self(),
    Work = fun() ->
        Outcome = execute_method(Method, Params, State),
        Parent ! {mcp_worker_result, Ref, Outcome}
    end,
    {Pid, Monitor} = spawn_monitor(Work),
    Timeout = maps:get(request_timeout, maps:get(config, State)),
    Timer = erlang:send_after(Timeout, self(), {mcp_worker_timeout, Ref}),
    Pending0 = maps:get(pending, State),
    Pending = #{from => From, id => Id, pid => Pid,
                monitor => Monitor, timer => Timer},
    {noreply, State#{pending => Pending0#{Ref => Pending},
                     active => maps:get(active, State) + 1}}.

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
    error_response(Id, Code, Message);
outcome_response(Id, _) ->
    error_response(Id, -32603, <<"Internal error">>).

enforce_response_bound(Response, State) ->
    Max = maps:get(max_response_bytes, maps:get(config, State)),
    case byte_size(jsx:encode(Response)) =< Max of
        true -> Response;
        false -> error_response(maps:get(<<"id">>, Response, null),
                                -32603, <<"Response exceeds limit">>)
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

session_check(undefined, _Version, _Phase, _State) -> {error, 400};
session_check(Session, Version, Phase, State) ->
    case maps:find(Session, maps:get(sessions, State)) of
        {ok, #{phase := Phase, version := Version} = SessionState} ->
            {ok, SessionState};
        {ok, _WrongPhase} -> {error, 400};
        error -> {error, 404}
    end.

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
                             <<"version">> => <<"0.3.0">>}}.

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
                max_keepalive => maps:get(max_keepalive, Config0, 100),
                allow_non_loopback => maps:get(allow_non_loopback,
                                               Config0, false),
                allowed_origins => normalize_origins(
                                     maps:get(allowed_origins, Config0, []))},
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

normalize_origins(Origins) when is_list(Origins) ->
    [lower(Value) || Value <- Origins, is_binary(Value)];
normalize_origins(_) -> invalid.

valid_config(Config) ->
    valid_ip(maps:get(ip, Config)) andalso
    is_boolean(maps:get(allow_non_loopback, Config)) andalso
    secure_bind(maps:get(ip, Config), maps:get(auth, Config),
                maps:get(allow_non_loopback, Config)) andalso
    is_integer(maps:get(port, Config)) andalso maps:get(port, Config) >= 0 andalso
    maps:get(port, Config) =< 65535 andalso
    valid_path(maps:get(path, Config)) andalso
    maps:get(allowed_origins, Config) =/= invalid andalso
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
    is_integer(maps:get(max_keepalive, Config)) andalso
    maps:get(max_keepalive, Config) >= 0.

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
    (maps:with([path, max_body_bytes, request_timeout,
                allowed_origins, auth], Config))#{server => Server}.

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
valid_ip({A, B, C, D}) ->
    lists:all(fun(V) -> is_integer(V) andalso V >= 0 andalso V =< 255 end,
              [A, B, C, D]);
valid_ip({A, B, C, D, E, F, G, H}) ->
    lists:all(fun(V) -> is_integer(V) andalso V >= 0 andalso V =< 16#ffff end,
              [A, B, C, D, E, F, G, H]);
valid_ip(_) -> false.
secure_bind({127, _B, _C, _D}, _Auth, _Allow) -> true;
secure_bind({0, 0, 0, 0, 0, 0, 0, 1}, _Auth, _Allow) -> true;
secure_bind(_Ip, none, _Allow) -> false;
secure_bind(_Ip, _ConfiguredAuth, true) -> true;
secure_bind(_Ip, _ConfiguredAuth, false) -> false.
lower(Value) -> list_to_binary(string:lowercase(binary_to_list(Value))).
