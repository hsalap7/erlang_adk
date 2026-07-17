-module(adk_mcp_oauth_metadata_handler_test).

-include_lib("eunit/include/eunit.hrl").

oauth_metadata_http_contract_test_() ->
    {timeout, 10, fun oauth_metadata_http_contract/0}.

oauth_metadata_http_contract() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Listener = {mcp_oauth_metadata_fixture, make_ref()},
    Path = <<"/.well-known/oauth-protected-resource/mcp">>,
    Document =
        #{<<"resource">> => <<"https://mcp.example.com/mcp">>,
          <<"authorization_servers">> => [<<"https://id.example.com">>],
          <<"scopes_supported">> => [<<"mcp:tools">>]},
    Dispatch = cowboy_router:compile(
                 [{'_', [{Path, adk_mcp_oauth_metadata_handler,
                            Document}]}]),
    {ok, _} = cowboy:start_clear(
                Listener,
                #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, 0}]},
                #{env => #{dispatch => Dispatch}}),
    try
        Port = ranch:get_port(Listener),
        {ok, Conn} = gun:open("127.0.0.1", Port),
        {ok, _} = gun:await_up(Conn, 3000),
        try
            assert_get_contract(Conn, Path, Document),
            assert_head_contract(Conn, Path),
            assert_method_not_allowed(Conn, Path, <<"POST">>),
            assert_method_not_allowed(Conn, Path, <<"OPTIONS">>)
        after
            gun:close(Conn)
        end
    after
        ok = cowboy:stop_listener(Listener)
    end.

assert_get_contract(Conn, Path, Document) ->
    Ref = gun:get(Conn, Path, []),
    {200, Headers, Body} = await_response(Conn, Ref),
    ?assertEqual(<<"application/json">>, header(<<"content-type">>, Headers)),
    ?assertEqual(<<"public, max-age=300">>,
                 header(<<"cache-control">>, Headers)),
    ?assertEqual(Document, jsx:decode(Body, [return_maps])).

assert_head_contract(Conn, Path) ->
    Ref = gun:request(Conn, <<"HEAD">>, Path, [], <<>>),
    {200, Headers, <<>>} = await_response(Conn, Ref),
    ?assertEqual(<<"application/json">>, header(<<"content-type">>, Headers)),
    ?assertEqual(<<"public, max-age=300">>,
                 header(<<"cache-control">>, Headers)).

assert_method_not_allowed(Conn, Path, Method) ->
    Ref = gun:request(Conn, Method, Path, [], <<>>),
    {405, Headers, <<>>} = await_response(Conn, Ref),
    ?assertEqual(<<"GET, HEAD">>, header(<<"allow">>, Headers)).

await_response(Conn, Ref) ->
    case gun:await(Conn, Ref, 3000) of
        {response, fin, Status, Headers} ->
            {Status, Headers, <<>>};
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(Conn, Ref, 3000),
            {Status, Headers, Body}
    end.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.
