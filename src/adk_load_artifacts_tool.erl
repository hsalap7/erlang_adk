%% @doc Built-in model-selected artifact attachment tool.
%%
%% The tool returns metadata only. The Runner resolves committed references
%% into bounded ephemeral model parts for the next request; artifact bytes are
%% never copied into the durable tool response or session state.
-module(adk_load_artifacts_tool).
-behaviour(adk_tool).

-export([schema/0, context_capabilities/0, execute/2]).

-define(MAX_ATTACHMENTS, 8).

schema() ->
    #{<<"name">> => <<"load_artifacts">>,
      <<"description">> =>
          <<"Attach scoped artifacts to the next model request.">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"artifacts">> =>
                      #{<<"type">> => <<"array">>,
                        <<"minItems">> => 1,
                        <<"maxItems">> => ?MAX_ATTACHMENTS,
                        <<"items">> =>
                            #{<<"type">> => <<"object">>,
                              <<"properties">> =>
                                  #{<<"name">> => #{<<"type">> => <<"string">>},
                                    <<"version">> =>
                                        #{<<"oneOf">> =>
                                              [#{<<"type">> => <<"integer">>,
                                                 <<"minimum">> => 1},
                                               #{<<"type">> => <<"string">>,
                                                 <<"enum">> => [<<"latest">>]}]}},
                              <<"required">> => [<<"name">>],
                              <<"additionalProperties">> => false}}},
            <<"required">> => [<<"artifacts">>],
            <<"additionalProperties">> => false}}.

context_capabilities() -> [artifact_attach].

execute(#{<<"artifacts">> := Artifacts}, Context)
  when is_list(Artifacts), length(Artifacts) =< ?MAX_ATTACHMENTS ->
    attach_all(Artifacts, Context, []);
execute(_Args, _Context) ->
    {error, invalid_artifact_attachment_request}.

attach_all([], _Context, Acc) ->
    {ok, #{<<"success">> => true,
           <<"attachments">> => lists:reverse(Acc)}};
attach_all([#{<<"name">> := Name} = Request | Rest], Context, Acc)
  when is_binary(Name) ->
    case selector(maps:get(<<"version">>, Request, <<"latest">>)) of
        {ok, Selector} ->
            case adk_context:attach_artifact(Context, Name, Selector) of
                {ok, Metadata} when is_map(Metadata) ->
                    attach_all(Rest, Context,
                               [public_metadata(Metadata) | Acc]);
                {error, Reason} ->
                    {ok, #{<<"success">> => false,
                           <<"error">> => structural_error(Reason),
                           <<"attachments">> => lists:reverse(Acc)}};
                Other ->
                    {error, {invalid_artifact_service_reply, Other}}
            end;
        {error, _} = Error -> Error
    end;
attach_all([_ | _], _Context, _Acc) ->
    {error, invalid_artifact_attachment_request}.

selector(<<"latest">>) -> {ok, latest};
selector(latest) -> {ok, latest};
selector(Version) when is_integer(Version), Version > 0 -> {ok, Version};
selector(_) -> {error, invalid_artifact_version}.

public_metadata(Metadata) ->
    compact(
      #{<<"name">> => maps:get(name, Metadata, undefined),
        <<"version">> => maps:get(version, Metadata, undefined),
        <<"mime_type">> => maps:get(mime_type, Metadata, undefined),
        <<"digest">> => maps:get(digest, Metadata, undefined),
        <<"size">> => maps:get(size, Metadata, undefined)}).

compact(Map) -> maps:filter(fun(_Key, Value) -> Value =/= undefined end, Map).

structural_error(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
structural_error(_) -> <<"artifact_operation_failed">>.
