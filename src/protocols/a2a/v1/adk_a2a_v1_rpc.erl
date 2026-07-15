%% @doc JSON-RPC 2.0 method dispatcher for the A2A 1.0 JSON-RPC binding.
-module(adk_a2a_v1_rpc).

-export([dispatch/5, method_type/1, rpc_error/2, task_state/1]).

-spec method_type(binary()) ->
    unary | stream | unsupported_push | unsupported | unknown.
method_type(<<"SendMessage">>) -> unary;
method_type(<<"SendStreamingMessage">>) -> stream;
method_type(<<"GetTask">>) -> unary;
method_type(<<"ListTasks">>) -> unary;
method_type(<<"CancelTask">>) -> unary;
method_type(<<"SubscribeToTask">>) -> stream;
method_type(<<"CreateTaskPushNotificationConfig">>) -> unsupported_push;
method_type(<<"GetTaskPushNotificationConfig">>) -> unsupported_push;
method_type(<<"ListTaskPushNotificationConfigs">>) -> unsupported_push;
method_type(<<"DeleteTaskPushNotificationConfig">>) -> unsupported_push;
method_type(<<"GetExtendedAgentCard">>) -> unsupported;
method_type(_) -> unknown.

-spec dispatch(gen_server:server_ref(), map(), term(), binary(), map()) ->
    {ok, map()} | {error, map()}.
dispatch(Server, Auth, Id, <<"SendMessage">>, Params) ->
    ReturnImmediately = maps:get(
                          <<"returnImmediately">>,
                          maps:get(<<"configuration">>, Params, #{}), false),
    Subscriber = case ReturnImmediately of true -> undefined; false -> self() end,
    case adk_a2a_v1_server:send_message(Server, Auth, Params, Subscriber) of
        {ok, #{task := Task}} when ReturnImmediately ->
            {ok, adk_a2a_v1_codec:result(Id, #{<<"task">> => Task})};
        {ok, #{task_id := TaskId, task := Task}} ->
            wait_send(Server, maps:get(scope, Auth), TaskId, Task, Id);
        {error, {execution_start_failed, _Reason,
                 #{task := FailedTask}}} ->
            {ok, adk_a2a_v1_codec:result(
                   Id, #{<<"task">> => FailedTask})};
        {error, Reason} -> {error, rpc_error(Id, Reason)}
    end;
dispatch(Server, Auth, Id, <<"GetTask">>, Params) ->
    case adk_a2a_v1_server:get_task(Server, maps:get(scope, Auth), Params) of
        {ok, Task} -> {ok, adk_a2a_v1_codec:result(Id, Task)};
        {error, Reason} -> {error, rpc_error(Id, Reason)}
    end;
dispatch(Server, Auth, Id, <<"ListTasks">>, Params) ->
    case adk_a2a_v1_server:list_tasks(Server, maps:get(scope, Auth), Params) of
        {ok, Result} -> {ok, adk_a2a_v1_codec:result(Id, Result)};
        {error, Reason} -> {error, rpc_error(Id, Reason)}
    end;
dispatch(Server, Auth, Id, <<"CancelTask">>, Params) ->
    case adk_a2a_v1_server:cancel_task(Server, maps:get(scope, Auth), Params) of
        {ok, Task} -> {ok, adk_a2a_v1_codec:result(Id, Task)};
        {error, Reason} -> {error, rpc_error(Id, Reason)}
    end;
dispatch(_Server, _Auth, Id, Method, _Params) ->
    case method_type(Method) of
        stream -> {error, rpc_error(Id, stream_method_requires_sse)};
        unsupported_push ->
            {error, rpc_error(Id, push_notification_not_supported)};
        unsupported -> {error, rpc_error(Id, unsupported_operation)};
        unknown ->
            {error, adk_a2a_v1_codec:error_response(
                      Id, -32601, <<"Method not found">>)};
        _ -> {error, rpc_error(Id, invalid_params)}
    end.

wait_send(Server, Scope, TaskId, InitialTask, Id) ->
    case returnable_state(task_state(InitialTask)) of
        true ->
            _ = adk_a2a_v1_server:unsubscribe(Server, TaskId, self()),
            {ok, adk_a2a_v1_codec:result(
                   Id, #{<<"task">> => InitialTask})};
        false ->
            receive
                {adk_a2a_v1_event, TaskId, _Seq, Payload, _Terminal} ->
                    case payload_state(Payload) of
                        State when is_binary(State) ->
                            case returnable_state(State) of
                                true ->
                                    _ = adk_a2a_v1_server:unsubscribe(
                                          Server, TaskId, self()),
                                    final_task(Server, Scope, TaskId, Id);
                                false ->
                                    wait_send(Server, Scope, TaskId,
                                              InitialTask, Id)
                            end;
                        undefined ->
                            wait_send(Server, Scope, TaskId, InitialTask, Id)
                    end
            after 65000 ->
                _ = adk_a2a_v1_server:unsubscribe(Server, TaskId, self()),
                {error, rpc_error(Id, wait_timeout)}
            end
    end.

final_task(Server, Scope, TaskId, Id) ->
    case adk_a2a_v1_server:get_task(
           Server, Scope, #{<<"id">> => TaskId}) of
        {ok, Task} ->
            {ok, adk_a2a_v1_codec:result(Id, #{<<"task">> => Task})};
        {error, Reason} -> {error, rpc_error(Id, Reason)}
    end.

-spec rpc_error(term(), term()) -> map().
rpc_error(Id, task_not_found) ->
    a2a_error(Id, -32001, <<"Task not found">>, <<"TASK_NOT_FOUND">>);
rpc_error(Id, task_not_cancelable) ->
    a2a_error(Id, -32002, <<"Task not cancelable">>,
              <<"TASK_NOT_CANCELABLE">>);
rpc_error(Id, push_notification_not_supported) ->
    a2a_error(Id, -32003, <<"Push notification is not supported">>,
              <<"PUSH_NOTIFICATION_NOT_SUPPORTED">>);
rpc_error(Id, unsupported_operation) ->
    a2a_error(Id, -32004, <<"Unsupported operation">>,
              <<"UNSUPPORTED_OPERATION">>);
rpc_error(Id, {extension_support_required, Missing}) ->
    adk_a2a_v1_codec:error_response(
      Id, -32008, <<"Required A2A extension is not supported">>,
      [#{<<"@type">> => <<"type.googleapis.com/google.rpc.ErrorInfo">>,
         <<"reason">> => <<"EXTENSION_SUPPORT_REQUIRED">>,
         <<"domain">> => <<"a2a-protocol.org">>,
         <<"metadata">> => #{<<"missingExtensions">> => Missing}}]);
rpc_error(Id, unsupported_terminal_subscription) ->
    a2a_error(Id, -32004, <<"Unsupported operation">>,
              <<"UNSUPPORTED_OPERATION">>);
rpc_error(Id, task_not_accepting_messages) ->
    a2a_error(Id, -32004, <<"Unsupported operation">>,
              <<"UNSUPPORTED_OPERATION">>);
rpc_error(Id, server_capacity_reached) ->
    a2a_error(Id, -32004, <<"Server task capacity reached">>,
              <<"UNSUPPORTED_OPERATION">>);
rpc_error(Id, replay_window_exceeded) ->
    a2a_error(Id, -32004, <<"Replay window exceeded">>,
              <<"UNSUPPORTED_OPERATION">>);
rpc_error(Id, subscriber_capacity) ->
    a2a_error(Id, -32004, <<"Subscriber capacity reached">>,
              <<"UNSUPPORTED_OPERATION">>);
rpc_error(Id, stream_method_requires_sse) ->
    a2a_error(Id, -32004, <<"Streaming operation required">>,
              <<"UNSUPPORTED_OPERATION">>);
rpc_error(Id, wait_timeout) ->
    adk_a2a_v1_codec:error_response(Id, -32603, <<"Internal error">>);
rpc_error(Id, server_unavailable) ->
    adk_a2a_v1_codec:error_response(Id, -32603, <<"Internal error">>);
rpc_error(Id, _InvalidParams) ->
    adk_a2a_v1_codec:error_response(Id, -32602, <<"Invalid parameters">>).

a2a_error(Id, Code, Message, Reason) ->
    adk_a2a_v1_codec:error_response(
      Id, Code, Message,
      [#{<<"@type">> => <<"type.googleapis.com/google.rpc.ErrorInfo">>,
         <<"reason">> => Reason,
         <<"domain">> => <<"a2a-protocol.org">>}]).

-spec task_state(map()) -> binary() | undefined.
task_state(#{<<"status">> := #{<<"state">> := State}}) -> State;
task_state(_) -> undefined.

payload_state(#{<<"statusUpdate">> :=
                    #{<<"status">> := #{<<"state">> := State}}}) -> State;
payload_state(#{<<"task">> := Task}) -> task_state(Task);
payload_state(_) -> undefined.

returnable_state(State) ->
    adk_a2a_v1_codec:terminal_state(State) orelse
    adk_a2a_v1_codec:interrupted_state(State).
