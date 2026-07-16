-module(adk_llm_correlation_probe).
-behaviour(adk_llm).

-export([generate/3, stream/4]).

generate(_Config, History, _Tools) ->
    case latest_user_content(lists:reverse(History)) of
        {ok, Content} when is_binary(Content) ->
            %% A tiny deterministic spread makes concurrent completions reorder
            %% without making the suite timing-dependent.
            receive after erlang:phash2(Content, 4) -> ok end,
            {ok, Content};
        error ->
            {error, missing_user_input}
    end.

stream(Config, History, Tools, Callback) ->
    case generate(Config, History, Tools) of
        {ok, Content} -> Callback(Content), ok;
        {error, _} = Error -> Error
    end.

latest_user_content([#{role := user, content := Content} | _]) ->
    {ok, Content};
latest_user_content([_ | Rest]) ->
    latest_user_content(Rest);
latest_user_content([]) ->
    error.
