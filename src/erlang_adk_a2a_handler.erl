-module(erlang_adk_a2a_handler).
-behavior(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            try jsx:decode(Body, [return_maps]) of
                #{<<"agent_name">> := AgentName, <<"prompt">> := Prompt} ->
                    AgentAtom = list_to_atom(binary_to_list(AgentName)),
                    case whereis(AgentAtom) of
                        undefined ->
                            Req2 = cowboy_req:reply(404, #{}, <<"Agent not found">>, Req1),
                            {ok, Req2, State};
                        Pid ->
                            case erlang_adk:prompt(Pid, binary_to_list(Prompt)) of
                                {ok, Response} ->
                                    JsonResp = jsx:encode(#{<<"response">> => list_to_binary(Response)}),
                                    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, JsonResp, Req1),
                                    {ok, Req2, State};
                                {error, Reason} ->
                                    Req2 = cowboy_req:reply(500, #{}, list_to_binary(io_lib:format("~p", [Reason])), Req1),
                                    {ok, Req2, State}
                            end
                    end
            catch
                _:_ ->
                    Req2 = cowboy_req:reply(400, #{}, <<"Invalid JSON payload">>, Req1),
                    {ok, Req2, State}
            end;
        _ ->
            Req1 = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req1, State}
    end.
