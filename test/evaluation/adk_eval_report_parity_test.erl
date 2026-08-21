-module(adk_eval_report_parity_test).

-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, adk_eval_report_parity_test_listener).
-define(BOUNDARY_LISTENER, adk_eval_report_boundary_test_listener).
-define(REJECT_LISTENER, adk_eval_report_reject_test_listener).
-define(TOKEN, <<"evaluation-report-parity-token-0123456789">>).
-define(GENERIC_RESPONSE_MAX_BYTES, 1048576).
-define(REPORT_HARD_MAX_BYTES, 16777216).

stored_report_cli_api_parity_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(State) ->
         [{"all stored report formats are byte-identical",
           ?_test(format_parity(State))},
          {"large reports share default and configured byte boundaries",
           ?_test(large_report_parity(State))},
          {"stored report failures retain exact boundaries",
           ?_test(error_parity(State))}]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    {ok, Store} = adk_eval_store_ets:start_link(#{}),
    unlink(Store),
    Scope = {app, <<"report-parity">>},
    Set = eval_set(),
    Result = eval_result(Set),
    JobId = <<"completed-report-job">>,
    {ok, _} = adk_eval_store_ets:create_evaluation(
                Store, Scope, Set, job(JobId)),
    {ok, _} = adk_eval_store_ets:transition_job(
                Store, Scope, JobId, [queued], running,
                #{started_at => 1}),
    {ok, _} = adk_eval_store_ets:transition_job(
                Store, Scope, JobId, [running], completed,
                #{result => Result, finished_at => 2}),
    LargeResult = large_eval_result(Result),
    LargeJobId = <<"large-completed-report-job">>,
    {ok, _} = adk_eval_store_ets:create_evaluation(
                Store, Scope, Set, job(LargeJobId)),
    {ok, _} = adk_eval_store_ets:transition_job(
                Store, Scope, LargeJobId, [queued], running,
                #{started_at => 3}),
    {ok, _} = adk_eval_store_ets:transition_job(
                Store, Scope, LargeJobId, [running], completed,
                #{result => LargeResult, finished_at => 4}),
    {ok, Service} = adk_eval_service:start_link(
                      #{store => {adk_eval_store_ets, Store},
                        max_concurrency => 1, max_queue => 4,
                        task_timeout_ms => 3000,
                        task_retention_ms => 100}),
    unlink(Service),
    PendingId = <<"pending-report-job">>,
    {ok, _} = adk_eval_store_ets:create_evaluation(
                Store, Scope, Set, job(PendingId)),
    Config = #{auth_token => ?TOKEN,
               session_service => erlang_adk_session,
               runner_options => #{}, run_options => #{},
               evaluation_service => Service,
               evaluation_scope => Scope,
               %% Request parsing remains independently capped at 64 KiB.
               %% The report response uses its own validated default.
               max_body_bytes => 65536,
               max_field_bytes => 512,
               max_resource_results => 10},
    {ok, _} = cowboy:start_clear(
                ?LISTENER, [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    OldToken = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    true = os:putenv("ERLANG_ADK_DEV_TOKEN", binary_to_list(?TOKEN)),
    #{port => ranch:get_port(?LISTENER), store => Store,
      service => Service, scope => Scope, job_id => JobId,
      large_job_id => LargeJobId, pending_id => PendingId,
      old_token => OldToken}.

cleanup(State) ->
    restore_env("ERLANG_ADK_DEV_TOKEN", maps:get(old_token, State)),
    _ = cowboy:stop_listener(?LISTENER),
    _ = catch adk_eval_service:stop(maps:get(service, State)),
    _ = catch adk_eval_store_ets:stop(maps:get(store, State)),
    ok.

format_parity(State) ->
    Formats =
        [{<<"json">>, "json", #{}, <<>>,
          <<"application/json; charset=utf-8">>},
         {<<"markdown">>, "markdown", #{}, <<>>,
          <<"text/markdown; charset=utf-8">>},
         {<<"junit">>, "junit",
          #{<<"suite_name">> => <<"parity&suite">>},
          <<"&suite_name=parity%26suite">>,
          <<"application/xml; charset=utf-8">>},
         {<<"sarif">>, "sarif", #{}, <<>>,
          <<"application/json; charset=utf-8">>},
         {<<"annotations">>, "annotations", #{}, <<>>,
          <<"application/json; charset=utf-8">>}],
    lists:foreach(
      fun({Format, CliFormat, ExtraOptions, ExtraQuery, ContentType}) ->
          Options = ExtraOptions#{<<"max_output_bytes">> => 1048576},
          {ok, Canonical1} = adk_eval_dev_api:report(
                               maps:get(service, State),
                               maps:get(scope, State),
                               maps:get(job_id, State), Format, Options),
          {ok, Canonical2} = adk_eval_dev_api:report(
                               maps:get(service, State),
                               maps:get(scope, State),
                               maps:get(job_id, State), Format, Options),
          ?assertEqual(Canonical1, Canonical2),
          Path = report_path(maps:get(job_id, State), Format, ExtraQuery),
          {200, Headers, ApiBody} = request(State, get, Path),
          ?assertEqual(ContentType,
                       proplists:get_value(<<"content-type">>, Headers)),
          ?assertEqual(Canonical1, ApiBody),
          Args0 = ["eval", "report", binary_to_list(maps:get(job_id, State)),
                   "--url", base_url(State), "--format", CliFormat],
          Args = case Format of
              <<"junit">> -> Args0 ++ ["--suite-name", "parity&suite"];
              _ -> Args0
          end,
          {ok, Cli} = adk_cli:command(Args),
          ?assertEqual(eval_report, maps:get(command, Cli)),
          ?assertEqual(stdout, maps:get(delivery, Cli)),
          ?assertEqual(Canonical1, maps:get(report, Cli))
      end, Formats),
    assert_file_delivery(State).

large_report_parity(State) ->
    Service = maps:get(service, State),
    Scope = maps:get(scope, State),
    JobId = maps:get(large_job_id, State),
    {ok, Expected} = adk_eval_dev_api:report(
                       Service, Scope, JobId, <<"json">>, #{}),
    Size = byte_size(Expected),
    ?assert(Size > ?GENERIC_RESPONSE_MAX_BYTES),
    ?assert(Size =< ?REPORT_HARD_MAX_BYTES),

    %% The default authenticated endpoint and the report-specific CLI receiver
    %% both accept bytes that unrelated Developer CLI calls still cap at 1 MiB.
    Path = report_path(JobId, <<"json">>, <<>>),
    {200, _, DefaultBody} = request(State, get, Path),
    ?assertEqual(Expected, DefaultBody),
    {ok, Stdout} = adk_cli:command(
                     ["eval", "report", binary_to_list(JobId),
                      "--url", base_url(State), "--format", "json"]),
    ?assertEqual(stdout, maps:get(delivery, Stdout)),
    ?assertEqual(Expected, maps:get(report, Stdout)),
    assert_large_file_delivery(State, Expected),

    %% Exact-size preflight and streamed collection are inclusive. A listener
    %% configured one byte lower rejects the same stored result before reply.
    ?assertEqual(
       {ok, Expected},
       adk_eval_dev_api:report(
         Service, Scope, JobId, <<"json">>,
         #{<<"max_output_bytes">> => Size})),
    ?assertEqual(
       {error, {eval_dev_view, output_limit_exceeded}},
       adk_eval_dev_api:report(
         Service, Scope, JobId, <<"json">>,
         #{<<"max_output_bytes">> => Size - 1})),
    with_report_listener(
      ?BOUNDARY_LISTENER, State, Size,
      fun(BoundaryState) ->
          {200, _, BoundaryBody} = request(BoundaryState, get, Path),
          ?assertEqual(Expected, BoundaryBody),
          {ok, BoundaryCli} = adk_cli:command(
                                ["eval", "report", binary_to_list(JobId),
                                 "--url", base_url(BoundaryState)]),
          ?assertEqual(Expected, maps:get(report, BoundaryCli))
      end),
    with_report_listener(
      ?REJECT_LISTENER, State, Size - 1,
      fun(RejectState) ->
          {400, _, ApiErrorBody} = request(RejectState, get, Path),
          ApiError = jsx:decode(ApiErrorBody, [return_maps]),
          ?assertEqual(<<"invalid_evaluation_report">>,
                       error_code(ApiErrorBody)),
          ?assert(byte_size(ApiErrorBody) < 1024),
          ?assertEqual(
             {error, {developer_api_http_error, 400, ApiError}},
             adk_cli:command(
               ["eval", "report", binary_to_list(JobId),
                "--url", base_url(RejectState)]))
      end),
    ?assertEqual(
       {error, invalid_dev_platform_config},
       adk_dev_router:validate_config(
         report_listener_config(
           State, ?REPORT_HARD_MAX_BYTES + 1))).

assert_file_delivery(State) ->
    Path = temp_path(),
    try
        {ok, Expected} = adk_eval_dev_api:report(
                           maps:get(service, State), maps:get(scope, State),
                           maps:get(job_id, State), <<"json">>,
                           #{<<"max_output_bytes">> => 1048576}),
        {ok, Cli} = adk_cli:command(
                      ["eval", "report",
                       binary_to_list(maps:get(job_id, State)),
                       "--url", base_url(State), "--format", "json",
                       "--output", Path]),
        ?assertEqual(file, maps:get(delivery, Cli)),
        ?assertEqual(Expected, maps:get(report, Cli)),
        ?assertEqual({ok, Expected}, file:read_file(Path))
    after
        _ = file:delete(Path)
    end.

assert_large_file_delivery(State, Expected) ->
    Path = temp_path(),
    try
        {ok, Cli} = adk_cli:command(
                      ["eval", "report",
                       binary_to_list(maps:get(large_job_id, State)),
                       "--url", base_url(State), "--format", "json",
                       "--output", Path]),
        ?assertEqual(file, maps:get(delivery, Cli)),
        ?assertEqual(Expected, maps:get(report, Cli)),
        ?assertEqual({ok, Expected}, file:read_file(Path))
    after
        _ = file:delete(Path)
    end.

error_parity(State) ->
    Service = maps:get(service, State),
    Scope = maps:get(scope, State),
    JobId = maps:get(job_id, State),
    PendingId = maps:get(pending_id, State),
    ?assertEqual(
       {error, {eval_dev_view, invalid_format}},
       adk_eval_dev_api:report(Service, Scope, JobId, <<"yaml">>, #{})),
    ?assertEqual(
       {error, {eval_dev_view, invalid_options}},
       adk_eval_dev_api:report(
         Service, Scope, JobId, <<"json">>, #{<<"unknown">> => true})),
    ?assertEqual(
       {error, {eval_dev_view, output_limit_exceeded}},
       adk_eval_dev_api:report(
         Service, Scope, JobId, <<"json">>,
         #{<<"max_output_bytes">> => 1})),
    ?assertEqual(
       {error, result_not_ready},
       adk_eval_dev_api:report(Service, Scope, PendingId, <<"json">>, #{})),
    ?assertEqual(
       {error, not_found},
       adk_eval_dev_api:report(
         Service, Scope, <<"missing-report-job">>, <<"json">>, #{})),

    {400, _, InvalidFormat} = request(
                                State, get,
                                report_path(JobId, <<"yaml">>, <<>>)),
    ?assertEqual(<<"invalid_evaluation_report">>, error_code(InvalidFormat)),
    {400, _, InvalidQuery} = request(
                               State, get,
                               <<(report_path(JobId, <<"json">>, <<>>))/binary,
                                 "&unknown=true">>),
    ?assertEqual(<<"invalid_evaluation_query">>, error_code(InvalidQuery)),
    {409, _, Pending} = request(
                          State, get,
                          report_path(PendingId, <<"json">>, <<>>)),
    ?assertEqual(<<"evaluation_result_not_ready">>, error_code(Pending)),
    {404, _, Missing} = request(
                          State, get,
                          report_path(<<"missing-report-job">>,
                                      <<"json">>, <<>>)),
    ?assertEqual(<<"evaluation_resource_not_found">>, error_code(Missing)),
    {405, _, Method} = request(
                         State, post,
                         report_path(JobId, <<"json">>, <<>>)),
    ?assertEqual(<<"method_not_allowed">>, error_code(Method)),

    ?assertEqual(
       {error, invalid_eval_report_format},
       adk_cli:command(
         ["eval", "report", binary_to_list(JobId),
          "--url", base_url(State), "--format", "yaml"])),
    ?assertEqual(
       {error, invalid_eval_suite_name},
       adk_cli:command(
         ["eval", "report", binary_to_list(JobId),
          "--url", base_url(State), "--suite-name", ""])),
    ?assertMatch(
       {error, {developer_api_http_error, 404, _}},
       adk_cli:command(
         ["eval", "report", "missing-report-job",
          "--url", base_url(State)])),
    ?assertEqual(
       {error, invalid_eval_job_id},
       adk_cli:command(
         ["eval", "report", "", "--url", base_url(State)])).

eval_set() ->
    {ok, Set} = adk_eval_set:new(
                  <<"report-parity-suite">>, <<"1">>,
                  [#{id => <<"case-1">>, input => <<"actual">>,
                     expected => <<"expected">>}]),
    Set.

eval_result(Set) ->
    Adapter = #{module => adk_eval_set_test_adapter,
                target => ignored, config => #{mode => stateful}},
    {ok, Result} = adk_eval_set:run(
                     Adapter, Set,
                     [#{id => <<"response">>,
                        criterion => exact_response}], #{}),
    Result.

large_eval_result(Result) ->
    Metadata = #{<<"chunk-a">> => binary:copy(<<"a">>, 700000),
                 <<"chunk-b">> => binary:copy(<<"b">>, 700000)},
    {ok, LargeResult} = adk_eval_set:decode_result(
                          Result#{<<"metadata">> => Metadata}),
    LargeResult.

job(JobId) ->
    #{job_id => JobId,
      eval_set_id => <<"report-parity-suite">>,
      eval_set_version => <<"1">>, metadata => #{}}.

report_path(JobId, Format, ExtraQuery) ->
    <<"/dev/v1/evaluation/jobs/", JobId/binary,
      "/report?format=", Format/binary, ExtraQuery/binary>>.

request(#{port := Port}, Method, Path) ->
    {ok, Connection} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Connection, 2000),
    Headers = [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
    Stream = case Method of
        get -> gun:get(Connection, Path, Headers);
        post -> gun:post(Connection, Path, Headers, <<>>)
    end,
    try
        case gun:await(Connection, Stream, 3000) of
            {response, fin, Status, ResponseHeaders} ->
                {Status, ResponseHeaders, <<>>};
            {response, nofin, Status, ResponseHeaders} ->
                {ok, Body} = gun:await_body(Connection, Stream, 3000),
                {Status, ResponseHeaders, Body}
        end
    after
        gun:close(Connection)
    end.

with_report_listener(Name, State, Limit, Fun) ->
    Config = report_listener_config(State, Limit),
    {ok, _} = cowboy:start_clear(
                Name, [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    ListenerState = State#{port => ranch:get_port(Name)},
    try Fun(ListenerState)
    after
        _ = cowboy:stop_listener(Name)
    end.

report_listener_config(State, Limit) ->
    #{auth_token => ?TOKEN,
      session_service => erlang_adk_session,
      runner_options => #{}, run_options => #{},
      evaluation_service => maps:get(service, State),
      evaluation_scope => maps:get(scope, State),
      max_body_bytes => 65536,
      max_field_bytes => 512,
      max_resource_results => 10,
      evaluation_report_max_bytes => Limit}.

base_url(#{port := Port}) ->
    "http://127.0.0.1:" ++ integer_to_list(Port).

error_code(Body) ->
    Payload = jsx:decode(Body, [return_maps]),
    maps:get(<<"code">>, maps:get(<<"error">>, Payload)).

temp_path() ->
    filename:join(
      temp_dir(),
      "adk-eval-report-parity-" ++
          integer_to_list(erlang:unique_integer([positive, monotonic])) ++
          ".json").

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).
