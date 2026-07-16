-module(adk_llm_probe).
-behaviour(adk_llm).
-export([generate/3, stream/4]).

generate(Config, History, Tools) ->
    notify(Config, {probe_generate, History, Tools}),
    case maps:get(mode, Config, response) of
        response -> {ok, maps:get(response, Config, <<"probe response">>)};
        error -> {error, maps:get(reason, Config, probe_error)};
        malformed_tool_call ->
            {tool_calls, [maps:get(malformed_call, Config, invalid)]};
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
            end;
        sub_agent_echo_call ->
            case History of
                [] -> call_sub_agent(Config, <<>>);
                _ ->
                    case maps:get(role, lists:last(History), undefined) of
                        tool -> {ok, <<"delegation complete">>};
                        _ -> call_sub_agent(
                               Config, latest_user_content(History))
                    end
            end;
        tool_call ->
            case lists:any(
                   fun(#{role := tool}) -> true;
                      (_) -> false
                   end, History) of
                true -> {ok, maps:get(response, Config, <<"tool complete">>)};
                false ->
                    Name = maps:get(call_name, Config),
                    Args = maps:get(call_args, Config, #{}),
                    {tool_calls, [{Name, Args, undefined,
                                   maps:get(call_id, Config,
                                            <<"probe-call-id">>)}]}
            end
    end.

stream(Config, _History, _Tools, Callback) ->
    Chunk = maps:get(response, Config, <<"probe stream">>),
    Callback(Chunk),
    ok.

call_sub_agent(Config) ->
    call_sub_agent(Config, <<"specialist task">>).

call_sub_agent(Config, Prompt) ->
    Name = maps:get(call_name, Config),
    {tool_calls, [{Name, #{<<"prompt">> => Prompt}, undefined}]}.

latest_user_content(History) ->
    case lists:dropwhile(
           fun(#{role := user}) -> false;
              (_) -> true
           end, lists:reverse(History)) of
        [#{content := Content} | _] -> Content;
        [] -> <<>>
    end.

notify(Config, Message) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
