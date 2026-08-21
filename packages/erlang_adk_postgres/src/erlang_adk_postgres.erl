%% @doc Curated Postgres tools restricted to operator-registered statements.
%%
%% SQL text, database URLs, and credentials are intentionally absent from the
%% tool schema and connector descriptor. The trusted backend maps a stable
%% statement ID to a prepared statement and separately resolves credentials.
-module(erlang_adk_postgres).

-export([new/2, manifest/0, schemas/1, resolved_call/4]).

-spec new(map(), {module(), term()}) ->
    {ok, adk_toolset:descriptor()} | {error, term()}.
new(Descriptor0, {Backend, BackendHandle}) when is_atom(Backend) ->
    case adk_connector_descriptor:validate(Descriptor0, native) of
        {ok, #{credential_ref := #{kind := credential}} = Descriptor} ->
            case ensure_backend(Backend) of
                ok ->
                    Handle = #{backend => {Backend, BackendHandle},
                               descriptor => Descriptor},
                    adk_connector_toolset:new(?MODULE, Handle, manifest());
                {error, _} = Error -> Error
            end;
        {ok, _NoCredential} -> {error, postgres_credential_profile_required};
        {error, _} = Error -> Error
    end;
new(_Descriptor, _Backend) ->
    {error, invalid_postgres_connector_backend}.

-spec manifest() -> map().
manifest() ->
    #{schema_version => 1,
      connector_id => <<"postgres">>,
      service => native,
      tools =>
          [#{name => <<"postgres_query_prepared">>,
             permissions => [<<"postgres.statements:read">>],
             side_effect => read,
             confirmation => never,
             parallel_safe => true},
           #{name => <<"postgres_execute_prepared">>,
             permissions => [<<"postgres.statements:write">>],
             side_effect => write,
             confirmation => required,
             parallel_safe => false}]}.

-spec schemas(map()) -> [map()].
schemas(_Handle) ->
    [schema(<<"postgres_query_prepared">>,
            <<"Run an operator-registered read-only prepared statement">>),
     schema(<<"postgres_execute_prepared">>,
            <<"Run an operator-registered mutation after confirmation">>)].

schema(Name, Description) ->
    #{<<"name">> => Name,
      <<"description">> => Description,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"statement_id">> =>
                      #{<<"type">> => <<"string">>,
                        <<"minLength">> => 1,
                        <<"maxLength">> => 128},
                  <<"parameters">> =>
                      #{<<"type">> => <<"array">>,
                        <<"maxItems">> => 128}},
            <<"required">> => [<<"statement_id">>],
            <<"additionalProperties">> => false}}.

-spec resolved_call(map(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
resolved_call(#{backend := {Backend, BackendHandle},
                descriptor := Descriptor}, Name,
              #{<<"statement_id">> := StatementId} = Args, _Context)
  when is_atom(Backend), is_binary(Name), is_binary(StatementId) ->
    case mode(Name) of
        {ok, Mode} ->
            Parameters = maps:get(<<"parameters">>, Args, []),
            Execute = fun() ->
                Backend:execute_prepared(
                  BackendHandle, Mode, StatementId, Parameters, Descriptor)
            end,
            {ok, #{name => Name,
                   args => Args,
                   execute => Execute,
                   pause_capable => false}};
        error -> {error, unknown_tool}
    end;
resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, invalid_postgres_tool_call}.

mode(<<"postgres_query_prepared">>) -> {ok, query};
mode(<<"postgres_execute_prepared">>) -> {ok, mutation};
mode(_) -> error.

ensure_backend(Backend) ->
    case code:ensure_loaded(Backend) of
        {module, Backend} ->
            case erlang:function_exported(
                   Backend, execute_prepared, 5) of
                true -> ok;
                false -> {error, invalid_postgres_connector_backend}
            end;
        _ -> {error, postgres_connector_backend_unavailable}
    end.
