%% @doc Full-case evaluator behaviour.
%%
%% Unlike the legacy per-turn adk_eval_metric callback, this behaviour sees
%% all actual invocations, the canonical trajectory, and the expected case.
-module(adk_eval_case_metric).

-type result() ::
    number()
    | {ok, number()}
    | {ok, number(), map()}
    | {not_evaluated, map()}
    | {error, term()}.
-export_type([result/0]).

-callback score_case(EvalInput :: map(), Config :: map()) -> result().
