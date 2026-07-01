-module(adk_llm_dummy).
-behaviour(adk_llm).
-export([generate/3]).

generate(_Config, History, _Tools) ->
    case length(History) > 0 of
        true ->
            LastMsg = lists:last(History),
            case maps:get(content, LastMsg) of
                "Trigger tool" -> {tool_calls, [{<<"dummy_tool">>, #{<<"arg">> => <<"val">>}}]};
                {tool_response, _, _} -> {ok, <<"Tool executed">>};
                _ -> {ok, <<"Simulated response">>}
            end;
        false ->
            {ok, <<"Simulated response">>}
    end.
