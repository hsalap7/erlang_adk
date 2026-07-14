-module(readme_release_tool).
-behaviour(adk_tool).

-export([schema/0, require_confirmation/2, execute/2]).

schema() ->
    #{<<"name">> => <<"publish_release">>,
      <<"description">> => <<"Publish a prepared release">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"environment">> =>
                      #{<<"type">> => <<"string">>,
                        <<"enum">> => [<<"staging">>, <<"production">>]},
                  <<"dry_run">> => #{<<"type">> => <<"boolean">>}},
            <<"required">> => [<<"environment">>, <<"dry_run">>],
            <<"additionalProperties">> => false}}.

%% Read-only dry runs proceed immediately. A real publication requires a
%% Runner/adk_run confirmation continuation before execute/2 is entered.
require_confirmation(#{<<"dry_run">> := true}, _Context) ->
    false;
require_confirmation(#{<<"environment">> := Environment}, _Context) ->
    #{required => true,
      hint => <<"Approve publishing to ", Environment/binary>>}.

execute(#{<<"environment">> := Environment,
          <<"dry_run">> := DryRun}, _Context) ->
    {ok, #{<<"environment">> => Environment,
           <<"dry_run">> => DryRun,
           <<"status">> => <<"prepared example">>}}.
