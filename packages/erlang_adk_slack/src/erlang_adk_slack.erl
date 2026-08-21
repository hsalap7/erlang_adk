%% @doc Curated Slack tools over a precompiled, trusted OpenAPI toolset.
%%
%% Pass `{adk_openapi_toolset, CompiledToolset}' in production. The compiled
%% toolset must advertise exactly the two operation IDs in this package.
-module(erlang_adk_slack).

-export([new/2, manifest/0, schemas/1, resolved_call/4]).

-spec new(map(), {module(), term()}) ->
    {ok, adk_toolset:descriptor()} | {error, term()}.
new(Descriptor0, {OpenApiModule, OpenApiHandle})
  when is_atom(OpenApiModule) ->
    case adk_connector_descriptor:validate(Descriptor0, openapi) of
        {ok, #{credential_ref := #{kind := credential}} = Descriptor} ->
            case ensure_openapi(OpenApiModule) of
                ok ->
                    Handle = #{openapi => {OpenApiModule, OpenApiHandle},
                               descriptor => Descriptor},
                    adk_connector_toolset:new(?MODULE, Handle, manifest());
                {error, _} = Error -> Error
            end;
        {ok, _NoCredential} -> {error, slack_credential_profile_required};
        {error, _} = Error -> Error
    end;
new(_Descriptor, _OpenApi) ->
    {error, invalid_slack_openapi_adapter}.

-spec manifest() -> map().
manifest() ->
    #{schema_version => 1,
      connector_id => <<"slack">>,
      service => openapi,
      tools =>
          [#{name => <<"slack_search_messages">>,
             permissions => [<<"slack.messages:read">>],
             side_effect => read,
             confirmation => never,
             parallel_safe => true},
           #{name => <<"slack_post_message">>,
             permissions => [<<"slack.messages:write">>],
             side_effect => external_action,
             confirmation => required,
             parallel_safe => false}]}.

-spec schemas(map()) -> [map()].
schemas(#{openapi := {OpenApiModule, OpenApiHandle}}) ->
    OpenApiModule:schemas(OpenApiHandle).

-spec resolved_call(map(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
resolved_call(#{openapi := {OpenApiModule, OpenApiHandle}},
              Name, Args, _Context)
  when is_atom(OpenApiModule), is_binary(Name), is_map(Args) ->
    %% Agent/session context is deliberately not forwarded to an HTTP adapter.
    OpenApiModule:resolved_call(OpenApiHandle, Name, Args, #{});
resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, invalid_slack_tool_call}.

ensure_openapi(OpenApiModule) ->
    case code:ensure_loaded(OpenApiModule) of
        {module, OpenApiModule} ->
            case erlang:function_exported(OpenApiModule, schemas, 1) andalso
                 erlang:function_exported(
                   OpenApiModule, resolved_call, 4) of
                true -> ok;
                false -> {error, invalid_slack_openapi_adapter}
            end;
        _ -> {error, slack_openapi_adapter_unavailable}
    end.
