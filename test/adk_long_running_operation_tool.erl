-module(adk_long_running_operation_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2, pause_capable/0]).

schema() ->
    #{<<"name">> => <<"start_external_operation">>,
      <<"description">> => <<"Starts a configured external operation.">>,
      <<"pause_capable">> => true,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"operation_id">> => #{<<"type">> => <<"string">>},
                  <<"summary">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"operation_id">>, <<"summary">>]}}.

pause_capable() -> true.

execute(#{<<"operation_id">> := OperationId,
          <<"summary">> := Summary}, _Context) ->
    adk_suspension:long_running(OperationId, Summary).
