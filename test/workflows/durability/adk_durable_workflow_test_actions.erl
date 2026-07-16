-module(adk_durable_workflow_test_actions).

-export([first/4, second/4, pause/4]).

first(_State, Context, Table, Parent) ->
    Calls = ets:update_counter(Table, first_calls, 1),
    Parent ! {durable_first_finished, Table, self(), Calls, Context},
    {ok, #{<<"first_committed">> => true}}.

second(_State, Context, Table, Parent) ->
    Parent ! {durable_second_started, Table, self(), Context},
    case ets:lookup_element(Table, allow_second, 2) of
        true ->
            finish_second(Table);
        false ->
            receive
                continue -> finish_second(Table)
            end
    end.

finish_second(Table) ->
    _ = ets:update_counter(Table, second_calls, 1),
    {ok, #{<<"second_committed">> => true}}.

pause(_State, Context, Table, Parent) ->
    Calls = ets:update_counter(Table, pause_calls, 1),
    Parent ! {durable_pause_started, Table, Calls, Context},
    {pause, <<"request_input">>, <<"Provide the graph input">>,
     #{<<"before_pause">> => true}}.
