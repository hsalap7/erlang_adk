-module(adk_tool).

%% Callback for executing a tool.
%% Expected to return {ok, Result} | {error, Reason}.
-callback execute(Args :: map(), Context :: map()) -> {ok, term()} | {error, term()}.

%% Callback for getting the schema/description of the tool.
-callback schema() -> map().

%% Optional least-authority declaration. A module that implements this
%% callback receives an invocation-bound `context_capability` instead of raw
%% session/artifact/memory handles. Modules without it use the documented
%% compatibility context until a future major-version migration.
-callback context_capabilities() -> [atom()].

%% Optional confirmation gates.  The argument-aware callback takes precedence
%% when a tool exports both forms.  A callback returns a boolean or an internal
%% metadata map such as #{required => true, hint => <<"Publish release">>}.
-callback require_confirmation() -> boolean() | map().
-callback require_confirmation(Args :: map(), Context :: map()) ->
    boolean() | map().

-optional_callbacks([context_capabilities/0,
                     require_confirmation/0, require_confirmation/2]).
