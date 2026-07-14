%% @doc Validation and JSON boundary helpers for the A2A 1.0 data model.
%%
%% A2A 1.0 uses ProtoJSON oneof members.  In particular, Parts contain one
%% of `text`, `raw`, `url`, or `data`; stream responses contain one of `task`,
%% `message`, `statusUpdate`, or `artifactUpdate`.  The pre-1.0 `kind`
%% discriminator is deliberately rejected at this boundary.
-module(adk_a2a_v1_codec).

-export([validate_agent_card/1,
         validate_message/1,
         validate_part/1,
         validate_artifact/1,
         validate_task/1,
         validate_stream_response/1,
         validate_jsonrpc_request/1,
         result/2,
         error_response/3,
         error_response/4,
         terminal_state/1,
         interrupted_state/1,
         json_safe/1]).

-define(VERSION, <<"1.0">>).
-define(MAX_SECURITY_SCHEMES, 32).
-define(MAX_SECURITY_REQUIREMENTS, 32).
-define(MAX_EXTENSIONS, 32).
-define(MAX_URI_BYTES, 2048).
-define(MAX_IDENTIFIER_BYTES, 512).
-define(MAX_FIELD_BYTES, 1024).
-define(MAX_PARTS, 256).
-define(MAX_ARTIFACTS, 128).
-define(MAX_HISTORY_MESSAGES, 256).
-define(MAX_CARD_BYTES, 1048576).
-define(MAX_MESSAGE_BYTES, 524288).
-define(MAX_ARTIFACT_BYTES, 2097152).
-define(MAX_TASK_BYTES, 4194304).
-define(MAX_STREAM_RESPONSE_BYTES, 4194304).

-spec validate_agent_card(term()) -> {ok, map()} | {error, term()}.
validate_agent_card(Card0) ->
    case json_safe(Card0) of
        {ok, Card} when is_map(Card),
                            map_size(Card) > 0 ->
            case within_json_bytes(Card, ?MAX_CARD_BYTES) of
                true -> validate_card_fields(Card);
                false -> {error, {invalid_agent_card, payload_too_large}}
            end;
        {ok, _} ->
            {error, {invalid_agent_card, expected_object}};
        {error, Reason} ->
            {error, {invalid_agent_card, Reason}}
    end.

-spec validate_message(term()) -> {ok, map()} | {error, term()}.
validate_message(Message0) ->
    case json_safe(Message0) of
        {ok, Message} when is_map(Message) ->
            case within_json_bytes(Message, ?MAX_MESSAGE_BYTES) of
                false -> {error, {invalid_message, payload_too_large}};
                true ->
                    case reject_kind(Message, message) of
                        ok -> validate_message_fields(Message);
                        Error -> Error
                    end
            end;
        {ok, _} -> {error, {invalid_message, expected_object}};
        {error, Reason} -> {error, {invalid_message, Reason}}
    end.

-spec validate_part(term()) -> {ok, map()} | {error, term()}.
validate_part(Part0) ->
    case json_safe(Part0) of
        {ok, Part} when is_map(Part) ->
            case reject_kind(Part, part) of
                ok -> validate_part_fields(Part);
                Error -> Error
            end;
        {ok, _} -> {error, {invalid_part, expected_object}};
        {error, Reason} -> {error, {invalid_part, Reason}}
    end.

-spec validate_artifact(term()) -> {ok, map()} | {error, term()}.
validate_artifact(Artifact0) ->
    case json_safe(Artifact0) of
        {ok, Artifact} when is_map(Artifact) ->
            case within_json_bytes(Artifact, ?MAX_ARTIFACT_BYTES) of
                false -> {error, {invalid_artifact, payload_too_large}};
                true -> validate_artifact_fields(Artifact)
            end;
        {ok, _} -> {error, {invalid_artifact, expected_object}};
        {error, Reason} -> {error, {invalid_artifact, Reason}}
    end.

validate_artifact_fields(Artifact) ->
            case {required_identifier(<<"artifactId">>, Artifact),
                  required_nonempty_list(<<"parts">>, Artifact)} of
                {{ok, _}, {ok, Parts}} when length(Parts) =< ?MAX_PARTS ->
                    case validate_list(Parts, fun validate_part/1, []) of
                        {ok, SafeParts} ->
                            {ok, Artifact#{<<"parts">> => SafeParts}};
                        {error, Reason} ->
                            {error, {invalid_artifact, <<"parts">>, Reason}}
                    end;
                {{error, Reason}, _} ->
                    {error, {invalid_artifact, <<"artifactId">>, Reason}};
                {_, {error, Reason}} ->
                    {error, {invalid_artifact, <<"parts">>, Reason}};
                _ ->
                    {error, {invalid_artifact, <<"parts">>, too_many_parts}}
            end.

-spec validate_stream_response(term()) -> {ok, map()} | {error, term()}.
validate_stream_response(Response0) ->
    case json_safe(Response0) of
        {ok, Response} when is_map(Response) ->
            case within_json_bytes(Response, ?MAX_STREAM_RESPONSE_BYTES) of
                false -> {error, {invalid_stream_response,
                                   payload_too_large}};
                true -> case reject_kind(Response, stream_response) of
                ok ->
                    Members = present_members(
                                [<<"task">>, <<"message">>,
                                 <<"statusUpdate">>, <<"artifactUpdate">>],
                                Response),
                    case Members of
                        [Member] -> validate_stream_member(Member, Response);
                        _ -> {error, {invalid_stream_response,
                                      expected_exactly_one_payload_member}}
                    end;
                Error -> Error
            end
            end;
        {ok, _} -> {error, {invalid_stream_response, expected_object}};
        {error, Reason} -> {error, {invalid_stream_response, Reason}}
    end.

-spec validate_task(term()) -> {ok, map()} | {error, term()}.
validate_task(Task0) ->
    case json_safe(Task0) of
        {ok, Task} when is_map(Task) ->
            case within_json_bytes(Task, ?MAX_TASK_BYTES) of
                false -> {error, {invalid_task, payload_too_large}};
                true ->
                    case reject_kind(Task, task) of
                        ok -> validate_task_fields(Task);
                        Error -> Error
                    end
            end;
        {ok, _} -> {error, {invalid_task, expected_object}};
        {error, Reason} -> {error, {invalid_task, Reason}}
    end.

-spec validate_jsonrpc_request(term()) ->
    {ok, term(), binary(), map()} | {error, term(), integer(), binary()}.
validate_jsonrpc_request(Request) when is_map(Request) ->
    Id = maps:get(<<"id">>, Request, null),
    case {maps:get(<<"jsonrpc">>, Request, undefined),
          maps:get(<<"method">>, Request, undefined),
          maps:get(<<"params">>, Request, #{})} of
        {<<"2.0">>, Method, Params}
          when is_binary(Method),
               byte_size(Method) > 0, is_map(Params) ->
            case valid_request_id(Id) andalso maps:is_key(<<"id">>, Request) of
                true -> {ok, Id, Method, Params};
                false -> {error, null, -32600,
                          <<"Request payload validation error">>}
            end;
        _ ->
            {error, safe_id(Id), -32600,
             <<"Request payload validation error">>}
    end;
validate_jsonrpc_request(_) ->
    {error, null, -32600, <<"Request payload validation error">>}.

-spec result(term(), term()) -> map().
result(Id, Value) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"result">> => Value}.

-spec error_response(term(), integer(), binary()) -> map().
error_response(Id, Code, Message) ->
    error_response(Id, Code, Message, undefined).

-spec error_response(term(), integer(), binary(), undefined | [map()]) -> map().
error_response(Id, Code, Message, undefined) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => safe_id(Id),
      <<"error">> => #{<<"code">> => Code, <<"message">> => Message}};
error_response(Id, Code, Message, Data) when is_list(Data) ->
    (error_response(Id, Code, Message))#{
      <<"error">> => #{<<"code">> => Code,
                        <<"message">> => Message,
                        <<"data">> => Data}}.

-spec terminal_state(term()) -> boolean().
terminal_state(<<"TASK_STATE_COMPLETED">>) -> true;
terminal_state(<<"TASK_STATE_FAILED">>) -> true;
terminal_state(<<"TASK_STATE_CANCELED">>) -> true;
terminal_state(<<"TASK_STATE_REJECTED">>) -> true;
terminal_state(_) -> false.

-spec interrupted_state(term()) -> boolean().
interrupted_state(<<"TASK_STATE_INPUT_REQUIRED">>) -> true;
interrupted_state(<<"TASK_STATE_AUTH_REQUIRED">>) -> true;
interrupted_state(_) -> false.

-spec json_safe(term()) -> {ok, term()} | {error, term()}.
json_safe(Value) ->
    adk_json:normalize(Value).

%% internal

validate_card_fields(Card) ->
    Required = [{<<"name">>, binary},
                {<<"description">>, binary},
                {<<"version">>, binary},
                {<<"supportedInterfaces">>, nonempty_list},
                {<<"capabilities">>, map},
                {<<"defaultInputModes">>, nonempty_binary_list},
                {<<"defaultOutputModes">>, nonempty_binary_list},
                {<<"skills">>, nonempty_list}],
    case validate_required_fields(Required, Card) of
        ok ->
            validate_card_details(Card);
        {error, Field, Reason} ->
            {error, {invalid_agent_card, Field, Reason}}
    end.

validate_card_details(Card) ->
    Interfaces = maps:get(<<"supportedInterfaces">>, Card),
    Skills = maps:get(<<"skills">>, Card),
    Capabilities = maps:get(<<"capabilities">>, Card),
    case validate_interfaces(Interfaces, []) of
        {ok, SafeInterfaces} ->
            case validate_capabilities(Capabilities) of
                {ok, SafeCapabilities} ->
                    case validate_card_security(Card) of
                        {ok, Schemes} ->
                            case validate_skills(Skills, Schemes, []) of
                                {ok, SafeSkills} ->
                                    {ok, Card#{
                                      <<"supportedInterfaces">> =>
                                          SafeInterfaces,
                                      <<"capabilities">> =>
                                          SafeCapabilities,
                                      <<"skills">> => SafeSkills}};
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

validate_interfaces([], Acc) -> {ok, lists:reverse(Acc)};
validate_interfaces([Interface | Rest], Acc) when is_map(Interface) ->
    case {required_binary(<<"url">>, Interface),
          required_binary(<<"protocolBinding">>, Interface),
          required_binary(<<"protocolVersion">>, Interface)} of
        {{ok, Url}, {ok, Binding}, {ok, Version}} ->
            case valid_interface_url(Url) andalso
                 valid_binding(Binding) andalso Version =:= ?VERSION of
                true -> validate_interfaces(Rest, [Interface | Acc]);
                false -> {error, {invalid_agent_card,
                                  <<"supportedInterfaces">>,
                                  unsupported_interface}}
            end;
        _ -> {error, {invalid_agent_card, <<"supportedInterfaces">>,
                      invalid_interface}}
    end;
validate_interfaces(_, _Acc) ->
    {error, {invalid_agent_card, <<"supportedInterfaces">>,
             invalid_interface}}.

valid_binding(<<"JSONRPC">>) -> true;
valid_binding(<<"GRPC">>) -> true;
valid_binding(<<"HTTP+JSON">>) -> true;
valid_binding(Binding) when is_binary(Binding) ->
    %% Custom bindings are identified by a URI in A2A 1.0.
    case uri_string:parse(Binding) of
        #{scheme := _} -> true;
        _ -> false
    end.

valid_interface_url(Url) ->
    byte_size(Url) =< ?MAX_URI_BYTES andalso
    try uri_string:parse(Url) of
        Parsed when is_map(Parsed) ->
            Scheme = to_binary(maps:get(scheme, Parsed, <<>>)),
            Host = to_binary(maps:get(host, Parsed, <<>>)),
            UserInfo = maps:get(userinfo, Parsed, undefined),
            Fragment = maps:get(fragment, Parsed, undefined),
            (Scheme =:= <<"https">> orelse Scheme =:= <<"http">>)
            andalso byte_size(Host) > 0
            andalso UserInfo =:= undefined
            andalso Fragment =:= undefined
    catch
        _:_ -> false
    end.

validate_skills([], _Schemes, Acc) -> {ok, lists:reverse(Acc)};
validate_skills([Skill | Rest], Schemes, Acc) when is_map(Skill) ->
    Fields = [{<<"id">>, binary}, {<<"name">>, binary},
              {<<"description">>, binary},
              {<<"tags">>, nonempty_binary_list}],
    case validate_required_fields(Fields, Skill) of
        ok ->
            case validate_optional_requirements(
                   maps:get(<<"securityRequirements">>, Skill, undefined),
                   Schemes) of
                ok -> validate_skills(Rest, Schemes, [Skill | Acc]);
                {error, Reason} ->
                    {error, {invalid_agent_card, <<"skills">>,
                             <<"securityRequirements">>, Reason}}
            end;
        {error, Field, Reason} ->
            {error, {invalid_agent_card, <<"skills">>, Field, Reason}}
    end;
validate_skills(_, _Schemes, _Acc) ->
    {error, {invalid_agent_card, <<"skills">>, invalid_skill}}.

validate_capabilities(Capabilities) when is_map(Capabilities) ->
    Booleans = [<<"streaming">>, <<"pushNotifications">>,
                <<"extendedAgentCard">>],
    case lists:all(
           fun(Key) ->
               case maps:find(Key, Capabilities) of
                   error -> true;
                   {ok, Value} -> is_boolean(Value)
               end
           end, Booleans) of
        false ->
            {error, {invalid_agent_card, <<"capabilities">>,
                     invalid_capability_flag}};
        true ->
            case maps:get(<<"extensions">>, Capabilities, []) of
                Extensions when is_list(Extensions),
                                length(Extensions) =< ?MAX_EXTENSIONS ->
                    case validate_extensions(Extensions, [], #{}) of
                        {ok, Safe} ->
                            {ok, Capabilities#{<<"extensions">> => Safe}};
                        {error, Reason} ->
                            {error, {invalid_agent_card, <<"capabilities">>,
                                     <<"extensions">>, Reason}}
                    end;
                _ ->
                    {error, {invalid_agent_card, <<"capabilities">>,
                             <<"extensions">>, invalid_extensions}}
            end
    end.

validate_extensions([], Acc, _Seen) -> {ok, lists:reverse(Acc)};
validate_extensions([Extension | Rest], Acc, Seen)
  when is_map(Extension) ->
    Uri = maps:get(<<"uri">>, Extension, undefined),
    Description = maps:get(<<"description">>, Extension, undefined),
    Required = maps:get(<<"required">>, Extension, false),
    Params = maps:get(<<"params">>, Extension, undefined),
    case valid_extension_uri(Uri)
         andalso valid_optional_binary(Description)
         andalso is_boolean(Required)
         andalso (Params =:= undefined orelse is_map(Params))
         andalso not maps:is_key(Uri, Seen) of
        true ->
            validate_extensions(Rest, [Extension | Acc], Seen#{Uri => true});
        false -> {error, invalid_extension}
    end;
validate_extensions(_, _Acc, _Seen) -> {error, invalid_extension}.

valid_extension_uri(Uri) when is_binary(Uri), byte_size(Uri) > 0,
                              byte_size(Uri) =< ?MAX_URI_BYTES ->
    try uri_string:parse(Uri) of
        #{scheme := Scheme} when Scheme =/= <<>>, Scheme =/= "" -> true;
        _ -> false
    catch _:_ -> false
    end;
valid_extension_uri(_) -> false.

validate_card_security(Card) ->
    Schemes0 = maps:get(<<"securitySchemes">>, Card, #{}),
    Requirements = maps:get(<<"securityRequirements">>, Card, undefined),
    case validate_security_schemes(Schemes0) of
        {ok, Schemes} ->
            case validate_optional_requirements(Requirements, Schemes) of
                ok -> {ok, Schemes};
                {error, Reason} ->
                    {error, {invalid_agent_card,
                             <<"securityRequirements">>, Reason}}
            end;
        {error, Reason} ->
            {error, {invalid_agent_card, <<"securitySchemes">>, Reason}}
    end.

validate_security_schemes(Schemes) when is_map(Schemes),
                                         map_size(Schemes) =<
                                             ?MAX_SECURITY_SCHEMES ->
    case lists:all(
           fun({Name, Scheme}) ->
               is_binary(Name) andalso byte_size(Name) > 0
               andalso byte_size(Name) =< 128
               andalso valid_security_scheme(Scheme)
           end, maps:to_list(Schemes)) of
        true -> {ok, Schemes};
        false -> {error, invalid_security_scheme}
    end;
validate_security_schemes(_) -> {error, invalid_security_schemes}.

valid_security_scheme(Scheme) when is_map(Scheme) ->
    Members = [<<"apiKeySecurityScheme">>, <<"httpAuthSecurityScheme">>,
               <<"oauth2SecurityScheme">>,
               <<"openIdConnectSecurityScheme">>,
               <<"mtlsSecurityScheme">>],
    case {map_size(Scheme), present_members(Members, Scheme)} of
        {1, [<<"apiKeySecurityScheme">>]} ->
            valid_api_key_scheme(maps:get(<<"apiKeySecurityScheme">>, Scheme));
        {1, [<<"httpAuthSecurityScheme">>]} ->
            valid_http_auth_scheme(
              maps:get(<<"httpAuthSecurityScheme">>, Scheme));
        {1, [<<"oauth2SecurityScheme">>]} ->
            valid_oauth2_scheme(maps:get(<<"oauth2SecurityScheme">>, Scheme));
        {1, [<<"openIdConnectSecurityScheme">>]} ->
            valid_oidc_scheme(
              maps:get(<<"openIdConnectSecurityScheme">>, Scheme));
        {1, [<<"mtlsSecurityScheme">>]} ->
            valid_description_object(maps:get(<<"mtlsSecurityScheme">>, Scheme));
        _ -> false
    end;
valid_security_scheme(_) -> false.

valid_api_key_scheme(Value) when is_map(Value) ->
    Location = maps:get(<<"location">>, Value, undefined),
    Name = maps:get(<<"name">>, Value, undefined),
    lists:member(Location, [<<"query">>, <<"header">>, <<"cookie">>])
    andalso nonempty_binary(Name)
    andalso valid_optional_description(Value);
valid_api_key_scheme(_) -> false.

valid_http_auth_scheme(Value) when is_map(Value) ->
    nonempty_binary(maps:get(<<"scheme">>, Value, undefined))
    andalso valid_optional_description(Value)
    andalso valid_optional_binary(maps:get(<<"bearerFormat">>, Value,
                                            undefined));
valid_http_auth_scheme(_) -> false.

valid_oauth2_scheme(Value) when is_map(Value) ->
    Flows = maps:get(<<"flows">>, Value, undefined),
    Metadata = maps:get(<<"oauth2MetadataUrl">>, Value, undefined),
    valid_oauth_flows(Flows)
    andalso valid_optional_https_url(Metadata)
    andalso valid_optional_description(Value);
valid_oauth2_scheme(_) -> false.

valid_oauth_flows(Flows) when is_map(Flows), map_size(Flows) =:= 1 ->
    case maps:to_list(Flows) of
        [{<<"authorizationCode">>, Flow}] ->
            valid_oauth_flow(
              Flow, [<<"authorizationUrl">>, <<"tokenUrl">>]);
        [{<<"clientCredentials">>, Flow}] ->
            valid_oauth_flow(Flow, [<<"tokenUrl">>]);
        [{<<"deviceCode">>, Flow}] ->
            valid_oauth_flow(
              Flow, [<<"deviceAuthorizationUrl">>, <<"tokenUrl">>]);
        [{<<"implicit">>, Flow}] ->
            valid_oauth_flow(Flow, [<<"authorizationUrl">>]);
        [{<<"password">>, Flow}] ->
            valid_oauth_flow(Flow, [<<"tokenUrl">>]);
        _ -> false
    end;
valid_oauth_flows(_) -> false.

valid_oauth_flow(Flow, RequiredUrls) when is_map(Flow) ->
    lists:all(fun(Key) -> valid_https_url(maps:get(Key, Flow, undefined)) end,
              RequiredUrls)
    andalso valid_optional_https_url(maps:get(<<"refreshUrl">>, Flow,
                                               undefined))
    andalso valid_scope_descriptions(maps:get(<<"scopes">>, Flow, #{}))
    andalso valid_optional_boolean_value(maps:get(<<"pkceRequired">>, Flow,
                                                  undefined));
valid_oauth_flow(_, _) -> false.

valid_scope_descriptions(Scopes) when is_map(Scopes), map_size(Scopes) =< 128 ->
    lists:all(
      fun({Scope, Description}) ->
          is_binary(Scope) andalso byte_size(Scope) > 0
          andalso byte_size(Scope) =< 256 andalso is_binary(Description)
      end, maps:to_list(Scopes));
valid_scope_descriptions(_) -> false.

valid_optional_boolean_value(undefined) -> true;
valid_optional_boolean_value(Value) -> is_boolean(Value).

valid_oidc_scheme(Value) when is_map(Value) ->
    valid_https_url(maps:get(<<"openIdConnectUrl">>, Value, undefined))
    andalso valid_optional_description(Value);
valid_oidc_scheme(_) -> false.

valid_description_object(Value) when is_map(Value) ->
    valid_optional_description(Value);
valid_description_object(_) -> false.

valid_optional_description(Map) ->
    valid_optional_binary(maps:get(<<"description">>, Map, undefined)).

valid_optional_binary(undefined) -> true;
valid_optional_binary(Value) -> is_binary(Value).

nonempty_binary(Value) -> is_binary(Value) andalso byte_size(Value) > 0.

valid_optional_https_url(undefined) -> true;
valid_optional_https_url(Value) -> valid_https_url(Value).

valid_https_url(Value) when is_binary(Value), byte_size(Value) > 0,
                           byte_size(Value) =< ?MAX_URI_BYTES ->
    try uri_string:parse(Value) of
        Parsed when is_map(Parsed) ->
            to_binary(maps:get(scheme, Parsed, <<>>)) =:= <<"https">>
            andalso byte_size(to_binary(maps:get(host, Parsed, <<>>))) > 0
            andalso maps:get(userinfo, Parsed, undefined) =:= undefined
    catch _:_ -> false
    end;
valid_https_url(_) -> false.

validate_optional_requirements(undefined, _Schemes) -> ok;
validate_optional_requirements(Requirements, Schemes)
  when is_list(Requirements),
       length(Requirements) =< ?MAX_SECURITY_REQUIREMENTS ->
    case lists:all(fun(Requirement) ->
                           valid_security_requirement(Requirement, Schemes)
                   end, Requirements) of
        true -> ok;
        false -> {error, invalid_security_requirement}
    end;
validate_optional_requirements(_, _Schemes) ->
    {error, invalid_security_requirements}.

valid_security_requirement(#{<<"schemes">> := Requirement} = Wrapper, Schemes)
  when map_size(Wrapper) =:= 1, is_map(Requirement),
       map_size(Requirement) > 0 ->
    lists:all(
      fun({Name, ScopeList}) ->
          maps:is_key(Name, Schemes) andalso valid_scope_list(ScopeList)
      end, maps:to_list(Requirement));
valid_security_requirement(_, _Schemes) -> false.

valid_scope_list(#{<<"list">> := Scopes} = Wrapper)
  when map_size(Wrapper) =:= 1, is_list(Scopes), length(Scopes) =< 128 ->
    lists:all(fun(Scope) -> is_binary(Scope) andalso byte_size(Scope) =< 256
              end, Scopes);
valid_scope_list(_) -> false.

validate_message_fields(Message) ->
    case {required_identifier(<<"messageId">>, Message),
          maps:get(<<"role">>, Message, undefined),
          required_nonempty_list(<<"parts">>, Message)} of
        {{ok, _}, Role, {ok, Parts}}
          when length(Parts) =< ?MAX_PARTS andalso
               (Role =:= <<"ROLE_USER">> orelse Role =:= <<"ROLE_AGENT">>) ->
            case validate_list(Parts, fun validate_part/1, []) of
                {ok, SafeParts} ->
                    validate_message_identifiers(
                      Message#{<<"parts">> => SafeParts});
                {error, Reason} ->
                    {error, {invalid_message, <<"parts">>, Reason}}
            end;
        {{error, Reason}, _, _} ->
            {error, {invalid_message, <<"messageId">>, Reason}};
        {_, _, {error, Reason}} ->
            {error, {invalid_message, <<"parts">>, Reason}};
        {{ok, _}, _, {ok, Parts}} when length(Parts) > ?MAX_PARTS ->
            {error, {invalid_message, <<"parts">>, too_many_parts}};
        _ ->
            {error, {invalid_message, <<"role">>, invalid_role}}
    end.

validate_message_identifiers(Message) ->
    Keys = [<<"contextId">>, <<"taskId">>],
    case lists:all(
           fun(Key) ->
               case maps:find(Key, Message) of
                   error -> true;
                   {ok, Value} -> valid_identifier(Value)
               end
           end, Keys) of
        true -> {ok, Message};
        false -> {error, {invalid_message, invalid_identifier}}
    end.

validate_part_fields(Part) ->
    Content = present_members([<<"text">>, <<"raw">>, <<"url">>,
                               <<"data">>], Part),
    case Content of
        [<<"text">>] ->
            validate_part_binary(Part, <<"text">>, ?MAX_MESSAGE_BYTES);
        [<<"raw">>] ->
            %% ProtoJSON represents bytes as base64.  Decoding here catches
            %% malformed file parts without retaining decoded bytes.
            case maps:get(<<"raw">>, Part) of
                Raw when is_binary(Raw),
                         byte_size(Raw) =< ?MAX_ARTIFACT_BYTES ->
                    try base64:decode(Raw) of
                        _ -> validate_optional_part_fields(Part)
                    catch _:_ ->
                        {error, {invalid_part, <<"raw">>, invalid_base64}}
                    end;
                _ -> {error, {invalid_part, <<"raw">>, expected_binary}}
            end;
        [<<"url">>] ->
            case validate_part_binary(Part, <<"url">>, ?MAX_URI_BYTES) of
                {ok, Safe} ->
                    case valid_file_url(maps:get(<<"url">>, Safe)) of
                        true -> {ok, Safe};
                        false -> {error, {invalid_part, <<"url">>,
                                          invalid_url}}
                    end;
                Error -> Error
            end;
        [<<"data">>] ->
            case within_json_bytes(maps:get(<<"data">>, Part),
                                   ?MAX_MESSAGE_BYTES) of
                true -> validate_optional_part_fields(Part);
                false -> {error, {invalid_part, <<"data">>,
                                   payload_too_large}}
            end;
        [] -> {error, {invalid_part, missing_content_member}};
        _ -> {error, {invalid_part, multiple_content_members}}
    end.

validate_stream_member(<<"task">>, Response) ->
    case validate_task(maps:get(<<"task">>, Response)) of
        {ok, Task} -> {ok, Response#{<<"task">> => Task}};
        Error -> Error
    end;
validate_stream_member(<<"message">>, Response) ->
    case validate_message(maps:get(<<"message">>, Response)) of
        {ok, Message} -> {ok, Response#{<<"message">> => Message}};
        Error -> Error
    end;
validate_stream_member(<<"statusUpdate">>, Response) ->
    Update = maps:get(<<"statusUpdate">>, Response),
    case validate_status_update(Update) of
        {ok, Safe} -> {ok, Response#{<<"statusUpdate">> => Safe}};
        Error -> Error
    end;
validate_stream_member(<<"artifactUpdate">>, Response) ->
    Update = maps:get(<<"artifactUpdate">>, Response),
    case validate_artifact_update(Update) of
        {ok, Safe} -> {ok, Response#{<<"artifactUpdate">> => Safe}};
        Error -> Error
    end.

validate_task_fields(Task) ->
    case {required_identifier(<<"id">>, Task),
          maps:get(<<"status">>, Task, undefined)} of
        {{ok, _}, Status} when is_map(Status) ->
            case validate_status(Status) of
                ok ->
                    case validate_optional_task_lists(Task) of
                        {ok, SafeTask} -> validate_optional_context(SafeTask);
                        Error -> Error
                    end;
                {error, Reason} -> {error, {invalid_task, <<"status">>, Reason}}
            end;
        {{error, Reason}, _} ->
            {error, {invalid_task, <<"id">>, Reason}};
        _ -> {error, {invalid_task, <<"status">>, expected_object}}
    end.

validate_optional_task_lists(Task0) ->
    case validate_optional_list(<<"artifacts">>, Task0,
                                fun validate_artifact/1,
                                ?MAX_ARTIFACTS) of
        {ok, Task1} ->
            validate_optional_list(<<"history">>, Task1,
                                   fun validate_message/1,
                                   ?MAX_HISTORY_MESSAGES);
        Error -> Error
    end.

validate_optional_list(Key, Map, Fun, Max) ->
    case maps:find(Key, Map) of
        error -> {ok, Map};
        {ok, Values} when is_list(Values), length(Values) =< Max ->
            case validate_list(Values, Fun, []) of
                {ok, Safe} -> {ok, Map#{Key => Safe}};
                {error, Reason} -> {error, {invalid_task, Key, Reason}}
            end;
        _ -> {error, {invalid_task, Key, expected_list}}
    end.

validate_optional_context(Task) ->
    case maps:find(<<"contextId">>, Task) of
        error -> {ok, Task};
        {ok, Value} when is_binary(Value), byte_size(Value) > 0,
                         byte_size(Value) =< ?MAX_IDENTIFIER_BYTES ->
            {ok, Task};
        _ -> {error, {invalid_task, <<"contextId">>,
                      expected_nonempty_binary}}
    end.

validate_status(Status) ->
    State = maps:get(<<"state">>, Status, undefined),
    Timestamp = maps:get(<<"timestamp">>, Status, undefined),
    Message = maps:get(<<"message">>, Status, undefined),
    case valid_task_state(State) andalso valid_optional_timestamp(Timestamp) of
        false -> {error, invalid_status};
        true ->
            case Message of
                undefined -> ok;
                _ ->
                    case validate_message(Message) of
                        {ok, _} -> ok;
                        {error, Reason} -> {error, Reason}
                    end
            end
    end.

validate_status_update(Update) when is_map(Update) ->
    case {required_identifier(<<"taskId">>, Update),
          required_identifier(<<"contextId">>, Update),
          maps:get(<<"status">>, Update, undefined)} of
        {{ok, _}, {ok, _}, Status} when is_map(Status) ->
            case validate_status(Status) of
                ok -> {ok, Update};
                {error, Reason} ->
                    {error, {invalid_status_update, Reason}}
            end;
        _ -> {error, {invalid_status_update, missing_required_field}}
    end;
validate_status_update(_) ->
    {error, {invalid_status_update, expected_object}}.

validate_artifact_update(Update) when is_map(Update) ->
    case {required_identifier(<<"taskId">>, Update),
          required_identifier(<<"contextId">>, Update),
          maps:find(<<"artifact">>, Update)} of
        {{ok, _}, {ok, _}, {ok, Artifact0}} ->
            case {adk_a2a_v1_codec:validate_artifact(Artifact0),
                  valid_optional_boolean(<<"append">>, Update),
                  valid_optional_boolean(<<"lastChunk">>, Update)} of
                {{ok, Artifact}, true, true} ->
                    {ok, Update#{<<"artifact">> => Artifact}};
                _ -> {error, {invalid_artifact_update, invalid_field}}
            end;
        _ -> {error, {invalid_artifact_update, missing_required_field}}
    end;
validate_artifact_update(_) ->
    {error, {invalid_artifact_update, expected_object}}.

valid_optional_boolean(Key, Map) ->
    case maps:find(Key, Map) of
        error -> true;
        {ok, Value} -> is_boolean(Value)
    end.

valid_task_state(<<"TASK_STATE_UNSPECIFIED">>) -> true;
valid_task_state(<<"TASK_STATE_SUBMITTED">>) -> true;
valid_task_state(<<"TASK_STATE_WORKING">>) -> true;
valid_task_state(<<"TASK_STATE_COMPLETED">>) -> true;
valid_task_state(<<"TASK_STATE_FAILED">>) -> true;
valid_task_state(<<"TASK_STATE_CANCELED">>) -> true;
valid_task_state(<<"TASK_STATE_INPUT_REQUIRED">>) -> true;
valid_task_state(<<"TASK_STATE_REJECTED">>) -> true;
valid_task_state(<<"TASK_STATE_AUTH_REQUIRED">>) -> true;
valid_task_state(_) -> false.

valid_optional_timestamp(undefined) -> true;
valid_optional_timestamp(Value) when is_binary(Value) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Value),
                                        [{unit, millisecond}]) of
        _ -> true
    catch _:_ -> false
    end;
valid_optional_timestamp(_) -> false.

validate_part_binary(Part, Key, MaxBytes) ->
    case maps:get(Key, Part) of
        Value when is_binary(Value), byte_size(Value) =< MaxBytes ->
            validate_optional_part_fields(Part);
        _ -> {error, {invalid_part, Key, expected_binary}}
    end.

validate_optional_part_fields(Part) ->
    Keys = [<<"filename">>, <<"mediaType">>],
    case lists:all(
           fun(Key) ->
               case maps:find(Key, Part) of
                   error -> true;
                   {ok, Value} -> is_binary(Value)
                                  andalso byte_size(Value) =< ?MAX_FIELD_BYTES
               end
           end, Keys) of
        true -> {ok, Part};
        false -> {error, {invalid_part, invalid_optional_field}}
    end.

valid_file_url(Url) ->
    try uri_string:parse(Url) of
        Parsed when is_map(Parsed) ->
            maps:is_key(scheme, Parsed) andalso
            maps:get(userinfo, Parsed, undefined) =:= undefined
    catch _:_ -> false
    end.

validate_list([], _Fun, Acc) -> {ok, lists:reverse(Acc)};
validate_list([Value | Rest], Fun, Acc) ->
    case Fun(Value) of
        {ok, Safe} -> validate_list(Rest, Fun, [Safe | Acc]);
        {error, _} = Error -> Error
    end.

validate_required_fields([], _Map) -> ok;
validate_required_fields([{Key, Type} | Rest], Map) ->
    case valid_required(Type, maps:get(Key, Map, undefined)) of
        true -> validate_required_fields(Rest, Map);
        false -> {error, Key, {expected, Type}}
    end.

valid_required(binary, Value) -> is_binary(Value) andalso byte_size(Value) > 0;
valid_required(map, Value) -> is_map(Value);
valid_required(nonempty_list, Value) -> is_list(Value) andalso Value =/= [];
valid_required(nonempty_binary_list, Value) ->
    is_list(Value) andalso Value =/= [] andalso
    lists:all(fun(V) -> is_binary(V) andalso byte_size(V) > 0 end, Value).

required_binary(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 -> {ok, Value};
        _ -> {error, expected_nonempty_binary}
    end.

required_identifier(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0,
                   byte_size(Value) =< ?MAX_IDENTIFIER_BYTES -> {ok, Value};
        _ -> {error, invalid_identifier}
    end.

valid_identifier(Value) ->
    is_binary(Value) andalso byte_size(Value) > 0
    andalso byte_size(Value) =< ?MAX_IDENTIFIER_BYTES.

required_nonempty_list(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        Value when is_list(Value), Value =/= [] -> {ok, Value};
        _ -> {error, expected_nonempty_list}
    end.

present_members(Keys, Map) ->
    [Key || Key <- Keys, maps:is_key(Key, Map)].

within_json_bytes(Value, Max) ->
    try jsx:encode(Value) of
        Encoded when is_binary(Encoded) -> byte_size(Encoded) =< Max
    catch _:_ -> false
    end.

reject_kind(Map, Type) ->
    case maps:is_key(<<"kind">>, Map) of
        true -> {error, {invalid_a2a_1_0_object, Type,
                         legacy_kind_discriminator}};
        false -> ok
    end.

valid_request_id(Id) ->
    is_binary(Id) orelse is_integer(Id) orelse is_float(Id).

safe_id(Id) ->
    case valid_request_id(Id) of true -> Id; false -> null end.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.
