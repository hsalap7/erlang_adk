%% @doc Curated Google Search and Vertex AI tool package.
%%
%% Network destinations and credentials are resolved by the injected trusted
%% backend. The public descriptor accepts registry IDs only.
-module(erlang_adk_google).

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
        {ok, _NoCredential} -> {error, google_credential_profile_required};
        {error, _} = Error -> Error
    end;
new(_Descriptor, _Backend) ->
    {error, invalid_google_connector_backend}.

-spec manifest() -> map().
manifest() ->
    #{schema_version => 1,
      connector_id => <<"google">>,
      service => native,
      tools =>
          [#{name => <<"google_search">>,
             permissions => [<<"google.search:query">>],
             side_effect => read,
             confirmation => never,
             parallel_safe => true},
           #{name => <<"vertex_generate_content">>,
             permissions => [<<"google.vertex:invoke">>],
             side_effect => none,
             confirmation => never,
             parallel_safe => true}]}.

-spec schemas(map()) -> [map()].
schemas(_Handle) ->
    [#{<<"name">> => <<"google_search">>,
       <<"description">> =>
           <<"Search Google using the operator-configured search service">>,
       <<"parameters">> => object_schema(
                              #{<<"query">> => string_schema()},
                              [<<"query">>])},
     #{<<"name">> => <<"vertex_generate_content">>,
       <<"description">> =>
           <<"Generate content with an operator-approved Vertex model">>,
       <<"parameters">> => object_schema(
                              #{<<"model_ref">> => string_schema(),
                                <<"prompt">> => string_schema()},
                              [<<"model_ref">>, <<"prompt">>])}].

-spec resolved_call(map(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
resolved_call(#{backend := {Backend, BackendHandle},
                descriptor := Descriptor}, Name, Args, _Context)
  when is_atom(Backend), is_binary(Name), is_map(Args) ->
    case operation(Name) of
        {ok, Operation} ->
            Execute = fun() ->
                Backend:invoke(BackendHandle, Operation, Args, Descriptor)
            end,
            {ok, #{name => Name,
                   args => Args,
                   execute => Execute,
                   pause_capable => false}};
        error -> {error, unknown_tool}
    end;
resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, invalid_google_tool_call}.

operation(<<"google_search">>) -> {ok, google_search};
operation(<<"vertex_generate_content">>) ->
    {ok, vertex_generate_content};
operation(_) -> error.

ensure_backend(Backend) ->
    case code:ensure_loaded(Backend) of
        {module, Backend} ->
            case erlang:function_exported(Backend, invoke, 4) of
                true -> ok;
                false -> {error, invalid_google_connector_backend}
            end;
        _ -> {error, google_connector_backend_unavailable}
    end.

object_schema(Properties, Required) ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => Properties,
      <<"required">> => Required,
      <<"additionalProperties">> => false}.

string_schema() ->
    #{<<"type">> => <<"string">>, <<"minLength">> => 1,
      <<"maxLength">> => 65536}.
