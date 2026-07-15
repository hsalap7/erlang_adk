%% @doc Metric and judge adapter behaviour for deterministic evaluation.
%%
%% A judge backed by an LLM implements the same callback but declares
%% `kind => judge' in its descriptor. The evaluation engine bounds it within
%% the containing case worker's heap and absolute deadline.
-module(adk_eval_metric).

-type score() :: number() | {ok, number()} | {ok, number(), map()} |
                 {error, term()}.
-export_type([score/0]).

-callback score(Expected :: term(), Actual :: term(),
                Context :: map(), Config :: map()) -> score().
