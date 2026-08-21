%% @doc Content-minimal public liveness and readiness probes.
-module(adk_health_handler).

-export([init/2]).

-spec init(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
init(Req0, State = #{mode := Mode}) ->
    Method = cowboy_req:method(Req0),
    case Method =:= <<"GET">> orelse Method =:= <<"HEAD">> of
        false ->
            Req = cowboy_req:reply(
                    405, #{<<"allow">> => <<"GET, HEAD">>,
                           <<"cache-control">> => <<"no-store">>}, <<>>, Req0),
            {ok, Req, State};
        true ->
            {Code, Body0} = health(Mode),
            Body = case Method of <<"HEAD">> -> <<>>; _ -> Body0 end,
            Req = cowboy_req:reply(
                    Code,
                    #{<<"content-type">> => <<"application/json">>,
                      <<"cache-control">> => <<"no-store">>},
                    Body, Req0),
            {ok, Req, State}
    end.

health(liveness) ->
    case adk_deployment_lifecycle:liveness() of
        {ok, _} -> {200, <<"{\"status\":\"live\"}">>};
        _ -> {503, <<"{\"status\":\"not_live\"}">>}
    end;
health(readiness) ->
    case adk_deployment_lifecycle:readiness() of
        {ok, _} -> {200, <<"{\"status\":\"ready\"}">>};
        _ -> {503, <<"{\"status\":\"not_ready\"}">>}
    end.
