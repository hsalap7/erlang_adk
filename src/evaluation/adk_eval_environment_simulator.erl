%% @doc Behaviour for bounded evaluation environment simulators.
%%
%% Environment simulators model effects such as a clock, database, or remote
%% service without granting the evaluated agent a real production capability.
%% Implementations are operator-selected Erlang modules, never names supplied
%% by an untrusted evaluation document.
-module(adk_eval_environment_simulator).

-type effect_result() ::
    {ok, Result :: term(), NewState :: term()}
    | {error, term(), NewState :: term()}
    | {error, term()}.
-export_type([effect_result/0]).

-callback init(Scenario :: map(), Context :: map(), Config :: map()) ->
    {ok, State :: term()} | {error, term()}.

-callback handle_effect(Effect :: map(), State :: term(),
                        Context :: map(), Config :: map()) -> effect_result().

-callback terminate(State :: term(), Config :: map()) -> ok.

-optional_callbacks([init/3, terminate/2]).
