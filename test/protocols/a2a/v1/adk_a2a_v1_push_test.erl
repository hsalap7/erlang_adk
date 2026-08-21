-module(adk_a2a_v1_push_test).

-include_lib("eunit/include/eunit.hrl").

-define(PUSH_LISTENER, adk_a2a_v1_push_http_test_listener).

push_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) ->
         _ = catch cowboy:stop_listener(?PUSH_LISTENER),
         ok
     end,
     [fun config_is_split_and_ssrf_policy_is_fail_closed/0,
      fun retries_keep_one_idempotency_key/0,
      fun http_delivery_is_bounded_authenticated_and_never_redirected/0,
      fun server_crud_is_scoped_and_secrets_are_not_returned/0,
      fun delete_cancels_inflight_delivery/0,
      fun server_owner_death_cancels_inflight_delivery/0,
      fun extended_card_requires_declared_capability_and_configuration/0]}.

config_is_split_and_ssrf_policy_is_fail_closed() ->
    {ok, Default} = adk_a2a_v1_push:normalize_policy(#{}),
    PrivateHttp = push_config(<<"http://127.0.0.1/hook">>),
    ?assertEqual(
       {error, insecure_a2a_push_destination},
       adk_a2a_v1_push:prepare_config(
         <<"task">>, <<"config">>, undefined, PrivateHttp, Default)),
    PrivateHttps = push_config(<<"https://10.0.0.1/hook">>),
    ?assertEqual(
       {error, a2a_push_private_destination_rejected},
       adk_a2a_v1_push:prepare_config(
         <<"task">>, <<"config">>, undefined, PrivateHttps, Default)),
    {ok, Local} = adk_a2a_v1_push:normalize_policy(
                    #{allow_http_loopback => true,
                      allowed_hosts => [<<"127.0.0.1">>],
                      allowed_private_hosts => [<<"127.0.0.1">>]}),
    Secret = <<"push-credential-private">>,
    Token = <<"notification-token-private">>,
    Config = PrivateHttp#{
               <<"token">> => Token,
               <<"authentication">> =>
                   #{<<"scheme">> => <<"Bearer">>,
                     <<"credentials">> => Secret}},
    {ok, Public, Private} = adk_a2a_v1_push:prepare_config(
                              <<"task">>, <<"config">>, undefined,
                              Config, Local),
    Encoded = term_to_binary(Public),
    ?assertEqual(nomatch, binary:match(Encoded, Secret)),
    ?assertEqual(nomatch, binary:match(Encoded, Token)),
    ?assertEqual(Secret,
                 maps:get(<<"credentials">>,
                          maps:get(authentication, Private))).

retries_keep_one_idempotency_key() ->
    Parent = self(),
    Transport = fun(Job, _Policy) ->
        Attempt = case get(push_attempt) of undefined -> 1; N -> N + 1 end,
        put(push_attempt, Attempt),
        Parent ! {push_attempt, Attempt, maps:get(delivery_id, Job)},
        case Attempt < 3 of
            true -> {error, a2a_push_connect_failed};
            false -> ok
        end
    end,
    {ok, Policy} = adk_a2a_v1_push:normalize_policy(
                     #{transport => Transport, max_attempts => 3,
                       retry_base_ms => 1,
                       allowed_hosts => [<<"hooks.example.test">>]}),
    Job = #{config => #{<<"url">> =>
                            <<"https://hooks.example.test/a2a">>},
            secret => #{}, delivery_id => <<"delivery-stable">>,
            payload => status_payload(<<"task">>)},
    ?assertEqual(ok, adk_a2a_v1_push:deliver(Job, Policy)),
    Attempts = [receive {push_attempt, N, Id} -> {N, Id}
                after 1000 -> error(push_retry_timeout) end
                || _ <- lists:seq(1, 3)],
    ?assertEqual([{1, <<"delivery-stable">>},
                  {2, <<"delivery-stable">>},
                  {3, <<"delivery-stable">>}], Attempts).

http_delivery_is_bounded_authenticated_and_never_redirected() ->
    _ = catch cowboy:stop_listener(?PUSH_LISTENER),
    Table = ets:new(?MODULE, [set, public]),
    Port = free_port(),
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/[...]", adk_a2a_v1_push_fixture_handler,
                          #{parent => self(), table => Table}}]}]),
    {ok, _} = cowboy:start_clear(
                ?PUSH_LISTENER,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}]},
                #{env => #{dispatch => Dispatch}}),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    PolicyOptions = #{allow_http_loopback => true,
                      allowed_hosts => [<<"127.0.0.1">>],
                      allowed_private_hosts => [<<"127.0.0.1">>],
                      timeout_ms => 3000, connect_timeout_ms => 1000,
                      max_attempts => 3, retry_base_ms => 1},
    {ok, Policy} = adk_a2a_v1_push:normalize_policy(PolicyOptions),
    Credential = <<"hook-secret-never-returned">>,
    Token = <<"hook-notification-token">>,
    DeliveryId = <<"stable-delivery-id">>,
    Payload = status_payload(<<"task-http">>),
    Job0 = #{secret =>
                 #{token => Token,
                   authentication =>
                       #{<<"scheme">> => <<"Bearer">>,
                         <<"credentials">> => Credential}},
             delivery_id => DeliveryId, payload => Payload},
    try
        RetryJob = Job0#{config =>
                             #{<<"url">> => <<Base/binary, "/retry">>}},
        ?assertEqual(ok, adk_a2a_v1_push:deliver(RetryJob, Policy)),
        Requests = [receive_push_http_request(<<"/retry">>)
                    || _ <- lists:seq(1, 3)],
        ?assertEqual([1, 2, 3], [Attempt || {Attempt, _, _} <- Requests]),
        lists:foreach(
          fun({_Attempt, Headers, Body}) ->
              ?assertEqual(<<"Bearer ", Credential/binary>>,
                           maps:get(<<"authorization">>, Headers)),
              ?assertEqual(Token,
                           maps:get(<<"x-a2a-notification-token">>,
                                    Headers)),
              ?assertEqual(DeliveryId,
                           maps:get(<<"idempotency-key">>, Headers)),
              ?assertEqual(DeliveryId,
                           maps:get(<<"a2a-delivery-id">>, Headers)),
              ?assertEqual(Payload, jsx:decode(Body, [return_maps]))
          end, Requests),
        {ok, NoRetryPolicy} = adk_a2a_v1_push:normalize_policy(
                                PolicyOptions#{max_attempts => 1}),
        RedirectJob = Job0#{config =>
                                #{<<"url">> =>
                                      <<Base/binary, "/redirect">>}},
        ?assertEqual(
           {error, {a2a_push_http_status, 307}},
           adk_a2a_v1_push:deliver(RedirectJob, NoRetryPolicy)),
        _ = receive_push_http_request(<<"/redirect">>),
        receive
            {a2a_push_http_request, <<"/target">>, _, _, _} ->
                ?assert(false)
        after 50 -> ok
        end,
        {ok, BoundedPolicy} = adk_a2a_v1_push:normalize_policy(
                                PolicyOptions#{max_attempts => 1,
                                               max_response_bytes => 16}),
        OversizedJob = Job0#{config =>
                                 #{<<"url">> =>
                                       <<Base/binary, "/oversized">>}},
        OversizedResult = adk_a2a_v1_push:deliver(
                            OversizedJob, BoundedPolicy),
        ?assertEqual({error, a2a_push_delivery_failed}, OversizedResult),
        ?assertEqual(nomatch,
                     binary:match(term_to_binary(OversizedResult),
                                  Credential))
    after
        _ = catch cowboy:stop_listener(?PUSH_LISTENER),
        ets:delete(Table)
    end.

server_crud_is_scoped_and_secrets_are_not_returned() ->
    Parent = self(),
    Transport = fun(Job, _Policy) ->
        Parent ! {push_delivered, Job},
        ok
    end,
    {Server, Worker, Emit, TaskId} = start_push_server(Transport),
    Secret = <<"server-push-secret">>,
    Token = <<"server-push-token">>,
    Config0 = (push_config(<<"https://hooks.example.test/a2a">>))#{
                <<"taskId">> => TaskId,
                <<"token">> => Token,
                <<"authentication">> =>
                    #{<<"scheme">> => <<"Bearer">>,
                      <<"credentials">> => Secret}},
    try
        {ok, Public = #{<<"id">> := ConfigId}} =
            adk_a2a_v1_server:create_push_config(
              Server, scope(<<"alice">>), Config0),
        PublicBytes = term_to_binary(Public),
        ?assertEqual(nomatch, binary:match(PublicBytes, Secret)),
        ?assertEqual(nomatch, binary:match(PublicBytes, Token)),
        {ok, Public} = adk_a2a_v1_server:get_push_config(
                         Server, scope(<<"alice">>),
                         #{<<"taskId">> => TaskId, <<"id">> => ConfigId}),
        {ok, #{<<"configs">> := [Public]}} =
            adk_a2a_v1_server:list_push_configs(
              Server, scope(<<"alice">>), #{<<"taskId">> => TaskId}),
        ?assertEqual(
           {error, task_not_found},
           adk_a2a_v1_server:get_push_config(
             Server, scope(<<"bob">>),
             #{<<"taskId">> => TaskId, <<"id">> => ConfigId})),
        ok = Emit({status, <<"TASK_STATE_WORKING">>, <<"progress">>}),
        Job = receive {push_delivered, Delivered} -> Delivered
              after 1000 -> error(push_delivery_timeout) end,
        ?assertEqual(Secret,
                     maps:get(<<"credentials">>,
                              maps:get(authentication,
                                       maps:get(secret, Job)))),
        ?assertEqual(status_payload_kind,
                     payload_kind(maps:get(payload, Job))),
        {ok, #{}} = adk_a2a_v1_server:delete_push_config(
                      Server, scope(<<"alice">>),
                      #{<<"taskId">> => TaskId, <<"id">> => ConfigId}),
        %% Delete is idempotent and no later event is enqueued.
        {ok, #{}} = adk_a2a_v1_server:delete_push_config(
                      Server, scope(<<"alice">>),
                      #{<<"taskId">> => TaskId, <<"id">> => ConfigId}),
        ok = Emit({status, <<"TASK_STATE_WORKING">>, <<"later">>}),
        receive {push_delivered, _} -> ?assert(false) after 50 -> ok end
    after
        Worker ! finish,
        gen_server:stop(Server)
    end.

delete_cancels_inflight_delivery() ->
    Parent = self(),
    Transport = fun(_Job, _Policy) ->
        Parent ! {blocking_push_worker, self()},
        receive never -> ok end
    end,
    {Server, Worker, Emit, TaskId} = start_push_server(Transport),
    try
        {ok, #{<<"id">> := ConfigId}} =
            adk_a2a_v1_server:create_push_config(
              Server, scope(<<"alice">>),
              (push_config(<<"https://hooks.example.test/a2a">>))#{
                <<"taskId">> => TaskId}),
        ok = Emit({status, <<"TASK_STATE_WORKING">>, <<"blocking">>}),
        PushWorker = receive {blocking_push_worker, Pid} -> Pid
                     after 1000 -> error(blocking_push_timeout) end,
        Monitor = erlang:monitor(process, PushWorker),
        {ok, #{}} = adk_a2a_v1_server:delete_push_config(
                      Server, scope(<<"alice">>),
                      #{<<"taskId">> => TaskId, <<"id">> => ConfigId}),
        receive
            {'DOWN', Monitor, process, PushWorker, killed} -> ok
        after 1000 -> error(orphaned_push_worker)
        end
    after
        Worker ! finish,
        gen_server:stop(Server)
    end.

server_owner_death_cancels_inflight_delivery() ->
    Parent = self(),
    Transport = fun(_Job, _Policy) ->
        Parent ! {owner_death_push_worker, self()},
        receive never -> ok end
    end,
    {Server, Worker, Emit, TaskId} = start_push_server(Transport),
    try
        {ok, _} = adk_a2a_v1_server:create_push_config(
                    Server, scope(<<"alice">>),
                    (push_config(<<"https://hooks.example.test/a2a">>))#{
                      <<"taskId">> => TaskId}),
        ok = Emit({status, <<"TASK_STATE_WORKING">>, <<"blocking">>}),
        PushWorker = receive {owner_death_push_worker, Pid} -> Pid
                     after 1000 -> error(owner_death_push_timeout) end,
        unlink(Server),
        ServerMonitor = erlang:monitor(process, Server),
        PushMonitor = erlang:monitor(process, PushWorker),
        exit(Server, kill),
        receive
            {'DOWN', ServerMonitor, process, Server, killed} -> ok
        after 1000 -> error(server_owner_death_timeout)
        end,
        receive
            {'DOWN', PushMonitor, process, PushWorker, killed} -> ok
        after 1000 -> error(orphaned_push_worker_after_owner_death)
        end
    after
        Worker ! finish,
        case is_process_alive(Server) of
            true -> _ = catch gen_server:stop(Server);
            false -> ok
        end
    end.

extended_card_requires_declared_capability_and_configuration() ->
    {ok, Public} = adk_a2a_v1_card:new(
                     #{url => <<"https://agent.example.test/a2a/v1">>,
                       extended_agent_card => true,
                       skills => [skill(<<"public">>)]}),
    {ok, Extended} = adk_a2a_v1_card:new(
                       #{url => <<"https://agent.example.test/a2a/v1">>,
                         extended_agent_card => true,
                         skills => [skill(<<"public">>),
                                    skill(<<"private">>)]}),
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined, card => Public,
                       extended_card => Extended,
                       executor => fun(_Request, _Emit) -> ok end}),
    try
        ?assertEqual({ok, Extended},
                     adk_a2a_v1_server:extended_card(
                       Server, scope(<<"alice">>))),
        {ok, Rpc} = adk_a2a_v1_rpc:dispatch(
                      Server, auth(<<"alice">>), 7,
                      <<"GetExtendedAgentCard">>, #{}),
        ?assertEqual(Extended, maps:get(<<"result">>, Rpc))
    after gen_server:stop(Server) end,
    {ok, MissingServer} = adk_a2a_v1_server:start_link(
                            #{name => undefined, card => Public,
                              executor => fun(_Request, _Emit) -> ok end}),
    try
        ?assertEqual(
           {error, extended_agent_card_not_configured},
           adk_a2a_v1_server:extended_card(
             MissingServer, scope(<<"alice">>)))
    after gen_server:stop(MissingServer) end.

start_push_server(Transport) ->
    Parent = self(),
    Executor = fun(_Request, Emit) ->
        Parent ! {push_executor, self(), Emit},
        receive finish -> {ok, <<"done">>} end
    end,
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<"https://agent.example.test/a2a/v1">>,
                     push_notifications => true}),
    {ok, Server} = adk_a2a_v1_server:start_link(
                     #{name => undefined, card => Card, executor => Executor,
                       task_timeout => 5000,
                       push_policy =>
                           #{transport => Transport,
                             retry_base_ms => 0,
                             allowed_hosts =>
                                 [<<"hooks.example.test">>]}}),
    {ok, #{task_id := TaskId}} = adk_a2a_v1_server:send_message(
                                  Server, auth(<<"alice">>),
                                  send_params(<<"push">>)),
    {Worker, Emit} = receive {push_executor, Pid, EmitFun} -> {Pid, EmitFun}
                     after 1000 -> error(push_executor_timeout) end,
    {Server, Worker, Emit, TaskId}.

push_config(Url) ->
    #{<<"url">> => Url}.

status_payload(TaskId) ->
    #{<<"statusUpdate">> =>
          #{<<"taskId">> => TaskId,
            <<"contextId">> => <<"context">>,
            <<"status">> =>
                #{<<"state">> => <<"TASK_STATE_WORKING">>,
                  <<"timestamp">> => <<"2026-08-19T00:00:00.000Z">>}}}.

payload_kind(#{<<"statusUpdate">> := _}) -> status_payload_kind;
payload_kind(_) -> other.

skill(Id) ->
    #{<<"id">> => Id, <<"name">> => Id,
      <<"description">> => <<"test skill">>, <<"tags">> => [<<"test">>]}.

auth(Id) ->
    #{principal => #{subject => Id}, scope => scope(Id), secret_seeds => []}.

scope(Id) -> adk_a2a_v1_auth:scope(Id).

send_params(Text) ->
    #{<<"message">> =>
          #{<<"messageId">> => unique(<<"message-">>),
            <<"role">> => <<"ROLE_USER">>,
            <<"parts">> => [#{<<"text">> => Text}]},
      <<"configuration">> => #{<<"returnImmediately">> => true}}.

unique(Prefix) ->
    <<Prefix/binary,
      (integer_to_binary(
         erlang:unique_integer([positive, monotonic])))/binary>>.

receive_push_http_request(Path) ->
    receive
        {a2a_push_http_request, Path, Attempt, Headers, Body} ->
            {Attempt, Headers, Body}
    after 1000 -> error(push_http_request_timeout)
    end.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {active, false},
                                      {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.
