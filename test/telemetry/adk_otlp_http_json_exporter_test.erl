-module(adk_otlp_http_json_exporter_test).
-include_lib("eunit/include/eunit.hrl").

bounded_trace_post_test() ->
    Config = config(success_response(),
                    #{headers => #{<<"authorization">> =>
                                       <<"Bearer collector-secret">>}}),
    ok = adk_otlp_http_json_exporter:export(span(), Config),
    Request = receive_request(),
    ?assertEqual(<<"POST">>, maps:get(method, Request)),
    ?assertEqual(<<"https://collector.example:4318/v1/traces">>,
                 maps:get(url, Request)),
    ?assertEqual(false, maps:get(follow_redirects, Request)),
    ?assertEqual([<<"https">>], maps:get(allowed_schemes, Request)),
    ?assertEqual([<<"collector.example">>],
                 maps:get(allowed_hosts, Request)),
    Headers = maps:from_list(maps:get(headers, Request)),
    ?assertEqual(<<"application/json">>,
                 maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"Bearer collector-secret">>,
                 maps:get(<<"authorization">>, Headers)),
    Body = jsx:decode(maps:get(body, Request), [return_maps]),
    ?assert(maps:is_key(<<"resourceSpans">>, Body)).

v1_envelope_uses_logs_path_test() ->
    Config = config(success_response(), #{}),
    ok = adk_otlp_http_json_exporter:export(log_envelope(), Config),
    Request = receive_request(),
    ?assertEqual(<<"https://collector.example:4318/v1/logs">>,
                 maps:get(url, Request)),
    ?assert(maps:is_key(<<"resourceLogs">>,
                       jsx:decode(maps:get(body, Request), [return_maps]))).

retry_classification_is_structural_and_redacted_test() ->
    Secret = <<"collector-secret-must-not-leak">>,
    Response = {ok, #{status => 503,
                      headers => [{<<"retry-after">>, <<"3">>}],
                      body => Secret}},
    Config = config(Response,
                    #{headers => #{<<"authorization">> => Secret}}),
    {error, {otlp_export_failed, Failure}} =
        adk_otlp_http_json_exporter:export(span(), Config),
    ?assertEqual(transient, maps:get(classification, Failure)),
    ?assertEqual(true, maps:get(retryable, Failure)),
    ?assertEqual(http_status, maps:get(reason, Failure)),
    ?assertEqual(503, maps:get(status, Failure)),
    ?assertEqual(3000, maps:get(retry_after_ms, Failure)),
    ?assertEqual(nomatch, binary:match(jsx:encode(Failure), Secret)),
    _ = receive_request().

permanent_status_and_redirect_are_not_followed_test() ->
    Config400 = config({ok, #{status => 400, headers => [],
                              body => <<"private response">>}}, #{}),
    {error, {otlp_export_failed,
             #{classification := permanent, retryable := false,
               reason := http_status, status := 400}}} =
        adk_otlp_http_json_exporter:export(span(), Config400),
    _ = receive_request(),
    Config302 = config({ok, #{status => 302,
                              headers => [{<<"location">>,
                                           <<"https://evil.example">>}],
                              body => <<>>}}, #{}),
    {error, {otlp_export_failed,
             #{classification := permanent, retryable := false,
               status := 302}}} =
        adk_otlp_http_json_exporter:export(span(), Config302),
    Request302 = receive_request(),
    ?assertEqual(false, maps:get(follow_redirects, Request302)).

partial_success_is_permanent_test() ->
    Body = jsx:encode(#{<<"partialSuccess">> =>
                            #{<<"rejectedSpans">> => <<"2">>,
                              <<"errorMessage">> => <<"do not expose me">>}}),
    Config = config({ok, #{status => 200,
                           headers => [{<<"content-type">>,
                                        <<"application/json">>}],
                           body => Body}}, #{}),
    {error, {otlp_export_failed,
             #{classification := permanent, retryable := false,
               reason := partial_success_rejected,
               rejected_items := 2}}} =
        adk_otlp_http_json_exporter:export(span(), Config),
    _ = receive_request().

endpoint_path_header_and_limit_validation_test() ->
    Base = #{transport => adk_otlp_fake_transport,
             transport_handle => #{owner => self(),
                                   response => success_response()}},
    Invalid = [
      Base#{endpoint => <<"ftp://collector.example">>},
      Base#{endpoint => <<"https://user:secret@collector.example">>},
      Base#{endpoint => <<"https://collector.example?token=secret">>},
      Base#{endpoint => <<"https://collector.example/base">>},
      Base#{endpoint => <<"https://-invalid.example">>},
      Base#{path => <<"//evil.example/v1/traces">>},
      Base#{path => <<"/v1/traces?token=secret">>},
      Base#{path => <<"/v1/%zz">>},
      Base#{headers => #{<<"content-type">> => <<"text/plain">>}},
      Base#{headers => [{<<"x-tenant">>, <<"a">>},
                        {<<"X-Tenant">>, <<"b">>}]},
      Base#{headers => #{<<"x-test">> => <<"bad\r\nheader">>}},
      Base#{timeout_ms => 0},
      Base#{unexpected => true}],
    [?assertEqual({error, invalid_otlp_exporter_config},
                  adk_otlp_http_json_exporter:validate_config(Config))
     || Config <- Invalid].

request_and_response_bounds_are_enforced_test() ->
    Large = (span())#{<<"attributes">> =>
                         #{<<"erlang_adk.test.value">> =>
                               binary:copy(<<"x">>, 2000)}},
    Config = config(success_response(), #{max_request_bytes => 1024}),
    ?assertMatch({error, {otlp_export_failed,
                          #{reason := request_too_large,
                            retryable := false}}},
                 adk_otlp_http_json_exporter:export(Large, Config)),
    receive {otlp_http_request, _} -> erlang:error(unexpected_request)
    after 0 -> ok
    end,
    TooLarge = {ok, #{status => 200, headers => [],
                      body => binary:copy(<<"x">>, 100)}},
    Config2 = config(TooLarge, #{max_response_bytes => 2}),
    ?assertMatch({error, {otlp_export_failed,
                          #{reason := response_too_large,
                            retryable := true}}},
                 adk_otlp_http_json_exporter:export(span(), Config2)),
    _ = receive_request().

transport_errors_do_not_echo_error_terms_test() ->
    Secret = <<"secret from transport">>,
    Config = (base_config())#{transport_handle =>
                                 #{owner => self(),
                                   error => {tls_failed, Secret}}},
    Error = adk_otlp_http_json_exporter:export(span(), Config),
    ?assertMatch({error, {otlp_export_failed,
                          #{classification := transient,
                            reason := transport_failed}}}, Error),
    ?assertEqual(nomatch, binary:match(term_to_binary(Error), Secret)),
    _ = receive_request().

start_signal_is_skipped_without_network_test() ->
    Start = maps:without([<<"status">>, <<"end_time_unix_nano">>,
                          <<"duration_nano">>],
                         (span())#{<<"phase">> => <<"start">>}),
    ok = adk_otlp_http_json_exporter:export(Start, base_config()),
    receive {otlp_http_request, _} -> erlang:error(unexpected_request)
    after 0 -> ok
    end.

bus_owns_retry_attempts_test() ->
    Name = adk_otlp_bus_retry_test,
    Config = config({ok, #{status => 503, headers => [], body => <<>>}}, #{}),
    Descriptor = #{id => <<"otlp">>,
                   module => adk_otlp_http_json_exporter,
                   config => Config,
                   timeout_ms => 1000,
                   max_heap_words => 200000,
                   failure_policy => open},
    {ok, Pid} = adk_observability_bus:start_link(
                  #{name => Name, exporters => [Descriptor],
                    batch_size => 1, max_attempts => 2,
                    flush_interval_ms => 5}),
    unlink(Pid),
    try
        {ok, accepted} = adk_observability_bus:enqueue(Name, span()),
        ok = adk_observability_bus:drain(Name, 3000),
        _ = receive_request(),
        _ = receive_request(),
        Counters = maps:get(<<"counters">>,
                            adk_observability_bus:stats(Name)),
        ?assertEqual(2, maps:get(<<"failed_attempts">>, Counters)),
        ?assertEqual(1, maps:get(<<"retried">>, Counters))
    after
        gen_server:stop(Pid)
    end.

bus_does_not_retry_permanent_otlp_failure_test() ->
    Name = adk_otlp_bus_permanent_test,
    Config = config({ok, #{status => 400, headers => [], body => <<>>}}, #{}),
    Descriptor = #{id => <<"otlp">>,
                   module => adk_otlp_http_json_exporter,
                   config => Config,
                   timeout_ms => 1000,
                   max_heap_words => 200000,
                   failure_policy => open},
    {ok, Pid} = adk_observability_bus:start_link(
                  #{name => Name, exporters => [Descriptor],
                    batch_size => 1, max_attempts => 3,
                    flush_interval_ms => 5}),
    unlink(Pid),
    try
        {ok, accepted} = adk_observability_bus:enqueue(Name, span()),
        ok = adk_observability_bus:drain(Name, 3000),
        _ = receive_request(),
        receive {otlp_http_request, _} -> erlang:error(unexpected_retry)
        after 20 -> ok
        end,
        Counters = maps:get(<<"counters">>,
                            adk_observability_bus:stats(Name)),
        ?assertEqual(1, maps:get(<<"failed_attempts">>, Counters)),
        ?assertEqual(0, maps:get(<<"retried">>, Counters)),
        ?assertEqual(1, maps:get(<<"permanent_failures">>, Counters))
    after
        gen_server:stop(Pid)
    end.

config(Response, Extra) ->
    maps:merge((base_config())#{transport_handle =>
                                   #{owner => self(), response => Response}},
               Extra).

base_config() ->
    #{endpoint => <<"https://collector.example:4318">>,
      transport => adk_otlp_fake_transport,
      transport_handle => #{owner => self(), response => success_response()},
      timeout_ms => 1000,
      max_request_bytes => 1048576,
      max_response_bytes => 65536,
      allow_private_hosts => false}.

success_response() ->
    {ok, #{status => 200,
           headers => [{<<"content-type">>,
                        <<"application/json; charset=utf-8">>}],
           body => <<"{}">>}}.

receive_request() ->
    receive {otlp_http_request, Request} -> Request
    after 1000 -> erlang:error(otlp_request_timeout)
    end.

span() -> adk_otlp_json_test:span().
log_envelope() -> adk_otlp_json_test:log_envelope().
