-module(erlang_adk_a2a_handler).
-behavior(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, Body, Req1} = read_body(Req0, <<>>),
            handle_body(Body, Req1, State);
        _ ->
            Req1 = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req1, State}
    end.

read_body(Req, Acc) ->
    case cowboy_req:read_body(Req) of
        {ok, Data, Req1} -> {ok, <<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} -> read_body(Req1, <<Acc/binary, Data/binary>>)
    end.

handle_body(Body, Req, State) ->
    Decoded = try jsx:decode(Body, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, invalid_json}
    end,
    case Decoded of
        {ok, #{<<"agent_name">> := AgentName, <<"prompt">> := Prompt}}
          when is_binary(AgentName), is_binary(Prompt) ->
            dispatch_prompt(AgentName, Prompt, Req, State);
        _ ->
            Req1 = cowboy_req:reply(400, #{}, <<"Invalid JSON payload">>, Req),
            {ok, Req1, State}
    end.

dispatch_prompt(AgentName, Prompt, Req, State) ->
    case adk_agent_registry:lookup(AgentName) of
        {error, not_found} ->
            Req1 = cowboy_req:reply(404, #{}, <<"Agent not found">>, Req),
            {ok, Req1, State};
        {ok, Pid} ->
            PromptResult = try erlang_adk:prompt(Pid, Prompt) of
                Result -> Result
            catch
                Class:PromptFailure -> {error, {Class, PromptFailure}}
            end,
            case PromptResult of
                {ok, Response} ->
                    JsonResp = jsx:encode(
                                 #{<<"response">> =>
                                       unicode:characters_to_binary(Response)}),
                    Req1 = cowboy_req:reply(
                             200,
                             #{<<"content-type">> => <<"application/json">>},
                             JsonResp, Req),
                    {ok, Req1, State};
                {error, Reason} ->
                    ErrorBody = unicode:characters_to_binary(
                                  io_lib:format("~p", [Reason])),
                    Req1 = cowboy_req:reply(500, #{}, ErrorBody, Req),
                    {ok, Req1, State}
            end
    end.
