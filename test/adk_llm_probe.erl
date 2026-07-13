-module(adk_llm_probe).
-behaviour(adk_llm).
-export([generate/3, stream/4]).

generate(Config, History, Tools) ->
    notify(Config, {probe_generate, History, Tools}),
    case maps:get(mode, Config, response) of
        response -> {ok, maps:get(response, Config, <<"probe response">>)};
        error -> {error, maps:get(reason, Config, probe_error)};
        delay ->
            timer:sleep(maps:get(delay_ms, Config, 50)),
            {ok, maps:get(response, Config, <<"delayed probe response">>)};
        sub_agent_call ->
            case History of
                [] -> call_sub_agent(Config);
                _ ->
                    case maps:get(role, lists:last(History), undefined) of
                        tool -> {ok, <<"delegation complete">>};
                        _ -> call_sub_agent(Config)
                    end
            end
    end.

stream(Config, _History, _Tools, Callback) ->
    Chunk = maps:get(response, Config, <<"probe stream">>),
    Callback(Chunk),
    ok.

call_sub_agent(Config) ->
    Name = maps:get(call_name, Config),
    {tool_calls, [{Name, #{<<"prompt">> => <<"specialist task">>}, undefined}]}.

notify(Config, Message) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
