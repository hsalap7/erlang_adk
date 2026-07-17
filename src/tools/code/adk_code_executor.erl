%% @doc Behaviour for trusted external code-sandbox adapters.
%%
%% Implementations must execute outside the BEAM node in a sandbox that
%% enforces its own filesystem, network, CPU, memory, and process limits. This
%% behaviour deliberately provides no local shell or eval fallback.
-module(adk_code_executor).

-type handle() :: term().
-type request() :: #{binary() => term()}.
-type context() :: #{binary() => term()}.
-type result() :: #{binary() => term()}.

-export_type([handle/0, request/0, context/0, result/0]).

-callback execute(Handle :: handle(), Request :: request(),
                  Context :: context()) ->
    {ok, result()} | {error, term()}.
