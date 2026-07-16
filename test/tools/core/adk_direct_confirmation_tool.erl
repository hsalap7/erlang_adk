-module(adk_direct_confirmation_tool).
-behaviour(adk_tool).

-export([schema/0, require_confirmation/2, execute/2]).

schema() ->
    #{<<"name">> => <<"direct_confirmation_probe">>,
      <<"description">> => <<"Probe direct confirmation handling">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"id">> => #{<<"type">> => <<"string">>},
                  <<"confirm">> => #{<<"type">> => <<"boolean">>}},
            <<"required">> => [<<"id">>, <<"confirm">>],
            <<"additionalProperties">> => false}}.

require_confirmation(Args, Context) ->
    notify({direct_confirmation_checked,
            maps:get(<<"id">>, Args), Context}),
    #{required => maps:get(<<"confirm">>, Args),
      hint => <<"Approve direct confirmation probe">>}.

execute(Args, Context) ->
    notify({direct_confirmation_executed,
            maps:get(<<"id">>, Args), self(), Context}),
    {ok, #{<<"id">> => maps:get(<<"id">>, Args)}}.

notify(Message) ->
    case persistent_term:get({adk_direct_confirmation_test, target},
                             undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
