-module(adk_eval_llm_judge_test_provider).
-behaviour(adk_llm).

-export([generate/3, stream/4]).

generate(Config, History, Tools) ->
    maybe_notify(Config, History, Tools),
    maybe_wait(Config),
    timer:sleep(maps:get(delay_ms, Config, 0)),
    maps:get(fixture_result, Config,
             {ok, <<"{\"score\":1,\"rationale\":\"fixture\"}">>}).

stream(_Config, _History, _Tools, _Callback) ->
    {error, unsupported}.

maybe_notify(Config, History, Tools) ->
    case maps:get(test_pid, Config, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {llm_judge_provider_request, self(),
                   maps:get(test_tag, Config, undefined),
                   Config, History, Tools};
        _ -> ok
    end.

maybe_wait(Config) ->
    case maps:get(wait_for_continue, Config, false) of
        true ->
            receive
                llm_judge_continue -> ok
            after 5000 -> ok
            end;
        false -> ok
    end.
