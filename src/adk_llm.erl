-module(adk_llm).

-type config() :: map().
-type memory() :: list(map()).
-type tools() :: list(module()).

-callback generate(Config :: config(), Memory :: memory(), Tools :: tools()) ->
    {ok, binary() | string()} | {tool_calls, list()} | {error, term()}.

-export([generate/3]).

%% @doc Dispatch the call to the specified provider.
generate(Config, Memory, Tools) ->
    Provider = maps:get(provider, Config),
    Provider:generate(Config, Memory, Tools).
