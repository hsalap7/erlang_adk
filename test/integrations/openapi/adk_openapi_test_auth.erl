-module(adk_openapi_test_auth).
-behaviour(adk_openapi_auth_manager).

-export([resolve/2]).

resolve(Server, Request) when is_pid(Server) ->
    Ref = make_ref(),
    Server ! {openapi_auth_request, self(), Ref, Request},
    receive
        {openapi_auth_reply, Ref, Reply} -> Reply
    after 60000 ->
        {error, timeout}
    end.
