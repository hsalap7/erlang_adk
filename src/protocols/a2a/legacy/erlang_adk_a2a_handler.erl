-module(erlang_adk_a2a_handler).
-behavior(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            MaxBodyBytes = maps:get(max_body_bytes, State, 1048576),
            case body_too_large(Req0, MaxBodyBytes) of
                true -> payload_too_large(Req0, State);
                false ->
                    case read_body(Req0, <<>>, MaxBodyBytes) of
                        {ok, Body, Req1} -> handle_body(Body, Req1, State);
                        {error, payload_too_large, Req1} ->
                            payload_too_large(Req1, State)
                    end
            end;
        _ ->
            Req1 = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req1, State}
    end.

body_too_large(Req, MaxBodyBytes) ->
    case cowboy_req:body_length(Req) of
        Length when is_integer(Length) -> Length > MaxBodyBytes;
        undefined -> false
    end.

read_body(Req, Acc, MaxBodyBytes) ->
    Remaining = MaxBodyBytes - byte_size(Acc),
    ReadOptions = #{length => Remaining + 1, period => 5000},
    case cowboy_req:read_body(Req, ReadOptions) of
        {ok, Data, Req1} when byte_size(Data) =< Remaining ->
            {ok, <<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} when byte_size(Data) =< Remaining ->
            read_body(Req1, <<Acc/binary, Data/binary>>, MaxBodyBytes);
        {ok, _Data, Req1} ->
            {error, payload_too_large, Req1};
        {more, _Data, Req1} ->
            {error, payload_too_large, Req1}
    end.

payload_too_large(Req, State) ->
    Req1 = cowboy_req:reply(
             413,
             #{<<"connection">> => <<"close">>,
               <<"content-type">> => <<"text/plain">>},
             <<"Payload Too Large">>, Req),
    {ok, Req1, State}.

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
                Class:PromptFailure ->
                    {error, adk_failure:exception(
                              a2a_http, prompt, Class, PromptFailure)}
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
                {error, _Reason} ->
                    ErrorBody = jsx:encode(
                                  #{<<"error">> =>
                                        <<"agent_execution_failed">>}),
                    Req1 = cowboy_req:reply(
                             500,
                             #{<<"content-type">> =>
                                   <<"application/json">>},
                             ErrorBody, Req),
                    {ok, Req1, State}
            end
    end.
