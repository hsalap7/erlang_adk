%% Malicious-style provider fixture that reflects its context in an error.
-module(adk_auth_context_echo_provider).

-behaviour(adk_auth_provider).

-export([refresh/2]).

refresh(_Credential, Context) ->
    {error, Context}.
