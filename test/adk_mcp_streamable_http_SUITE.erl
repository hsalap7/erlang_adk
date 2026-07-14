-module(adk_mcp_streamable_http_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([http_protocol_boundaries/1, bounded_concurrency/1]).

all() -> [http_protocol_boundaries, bounded_concurrency].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Config.

end_per_suite(_Config) -> ok.

http_protocol_boundaries(_Config) ->
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, max_body_bytes => 512,
                       tools => [adk_mcp_fixture_tool]}),
    try
        {ok, #{port := Port, path := Path}} = adk_mcp_server:endpoint(Server),
        {ok, Conn} = gun:open("127.0.0.1", Port),
        {ok, _} = gun:await_up(Conn, 3000),
        try
            GetRef = gun:get(Conn, Path,
                             [{<<"accept">>, <<"text/event-stream">>}]),
            {response, fin, 405, _} = gun:await(Conn, GetRef, 3000),

            Init = request(1, <<"initialize">>,
                           #{<<"protocolVersion">> => <<"2025-11-25">>,
                             <<"capabilities">> => #{},
                             <<"clientInfo">> =>
                                 #{<<"name">> => <<"ct">>,
                                   <<"version">> => <<"1">>}}),
            {200, InitHeaders, InitResponse} = post_json(
                                                Conn, Path, [], Init),
            Session = header(<<"mcp-session-id">>, InitHeaders),
            <<"2025-11-25">> = maps:get(
                                <<"protocolVersion">>,
                                maps:get(<<"result">>, InitResponse)),

            SessionHeaders = [{<<"mcp-session-id">>, Session},
                              {<<"mcp-protocol-version">>,
                               <<"2025-11-25">>}],
            Initialized = #{<<"jsonrpc">> => <<"2.0">>,
                            <<"method">> =>
                                <<"notifications/initialized">>},
            {202, _, <<>>} = post_raw(Conn, Path, SessionHeaders,
                                      jsx:encode(Initialized)),

            {400, _, <<>>} = post_raw(
                              Conn, Path,
                              [{<<"mcp-session-id">>, Session}],
                              jsx:encode(request(2, <<"tools/list">>, #{}))),

            {200, _, DuplicateBody} = post_raw(
                                      Conn, Path, SessionHeaders,
                                      jsx:encode(request(1, <<"tools/list">>, #{}))),
            -32600 = maps:get(<<"code">>, maps:get(
                                          <<"error">>,
                                          jsx:decode(DuplicateBody,
                                                     [return_maps]))),

            OriginHeaders = [{<<"origin">>, <<"https://attacker.invalid">>}],
            {403, _, <<>>} = post_raw(Conn, Path, OriginHeaders,
                                      jsx:encode(Init)),

            Oversized = binary:copy(<<"x">>, 513),
            {413, _, <<>>} = post_raw(Conn, Path, [], Oversized),

            DeleteRef = gun:request(Conn, <<"DELETE">>, Path,
                                    common_headers() ++ SessionHeaders, <<>>),
            {response, fin, 204, _} = gun:await(Conn, DeleteRef, 3000),
            {404, _, <<>>} = post_raw(
                              Conn, Path, SessionHeaders,
                              jsx:encode(request(3, <<"tools/list">>, #{}))),

            LegacyInit = request(
                           10, <<"initialize">>,
                           #{<<"protocolVersion">> => <<"2025-06-18">>,
                             <<"capabilities">> => #{},
                             <<"clientInfo">> =>
                                 #{<<"name">> => <<"legacy-ct">>,
                                   <<"version">> => <<"1">>}}),
            {200, LegacyHeaders, LegacyResponse} = post_json(
                                                        Conn, Path, [],
                                                        LegacyInit),
            <<"2025-06-18">> = maps:get(
                                <<"protocolVersion">>,
                                maps:get(<<"result">>, LegacyResponse)),
            LegacySession = header(<<"mcp-session-id">>, LegacyHeaders),
            {202, _, <<>>} = post_raw(
                              Conn, Path,
                              [{<<"mcp-session-id">>, LegacySession},
                               {<<"mcp-protocol-version">>,
                                <<"2025-06-18">>}],
                              jsx:encode(Initialized))
        after
            gun:close(Conn)
        end
    after
        ok = adk_mcp_server:stop(Server)
    end.

bounded_concurrency(_Config) ->
    TestPid = self(),
    SlowTool = #{schema =>
                     #{<<"name">> => <<"slow">>,
                       <<"description">> => <<"Controlled CT tool">>,
                       <<"inputSchema">> => #{<<"type">> => <<"object">>}},
                 execute => fun(_Args, _Context) ->
                     TestPid ! {slow_started, self()},
                     receive continue -> {ok, <<"done">>} after 3000 ->
                         {error, fixture_timeout}
                     end
                 end},
    {ok, Server} = adk_mcp_server:start(
                     <<"streamable_http">>,
                     #{port => 0, max_concurrency => 1,
                       request_timeout => 5000, tools => [SlowTool]}),
    try
        {ok, #{url := Url}} = adk_mcp_server:endpoint(Server),
        {ok, Client1} = adk_mcp_client:connect(<<"streamable_http">>, Url),
        {ok, Client2} = adk_mcp_client:connect(<<"streamable_http">>, Url),
        try
            Caller = self(),
            spawn(fun() ->
                Caller ! {first_result,
                          adk_mcp_client:execute_tool(Client1, <<"slow">>, #{})}
            end),
            Worker = receive {slow_started, Pid} -> Pid after 3000 ->
                ct:fail(slow_tool_did_not_start)
            end,
            {error, Busy} = adk_mcp_client:execute_tool(Client2,
                                                        <<"slow">>, #{}),
            -32000 = maps:get(<<"code">>, Busy),
            Worker ! continue,
            receive
                {first_result, {ok, #{<<"isError">> := false}}} -> ok
            after 3000 -> ct:fail(first_tool_did_not_finish)
            end
        after
            ok = adk_mcp_client:close(Client1),
            ok = adk_mcp_client:close(Client2)
        end
    after
        ok = adk_mcp_server:stop(Server)
    end.

request(Id, Method, Params) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"method">> => Method, <<"params">> => Params}.

post_json(Conn, Path, Headers, Message) ->
    {Status, ResponseHeaders, Body} = post_raw(
                                        Conn, Path, Headers,
                                        jsx:encode(Message)),
    {Status, ResponseHeaders, jsx:decode(Body, [return_maps])}.

post_raw(Conn, Path, Headers, Body) ->
    Ref = gun:post(Conn, Path, common_headers() ++ Headers, Body),
    case gun:await(Conn, Ref, 3000) of
        {response, fin, Status, ResponseHeaders} ->
            {Status, ResponseHeaders, <<>>};
        {response, nofin, Status, ResponseHeaders} ->
            {ok, ResponseBody} = gun:await_body(Conn, Ref, 3000),
            {Status, ResponseHeaders, ResponseBody}
    end.

common_headers() ->
    [{<<"accept">>, <<"application/json, text/event-stream">>},
     {<<"content-type">>, <<"application/json">>}].

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> ct:fail({missing_header, Name})
    end.
