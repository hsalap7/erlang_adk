-module(adk_dev_eval_http_test).

-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, adk_dev_eval_http_test_listener).
-define(TOKEN, <<"0123456789abcdef-evaluation-token">>).

developer_evaluation_http_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(State) ->
         ?_test(durable_authoring_history_and_baseline(State))
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Name = <<"DevHttpEvalAgent",
             (integer_to_binary(
                erlang:unique_integer([positive])))/binary>>,
    {ok, Agent} = erlang_adk:spawn_agent(
                    Name,
                    #{provider => adk_eval_agent_test_provider,
                      mode => response}, []),
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    {ok, Service} = adk_eval_service:start_link(
                      #{store => {adk_eval_store_ets, Store},
                        max_concurrency => 1, max_queue => 4,
                        task_timeout_ms => 3000,
                        task_retention_ms => 100}),
    unlink(Service),
    Scope = {app, <<"developer-eval-http">>},
    Config = #{auth_token => ?TOKEN,
               session_service => erlang_adk_session,
               runner_options => #{}, run_options => #{},
               evaluation_service => Service,
               evaluation_scope => Scope,
               max_body_bytes => 65536,
               max_field_bytes => 512,
               max_resource_results => 10},
    {ok, _} = cowboy:start_clear(
                ?LISTENER, [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    #{port => ranch:get_port(?LISTENER), name => Name, agent => Agent,
      store => Store, service => Service, scope => Scope}.

cleanup(State) ->
    _ = cowboy:stop_listener(?LISTENER),
    _ = catch adk_eval_service:stop(maps:get(service, State)),
    _ = catch adk_eval_store_ets:stop(maps:get(store, State)),
    _ = catch erlang_adk:stop_agent(maps:get(agent, State)),
    ok.

durable_authoring_history_and_baseline(State) ->
    Path = <<"/dev/v1/evaluation/jobs">>,
    {200, _, UiBody} = request(State, get, <<"/dev">>, [], <<>>),
    ?assertNotEqual(nomatch,
                    binary:match(UiBody, <<"Submit evaluation">>)),
    ?assertNotEqual(nomatch,
                    binary:match(UiBody, <<"Refresh history">>)),
    {401, _, _} = request(State, get, Path, [], <<>>),
    Payload = authoring_payload(maps:get(name, State)),
    {202, Headers, SubmittedBody} = request(
                                      State, post, Path, json_headers(),
                                      jsx:encode(Payload)),
    Submitted = jsx:decode(SubmittedBody, [return_maps]),
    JobId = maps:get(<<"job_id">>, Submitted),
    ?assertEqual(
       <<"/dev/v1/evaluation/jobs/", JobId/binary>>,
       proplists:get_value(<<"location">>, Headers)),
    {ok, Completed} = await(
                        maps:get(service, State), maps:get(scope, State),
                        JobId, 3000),
    ?assertEqual(completed, maps:get(phase, Completed)),

    JobPath = <<Path/binary, "/", JobId/binary>>,
    {200, _, JobBody} = request(State, get, JobPath, auth_headers(), <<>>),
    ?assertEqual(<<"completed">>,
                 maps:get(<<"phase">>, decode(JobBody))),
    {200, _, ResultBody} = request(
                             State, get,
                             <<JobPath/binary, "/result">>,
                             auth_headers(), <<>>),
    ?assertEqual(true, maps:get(<<"passed">>, decode(ResultBody))),
    {200, _, HistoryBody} = request(
                              State, get, <<Path/binary, "?limit=10">>,
                              auth_headers(), <<>>),
    ?assertEqual(1, length(maps:get(<<"items">>, decode(HistoryBody)))),
    {200, _, SetBody} = request(
                          State, get,
                          <<"/dev/v1/evaluation/sets/ui-suite/1">>,
                          auth_headers(), <<>>),
    ?assertEqual(<<"ui-suite">>, maps:get(<<"id">>, decode(SetBody))),

    BaselinePath = <<"/dev/v1/evaluation/baselines/main">>,
    {200, _, _} = request(
                    State, put, BaselinePath, json_headers(),
                    jsx:encode(#{<<"job_id">> => JobId})),
    {200, _, BaselineBody} = request(
                               State, get, BaselinePath,
                               auth_headers(), <<>>),
    ?assertEqual(JobId, maps:get(<<"job_id">>, decode(BaselineBody))),

    Unsafe = Payload#{<<"adapter_module">> => <<"unsafe">>},
    {400, _, ErrorBody} = request(
                            State, post, Path, json_headers(),
                            jsx:encode(Unsafe)),
    ?assertEqual(<<"invalid_evaluation_authoring_request">>,
                 error_code(ErrorBody)).

authoring_payload(Name) ->
    #{<<"agent_name">> => Name,
      <<"set">> =>
          #{<<"schema_version">> => 2,
            <<"id">> => <<"ui-suite">>,
            <<"version">> => <<"1">>,
            <<"cases">> =>
                [#{<<"id">> => <<"case-1">>,
                   <<"turns">> =>
                       [#{<<"input">> => <<"evaluate">>,
                          <<"expected">> => <<"evaluated">>}]}],
            <<"metadata">> => #{}},
      <<"metrics">> =>
          [#{<<"id">> => <<"semantic">>,
             <<"metric">> => <<"semantic_quality">>,
             <<"threshold">> => 1.0,
             <<"scope">> => <<"turn">>,
             <<"config">> =>
                 #{<<"algorithm">> => <<"exact_normalized">>}}]}.

await(Service, Scope, JobId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await(Service, Scope, JobId, Deadline, poll).

await(Service, Scope, JobId, Deadline, poll) ->
    case adk_eval_service:status(Service, Scope, JobId) of
        {ok, #{phase := Phase} = Status}
          when Phase =:= completed; Phase =:= failed;
               Phase =:= timed_out; Phase =:= cancelled ->
            {ok, Status};
        {ok, _} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    receive after 10 -> ok end,
                    await(Service, Scope, JobId, Deadline, poll);
                false -> {error, timeout}
            end;
        {error, _} = Error -> Error
    end.

request(#{port := Port}, Method, Path, Headers, Body) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn, 2000),
    Ref = case Method of
        get -> gun:get(Conn, Path, Headers);
        post -> gun:post(Conn, Path, Headers, Body);
        put -> gun:put(Conn, Path, Headers, Body)
    end,
    try
        case gun:await(Conn, Ref, 3000) of
            {response, fin, Status, ResponseHeaders} ->
                {Status, ResponseHeaders, <<>>};
            {response, nofin, Status, ResponseHeaders} ->
                {ok, ResponseBody} = gun:await_body(Conn, Ref, 3000),
                {Status, ResponseHeaders, ResponseBody}
        end
    after
        gun:close(Conn)
    end.

auth_headers() ->
    [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}].

json_headers() ->
    [{<<"content-type">>, <<"application/json">>} | auth_headers()].

decode(Body) -> jsx:decode(Body, [return_maps]).

error_code(Body) ->
    maps:get(<<"code">>, maps:get(<<"error">>, decode(Body))).
