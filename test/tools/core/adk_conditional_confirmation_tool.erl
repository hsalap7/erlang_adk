-module(adk_conditional_confirmation_tool).
-behaviour(adk_tool).
-behaviour(adk_parallel_tool).

-export([schema/0, parallel_safe/0, pause_capable/0,
         require_confirmation/2, execute/2]).

schema() ->
    #{<<"name">> => <<"conditional_confirmation_probe">>,
      <<"description">> => <<"Probe an input-dependent confirmed side effect">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"id">> => #{<<"type">> => <<"string">>},
                  <<"confirm">> => #{<<"type">> => <<"boolean">>},
                  <<"mode">> =>
                      #{<<"type">> => <<"string">>,
                        <<"enum">> => [<<"success">>, <<"long_running">>]}},
            <<"required">> => [<<"id">>, <<"confirm">>],
            <<"additionalProperties">> => false}}.

parallel_safe() -> true.

pause_capable() -> true.

require_confirmation(Args, Context) ->
    Id = maps:get(<<"id">>, Args),
    notify({confirmation_checked, Id, Context}),
    case Id of
        <<"confirmation-error">> ->
            erlang:error(confirmation_probe_failed);
        _ ->
            #{required => maps:get(<<"confirm">>, Args),
              hint => <<"Approve conditional confirmation probe">>}
    end.

execute(Args, Context) ->
    Id = maps:get(<<"id">>, Args),
    notify({confirmation_tool_executed, conditional, Id, self(), Context}),
    case maps:get(<<"mode">>, Args, <<"success">>) of
        <<"long_running">> ->
            OperationId = <<"confirmation-op-", Id/binary>>,
            adk_suspension:long_running(
              OperationId, <<"Conditional operation is still running">>);
        <<"success">> ->
            {ok, #{<<"id">> => Id, <<"kind">> => <<"conditional">>}}
    end.

notify(Message) ->
    case persistent_term:get({adk_tool_confirmation_test, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
