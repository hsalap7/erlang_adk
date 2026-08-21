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
          ?_test(agent_card_cache_validators_case(Context)),
          ?_test(protojson_alias_and_unknown_field_case(Context)),
          ?_test(direct_message_response_case(Context)),
          ?_test(direct_message_stream_response_case(Context)),
          ?_test(send_history_length_zero_case(Context)),
          ?_test(stream_client_closes_on_terminal_case(Context)),
          ?_test(incremental_callback_applies_backpressure_case(Context)),
          ?_test(callback_stop_cancels_stream_case(Context)),
          ?_test(stream_owner_death_releases_subscription_case(Context)),
          ?_test(malformed_and_legacy_rpc_case(Context)),
          ?_test(optional_methods_return_a2a_errors_case(Context)),
          ?_test(version_and_auth_are_enforced_case(Context)),
          ?_test(cross_principal_http_scope_case(Context)),
          ?_test(resubscribe_replays_then_closes_case(Context)),
          ?_test(push_config_crud_client_case(Context)),
          ?_test(extended_agent_card_http_endpoint_case(Context)),
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
    Executor = fun(#{message := Message}, Emit) ->
        Text = first_text(Message),
        case Text of
            <<"slow">> ->
                ok = Emit({status, <<"TASK_STATE_WORKING">>, undefined}),
                timer:sleep(300),
                {ok, <<"echo: slow">>};
            <<"direct">> ->
                {message,
                 #{<<"role">> => <<"ROLE_AGENT">>,
                   <<"parts">> =>
                       [#{<<"text">> => <<"Direct message response">>}]}};
            _ -> {ok, <<"echo: ", Text/binary>>}
        end
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

agent_card_cache_validators_case(#{base := Base}) ->
    Url = <<Base/binary, "/.well-known/agent-card.json">>,
    {200, Headers, _Body} = raw_get_headers(Url, none, undefined, []),
    ETag = response_header("etag", Headers),
    LastModified = response_header("last-modified", Headers),
    ?assert(is_list(ETag) andalso ETag =/= []),
    ?assert(is_list(LastModified) andalso LastModified =/= []),
    {304, ConditionalHeaders, <<>>} = raw_get_headers(
                                      Url, none, undefined,
                                      [{"If-None-Match", ETag}]),
    ?assertEqual(ETag, response_header("etag", ConditionalHeaders)).

protojson_alias_and_unknown_field_case(#{rpc_url := Url}) ->
    MessageId = <<"unknown-", (integer_to_binary(
                      erlang:unique_integer([positive, monotonic])))/binary>>,
    Message = #{<<"messageId">> => MessageId,
                <<"role">> => <<"ROLE_USER">>,
                <<"parts">> => [#{<<"text">> => <<"forward">>,
                                   <<"futurePart">> => true}],
                <<"tckUnknownField">> => <<"ignored">>},
    {200, SendBody} = raw_post(
                        Url,
                        jsx:encode(rpc(101, <<"SendMessage">>,
                                       #{<<"message">> => Message,
                                         <<"tckExtraParam">> => 42})),
                        alice, <<"1.0">>),
    #{<<"result">> := #{<<"task">> := Task}} =
        jsx:decode(SendBody, [return_maps]),
    ContextId = maps:get(<<"contextId">>, Task),
    [Retained] = maps:get(<<"history">>, Task),
    ?assertEqual(false, maps:is_key(<<"tckUnknownField">>, Retained)),
    [RetainedPart] = maps:get(<<"parts">>, Retained),
    ?assertEqual(false, maps:is_key(<<"futurePart">>, RetainedPart)),
    {200, ListBody} = raw_post(
                        Url,
                        jsx:encode(rpc(
                                     102, <<"ListTasks">>,
                                     #{<<"context_id">> => ContextId,
                                       <<"page_size">> => 100,
                                       <<"include_artifacts">> => false})),
                        alice, <<"1.0">>),
    #{<<"result">> := #{<<"tasks">> := Listed}} =
        jsx:decode(ListBody, [return_maps]),
    ?assert(lists:any(fun(#{<<"id">> := Id}) ->
                          Id =:= maps:get(<<"id">>, Task)
                      end, Listed)).

direct_message_response_case(#{card := Card}) ->
    {ok, #{<<"message">> := Message}} = adk_a2a_v1_client:send(
                                           Card, message(<<"direct">>),
                                           alice_options(#{})),
    ?assertEqual(<<"ROLE_AGENT">>, maps:get(<<"role">>, Message)),
    [#{<<"text">> := <<"Direct message response">>}] =
        maps:get(<<"parts">>, Message).

direct_message_stream_response_case(#{card := Card}) ->
    {ok, [#{<<"message">> := Message}]} =
        adk_a2a_v1_client:send_stream(
          Card, message(<<"direct">>), alice_options(#{})),
    ?assertEqual(<<"ROLE_AGENT">>, maps:get(<<"role">>, Message)).

send_history_length_zero_case(#{card := Card}) ->
    {ok, #{<<"task">> := Task}} = adk_a2a_v1_client:send(
                                      Card, message(<<"history zero">>),
                                      alice_options(
                                        #{configuration =>
                                              #{<<"historyLength">> => 0}})),
    ?assertEqual(false, maps:is_key(<<"history">>, Task)).

stream_client_closes_on_terminal_case(#{card := Card}) ->
    {ok, Events} = adk_a2a_v1_client:send_stream(
                     Card, message(<<"stream">>), alice_options(#{})),
    [#{<<"task">> := _} | _] = Events,
    ?assert(lists:any(fun terminal_event/1, Events)),
    ?assert(lists:any(fun(E) -> maps:is_key(<<"artifactUpdate">>, E) end,
                      Events)).

incremental_callback_applies_backpressure_case(#{card := Card}) ->
    Parent = self(),
    Caller = spawn(fun() ->
        Callback = fun(Payload) ->
            Parent ! {a2a_callback_event, self(), Payload},
            case get(a2a_callback_blocked) of
                undefined ->
                    put(a2a_callback_blocked, true),
                    receive release_callback -> continue end;
                true -> continue
            end
        end,
        Result = adk_a2a_v1_client:send_stream(
                   Card, message(<<"callback stream">>),
                   alice_options(#{}), Callback),
        Parent ! {a2a_callback_result, self(), Result}
    end),
    First = receive
        {a2a_callback_event, Caller, Payload} -> Payload
    after 1000 -> error(first_callback_timeout)
    end,
    ?assert(maps:is_key(<<"task">>, First)),
    ?assert(is_process_alive(Caller)),
    receive
        {a2a_callback_result, Caller, _} -> ?assert(false)
    after 25 -> ok
    end,
    Caller ! release_callback,
    receive
        {a2a_callback_result, Caller, ok} -> ok
    after 2000 -> error(callback_stream_timeout)
    end,
    Remaining = drain_callback_events(Caller, []),
    ?assert(lists:any(fun terminal_event/1, Remaining)).

callback_stop_cancels_stream_case(#{card := Card, server := Server}) ->
    Key = {?MODULE, callback_stop},
    erase(Key),
    Callback = fun(Payload) -> put(Key, Payload), stop end,
    ok = adk_a2a_v1_client:send_stream(
           Card, message(<<"slow">>), alice_options(#{}), Callback),
    #{<<"task">> := #{<<"id">> := TaskId}} = erase(Key),
    ok = wait_for_subscribers(Server, TaskId, 0, 2000).

stream_owner_death_releases_subscription_case(
  #{card := Card, server := Server}) ->
    Parent = self(),
    Caller = spawn(fun() ->
        Callback = fun(Payload) ->
            Parent ! {owner_death_stream_snapshot, self(), Payload},
            receive never -> continue end
        end,
        _ = adk_a2a_v1_client:send_stream(
              Card, message(<<"slow">>), alice_options(#{}), Callback)
    end),
    TaskId = receive
        {owner_death_stream_snapshot, Caller,
         #{<<"task">> := #{<<"id">> := Id}}} -> Id
    after 1000 -> error(owner_death_stream_start_timeout)
    end,
    ?assertEqual(1, subscriber_count(Server, TaskId)),
    Monitor = erlang:monitor(process, Caller),
    exit(Caller, kill),
    receive
        {'DOWN', Monitor, process, Caller, killed} -> ok
    after 1000 -> error(stream_owner_death_timeout)
    end,
    ok = wait_for_subscribers(Server, TaskId, 0, 2000).

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

push_config_crud_client_case(_Context) ->
    Parent = self(),
    Port = free_port(),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    RpcUrl = <<Base/binary, "/a2a/v1">>,
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => RpcUrl, push_notifications => true}),
    Executor = fun(_Request, _Emit) ->
        Parent ! {push_crud_executor, self()},
        receive finish -> {ok, <<"done">>} end
    end,
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined, card => Card, executor => Executor,
                       push_policy =>
                           #{transport => fun(_Job, _Policy) -> ok end,
                             allowed_hosts =>
                                 [<<"hooks.example.test">>]}}),
    Handler = #{server => Server, auth => adk_a2a_v1_test_auth,
                max_body_bytes => 65536},
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/a2a/v1", adk_a2a_v1_handler,
                          Handler#{endpoint => jsonrpc}}]}]),
    {ok, _} = cowboy:start_clear(
                ?EXT_LISTENER,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}]},
                #{env => #{dispatch => Dispatch}}),
    Secret = <<"push-client-secret">>,
    try
        Options = alice_options(
                    #{configuration =>
                          #{<<"returnImmediately">> => true}}),
        {ok, #{<<"task">> := #{<<"id">> := TaskId}}} =
            adk_a2a_v1_client:send(Card, message(<<"push CRUD">>), Options),
        Worker = receive {push_crud_executor, Pid} -> Pid
                 after 1000 -> error(push_crud_executor_timeout) end,
        Config = #{<<"taskId">> => TaskId,
                   <<"url">> => <<"https://hooks.example.test/a2a">>,
                   <<"authentication">> =>
                       #{<<"scheme">> => <<"Bearer">>,
                         <<"credentials">> => Secret}},
        {ok, Public = #{<<"id">> := ConfigId}} =
            adk_a2a_v1_client:create_push_config(
              Card, Config, alice_options(#{})),
        ?assertEqual(nomatch,
                     binary:match(term_to_binary(Public), Secret)),
        {ok, Public} = adk_a2a_v1_client:get_push_config(
                         Card, TaskId, ConfigId, alice_options(#{})),
        {ok, #{<<"configs">> := [Public],
               <<"nextPageToken">> := <<>>}} =
            adk_a2a_v1_client:list_push_configs(
              Card, #{<<"taskId">> => TaskId}, alice_options(#{})),
        {ok, #{}} = adk_a2a_v1_client:delete_push_config(
                      Card, TaskId, ConfigId, alice_options(#{})),
        Worker ! finish
    after
        _ = catch cowboy:stop_listener(?EXT_LISTENER),
        _ = catch gen_server:stop(Server)
    end.

extended_agent_card_http_endpoint_case(_Context) ->
    Port = free_port(),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    RpcUrl = <<Base/binary, "/a2a/v1">>,
    {ok, PublicCard} = adk_a2a_v1_card:new(
                         #{url => RpcUrl,
                           extended_agent_card => true,
                           skills => [extended_skill(<<"public">>)]}),
    {ok, ExtendedCard} = adk_a2a_v1_card:new(
                           #{url => RpcUrl,
                             extended_agent_card => true,
                             skills => [extended_skill(<<"public">>),
                                        extended_skill(<<"private">>)]}),
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined, card => PublicCard,
                       extended_card => ExtendedCard,
                       executor => fun(_Request, _Emit) -> {ok, <<"ok">>} end}),
    Handler = #{server => Server, auth => adk_a2a_v1_test_auth},
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/extendedAgentCard", adk_a2a_v1_handler,
                          Handler#{endpoint => extended_card}},
                         {"/a2a/v1", adk_a2a_v1_handler,
                          Handler#{endpoint => jsonrpc}}]}]),
    {ok, _} = cowboy:start_clear(
                ?EXT_LISTENER,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}]},
                #{env => #{dispatch => Dispatch}}),
    Url = <<Base/binary, "/extendedAgentCard">>,
    try
        {200, Body} = raw_get(Url, alice, <<"1.0">>),
        ?assertEqual(ExtendedCard, jsx:decode(Body, [return_maps])),
        ?assertEqual(
           {ok, ExtendedCard},
           adk_a2a_v1_client:get_extended_card(
             PublicCard, alice_options(#{}))),
        {401, <<>>} = raw_get(Url, none, <<"1.0">>),
        {400, VersionBody} = raw_get(Url, alice, undefined),
        #{<<"code">> := -32009} = jsx:decode(VersionBody, [return_maps])
    after
        _ = catch cowboy:stop_listener(?EXT_LISTENER),
        _ = catch gen_server:stop(Server)
    end.

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

raw_get(Url, Principal, Version) ->
    {Status, _Headers, ResponseBody} =
        raw_get_headers(Url, Principal, Version, []),
    {Status, ResponseBody}.

raw_get_headers(Url, Principal, Version, ExtraHeaders) ->
    Headers0 = case Principal of
        alice -> [{"Authorization", "Bearer alice-secret"}];
        none -> []
    end,
    Headers = case Version of
        undefined -> ExtraHeaders ++ Headers0;
        Value -> [{"A2A-Version", binary_to_list(Value)} |
                  ExtraHeaders ++ Headers0]
    end,
    {ok, {{_, Status, _}, ResponseHeaders, ResponseBody}} =
        httpc:request(
          get, {binary_to_list(Url), Headers},
          [{timeout, 3000}], [{body_format, binary}]),
    {Status, ResponseHeaders, ResponseBody}.

response_header(Name, Headers) ->
    case [Value || {Key, Value} <- Headers,
                   string:lowercase(Key) =:= Name] of
        [Value | _] -> Value;
        [] -> undefined
    end.

terminal_event(#{<<"statusUpdate">> :=
                     #{<<"status">> := #{<<"state">> := State}}}) ->
    adk_a2a_v1_codec:terminal_state(State);
terminal_event(_) -> false.

drain_callback_events(Caller, Acc) ->
    receive
        {a2a_callback_event, Caller, Payload} ->
            drain_callback_events(Caller, [Payload | Acc])
    after 0 -> lists:reverse(Acc)
    end.

wait_for_subscribers(Server, TaskId, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_subscribers_until(Server, TaskId, Expected, Deadline).

wait_for_subscribers_until(Server, TaskId, Expected, Deadline) ->
    Count = subscriber_count(Server, TaskId),
    Now = erlang:monotonic_time(millisecond),
    case Count of
        Expected -> ok;
        _ when Now >= Deadline ->
            error(a2a_subscriber_release_timeout);
        _ ->
            receive after 10 -> ok end,
            wait_for_subscribers_until(Server, TaskId, Expected, Deadline)
    end.

subscriber_count(Server, TaskId) ->
    State = sys:get_state(Server),
    Entry = maps:get(TaskId, maps:get(tasks, State)),
    map_size(maps:get(subscribers, Entry)).

task_state(#{<<"status">> := #{<<"state">> := State}}) -> State.

first_text(#{<<"parts">> := Parts}) ->
    hd([Text || #{<<"text">> := Text} <- Parts]).

extended_skill(Id) ->
    #{<<"id">> => Id, <<"name">> => Id,
      <<"description">> => <<"HTTP fixture skill">>,
      <<"tags">> => [<<"test">>]}.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {active, false},
                                      {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.
