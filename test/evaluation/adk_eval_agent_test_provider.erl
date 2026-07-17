-module(adk_eval_agent_test_provider).
-behaviour(adk_llm).

-export([generate/3, stream/4, validate_config/1]).

generate(Config, _History, _Tools) ->
    notify(Config),
    case maps:get(mode, Config, response) of
        response ->
            {ok, maps:get(response, Config, <<"evaluated">>)};
        error ->
            {error, forced_eval_provider_failure};
        pause ->
            {tool_calls,
             [{<<"request_human_approval">>,
               #{<<"action_summary">> => <<"Approve evaluation">>},
               undefined, <<"eval-approval-call">>}]};
        block ->
            receive
                eval_agent_provider_continue ->
                    {ok, <<"continued">>}
            after maps:get(block_ms, Config, 5000) ->
                {ok, <<"late response">>}
            end
    end.

stream(_Config, _History, _Tools, _Callback) ->
    {error, unsupported}.

validate_config(Config) ->
    case maps:get(init_test_pid, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {eval_agent_provider_validating, self()};
        _ ->
            ok
    end,
    timer:sleep(maps:get(init_delay_ms, Config, 0)),
    ok.

notify(Config) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {eval_agent_provider_called, self()};
        _ ->
            ok
    end.
