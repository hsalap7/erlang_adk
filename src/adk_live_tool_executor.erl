%% @doc Explicit trusted execution boundary for Gemini Live function calls.
%%
%% A Live session never discovers or invokes application tools implicitly. An
%% application must opt in with a concrete implementation of this behaviour,
%% an allowlist, and a scheduling policy. The callback runs in a bounded worker
%% owned by the Live session rather than in the session process itself.
-module(adk_live_tool_executor).

-callback execute(Call :: #{id := binary(), name := binary(), args := map()},
                  Options :: map()) ->
    {ok, Response :: map()} | {error, term()}.

