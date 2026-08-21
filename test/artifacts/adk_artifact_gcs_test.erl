-module(adk_artifact_gcs_test).

-include_lib("eunit/include/eunit.hrl").

-define(SCOPE_A, {session, <<"app">>, <<"user-a">>, <<"session">>}).
-define(SCOPE_B, {session, <<"app">>, <<"user-b">>, <<"session">>}).

immutable_versions_survive_adapter_restart_test() ->
    Store = adk_artifact_gcs_test_transport:new(),
    {ok, First} = start(Store),
    try
        {ok, #{version := 1}} =
            adk_artifact_gcs:put(First, ?SCOPE_A, <<"report.txt">>,
                                 <<"one">>, #{}),
        {ok, #{version := 2}} =
            adk_artifact_gcs:put(First, ?SCOPE_A, <<"report.txt">>,
                                 <<"two">>, #{})
    after
        ok = adk_artifact_gcs:stop(First)
    end,
    {ok, Second} = start(Store),
    try
        {ok, #{version := 3}} =
            adk_artifact_gcs:put(Second, ?SCOPE_A, <<"report.txt">>,
                                 <<"three">>, #{}),
        {ok, #{version := 3, data := <<"three">>}} =
            adk_artifact_gcs:get(Second, ?SCOPE_A, <<"report.txt">>, latest),
        {ok, #{items := Versions, next_cursor := undefined}} =
            adk_artifact_gcs:list_versions(
              Second, ?SCOPE_A, <<"report.txt">>, #{}),
        ?assertEqual([1, 2, 3], [maps:get(version, Item) || Item <- Versions])
    after
        ok = adk_artifact_gcs:stop(Second)
    end.

exact_scope_isolation_and_range_reads_test() ->
    Store = adk_artifact_gcs_test_transport:new(),
    {ok, Service} = start(Store),
    try
        {ok, _} = adk_artifact_gcs:put(
                    Service, ?SCOPE_A, <<"shared.bin">>, <<"abcdef">>, #{}),
        {ok, _} = adk_artifact_gcs:put(
                    Service, ?SCOPE_B, <<"shared.bin">>, <<"UVWXYZ">>, #{}),
        {ok, #{data := <<"bcd">>,
               range := #{offset := 1, length := 3, total_size := 6}}} =
            adk_artifact_gcs:get_range(
              Service, ?SCOPE_A, <<"shared.bin">>, latest,
              #{offset => 1, length => 3}, #{}),
        {ok, #{data := <<"UVWXYZ">>}} =
            adk_artifact_gcs:get(Service, ?SCOPE_B, <<"shared.bin">>, latest),
        ?assertEqual(
           {error, invalid_range},
           adk_artifact_gcs:get_range(
             Service, ?SCOPE_A, <<"shared.bin">>, latest,
             #{offset => 5, length => 2}, #{})),
        {ok, #{scope := ?SCOPE_A, items := [<<"shared.bin">>]}} =
            adk_artifact_gcs:list_names(Service, ?SCOPE_A, #{})
    after
        ok = adk_artifact_gcs:stop(Service)
    end.

concurrent_adapters_reserve_distinct_versions_test() ->
    Store = adk_artifact_gcs_test_transport:new(),
    {ok, A} = start(Store),
    {ok, B} = start(Store),
    try
        Parent = self(),
        P1 = spawn(fun() ->
                           Parent ! {put_a, adk_artifact_gcs:put(
                                             A, ?SCOPE_A, <<"race">>,
                                             <<"a">>, #{})}
                   end),
        P2 = spawn(fun() ->
                           Parent ! {put_b, adk_artifact_gcs:put(
                                             B, ?SCOPE_A, <<"race">>,
                                             <<"b">>, #{})}
                   end),
        ?assert(is_pid(P1)),
        ?assert(is_pid(P2)),
        V1 = receive {put_a, {ok, M1}} -> maps:get(version, M1) after 5000 -> timeout end,
        V2 = receive {put_b, {ok, M2}} -> maps:get(version, M2) after 5000 -> timeout end,
        ?assertEqual([1, 2], lists:sort([V1, V2]))
    after
        ok = adk_artifact_gcs:stop(A),
        ok = adk_artifact_gcs:stop(B)
    end.

trusted_config_rejects_endpoint_and_header_overrides_test() ->
    Store = adk_artifact_gcs_test_transport:new(),
    Base = config(Store),
    ?assertEqual({error, {unknown_config, [endpoint]}},
                 adk_artifact_gcs:start_link(
                   Base#{endpoint => <<"http://127.0.0.1/metadata">>})),
    ?assertEqual({error, {unknown_config, [headers]}},
                 adk_artifact_gcs:start_link(
                   Base#{headers => [{<<"host">>, <<"attacker">>}]})),
    ?assertEqual({error, {unknown_config, [url]}},
                 adk_artifact_gcs:start_link(
                   Base#{url => <<"https://attacker.example">>})).

credentials_and_transport_failures_are_redacted_test() ->
    Secret = <<"gcs-secret-token-do-not-render">>,
    Store0 = adk_artifact_gcs_test_transport:new(),
    Store = Store0#{fail => {backend_leak, Secret}},
    Config = (config(Store))#{credential =>
                                  {adk_artifact_gcs_test_credential,
                                   #{token => Secret}}},
    {ok, Service} = adk_artifact_gcs:start_link(Config),
    try
        ?assertEqual({error, unavailable},
                     adk_artifact_gcs:put(
                       Service, ?SCOPE_A, <<"secret">>, <<"data">>, #{})),
        Status = term_to_binary(sys:get_status(Service)),
        ?assertEqual(nomatch, binary:match(Status, Secret))
    after
        ok = adk_artifact_gcs:stop(Service)
    end.

fixed_https_request_policy_test() ->
    Secret = <<"access-token">>,
    Http = #{controller => self(),
             response => {ok, #{status => 404, headers => [], body => <<>>}}},
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    Context = #{bucket => <<"safe-bucket">>, project => <<"safe-project">>,
                credential => {adk_artifact_gcs_test_credential,
                               #{token => Secret}},
                deadline => Deadline, max_response_bytes => 1024},
    ?assertEqual({error, not_found},
                 adk_artifact_gcs_http_transport:get(
                   {adk_artifact_gcs_test_transport, Http},
                   <<"object/with/slash">>, Context)),
    Request = receive {gcs_http_request, Value} -> Value after 1000 -> timeout end,
    #{url := Url, headers := Headers, follow_redirects := false,
      allowed_schemes := [<<"https">>],
      allowed_hosts := [<<"storage.googleapis.com">>],
      allow_private_hosts := false} = Request,
    ?assertMatch(<<"https://storage.googleapis.com/", _/binary>>, Url),
    ?assertNotEqual(nomatch, binary:match(Url, <<"object%2Fwith%2Fslash">>)),
    ?assertEqual({<<"authorization">>, <<"Bearer ", Secret/binary>>},
                 lists:keyfind(<<"authorization">>, 1, Headers)).

http_transport_crud_and_status_contract_test() ->
    Context = http_context(),
    ?assertEqual(
       ok,
       adk_artifact_gcs_http_transport:put_if_absent(
         http_response(201, <<>>), <<"object">>, <<"payload">>, Context)),
    ?assertEqual(
       {error, exists},
       adk_artifact_gcs_http_transport:put_if_absent(
         http_response(412, <<>>), <<"object">>, <<"payload">>, Context)),
    ?assertEqual(
       {ok, <<"payload">>},
       adk_artifact_gcs_http_transport:get(
         http_response(200, <<"payload">>), <<"object">>, Context)),
    ?assertEqual(
       {error, not_found},
       adk_artifact_gcs_http_transport:get(
         http_response(404, <<>>), <<"object">>, Context)),
    ?assertEqual(
       ok,
       adk_artifact_gcs_http_transport:delete(
         http_response(204, <<>>), <<"object">>, Context)),
    ?assertEqual(
       {error, not_found},
       adk_artifact_gcs_http_transport:delete(
         http_response(404, <<>>), <<"object">>, Context)),
    StatusCases =
        [{401, credential_unavailable}, {403, forbidden}, {408, timeout},
         {429, overloaded}, {500, unavailable},
         {400, storage_request_failed}],
    lists:foreach(
      fun({Status, Reason}) ->
          ?assertEqual(
             {error, Reason},
             adk_artifact_gcs_http_transport:get(
               http_response(Status, <<>>), <<"object">>, Context))
      end, StatusCases).

http_transport_range_and_page_validation_test() ->
    flush_http_requests(),
    Context = http_context(),
    ?assertEqual(
       {ok, <<"bcd">>},
       adk_artifact_gcs_http_transport:get_range(
         http_response(206, <<"bcd">>), <<"object">>, 1, 3, Context)),
    RangeRequest = receive
        {gcs_http_request, Value} -> Value
    after 1000 ->
        timeout
    end,
    ?assert(lists:member({<<"range">>, <<"bytes=1-3">>},
                         maps:get(headers, RangeRequest))),
    ?assertEqual(
       {error, invalid_response},
       adk_artifact_gcs_http_transport:get_range(
         http_response(206, <<"bc">>), <<"object">>, 1, 3, Context)),
    ?assertEqual(
       {error, invalid_range},
       adk_artifact_gcs_http_transport:get_range(
         http_response(416, <<>>), <<"object">>, 10, 1, Context)),
    Page = jsx:encode(
             #{<<"items">> =>
                   [#{<<"name">> => <<"prefix/a">>},
                    #{<<"name">> => <<"prefix/b">>}],
               <<"nextPageToken">> => <<"next page">>}),
    ?assertEqual(
       {ok, #{items => [<<"prefix/a">>, <<"prefix/b">>],
              next_cursor => <<"next page">>}},
       adk_artifact_gcs_http_transport:list(
         http_response(200, Page), <<"prefix/">>, <<"old page">>, 2,
         Context)),
    ?assertEqual(
       {ok, #{items => [], next_cursor => undefined}},
       adk_artifact_gcs_http_transport:list(
         http_response(200, <<"{}">>), <<"prefix/">>, undefined, 2,
         Context)),
    InvalidPages =
        [<<"[]">>, <<"not-json">>,
         jsx:encode(#{<<"items">> => [#{<<"name">> => <<>>}]}),
         jsx:encode(#{<<"nextPageToken">> => <<"bad\n">>})],
    lists:foreach(
      fun(Body) ->
          ?assertEqual(
             {error, invalid_response},
             adk_artifact_gcs_http_transport:list(
               http_response(200, Body), <<"prefix/">>, undefined, 2,
               Context))
      end, InvalidPages),
    ?assertEqual(
       {error, invalid_cursor},
       adk_artifact_gcs_http_transport:list(
         http_response(200, <<"{}">>), <<"prefix/">>, <<"bad\n">>, 2,
         Context)),
    ?assertEqual(
       {error, invalid_cursor},
       adk_artifact_gcs_http_transport:list(
         http_response(200, <<"{}">>), <<"prefix/">>,
         binary:copy(<<"x">>, 4097), 2, Context)).

http_transport_fails_closed_on_credentials_transport_and_shape_test() ->
    Context = http_context(),
    ?assertEqual(
       {error, timeout},
       adk_artifact_gcs_http_transport:get(
         http_response(200, <<>>), <<"object">>,
         Context#{deadline => erlang:monotonic_time(millisecond) - 1})),
    ?assertEqual(
       {error, credential_unavailable},
       adk_artifact_gcs_http_transport:get(
         http_response(200, <<>>), <<"object">>,
         Context#{credential =>
                      {adk_artifact_gcs_test_credential,
                       #{error => deliberate_failure}}})),
    ?assertEqual(
       {error, timeout},
       adk_artifact_gcs_http_transport:get(
         http_result({error, timeout}), <<"object">>, Context)),
    ?assertEqual(
       {error, response_too_large},
       adk_artifact_gcs_http_transport:get(
         http_result({error, response_too_large}), <<"object">>, Context)),
    ?assertEqual(
       {error, transport_failed},
       adk_artifact_gcs_http_transport:get(
         http_result({error, closed}), <<"object">>, Context)),
    ?assertEqual(
       {error, transport_failed},
       adk_artifact_gcs_http_transport:get(
         http_result(raise), <<"object">>, Context)),
    ?assertEqual(
       {error, invalid_response},
       adk_artifact_gcs_http_transport:get(
         http_result({ok, #{status => 200, body => not_binary}}),
         <<"object">>, Context)),
    ?assertEqual(
       {error, invalid_transport_handle},
       adk_artifact_gcs_http_transport:get(invalid, <<"object">>, Context)),
    InvalidCalls =
        [adk_artifact_gcs_http_transport:put_if_absent(
           invalid, not_binary, <<>>, Context),
         adk_artifact_gcs_http_transport:get(invalid, not_binary, Context),
         adk_artifact_gcs_http_transport:get_range(
           invalid, <<"object">>, -1, 0, Context),
         adk_artifact_gcs_http_transport:list(
           invalid, not_binary, undefined, 0, Context),
         adk_artifact_gcs_http_transport:delete(
           invalid, not_binary, Context)],
    ?assertEqual(lists:duplicate(5, {error, invalid_request}), InvalidCalls).

http_context() ->
    #{bucket => <<"safe bucket">>, project => <<"safe project">>,
      credential =>
          {adk_artifact_gcs_test_credential, #{token => <<"access-token">>}},
      deadline => erlang:monotonic_time(millisecond) + 5000,
      max_response_bytes => 65536}.

http_response(Status, Body) ->
    http_result({ok, #{status => Status, headers => [], body => Body}}).

http_result(Result) ->
    {adk_artifact_gcs_test_transport,
     #{controller => self(), response => Result}}.

flush_http_requests() ->
    receive
        {gcs_http_request, _Request} -> flush_http_requests()
    after 0 ->
        ok
    end.

start(Store) -> adk_artifact_gcs:start_link(config(Store)).

config(Store) ->
    #{bucket => <<"adk-test-bucket">>,
      project => <<"adk-test-project">>,
      credential => {adk_artifact_gcs_test_credential,
                     #{token => <<"unused-by-fake">>}},
      transport => {adk_artifact_gcs_test_transport, Store},
      max_artifact_bytes => 1024 * 1024,
      max_response_bytes => 1024 * 1024,
      stream => #{chunk_bytes => 2, max_credit_messages => 2,
                  max_credit_bytes => 4, timeout_ms => 1000}}.
