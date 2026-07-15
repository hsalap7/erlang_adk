%% @doc Behaviour for production authentication-bound authorization policy.
%%
%% Implementations receive an identity which has already been authenticated by
%% a trusted HTTP/OIDC boundary. They must make a decision for the exact
%% operation and resource; possession of an authenticated identity alone is
%% not authorization.
-module(adk_authorizer).

-type action() :: list_agents | start_run | observe_run |
                  control_run | resume_run.
-type identity() :: adk_jwt_policy:identity().
-type resource() :: map().
-type decision() :: #{
    principal := binary(),
    user_id := binary(),
    owner_scope := binary(),
    action := action()
}.

-export_type([action/0, identity/0, resource/0, decision/0]).

-callback authorize(Policy :: term(), Identity :: identity(),
                    Action :: action(), Resource :: resource()) ->
    {ok, decision()} | {error, unauthenticated | forbidden}.
