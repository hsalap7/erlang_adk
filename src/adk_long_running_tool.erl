%% @doc adk_long_running_tool - Built-in tool for pausing execution.
%%
%% When an agent calls a long-running tool, the engine pauses execution and
%% yields control back to the user or orchestrator. The workflow can be
%% resumed later by providing the tool result.
-module(adk_long_running_tool).
-behaviour(adk_tool).

-export([schema/0, execute/2]).

%% @doc Tool schema for the long-running interaction.
-spec schema() -> map().
schema() ->
    #{
        <<"name">> => <<"request_human_approval">>,
        <<"description">> => <<"Pauses the workflow and requests human approval for an action.">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"action_summary">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"Description of what needs approval.">>
                }
            },
            <<"required">> => [<<"action_summary">>]
        }
    }.

%% @doc Executing this tool intentionally throws a pause exception
%% that the adk_runner catches to suspend the workflow.
-spec execute(Args :: map(), Context :: map()) -> {ok, term()} | {error, term()}.
execute(Args, _Context) ->
    Summary = maps:get(<<"action_summary">>, Args, <<"Unknown action">>),
    %% We throw a special term that the runner's execute_tools logic must catch
    erlang:throw({adk_pause, human_in_the_loop, Summary}).
