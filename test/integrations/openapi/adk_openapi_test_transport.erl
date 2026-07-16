-module(adk_openapi_test_transport).
-behaviour(adk_openapi_http_transport).

-export([request/2]).

request(Server, Request) when is_pid(Server) ->
    Ref = make_ref(),
    Server ! {openapi_transport_request, self(), Ref, Request},
    receive
        {openapi_transport_reply, Ref, Reply} -> Reply
    after 60000 ->
        {error, timeout}
    end.
