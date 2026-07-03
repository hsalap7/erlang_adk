-module(adk_tool).

%% Callback for executing a tool.
%% Expected to return {ok, Result} | {error, Reason}.
-callback execute(Args :: map(), Context :: map()) -> {ok, term()} | {error, term()}.

%% Callback for getting the schema/description of the tool.
-callback schema() -> map().
