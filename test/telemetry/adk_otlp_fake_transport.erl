-module(adk_otlp_fake_transport).
-behaviour(adk_otlp_http_transport).

-export([request/2]).

request(#{owner := Owner, response := Response}, Request)
  when is_pid(Owner) ->
    Owner ! {otlp_http_request, Request},
    Response;
request(#{owner := Owner, error := Error}, Request)
  when is_pid(Owner) ->
    Owner ! {otlp_http_request, Request},
    {error, Error};
request(_Handle, _Request) ->
    {error, invalid_fake_transport_handle}.
