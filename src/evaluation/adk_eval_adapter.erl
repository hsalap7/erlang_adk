%% @doc Adapter behaviour used by versioned, multi-turn evaluation sets.
%%
%% One worker process owns a case and threads `State' through its turns. This
%% maps naturally to an Erlang session process while letting tests use a small
%% deterministic adapter. The adapter may return canonical ADK events so the
%% evaluator can preserve and score the trajectory.
-module(adk_eval_adapter).

-type turn_result() :: #{
    output := term(),
    events => [adk_event:event() | map()],
    state => term(),
    metadata => map()
}.
-export_type([turn_result/0]).

-callback run_turn(Target :: term(), Turn :: map(), State :: term(),
                   Context :: map(), Config :: map()) ->
    {ok, turn_result()} | {error, term()}.

%% A v2 adapter may allocate a fresh target/session for every case and sample.
%% The callbacks are optional so existing v1 adapters remain source compatible.
-callback init_case(Target :: term(), Case :: map(), Context :: map(),
                    Config :: map()) ->
    {ok, CaseTarget :: term(), InitialState :: term()}
    | {ok, InitialState :: term()}
    | {error, term()}.

-callback terminate_case(CaseTarget :: term(), FinalState :: term(),
                         Config :: map()) -> ok | {error, term()}.

-optional_callbacks([init_case/4, terminate_case/3]).
