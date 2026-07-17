-module(adk_a2a_v1_http_test).
-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, adk_a2a_v1_http_test_listener).
-define(EXT_LISTENER, adk_a2a_v1_extension_http_test_listener).

a2a_v1_http_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Context) ->
         [?_test(well_known_and_unary_client_case(Context)),
          ?_test(stream_client_closes_on_terminal_case(Context)),
          ?_test(malformed_and_legacy_rpc_case(Context)),
          ?_test(optional_methods_return_a2a_errors_case(Context)),
          ?_test(version_and_auth_are_enforced_case(Context)),
          ?_test(cross_principal_http_scope_case(Context)),
          ?_test(resubscribe_replays_then_closes_case(Context)),
          ?_test(required_extensions_are_enforced_case(Context))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    _ = catch cowboy:stop_listener(?LISTENER),
    Port = free_port(),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    RpcUrl = <<Base/binary, "/a2a/v1">>,
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => RpcUrl, name => <<"HTTP fixture">>,
                     description => <<"A2A conformance fixture">>}),
    Executor = fun(#{message := Message}, _Emit) ->
        Text = first_text(Message),
        case Text of <<"slow">> -> timer:sleep(300); _ -> ok end,
        {ok, <<"echo: ", Text/binary>>}
    end,
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined, card => Card,
                       executor => Executor, task_timeout => 2000,
                       retention_ms => 5000, max_tasks => 50,
                       max_active => 10, max_events => 64,
                       max_subscribers_per_task => 8}),
    Handler = #{server => Server, auth => adk_a2a_v1_test_auth,
                max_body_bytes => 65536, sse_heartbeat_ms => 1000},
    Dispatch = cowboy_router:compile(
                 [{'_', [
                   {"/.well-known/agent-card.json", adk_a2a_v1_handler,
                    Handler#{endpoint => card}},
                   {"/a2a/v1", adk_a2a_v1_handler,
                    Handler#{endpoint => jsonrpc}}
                 ]}]),
    {ok, _} = cowboy:start_clear(
                ?LISTENER,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}]},
                #{env => #{dispatch => Dispatch}}),
    #{server => Server, base => Base, rpc_url => RpcUrl, card => Card}.

cleanup(#{server := Server}) ->
    _ = catch cowboy:stop_listener(?LISTENER),
    _ = catch cowboy:stop_listener(?EXT_LISTENER),
    _ = catch gen_server:stop(Server),
    ok.

well_known_and_unary_client_case(#{base := Base}) ->
    {ok, Card} = adk_a2a_v1_client:discover(
                   Base, local_client_options(#{})),
    [#{<<"protocolBinding">> := <<"JSONRPC">>,
       <<"protocolVersion">> := <<"1.0">>}] =
        maps:get(<<"supportedInterfaces">>, Card),
    {ok, #{<<"task">> := Task}} = adk_a2a_v1_client:send(
                                       Card, message(<<"hello">>),
                                       alice_options(#{})),
    ?assertEqual(<<"TASK_STATE_COMPLETED">>, task_state(Task)),
    [#{<<"parts">> := [#{<<"text">> := <<"echo: hello">>}]}] =
        maps:get(<<"artifacts">>, Task).

stream_client_closes_on_terminal_case(#{card := Card}) ->
    {ok, Events} = adk_a2a_v1_client:send_stream(
                     Card, message(<<"stream">>), alice_options(#{})),
    [#{<<"task">> := _} | _] = Events,
    ?assert(lists:any(fun terminal_event/1, Events)),
    ?assert(lists:any(fun(E) -> maps:is_key(<<"artifactUpdate">>, E) end,
                      Events)).

malformed_and_legacy_rpc_case(#{rpc_url := Url}) ->
    {400, ParseBody} = raw_post(Url, <<"{">>, alice, <<"1.0">>),
    #{<<"error">> := #{<<"code">> := -32700}} =
        jsx:decode(ParseBody, [return_maps]),
    Legacy = rpc(1, <<"message/send">>, #{}),
    {200, LegacyBody} = raw_post(Url, jsx:encode(Legacy), alice, <<"1.0">>),
    #{<<"error">> := #{<<"code">> := -32601}} =
        jsx:decode(LegacyBody, [return_maps]),
    KindPart = rpc(
                 2, <<"SendMessage">>,
                 #{<<"message">> =>
                       #{<<"messageId">> => <<"legacy">>,
                         <<"role">> => <<"ROLE_USER">>,
                         <<"parts">> =>
                             [#{<<"kind">> => <<"text">>,
                                <<"text">> => <<"old">>}]}}),
    {200, KindBody} = raw_post(Url, jsx:encode(KindPart), alice, <<"1.0">>),
    #{<<"error">> := #{<<"code">> := -32602}} =
        jsx:decode(KindBody, [return_maps]).

optional_methods_return_a2a_errors_case(#{rpc_url := Url}) ->
    PushMethods = [<<"CreateTaskPushNotificationConfig">>,
                   <<"GetTaskPushNotificationConfig">>,
                   <<"ListTaskPushNotificationConfigs">>,
                   <<"DeleteTaskPushNotificationConfig">>],
    lists:foreach(
      fun(Method) ->
          {200, Body} = raw_post(
                          Url, jsx:encode(rpc(10, Method, #{})),
                          alice, <<"1.0">>),
          #{<<"error">> := #{<<"code">> := -32003}} =
              jsx:decode(Body, [return_maps])
      end, PushMethods),
    {200, ExtendedBody} = raw_post(
                            Url,
                            jsx:encode(rpc(11, <<"GetExtendedAgentCard">>, #{})),
                            alice, <<"1.0">>),
    #{<<"error">> := #{<<"code">> := -32004}} =
        jsx:decode(ExtendedBody, [return_maps]),
    {200, CustomBody} = raw_post(
                          Url,
                          jsx:encode(rpc(12, <<"example.test/Custom">>, #{})),
                          alice, <<"1.0">>),
    #{<<"error">> := #{<<"code">> := -32601}} =
        jsx:decode(CustomBody, [return_maps]).

version_and_auth_are_enforced_case(#{rpc_url := Url}) ->
    Request = rpc(1, <<"GetTask">>, #{<<"id">> => <<"missing">>}),
    {200, VersionBody} = raw_post(Url, jsx:encode(Request), alice, undefined),
    #{<<"error">> := #{<<"code">> := -32009}} =
        jsx:decode(VersionBody, [return_maps]),
    {401, <<>>} = raw_post(Url, jsx:encode(Request), none, <<"1.0">>).

cross_principal_http_scope_case(#{card := Card}) ->
    Options = alice_options(
                #{configuration => #{<<"returnImmediately">> => true}}),
    {ok, #{<<"task">> := #{<<"id">> := TaskId}}} =
        adk_a2a_v1_client:send(Card, message(<<"private">>), Options),
    {error, {a2a_error, #{<<"code">> := -32001}}} =
        adk_a2a_v1_client:get_task(Card, TaskId, bob_options(#{})).

resubscribe_replays_then_closes_case(#{card := Card}) ->
    Options = alice_options(
                #{configuration => #{<<"returnImmediately">> => true}}),
    {ok, #{<<"task">> := #{<<"id">> := TaskId}}} =
        adk_a2a_v1_client:send(Card, message(<<"slow">>), Options),
    {ok, Events} = adk_a2a_v1_client:subscribe(
                     Card, TaskId,
                     alice_options(#{last_event_id => 0, timeout => 3000})),
    [#{<<"task">> := Snapshot} | _] = Events,
    ?assertEqual(TaskId, maps:get(<<"id">>, Snapshot)),
    ?assert(lists:any(fun terminal_event/1, Events)).

required_extensions_are_enforced_case(_Context) ->
    Extension = <<"https://example.test/a2a/extensions/audit/v1">>,
    Port = free_port(),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    RpcUrl = <<Base/binary, "/a2a/v1">>,
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => RpcUrl,
                     extensions => [#{<<"uri">> => Extension,
                                      <<"required">> => true}]}),
    Executor = fun(_Request, _Emit) -> {ok, <<"ok">>} end,
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined, card => Card,
                       executor => Executor}),
    Handler = #{server => Server, auth => adk_a2a_v1_test_auth,
                max_body_bytes => 65536, sse_heartbeat_ms => 1000,
                max_extensions => 2, max_extension_header_bytes => 256},
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/a2a/v1", adk_a2a_v1_handler,
                          Handler#{endpoint => jsonrpc}}]}]),
    {ok, _} = cowboy:start_clear(
                ?EXT_LISTENER,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}]},
                #{env => #{dispatch => Dispatch}}),
    Request = jsx:encode(rpc(20, <<"GetTask">>,
                             #{<<"id">> => <<"missing">>})),
    try
        {200, MissingBody} = raw_post(RpcUrl, Request, alice, <<"1.0">>),
        #{<<"error">> := #{<<"code">> := -32008}} =
            jsx:decode(MissingBody, [return_maps]),
        {200, PresentBody} = raw_post_with_headers(
                               RpcUrl, Request, alice, <<"1.0">>,
                               [{"A2A-Extensions",
                                 binary_to_list(Extension)}]),
        #{<<"error">> := #{<<"code">> := -32001}} =
            jsx:decode(PresentBody, [return_maps]),
        Oversized = binary:copy(<<"x">>, 257),
        {200, OversizedBody} = raw_post_with_headers(
                                 RpcUrl, Request, alice, <<"1.0">>,
                                 [{"A2A-Extensions",
                                   binary_to_list(Oversized)}]),
        #{<<"error">> := #{<<"code">> := -32008}} =
            jsx:decode(OversizedBody, [return_maps])
    after
        _ = catch cowboy:stop_listener(?EXT_LISTENER),
        _ = catch gen_server:stop(Server)
    end.

alice_options(Extra) ->
    maps:merge(#{auth_fun => fun() ->
        [{<<"authorization">>, <<"Bearer alice-secret">>}]
    end, timeout => 3000, allow_http_loopback => true,
      allow_undeclared_auth => true}, Extra).

bob_options(Extra) ->
    maps:merge(#{auth_fun => fun() ->
        [{<<"authorization">>, <<"Bearer bob-secret">>}]
    end, timeout => 3000, allow_http_loopback => true,
      allow_undeclared_auth => true}, Extra).

local_client_options(Extra) ->
    maps:merge(#{timeout => 3000, allow_http_loopback => true}, Extra).

message(Text) ->
    #{<<"messageId">> =>
          <<"m-", (integer_to_binary(
                     erlang:unique_integer([positive, monotonic])))/binary>>,
      <<"role">> => <<"ROLE_USER">>,
      <<"parts">> => [#{<<"text">> => Text}]}.

rpc(Id, Method, Params) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"method">> => Method, <<"params">> => Params}.

raw_post(Url, Body, Principal, Version) ->
    raw_post_with_headers(Url, Body, Principal, Version, []).

raw_post_with_headers(Url, Body, Principal, Version, ExtraHeaders) ->
    Headers0 = case Principal of
        alice -> [{"Authorization", "Bearer alice-secret"}];
        bob -> [{"Authorization", "Bearer bob-secret"}];
        none -> []
    end,
    Headers = case Version of
        undefined -> ExtraHeaders ++ Headers0;
        Value -> [{"A2A-Version", binary_to_list(Value)} |
                  ExtraHeaders ++ Headers0]
    end,
    {ok, {{_, Status, _}, _ResponseHeaders, ResponseBody}} =
        httpc:request(
          post, {binary_to_list(Url), Headers, "application/json", Body},
          [{timeout, 3000}], [{body_format, binary}]),
    {Status, ResponseBody}.

terminal_event(#{<<"statusUpdate">> :=
                     #{<<"status">> := #{<<"state">> := State}}}) ->
    adk_a2a_v1_codec:terminal_state(State);
terminal_event(_) -> false.

task_state(#{<<"status">> := #{<<"state">> := State}}) -> State.

first_text(#{<<"parts">> := Parts}) ->
    hd([Text || #{<<"text">> := Text} <- Parts]).

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {active, false},
                                      {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.
