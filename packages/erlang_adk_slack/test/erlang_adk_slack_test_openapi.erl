-module(erlang_adk_slack_test_openapi).

-behaviour(erlang_adk_slack_openapi).

-export([schemas/1, resolved_call/4]).

schemas(_Target) ->
    [schema(<<"slack_search_messages">>, [<<"query">>]),
     schema(<<"slack_post_message">>, [<<"channel">>, <<"text">>])].

resolved_call(Target, Name, Args, Context) ->
    Target ! {slack_openapi_resolved, Name, Args, Context},
    {ok, #{name => Name,
           args => Args,
           execute => fun() ->
                              Target ! {slack_openapi_executed, Name, Args},
                              {ok, #{<<"ok">> => true}}
                      end,
           pause_capable => false}}.

schema(Name, Required) ->
    Properties = maps:from_list(
                   [{Key, #{<<"type">> => <<"string">>}}
                    || Key <- Required]),
    #{<<"name">> => Name,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> => Properties,
            <<"required">> => Required,
            <<"additionalProperties">> => false}}.
