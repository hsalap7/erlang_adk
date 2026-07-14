-module(adk_failure_security_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"secret_failure_tool">>,
      <<"description">> => <<"Fails without exposing its response body">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> => #{},
            <<"additionalProperties">> => false}}.

execute(_Args, _Context) ->
    Seed = persistent_term:get({?MODULE, seed}),
    {error, {http_error, 502,
             #{<<"body">> => Seed,
               <<"authorization">> => Seed}}}.
