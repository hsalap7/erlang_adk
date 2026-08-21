%% @doc OpenAPI toolset boundary used by the Slack connector.
-module(erlang_adk_slack_openapi).

-callback schemas(Handle :: term()) -> [map()].
-callback resolved_call(Handle :: term(), Name :: binary(), Args :: map(),
                        Context :: map()) ->
    {ok, map()} | {error, term()}.
