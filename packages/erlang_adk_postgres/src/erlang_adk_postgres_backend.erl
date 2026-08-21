%% @doc Trusted prepared-statement boundary for the Postgres connector.
-module(erlang_adk_postgres_backend).

-callback execute_prepared(
            Handle :: term(),
            Mode :: query | mutation,
            StatementId :: binary(),
            Parameters :: list(),
            Descriptor :: adk_connector_descriptor:descriptor()) ->
    {ok, term()} | {error, term()}.
