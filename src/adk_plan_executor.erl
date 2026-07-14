%% @doc Trusted adapter that interprets one JSON-safe plan action.
%%
%% The core runtime never evaluates source text, shell fragments, functions,
%% or module names contained in a plan. Applications should map a bounded set
%% of action values to existing tools, agents, or workflows here.
-module(adk_plan_executor).

-type descriptor() :: #{module := module(), target := term(),
                        config => map()}.
-export_type([descriptor/0]).

-callback execute(Target :: term(), Step :: adk_plan:step(),
                  Context :: map(), Config :: map()) ->
    {ok, term()} | {error, term()}.
