%% @doc Trusted runtime boundary for the Google connector.
-module(erlang_adk_google_backend).

-callback invoke(Handle :: term(),
                 Operation :: google_search | vertex_generate_content,
                 Args :: map(),
                 Descriptor :: adk_connector_descriptor:descriptor()) ->
    {ok, term()} | {error, term()}.
