%% @doc Behaviour for provider-neutral explicit planning and replanning.
%%
%% Planner callbacks return data. They do not execute steps. The runtime
%% validates every plan and invokes a separate trusted `adk_plan_executor'.
-module(adk_planner).

-type descriptor() :: #{module := module(), target := term(),
                        config => map()}.
-type decision() :: continue |
                    {replan, adk_plan:plan()} |
                    {complete, term()} |
                    {fail, term()} |
                    {error, term()}.
-export_type([descriptor/0, decision/0]).

-callback plan(Target :: term(), Goal :: term(), Context :: map(),
               Config :: map()) ->
    {ok, adk_plan:plan()} | {complete, term()} | {error, term()}.

-callback review(Target :: term(), Plan :: adk_plan:plan(),
                 Step :: adk_plan:step(), Observation :: map(),
                 Context :: map(), Config :: map()) -> decision().
