-module(adk_auth_bounds_provider).

-behaviour(adk_auth_provider).

-export([refresh/2]).

refresh(#{mode := valid}, _Context) ->
    {ok, #{access_token => <<"bounded-token">>,
           token_type => <<"Bearer">>, expires_in_ms => 60000}};
refresh(#{mode := oversized_access}, _Context) ->
    {ok, #{access_token => binary:copy(<<"a">>, 131073),
           token_type => <<"Bearer">>, expires_in_ms => 60000}};
refresh(#{mode := oversized_error}, _Context) ->
    {error, binary:copy(<<"e">>, 1048577)};
refresh(#{mode := invalid_token_type}, _Context) ->
    {ok, #{access_token => <<"bounded-token">>,
           token_type => <<"Bearer bad">>, expires_in_ms => 60000}};
refresh(#{mode := oversized_expiry}, _Context) ->
    {ok, #{access_token => <<"bounded-token">>,
           token_type => <<"Bearer">>, expires_in_ms => 604800001}};
refresh(#{mode := heap_bomb}, _Context) ->
    Huge = lists:seq(1, 1000000),
    {ok, #{access_token => integer_to_binary(length(Huge)),
           token_type => <<"Bearer">>, expires_in_ms => 60000}};
refresh(_Credential, _Context) ->
    {error, invalid_fixture_credential}.
