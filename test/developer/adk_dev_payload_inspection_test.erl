-module(adk_dev_payload_inspection_test).

-include_lib("eunit/include/eunit.hrl").

redacted_plugin_capture_is_bounded_test() ->
    {ok, Store} = adk_dev_payload_store:start_link(
                    #{name => undefined, max_events => 3,
                      max_event_bytes => 8192, max_total_bytes => 16384,
                      retention_ms => 60000, call_timeout_ms => 500}),
    try
        Config = #{store => Store, max_event_bytes => 8192,
                   call_timeout_ms => 500},
        Context = #{run_id => <<"run-1">>, app_name => <<"app">>,
                    user_id => <<"user">>, session => <<"session">>,
                    access_token => <<"context-secret">>},
        Request = #{memory => [#{role => user, content => <<"hello">>}],
                    api_key => <<"request-secret">>},
        ?assertEqual(observe,
                     adk_dev_payload_plugin:before_model(
                       Context, Request, Config)),
        ?assertEqual(observe,
                     adk_dev_payload_plugin:after_model(
                       Context,
                       {ok, #{content => <<"answer">>,
                              authorization => <<"response-secret">>}},
                       Config)),
        {ok, Page} = adk_dev_payload_store:query(Store, #{limit => 10}),
        [CapturedRequest, CapturedResponse] = maps:get(<<"items">>, Page),
        ?assertEqual(<<"request">>, maps:get(<<"phase">>, CapturedRequest)),
        ?assertNot(maps:is_key(
                     <<"access_token">>,
                     maps:get(<<"context">>, CapturedRequest))),
        ?assertEqual(
           adk_secret_redactor:marker(),
           maps:get(<<"api_key">>,
                    maps:get(<<"payload">>, CapturedRequest))),
        Encoded = jsx:encode(Page),
        ?assertEqual(nomatch, binary:match(Encoded, <<"context-secret">>)),
        ?assertEqual(nomatch, binary:match(Encoded, <<"request-secret">>)),
        ?assertEqual(nomatch, binary:match(Encoded, <<"response-secret">>)),
        ?assertEqual(<<"response">>,
                     maps:get(<<"phase">>, CapturedResponse))
    after
        gen_server:stop(Store)
    end.

eviction_reports_replay_gap_and_clear_preserves_cursor_test() ->
    {ok, Store} = adk_dev_payload_store:start_link(
                    #{name => undefined, max_events => 2,
                      max_event_bytes => 2048, max_total_bytes => 4096,
                      retention_ms => 60000}),
    try
        {ok, 1} = append(Store, <<"one">>),
        {ok, 2} = append(Store, <<"two">>),
        {ok, 3} = append(Store, <<"three">>),
        ?assertMatch(
           {error, {replay_gap, _}},
           adk_dev_payload_store:query(
             Store, #{after_cursor => 0, limit => 2})),
        {ok, Page} = adk_dev_payload_store:query(Store, #{limit => 2}),
        ?assertEqual([2, 3],
                     [maps:get(<<"cursor">>, Item)
                      || Item <- maps:get(<<"items">>, Page)]),
        ok = adk_dev_payload_store:clear(Store),
        {ok, Empty} = adk_dev_payload_store:query(Store, #{limit => 2}),
        ?assertEqual([], maps:get(<<"items">>, Empty)),
        ?assertEqual(3, maps:get(<<"next_cursor">>, Empty))
    after
        gen_server:stop(Store)
    end.

authenticated_http_payload_window_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Listener = adk_dev_payload_http_listener,
    _ = catch cowboy:stop_listener(Listener),
    {ok, Store} = adk_dev_payload_store:start_link(
                    #{name => undefined, max_events => 4,
                      max_event_bytes => 4096, max_total_bytes => 16384,
                      retention_ms => 60000}),
    Token = <<"payload-local-token">>,
    try
        {ok, 1} = append(Store, <<"captured">>),
        Config = #{auth_token => Token,
                   provider_payload_store => Store,
                   max_resource_results => 4},
        {ok, _} = cowboy:start_clear(
                    Listener, [{ip, {127, 0, 0, 1}}, {port, 0}],
                    #{env => #{dispatch => adk_dev_router:compile(Config)}}),
        Port = ranch:get_port(Listener),
        {200, Body} = request(
                        Port, <<"GET">>,
                        <<"/dev/v1/provider-payloads?limit=4">>, Token),
        #{<<"items">> := [#{<<"payload">> :=
                                  #{<<"value">> := <<"captured">>}}]} =
            jsx:decode(Body, [return_maps]),
        {401, _} = request(
                     Port, <<"GET">>,
                     <<"/dev/v1/provider-payloads">>, undefined),
        {200, _} = request(
                     Port, <<"DELETE">>,
                     <<"/dev/v1/provider-payloads">>, Token),
        {200, EmptyBody} = request(
                             Port, <<"GET">>,
                             <<"/dev/v1/provider-payloads">>, Token),
        #{<<"items">> := []} = jsx:decode(EmptyBody, [return_maps]),
        {Ui, _Csp} = adk_dev_ui:render(),
        ?assertNotEqual(
           nomatch, binary:match(Ui, <<"Provider payload inspection">>)),
        ?assertNotEqual(
           nomatch,
           binary:match(Ui, <<"Disabled by default">>))
    after
        _ = catch cowboy:stop_listener(Listener),
        gen_server:stop(Store)
    end.

append(Store, Value) ->
    Json = jsx:encode(#{<<"schema_version">> => 1,
                        <<"context">> => #{<<"run_id">> => <<"run">>},
                        <<"payload">> => #{<<"value">> => Value}}),
    adk_dev_payload_store:append_json(
      Store, <<"request">>, Json, 500).

request(Port, Method, Path, Token) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn, 2000),
    Headers = case Token of
        undefined -> [];
        _ -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
    end,
    Ref = gun:request(Conn, Method, Path, Headers, <<>>),
    try
        case gun:await(Conn, Ref, 3000) of
            {response, fin, Status, _} -> {Status, <<>>};
            {response, nofin, Status, _} ->
                {ok, Body} = gun:await_body(Conn, Ref, 3000),
                {Status, Body}
        end
    after
        gun:close(Conn)
    end.
