-module(erlang_adk_a2a_client).
-export([prompt/3]).

%% @doc Call this project's small JSON agent endpoint over HTTP.
prompt(Url, AgentName, Prompt) ->
    UrlString = to_list(Url),
    Payload = jsx:encode(#{
        <<"agent_name">> => unicode:characters_to_binary(AgentName),
        <<"prompt">> => unicode:characters_to_binary(Prompt)
    }),
    Headers = [{"Content-Type", "application/json"}],
    HttpOptions = [{timeout, 60000}, {ssl, ssl_options(UrlString)}],
    case httpc:request(post, {UrlString, Headers, "application/json", Payload},
                       HttpOptions, []) of
        {ok, {{_, 200, _}, _, Body}} ->
            Json = jsx:decode(list_to_binary(Body), [return_maps]),
            {ok, maps:get(<<"response">>, Json)};
        {ok, {{_, StatusCode, _}, _, Body}} ->
            {error, {http_error, StatusCode, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

ssl_options("http://" ++ _Rest) ->
    [];
ssl_options(_HttpsUrl) ->
    try apply(public_key, cacerts_get, []) of
        Certs -> [{verify, verify_peer}, {cacerts, Certs}]
    catch
        _:_ -> [{verify, verify_peer}]
    end.

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> binary_to_list(Value).
