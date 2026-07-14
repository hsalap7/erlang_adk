-module(adk_agent_mailbox_llm).
-behaviour(adk_llm).

-export([generate/3, stream/4]).

generate(Config, History, _Tools) ->
    Prompt = latest_prompt(History),
    Observer = maps:get(observer, Config),
    Observer ! {agent_mailbox_started,
                maps:get(agent_tag, Config, undefined),
                Prompt, self()},
    case maps:get(mode, Config, block) of
        block ->
            receive
                release -> {ok, Prompt};
                {release, Response} -> {ok, Response}
            end;
        response -> {ok, maps:get(response, Config, Prompt)};
        provider_error -> {error, maps:get(reason, Config, unavailable)}
    end.

stream(Config, History, Tools, Callback) ->
    case generate(Config, History, Tools) of
        {ok, Response} -> Callback(Response), ok;
        {error, _} = Error -> Error
    end.

latest_prompt(History) ->
    case lists:reverse(History) of
        [#{role := user, content := Content} | _] -> Content;
        [_Other | Rest] -> latest_prompt(lists:reverse(Rest));
        [] -> <<>>
    end.
