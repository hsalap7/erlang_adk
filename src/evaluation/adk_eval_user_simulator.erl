%% @doc Behaviour for deterministic evaluation user simulators.
%%
%% A simulator is invoked inside the evaluation case worker. Implementations
%% must keep all returned values JSON-compatible; the runner applies hard
%% step, byte, heap, and deadline bounds before values enter a stored result.
-module(adk_eval_user_simulator).

-type next_result() ::
    {continue, Turn :: map(), NewState :: term()}
    | {done, NewState :: term()}
    | {error, term()}.
-export_type([next_result/0]).

-callback init(Scenario :: map(), Context :: map(), Config :: map()) ->
    {ok, State :: term()} | {error, term()}.

-callback next_turn(Transcript :: [map()], State :: term(),
                    Context :: map(), Config :: map()) -> next_result().

-callback terminate(State :: term(), Config :: map()) -> ok.

-optional_callbacks([init/3, terminate/2]).
