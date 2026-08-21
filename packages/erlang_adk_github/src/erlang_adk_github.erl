%% @doc Curated GitHub tools backed by an operator-owned MCP connection.
-module(erlang_adk_github).

-export([new/2, manifest/0, schemas/1, resolved_call/4]).

-spec new(map(), {module(), term()}) ->
    {ok, adk_toolset:descriptor()} | {error, term()}.
new(Descriptor0, {McpModule, McpHandle}) when is_atom(McpModule) ->
    case adk_connector_descriptor:validate(Descriptor0, mcp) of
        {ok, #{credential_ref := #{kind := credential}} = Descriptor} ->
            case ensure_mcp(McpModule) of
                ok ->
                    Handle = #{mcp => {McpModule, McpHandle},
                               descriptor => Descriptor},
                    adk_connector_toolset:new(?MODULE, Handle, manifest());
                {error, _} = Error -> Error
            end;
        {ok, _NoCredential} -> {error, github_credential_profile_required};
        {error, _} = Error -> Error
    end;
new(_Descriptor, _Mcp) ->
    {error, invalid_github_mcp_adapter}.

-spec manifest() -> map().
manifest() ->
    #{schema_version => 1,
      connector_id => <<"github">>,
      service => mcp,
      tools =>
          [#{name => <<"github_search_repositories">>,
             permissions => [<<"github.repositories:read">>],
             side_effect => read,
             confirmation => never,
             parallel_safe => true},
           #{name => <<"github_create_issue">>,
             permissions => [<<"github.issues:write">>],
             side_effect => write,
             confirmation => required,
             parallel_safe => false}]}.

-spec schemas(map()) -> [map()].
schemas(_Handle) ->
    [#{<<"name">> => <<"github_search_repositories">>,
       <<"description">> => <<"Search repositories through GitHub MCP">>,
       <<"parameters">> => object_schema(
                              #{<<"query">> => string_schema()},
                              [<<"query">>])},
     #{<<"name">> => <<"github_create_issue">>,
       <<"description">> => <<"Create a GitHub issue after confirmation">>,
       <<"parameters">> => object_schema(
                              #{<<"owner">> => short_string_schema(),
                                <<"repo">> => short_string_schema(),
                                <<"title">> => short_string_schema(),
                                <<"body">> => string_schema()},
                              [<<"owner">>, <<"repo">>, <<"title">>])}].

-spec resolved_call(map(), binary(), map(), map()) ->
    {ok, map()} | {error, term()}.
resolved_call(#{mcp := {McpModule, McpHandle}}, Name, Args, _Context)
  when is_atom(McpModule), is_binary(Name), is_map(Args) ->
    case remote_name(Name) of
        {ok, RemoteName} ->
            Execute = fun() ->
                McpModule:execute_tool(McpHandle, RemoteName, Args)
            end,
            {ok, #{name => Name,
                   args => Args,
                   execute => Execute,
                   pause_capable => false}};
        error -> {error, unknown_tool}
    end;
resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, invalid_github_tool_call}.

remote_name(<<"github_search_repositories">>) ->
    {ok, <<"search_repositories">>};
remote_name(<<"github_create_issue">>) -> {ok, <<"create_issue">>};
remote_name(_) -> error.

ensure_mcp(McpModule) ->
    case code:ensure_loaded(McpModule) of
        {module, McpModule} ->
            case erlang:function_exported(McpModule, execute_tool, 3) of
                true -> ok;
                false -> {error, invalid_github_mcp_adapter}
            end;
        _ -> {error, github_mcp_adapter_unavailable}
    end.

object_schema(Properties, Required) ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => Properties,
      <<"required">> => Required,
      <<"additionalProperties">> => false}.

string_schema() ->
    #{<<"type">> => <<"string">>, <<"minLength">> => 1,
      <<"maxLength">> => 65536}.

short_string_schema() ->
    #{<<"type">> => <<"string">>, <<"minLength">> => 1,
      <<"maxLength">> => 1024}.
