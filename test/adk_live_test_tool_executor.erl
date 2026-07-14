-module(adk_live_test_tool_executor).
-behaviour(adk_live_tool_executor).

-export([execute/2]).

execute(#{id := Id, name := Name, args := Args},
        #{test_pid := TestPid}) when is_pid(TestPid) ->
    TestPid ! {live_tool_started, self(), Id, Name, Args},
    receive
        {live_tool_complete, Id, Response} when is_map(Response) ->
            {ok, Response};
        {live_tool_fail, Id} ->
            {error, deliberate_failure}
    end.

