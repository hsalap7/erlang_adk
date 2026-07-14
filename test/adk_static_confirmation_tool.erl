-module(adk_static_confirmation_tool).
-behaviour(adk_tool).
-behaviour(adk_parallel_tool).

-export([schema/0, parallel_safe/0, require_confirmation/0, execute/2]).

schema() ->
    #{<<"name">> => <<"static_confirmation_probe">>,
      <<"description">> => <<"Probe a statically confirmed side effect">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"id">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"id">>],
            <<"additionalProperties">> => false}}.

parallel_safe() -> true.

require_confirmation() -> true.

execute(Args, Context) ->
    notify({confirmation_tool_executed, static,
            maps:get(<<"id">>, Args), self(), Context}),
    {ok, #{<<"id">> => maps:get(<<"id">>, Args),
           <<"kind">> => <<"static">>}}.

notify(Message) ->
    case persistent_term:get({adk_tool_confirmation_test, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
