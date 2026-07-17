-module(adk_llm_context_cache_probe).

-behaviour(adk_llm).

-export([generate/3, stream/4, capabilities/0, validate_config/1,
         before_model/3, set_callback_target/1, clear_callback_target/0]).

-define(CALLBACK_TARGET, {?MODULE, callback_target}).

capabilities() ->
    #{function_calling => true,
      generation_config => true}.

validate_config(_Config) ->
    ok.

generate(Config, History, Tools) ->
    notify_provider(Config, {context_cache_provider_config,
                             Config, History, Tools}),
    {ok, maps:get(response, Config, <<"context cache probe response">>)}.

stream(Config, _History, _Tools, Callback) ->
    Callback(maps:get(response, Config, <<"context cache probe stream">>)),
    ok.

before_model(Config, _Memory, _Tools) ->
    case persistent_term:get(?CALLBACK_TARGET, undefined) of
        Target when is_pid(Target) ->
            Target ! {context_cache_callback_config, Config};
        _ ->
            ok
    end,
    continue.

set_callback_target(Target) when is_pid(Target) ->
    persistent_term:put(?CALLBACK_TARGET, Target),
    ok.

clear_callback_target() ->
    persistent_term:erase(?CALLBACK_TARGET),
    ok.

notify_provider(Config, Message) ->
    case maps:get(test_pid, Config, undefined) of
        Target when is_pid(Target) -> Target ! Message;
        _ -> ok
    end.
