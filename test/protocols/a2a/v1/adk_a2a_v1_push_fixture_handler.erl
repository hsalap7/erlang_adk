-module(adk_a2a_v1_push_fixture_handler).

-export([init/2]).

init(Req0, State = #{parent := Parent, table := Table}) ->
    {Body, Req1} = read_body(Req0, [], 0),
    Path = cowboy_req:path(Req1),
    Attempt = ets:update_counter(Table, Path, {2, 1}, {Path, 0}),
    Parent ! {a2a_push_http_request, Path, Attempt,
              cowboy_req:headers(Req1), Body},
    Req2 = reply(Path, Attempt, Req1),
    {ok, Req2, State}.

reply(<<"/retry">>, Attempt, Req) when Attempt < 3 ->
    cowboy_req:reply(500, #{}, <<"retry">>, Req);
reply(<<"/retry">>, _Attempt, Req) ->
    cowboy_req:reply(204, #{}, <<>>, Req);
reply(<<"/redirect">>, _Attempt, Req) ->
    cowboy_req:reply(307, #{<<"location">> => <<"/target">>}, <<>>, Req);
reply(<<"/target">>, _Attempt, Req) ->
    cowboy_req:reply(204, #{}, <<>>, Req);
reply(<<"/oversized">>, _Attempt, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>},
                     binary:copy(<<"x">>, 1024), Req);
reply(_Path, _Attempt, Req) ->
    cowboy_req:reply(404, #{}, <<>>, Req).

read_body(Req0, Acc, Size) when Size =< 1048576 ->
    case cowboy_req:read_body(Req0, #{length => 65536, period => 1000}) of
        {ok, Chunk, Req1} ->
            {iolist_to_binary(lists:reverse([Chunk | Acc])), Req1};
        {more, Chunk, Req1} ->
            read_body(Req1, [Chunk | Acc], Size + byte_size(Chunk))
    end.
