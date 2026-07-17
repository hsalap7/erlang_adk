-module(adk_stateful_echo_plugin).
-behaviour(adk_stateful_plugin).

-export([init/1, handle_hook/4]).

init(_Config) ->
    {ok, #{}}.

handle_hook(Hook, Context, Value, State) ->
    {ok, {amend, {Hook, Context, Value}}, State}.
