-module(adk_code_test_executor).
-behaviour(adk_code_executor).

-export([execute/3]).

execute(TestPid, Request, Context) when is_pid(TestPid) ->
    TestPid ! {code_executor_request, Request, Context},
    case maps:get(<<"code">>, Request) of
        <<"crash">> -> erlang:error(sandbox_adapter_crash);
        <<"invalid-output">> -> {ok, #{bad => self()}};
        <<"large-output">> -> {ok, #{<<"stdout">> => <<0:(2048 * 8)>>}};
        <<"provider-error">> ->
            {error, #{password => <<"must-not-leak">>, reason => denied}};
        Code ->
            {ok, #{<<"stdout">> => Code,
                   <<"stderr">> => <<>>,
                   <<"exit_code">> => 0}}
    end.
