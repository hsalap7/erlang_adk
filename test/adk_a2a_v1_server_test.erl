-module(adk_a2a_v1_server_test).
-include_lib("eunit/include/eunit.hrl").

a2a_v1_server_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun lifecycle_history_and_artifact_case/0,
      fun cross_principal_visibility_case/0,
      fun cancellation_stops_execution_case/0,
      fun credentials_are_redacted_case/0,
      fun replay_is_ordered_and_bounded_case/0,
      fun list_tasks_cursor_case/0,
      fun active_admission_is_bounded_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok.

cleanup(_) -> ok.

lifecycle_history_and_artifact_case() ->
    Server = start_server(fun(_Request, _Emit) -> {ok, <<"a poem">>} end),
    try
        {ok, #{task_id := TaskId, task := Initial}} =
            adk_a2a_v1_server:send_message(
              Server, auth(<<"alice">>), send_params(<<"write">>), self()),
        ?assertEqual(<<"TASK_STATE_WORKING">>, task_state(Initial)),
        wait_terminal(TaskId),
        {ok, Task} = adk_a2a_v1_server:get_task(
                       Server, scope(<<"alice">>), #{<<"id">> => TaskId}),
        ?assertEqual(<<"TASK_STATE_COMPLETED">>, task_state(Task)),
        [Input] = maps:get(<<"history">>, Task),
        ?assertEqual(TaskId, maps:get(<<"taskId">>, Input)),
        ?assertEqual(maps:get(<<"contextId">>, Task),
                     maps:get(<<"contextId">>, Input)),
        [#{<<"parts">> := [#{<<"text">> := <<"a poem">>}]}] =
            maps:get(<<"artifacts">>, Task)
    after
        gen_server:stop(Server)
    end.

cross_principal_visibility_case() ->
    Server = start_server(fun(_Request, _Emit) -> timer:sleep(30), ok end),
    try
        {ok, #{task_id := TaskId}} = adk_a2a_v1_server:send_message(
                                      Server, auth(<<"alice">>),
                                      send_params(<<"private">>)),
        ?assertEqual(
           {error, task_not_found},
           adk_a2a_v1_server:get_task(
             Server, scope(<<"bob">>), #{<<"id">> => TaskId})),
        {ok, #{<<"tasks">> := []}} = adk_a2a_v1_server:list_tasks(
                                          Server, scope(<<"bob">>), #{}),
        ?assertEqual(
           {error, task_not_found},
           adk_a2a_v1_server:cancel_task(
             Server, scope(<<"bob">>), #{<<"id">> => TaskId}))
    after
        gen_server:stop(Server)
    end.

cancellation_stops_execution_case() ->
    Parent = self(),
    Executor = fun(_Request, _Emit) ->
        Parent ! {a2a_execution, self()},
        receive never -> impossible end
    end,
    Server = start_server(Executor),
    try
        {ok, #{task_id := TaskId}} = adk_a2a_v1_server:send_message(
                                      Server, auth(<<"alice">>),
                                      send_params(<<"block">>), self()),
        Execution = receive {a2a_execution, Pid} -> Pid after 1000 -> error(timeout) end,
        Ref = erlang:monitor(process, Execution),
        {ok, Canceled} = adk_a2a_v1_server:cancel_task(
                           Server, scope(<<"alice">>),
                           #{<<"id">> => TaskId}),
        ?assertEqual(<<"TASK_STATE_CANCELED">>, task_state(Canceled)),
        receive {'DOWN', Ref, process, Execution, killed} -> ok
        after 1000 -> ?assert(false)
        end,
        ?assertEqual(
           {error, task_not_cancelable},
           adk_a2a_v1_server:cancel_task(
             Server, scope(<<"alice">>), #{<<"id">> => TaskId}))
    after
        gen_server:stop(Server)
    end.

credentials_are_redacted_case() ->
    Secret = <<"credential-value-123">>,
    Executor = fun(#{principal := Principal}, _Emit) ->
        #{<<"access_token">> => Secret,
          <<"echo">> => maps:get(token, Principal)}
    end,
    Server = start_server(Executor),
    Auth = #{principal => #{subject => <<"alice">>, token => Secret},
             scope => scope(<<"alice">>), secret_seeds => [Secret]},
    try
        {ok, #{task_id := TaskId}} = adk_a2a_v1_server:send_message(
                                      Server, Auth, send_params(<<"secret">>),
                                      self()),
        wait_terminal(TaskId),
        {ok, Task} = adk_a2a_v1_server:inspect_task(Server, TaskId),
        Encoded = jsx:encode(Task),
        ?assertEqual(nomatch, binary:match(Encoded, Secret)),
        ?assertNotEqual(nomatch, binary:match(Encoded, <<"[REDACTED]">>))
    after
        gen_server:stop(Server)
    end.

replay_is_ordered_and_bounded_case() ->
    Parent = self(),
    Executor = fun(_Request, Emit) ->
        ok = Emit({artifact, artifact(<<"first">>), false, false}),
        Parent ! {progress_written, self()},
        receive continue -> ok end,
        {ok, <<"done">>}
    end,
    Server = start_server(Executor),
    try
        {ok, #{task_id := TaskId}} = adk_a2a_v1_server:send_message(
                                      Server, auth(<<"alice">>),
                                      send_params(<<"stream">>)),
        Worker = receive {progress_written, Pid} -> Pid
                 after 1000 -> error(timeout) end,
        {ok, TaskId, Frames} = adk_a2a_v1_server:subscribe(
                                Server, scope(<<"alice">>),
                                #{<<"id">> => TaskId,
                                  last_event_id => 0}, self()),
        [{0, #{<<"task">> := _}} | Rest] = Frames,
        Sequences = [Seq || {Seq, _} <- Rest],
        ?assertEqual(Sequences, lists:usort(Sequences)),
        ?assert(lists:any(fun({_Seq, P}) ->
                              maps:is_key(<<"artifactUpdate">>, P)
                          end, Rest)),
        Worker ! continue,
        TerminalSeq = receive
            {adk_a2a_v1_event, TaskId, Seq, _Payload, true} -> Seq
        after 1000 -> error(timeout)
        end,
        ?assert(TerminalSeq > lists:last(Sequences))
    after
        gen_server:stop(Server)
    end.

list_tasks_cursor_case() ->
    Server = start_server(fun(_Request, _Emit) -> ok end),
    try
        {ok, #{task_id := First}} = adk_a2a_v1_server:send_message(
                                     Server, auth(<<"alice">>),
                                     send_params(<<"one">>), self()),
        wait_terminal(First),
        timer:sleep(2),
        {ok, #{task_id := Second}} = adk_a2a_v1_server:send_message(
                                      Server, auth(<<"alice">>),
                                      send_params(<<"two">>), self()),
        wait_terminal(Second),
        {ok, Page1} = adk_a2a_v1_server:list_tasks(
                        Server, scope(<<"alice">>),
                        #{<<"pageSize">> => 1}),
        [#{<<"id">> := Second}] = maps:get(<<"tasks">>, Page1),
        Token = maps:get(<<"nextPageToken">>, Page1),
        ?assert(byte_size(Token) > 0),
        {ok, Page2} = adk_a2a_v1_server:list_tasks(
                        Server, scope(<<"alice">>),
                        #{<<"pageSize">> => 1,
                          <<"pageToken">> => Token}),
        [#{<<"id">> := First}] = maps:get(<<"tasks">>, Page2),
        ?assertEqual(<<>>, maps:get(<<"nextPageToken">>, Page2)),
        ?assertEqual(2, maps:get(<<"totalSize">>, Page2)),
        ?assertEqual(false,
                     maps:is_key(<<"artifacts">>,
                                 hd(maps:get(<<"tasks">>, Page2))))
    after
        gen_server:stop(Server)
    end.

active_admission_is_bounded_case() ->
    Parent = self(),
    Executor = fun(_Request, _Emit) ->
        Parent ! {capacity_worker, self()},
        receive stop -> ok end
    end,
    Server = start_server(Executor, #{max_active => 1}),
    try
        {ok, #{task_id := TaskId}} = adk_a2a_v1_server:send_message(
                                      Server, auth(<<"alice">>),
                                      send_params(<<"one">>)),
        Worker = receive {capacity_worker, Pid} -> Pid
                 after 1000 -> error(timeout) end,
        ?assertEqual(
           {error, server_capacity_reached},
           adk_a2a_v1_server:send_message(
             Server, auth(<<"alice">>), send_params(<<"two">>))),
        Worker ! stop,
        wait_until_terminal(Server, TaskId)
    after
        gen_server:stop(Server)
    end.

start_server(Executor) -> start_server(Executor, #{}).
start_server(Executor, Extra) ->
    Options = maps:merge(
                #{name => undefined, card => card(), executor => Executor,
                  task_timeout => 2000, retention_ms => 5000,
                  max_tasks => 20, max_active => 10,
                  max_events => 32, max_subscribers_per_task => 8}, Extra),
    {ok, Server} = adk_a2a_v1_server:start_link(Options),
    Server.

card() ->
    {ok, Card} = adk_a2a_v1_card:new(
                   #{url => <<"http://127.0.0.1:1/a2a/v1">>,
                     name => <<"Test">>, description => <<"Test agent">>}),
    Card.

auth(Id) ->
    #{principal => #{subject => Id}, scope => scope(Id), secret_seeds => []}.

scope(Id) -> adk_a2a_v1_auth:scope(Id).

send_params(Text) ->
    #{<<"message">> =>
          #{<<"messageId">> => unique(<<"message-">>),
            <<"role">> => <<"ROLE_USER">>,
            <<"parts">> => [#{<<"text">> => Text}]},
      <<"configuration">> => #{<<"returnImmediately">> => true}}.

artifact(Text) ->
    #{<<"artifactId">> => unique(<<"artifact-">>),
      <<"parts">> => [#{<<"text">> => Text}]}.

unique(Prefix) ->
    <<Prefix/binary, (integer_to_binary(
                        erlang:unique_integer([positive, monotonic])))/binary>>.

task_state(Task) ->
    maps:get(<<"state">>, maps:get(<<"status">>, Task)).

wait_terminal(TaskId) ->
    receive
        {adk_a2a_v1_event, TaskId, _Seq, _Payload, true} -> ok;
        {adk_a2a_v1_event, TaskId, _Seq, _Payload, false} -> wait_terminal(TaskId)
    after 1000 -> error({terminal_timeout, TaskId})
    end.

wait_until_terminal(Server, TaskId) ->
    case adk_a2a_v1_server:inspect_task(Server, TaskId) of
        {ok, Task} ->
            case adk_a2a_v1_codec:terminal_state(task_state(Task)) of
                true -> ok;
                false -> timer:sleep(5), wait_until_terminal(Server, TaskId)
            end
    end.
