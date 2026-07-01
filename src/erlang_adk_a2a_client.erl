-module(erlang_adk_a2a_client).
-export([prompt/3]).

%% @doc Call a remote agent using the A2A protocol over HTTP.
prompt(Url, AgentName, Prompt) ->
    Payload = jsx:encode(#{<<"agent_name">> => list_to_binary(AgentName), <<"prompt">> => list_to_binary(Prompt)}),
    Headers = [{"Content-Type", "application/json"}],
    case httpc:request(post, {Url, Headers, "application/json", Payload}, [{timeout, 60000}], []) of
        {ok, {{_, 200, _}, _, Body}} ->
            Json = jsx:decode(list_to_binary(Body), [return_maps]),
            {ok, binary_to_list(maps:get(<<"response">>, Json))};
        {ok, {{_, StatusCode, _}, _, Body}} ->
            {error, {http_error, StatusCode, Body}};
        {error, Reason} ->
            {error, Reason}
    end.
