-module(adk_llm).

-type config() :: map().
-type memory() :: list(map()).
-type tools() :: list(module() | map()).

-export_type([config/0, memory/0, tools/0]).

-callback generate(Config :: config(), Memory :: memory(), Tools :: tools()) ->
    {ok, binary() | string()} | {tool_calls, list()} | {error, term()}.

-callback stream(Config :: config(), Memory :: memory(), Tools :: tools(), Callback :: fun((binary()) -> ok)) ->
    ok | {tool_calls, list()} | {error, term()}.

-export([generate/3, stream/4]).

%% @doc Dispatch the call to the specified provider.
generate(Config, Memory, Tools) ->
    Provider = maps:get(provider, Config),
    Provider:generate(Config, Memory, Tools).

%% @doc Dispatch the streaming call to the specified provider.
stream(Config, Memory, Tools, Callback) ->
    Provider = maps:get(provider, Config),
    Provider:stream(Config, Memory, Tools, Callback).
