-module(adk_dev_graph_trace_test).

-include_lib("eunit/include/eunit.hrl").

catalog_is_server_owned_bounded_and_isolated_test() ->
    {ok, Catalog} = adk_dev_graph_catalog:start_link(
                      #{name => undefined, max_graphs => 2,
                        max_graph_bytes => 65536, max_total_bytes => 131072}),
    try
        Compiled = compiled_graph(),
        {ok, Published} = adk_dev_graph_catalog:publish(
                            Catalog, <<"alice">>, <<"checkout">>, Compiled),
        ?assertEqual(<<"checkout">>, maps:get(<<"id">>, Published)),
        ?assertEqual({error, not_found},
                     adk_dev_graph_catalog:get(
                       Catalog, <<"bob">>, <<"checkout">>)),
        {ok, #{<<"graphs">> := [Summary],
               <<"truncated">> := false}} =
            adk_dev_graph_catalog:list(Catalog, <<"alice">>, #{}),
        ?assertEqual(<<"checkout">>, maps:get(<<"id">>, Summary)),
        ?assertNot(maps:is_key(<<"graph">>, Summary)),
        ?assertEqual({error, invalid_graph_publish},
                     adk_dev_graph_catalog:publish(
                       Catalog, <<>>, <<"bad">>, Compiled))
    after
        gen_server:stop(Catalog)
    end.

trace_view_preserves_gap_and_builds_metadata_overlay_test() ->
    {ok, Catalog} = adk_dev_graph_catalog:start_link(#{name => undefined}),
    {ok, Store} = adk_trace_store:start_link(
                    #{name => undefined, max_events => 2,
                      max_bytes => 65536, max_event_bytes => 16384,
                      max_principals => 4, max_events_per_principal => 2,
                      max_bytes_per_principal => 65536,
                      retention_ms => 60000, max_query_events => 2,
                      max_query_bytes => 65536}),
    try
        {ok, _} = adk_dev_graph_catalog:publish(
                    Catalog, <<"alice">>, <<"checkout">>, compiled_graph()),
        {ok, 1} = adk_trace_store:append_lifecycle(
                    Store, <<"trace-alice">>, lifecycle(<<"node_started">>, 1)),
        {ok, 2} = adk_trace_store:append_lifecycle(
                    Store, <<"trace-alice">>, lifecycle(<<"node_completed">>, 2)),
        {ok, Overlay} = adk_dev_trace_view:graph_overlay(
                          Catalog, <<"alice">>, <<"checkout">>,
                          Store, <<"trace-alice">>,
                          #{limit => 2, max_bytes => 65536}),
        ?assertEqual(false, maps:get(<<"content_captured">>, Overlay)),
        NodeStates = maps:get(
                       <<"node_states">>, maps:get(<<"overlay">>, Overlay)),
        ?assertEqual(<<"completed">>, maps:get(<<"step">>, NodeStates)),
        {ok, 3} = adk_trace_store:append_lifecycle(
                    Store, <<"trace-alice">>, lifecycle(<<"node_started">>, 3)),
        ?assertMatch(
           {error, {replay_gap, _}},
           adk_dev_trace_view:query(
             Store, <<"trace-alice">>, #{workflow_id => <<"checkout">>},
             0, #{limit => 2, max_bytes => 65536})),
        {ok, Empty} = adk_dev_trace_view:query(
                        Store, <<"trace-bob">>,
                        #{workflow_id => <<"checkout">>}, 0,
                        #{limit => 2, max_bytes => 65536}),
        ?assertEqual([], maps:get(<<"events">>, Empty))
    after
        gen_server:stop(Store),
        gen_server:stop(Catalog)
    end.

authenticated_http_graph_and_trace_queries_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Listener = adk_dev_graph_trace_http_listener,
    _ = catch cowboy:stop_listener(Listener),
    {ok, Catalog} = adk_dev_graph_catalog:start_link(#{name => undefined}),
    {ok, Store} = adk_trace_store:start_link(
                    #{name => undefined, max_events => 2,
                      max_bytes => 65536, max_event_bytes => 16384,
                      max_principals => 4, max_events_per_principal => 2,
                      max_bytes_per_principal => 65536,
                      retention_ms => 60000, max_query_events => 2,
                      max_query_bytes => 65536}),
    Token = <<"graph-trace-local-token">>,
    try
        {ok, _} = adk_dev_graph_catalog:publish(
                    Catalog, <<"owner">>, <<"checkout">>, compiled_graph()),
        {ok, 1} = adk_trace_store:append_lifecycle(
                    Store, <<"trace-owner">>, lifecycle(<<"node_started">>, 1)),
        {ok, 2} = adk_trace_store:append_lifecycle(
                    Store, <<"trace-owner">>, lifecycle(<<"node_completed">>, 2)),
        Config = #{auth_token => Token, graph_catalog => Catalog,
                   graph_owner => <<"owner">>, trace_store => Store,
                   trace_principal => <<"trace-owner">>,
                   max_resource_results => 2, sse_max_bytes => 65536},
        {ok, _} = cowboy:start_clear(
                    Listener, [{ip, {127, 0, 0, 1}}, {port, 0}],
                    #{env => #{dispatch => adk_dev_router:compile(Config)}}),
        Port = ranch:get_port(Listener),
        {200, GraphsBody} = http_get(
                              Port, <<"/dev/v1/graphs">>, Token),
        #{<<"graphs">> := [#{<<"id">> := <<"checkout">>}]} =
            jsx:decode(GraphsBody, [return_maps]),
        {200, OverlayBody} = http_get(
                               Port,
                               <<"/dev/v1/graphs/checkout/overlay?limit=2">>,
                               Token),
        #{<<"content_captured">> := false,
          <<"overlay">> := #{<<"node_states">> :=
                                  #{<<"step">> := <<"completed">>}}} =
            jsx:decode(OverlayBody, [return_maps]),
        {401, _} = http_get(Port, <<"/dev/v1/graphs">>, undefined),
        {ok, 3} = adk_trace_store:append_lifecycle(
                    Store, <<"trace-owner">>, lifecycle(<<"node_started">>, 3)),
        {409, GapBody} = http_get(
                           Port,
                           <<"/dev/v1/traces?workflow_id=checkout&after_cursor=0&limit=2">>,
                           Token),
        #{<<"error">> := #{<<"code">> := <<"trace_replay_gap">>}} =
            jsx:decode(GapBody, [return_maps])
    after
        _ = catch cowboy:stop_listener(Listener),
        gen_server:stop(Store),
        gen_server:stop(Catalog)
    end.

compiled_graph() ->
    Spec = #{version => 1, id => <<"checkout">>, kind => graph,
             entry => <<"step">>, max_steps => 4,
             nodes => [#{id => <<"step">>,
                         run => fun(_State) -> {ok, #{}} end}],
             edges => #{<<"step">> => end_node}},
    {ok, Compiled} = adk_workflow:compile(Spec),
    Compiled.

lifecycle(Type, Sequence) ->
    #{<<"schema_version">> => 1,
      <<"type">> => Type,
      <<"sequence">> => Sequence,
      <<"timestamp">> => erlang:system_time(millisecond),
      <<"workflow_id">> => <<"checkout">>,
      <<"workflow_kind">> => <<"graph">>,
      <<"invocation_id">> => <<"invocation-1">>,
      <<"node_id">> => <<"step">>,
      <<"outcome">> => <<"ok">>}.

http_get(Port, Path, Token) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn, 2000),
    Headers = case Token of
        undefined -> [];
        _ -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
    end,
    Ref = gun:get(Conn, Path, Headers),
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
