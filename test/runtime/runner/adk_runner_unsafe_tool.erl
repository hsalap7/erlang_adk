-module(adk_runner_unsafe_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

schema() ->
    #{<<"name">> => <<"unsafe_probe">>,
      <<"description">> => <<"Runner serial barrier probe">>,
      <<"parameters">> => #{<<"type">> => <<"object">>}}.

execute(Args, _Context) ->
    Id = maps:get(<<"id">>, Args),
    notify({runner_tool_started, Id, self(), unsafe}),
    receive after maps:get(<<"delay">>, Args, 0) -> ok end,
    notify({runner_tool_finished, Id, self()}),
    {ok, #{<<"id">> => Id}}.

notify(Message) ->
    case persistent_term:get({adk_runner_parallel_tool, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.
