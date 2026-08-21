%% @doc Handler contract for inspecting or compensating an orphaned artifact
%% effect. Implementations receive only the bounded journal projection.
-module(adk_artifact_reconcile_handler).

-callback reconcile(State :: term(), Effect :: map(),
                    TimeoutMs :: pos_integer()) ->
    {ok, committed | compensated | not_applied} | {error, term()}.
