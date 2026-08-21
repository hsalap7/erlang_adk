-module(erlang_adk_github_test_mcp).

-behaviour(erlang_adk_github_mcp).

-export([execute_tool/3]).

execute_tool(Target, Name, Args) ->
    Target ! {github_mcp_call, Name, Args},
    {ok, #{<<"content">> => []}}.
