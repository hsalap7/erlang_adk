-module(adk_llm_agent_spec_probe).
-behaviour(adk_llm).

-export([generate/3, stream/4, capabilities/0, validate_config/1]).

capabilities() ->
    #{function_calling => true,
      generation_config => true,
      thinking => true,
      safety_settings => true,
      structured_output => true,
      multimodal => false}.

validate_config(_Config) ->
    ok.

generate(Config, History, Tools) ->
    notify(Config, {agent_spec_probe, Config, History, Tools}),
    case maps:get(mode, Config, response) of
        response -> {ok, maps:get(response, Config, <<"probe response">>)};
        error -> {error, maps:get(reason, Config, probe_error)}
    end.

stream(Config, History, Tools, Callback) ->
    notify(Config, {agent_spec_stream_probe, Config, History, Tools}),
    Callback(maps:get(response, Config, <<"probe stream">>)),
    ok.

notify(Config, Message) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
