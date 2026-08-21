-module(erlang_adk_google_test_backend).

-behaviour(erlang_adk_google_backend).

-export([invoke/4]).

invoke(Target, Operation, Args, Descriptor) ->
    Target ! {google_invoked, Operation, Args, Descriptor},
    {ok, #{operation => Operation}}.
