%% @doc Optional evaluation worker transport behaviour.
%%
%% Worker transports are configured by trusted runtime options. A transport
%% owns cancellation and must send exactly one terminal message to Owner:
%% <code>{adk_eval_worker_terminal, Module, Ref, Outcome}</code> where Outcome
%% follows the <code>adk_task</code> terminal outcome contract.
-module(adk_eval_worker).

-type outcome() ::
    {completed, {ok, map()} | {error, term()}}
    | {failed, term()}
    | {timed_out, term()}
    | {cancelled, term()}.
-export_type([outcome/0]).

-callback start(Request :: map(), Owner :: pid(), Config :: map()) ->
    {ok, Ref :: reference(), Handle :: term()} | {error, term()}.

-callback cancel(Handle :: term(), Reason :: term()) ->
    ok | {error, already_terminal | not_found | term()}.

-callback capabilities(Config :: map()) -> map().

-optional_callbacks([capabilities/1]).
