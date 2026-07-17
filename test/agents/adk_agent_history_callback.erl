-module(adk_agent_history_callback).
-behaviour(adk_callbacks).

-export([before_agent/2, after_agent/2]).

before_agent(_AgentName, <<"skip model">>) ->
    {halt, <<"short-circuited response">>};
before_agent(_AgentName, "skip model") ->
    {halt, <<"short-circuited response">>};
before_agent(_AgentName, <<"map response">>) ->
    {halt, #{status => ok}};
before_agent(_AgentName, "map response") ->
    {halt, #{status => ok}};
before_agent(_AgentName, _Input) ->
    continue.

after_agent(_AgentName, "original response") ->
    {replace, <<"replacement response">>};
after_agent(_AgentName, <<"original response">>) ->
    {replace, <<"replacement response">>};
after_agent(_AgentName, _Output) ->
    continue.
