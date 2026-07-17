-module(adk_openapi_toolset_boundary_adapter).

-behaviour(adk_openapi_http_transport).
-behaviour(adk_openapi_auth_manager).

-export([request/2, resolve/2]).

request(Owner, Request) when is_pid(Owner) ->
    Owner ! {openapi_boundary_request, Request},
    request(json, Request);
request(throw, _Request) ->
    error(test_transport_failure);
request(timeout, _Request) ->
    {error, timeout};
request(error, _Request) ->
    {error, refused};
request(invalid, _Request) ->
    invalid;
request(invalid_map, _Request) ->
    {ok, #{status => invalid, body => <<>>}};
request(empty, _Request) ->
    {ok, #{status => 204, headers => [], body => <<>>}};
request(json_header_map, _Request) ->
    {ok, #{status => 200,
           headers => #{<<"Content-Type">> => <<"application/json">>},
           body => <<"{\"ok\":true}">>}};
request(json_no_header, _Request) ->
    {ok, #{status => 200, headers => [], body => <<"{\"ok\":true}">>}};
request(json_bad_headers, _Request) ->
    {ok, #{status => 200, headers => invalid,
           body => <<"{\"ok\":true}">>}};
request(json, _Request) ->
    {ok, #{status => 200,
           headers => [{<<"content-type">>, <<"application/json">>}],
           body => <<"{\"ok\":true}">>}}.

resolve(throw, _Request) ->
    error(test_auth_failure);
resolve(error, _Request) ->
    {error, missing};
resolve(invalid, _Request) ->
    invalid;
resolve(empty_api_key, _Request) ->
    {ok, {api_key, <<>>}};
resolve(unsafe_api_key, _Request) ->
    {ok, {api_key, <<"bad\r\nvalue">>}};
resolve(invalid_utf8_api_key, _Request) ->
    {ok, {api_key, <<255>>}};
resolve(spaced_bearer, _Request) ->
    {ok, {bearer, <<"two words">>}};
resolve(valid_api_key, _Request) ->
    {ok, {api_key, <<"key-value">>}};
resolve(valid_bearer, _Request) ->
    {ok, {bearer, <<"bearer-value">>}}.
