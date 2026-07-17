%% Deterministic injected transport used by model adapter flow tests.
-module(adk_model_fixture_transport).

-behaviour(adk_model_http_transport).

-export([request/2, stream/3]).

request({Owner, {response, Status, Body}}, Request) ->
    Owner ! {model_http_request, Request},
    {ok, #{status => Status, headers => [], body => encode(Body)}};
request(_Handle, _Request) ->
    {error, invalid_fixture_request}.

stream({Owner, {stream, Status, Chunks, ErrorBody}}, Request, Callback) ->
    Owner ! {model_http_stream_request, Request},
    case Status >= 200 andalso Status < 300 of
        true ->
            case feed_chunks(Chunks, Callback) of
                ok -> {ok, #{status => Status, headers => [], body => <<>>}};
                {error, _} = Error -> Error
            end;
        false ->
            {ok, #{status => Status, headers => [],
                   body => encode(ErrorBody)}}
    end;
stream(_Handle, _Request, _Callback) ->
    {error, invalid_fixture_stream_request}.

feed_chunks([], _Callback) -> ok;
feed_chunks([Chunk | Rest], Callback) ->
    case Callback(Chunk) of
        ok -> feed_chunks(Rest, Callback);
        {error, _} = Error -> Error;
        _ -> {error, invalid_fixture_callback_result}
    end.

encode(Value) when is_binary(Value) -> Value;
encode(Value) -> jsx:encode(Value).
