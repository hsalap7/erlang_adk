-module(adk_openapi_toolset_test).

-include_lib("eunit/include/eunit.hrl").

openapi_toolset_test_() ->
    [fun deterministic_schema_generation/0,
     fun path_query_header_and_body_encoding/0,
     fun auth_is_out_of_band_and_response_is_redacted/0,
     fun invalid_specs_and_limits_are_rejected/0,
     fun target_allowlist_and_ssrf_policy/0,
     fun bounded_transport_timeout_kills_worker/0,
     fun request_and_response_limits/0,
     fun status_redirect_and_json_handling/0].

deterministic_schema_generation() ->
    Opts = compile_opts(self()),
    {ok, Toolset1} = adk_openapi_toolset:compile(base_spec(), Opts),
    {ok, Toolset2} = adk_openapi_toolset:compile(base_spec(), Opts),
    Schemas = adk_openapi_toolset:schemas(Toolset1),
    ?assertEqual(Schemas, adk_openapi_toolset:schemas(Toolset2)),
    ?assertEqual([<<"getPet">>, <<"updatePet">>],
                 [maps:get(<<"name">>, Schema) || Schema <- Schemas]),
    {ok, Update} = adk_openapi_toolset:schema(Toolset1, <<"updatePet">>),
    Parameters = maps:get(<<"parameters">>, Update),
    Properties = maps:get(<<"properties">>, Parameters),
    ?assertEqual(
       [<<"X-Trace">>, <<"body">>, <<"limit">>, <<"petId">>, <<"tags">>],
       lists:sort(maps:keys(Properties))),
    ?assertEqual([<<"body">>, <<"petId">>],
                 maps:get(<<"required">>, Parameters)),
    ?assertEqual(false, maps:get(<<"additionalProperties">>, Parameters)),
    BodySchema = maps:get(<<"body">>, Properties),
    ?assertEqual(<<"object">>, maps:get(<<"type">>, BodySchema)),
    ?assertNot(maps:is_key(<<"$ref">>, BodySchema)),
    ?assertEqual({error, unknown_tool},
                 adk_openapi_toolset:schema(Toolset1, <<"missing">>)).

path_query_header_and_body_encoding() ->
    Parent = self(),
    Transport = start_transport(
                  Parent,
                  fun(_Request) ->
                      json_response(200, #{<<"name">> => <<"Ada">>,
                                           <<"age">> => 4})
                  end),
    {ok, Toolset} = adk_openapi_toolset:compile(
                      base_spec(), compile_opts(Transport)),
    Args = #{<<"petId">> => <<"a/b c">>,
             <<"limit">> => 2,
             <<"tags">> => [<<"red">>, <<"blue">>],
             <<"X-Trace">> => <<"trace-1">>,
             <<"body">> => #{<<"name">> => <<"Ada">>, <<"age">> => 4}},
    ?assertEqual(
       {ok, #{<<"status">> => 200,
              <<"data">> => #{<<"name">> => <<"Ada">>,
                                <<"age">> => 4}}},
       adk_openapi_toolset:execute(Toolset, <<"updatePet">>, Args)),
    {_Worker, Request} = receive_transport_request(),
    ?assertEqual(<<"POST">>, maps:get(method, Request)),
    ?assertEqual(
       <<"https://api.example.com/v1/pets/a%2Fb%20c?limit=2&tags=red&tags=blue">>,
       maps:get(url, Request)),
    ?assertEqual(false, maps:get(follow_redirects, Request)),
    Headers = maps:from_list(maps:get(headers, Request)),
    ?assertEqual(<<"trace-1">>, maps:get(<<"x-trace">>, Headers)),
    ?assertEqual(<<"application/json">>,
                 maps:get(<<"content-type">>, Headers)),
    ?assertEqual(maps:get(<<"body">>, Args),
                 jsx:decode(maps:get(body, Request), [return_maps])),
    ?assertEqual(
       {error, invalid_arguments},
       adk_openapi_toolset:execute(
         Toolset, <<"updatePet">>,
         Args#{<<"X-Trace">> => <<"ok\r\nx-injected: yes">>})),
    ?assertEqual(no_transport_request,
                 maybe_receive_transport_request(30)),
    Transport ! stop.

auth_is_out_of_band_and_response_is_redacted() ->
    Parent = self(),
    Auth = start_auth(Parent),
    Transport = start_transport(
                  Parent,
                  fun(Request) ->
                      Secret = request_credential(Request),
                      json_response(
                        200,
                        #{<<"echo">> => Secret,
                          <<"access_token">> => <<"server-token">>})
                  end),
    Opts = (compile_opts(Transport))#{auth =>
                 {adk_openapi_test_auth, Auth}},
    {ok, Toolset} = adk_openapi_toolset:compile(auth_spec(), Opts),
    Context = #{access_token => <<"context-secret-must-not-travel">>,
                user_id => <<"user">>},
    lists:foreach(
      fun({Operation, ExpectedType, ExpectedLocation}) ->
          {ok, Result} = adk_openapi_toolset:execute(
                           Toolset, Operation, #{}, Context),
          Data = maps:get(<<"data">>, Result),
          ?assertNot(maps:is_key(<<"access_token">>, Data)),
          Echo = maps:get(<<"echo">>, Data),
          ?assertEqual(nomatch,
                       binary:match(Echo, expected_secret(ExpectedType))),
          {_AuthWorker, AuthRequest} = receive_auth_request(),
          ?assertEqual(ExpectedType, maps:get(scheme_type, AuthRequest)),
          case ExpectedType of
              api_key ->
                  ?assertEqual(ExpectedLocation,
                               maps:get(location, AuthRequest));
              oauth2 ->
                  ?assertEqual([<<"read:pets">>],
                               maps:get(scopes, AuthRequest));
              bearer -> ok
          end,
          ?assertNot(contains_binary(AuthRequest,
                                    <<"context-secret-must-not-travel">>)),
          {_TransportWorker, HttpRequest} = receive_transport_request(),
          assert_auth_applied(ExpectedType, ExpectedLocation, HttpRequest),
          ?assertNot(contains_binary(Result, expected_secret(ExpectedType)))
      end,
      [{<<"apiOperation">>, api_key, header},
       {<<"apiQueryOperation">>, api_key, query},
       {<<"bearerOperation">>, bearer, header},
       {<<"oauthOperation">>, oauth2, header}]),
    {ok, ApiSchema} = adk_openapi_toolset:schema(Toolset,
                                                <<"apiOperation">>),
    ?assertEqual(#{}, maps:get(<<"properties">>,
                              maps:get(<<"parameters">>, ApiSchema))),
    Auth ! stop,
    Transport ! stop.

invalid_specs_and_limits_are_rejected() ->
    Opts = compile_opts(self()),
    MissingOperationId = update_operation(
                           base_spec(), <<"post">>,
                           fun(Operation) ->
                               maps:remove(<<"operationId">>, Operation)
                           end),
    ?assertEqual({error, missing_operation_id},
                 adk_openapi_toolset:compile(MissingOperationId, Opts)),

    RemoteRef = update_operation(
                  base_spec(), <<"post">>,
                  fun(Operation) ->
                      Body = maps:get(<<"requestBody">>, Operation),
                      Content = maps:get(<<"content">>, Body),
                      Media = maps:get(<<"application/json">>, Content),
                      Operation#{<<"requestBody">> =>
                        Body#{<<"content">> =>
                          Content#{<<"application/json">> =>
                            Media#{<<"schema">> =>
                              #{<<"$ref">> =>
                                <<"https://evil.example/schema.json">>}}}}}
                  end),
    ?assertEqual({error, remote_reference_not_allowed},
                 adk_openapi_toolset:compile(RemoteRef, Opts)),

    MismatchedPath = remove_path_parameter(base_spec()),
    ?assertEqual({error, path_parameter_mismatch},
                 adk_openapi_toolset:compile(MismatchedPath, Opts)),
    ?assertEqual({error, too_many_openapi_operations},
                 adk_openapi_toolset:compile(
                   base_spec(), Opts#{max_operations => 1})),
    ?assertEqual({error, too_many_openapi_parameters},
                 adk_openapi_toolset:compile(
                   base_spec(), Opts#{max_parameters => 2})),
    CredentialArgument = update_operation(
                           base_spec(), <<"post">>,
                           fun(Operation) ->
                               Parameters = maps:get(<<"parameters">>, Operation),
                               Operation#{<<"parameters">> =>
                                 [#{<<"name">> => <<"X-API-Key">>,
                                    <<"in">> => <<"header">>,
                                    <<"schema">> =>
                                        #{<<"type">> => <<"string">>}}
                                  | Parameters]}
                           end),
    ?assertEqual({error, unsafe_openapi_parameter},
                 adk_openapi_toolset:compile(CredentialArgument, Opts)).

target_allowlist_and_ssrf_policy() ->
    Evil = set_server(base_spec(), <<"https://evil.example/v1">>),
    ?assertEqual({error, openapi_target_not_allowed},
                 adk_openapi_toolset:compile(Evil, compile_opts(self()))),
    LocalOpts = #{transport => {adk_openapi_test_transport, self()},
                  allowed_hosts => [<<"localhost">>]},
    ?assertEqual({error, private_host_not_allowed},
                 adk_openapi_toolset:compile(
                   set_server(base_spec(), <<"http://localhost:8080">>),
                   LocalOpts#{allowed_schemes => [<<"http">>]})),
    RelativeEscape = set_server(base_spec(), <<"//evil.example/v1">>),
    ?assertEqual(
       {error, openapi_target_not_allowed},
       adk_openapi_toolset:compile(
         RelativeEscape,
         (compile_opts(self()))#{base_url =>
                                     <<"https://api.example.com/root/">>})).

bounded_transport_timeout_kills_worker() ->
    Parent = self(),
    Transport = start_transport(Parent, fun(_Request) -> no_reply end),
    {ok, Toolset} = adk_openapi_toolset:compile(
                      base_spec(),
                      (compile_opts(Transport))#{timeout_ms => 50}),
    ?assertEqual(
       {error, timeout},
       adk_openapi_toolset:execute(
         Toolset, <<"getPet">>, #{<<"petId">> => <<"one">>})),
    {Worker, Request} = receive_transport_request(),
    ?assertEqual(false, maps:get(follow_redirects, Request)),
    ?assertNot(is_process_alive(Worker)),
    Transport ! stop.

request_and_response_limits() ->
    Parent = self(),
    RequestTransport = start_transport(
                         Parent, fun(_Request) -> json_response(200, #{}) end),
    {ok, RequestToolset} = adk_openapi_toolset:compile(
                             base_spec(),
                             (compile_opts(RequestTransport))#{
                               max_request_body_bytes => 16}),
    LargeArgs = #{<<"petId">> => <<"one">>,
                  <<"body">> => #{<<"name">> =>
                                      binary:copy(<<"x">>, 100)}},
    ?assertEqual(
       {error, request_body_too_large},
       adk_openapi_toolset:execute(
         RequestToolset, <<"updatePet">>, LargeArgs)),
    ?assertEqual(no_transport_request,
                 maybe_receive_transport_request(30)),
    RequestTransport ! stop,

    ResponseTransport = start_transport(
                          Parent,
                          fun(_Request) ->
                              {ok, #{status => 200,
                                     headers => [{<<"content-type">>,
                                                  <<"application/json">>}],
                                     body => binary:copy(<<"x">>, 100)}}
                          end),
    {ok, ResponseToolset} = adk_openapi_toolset:compile(
                              base_spec(),
                              (compile_opts(ResponseTransport))#{
                                max_response_bytes => 32}),
    ?assertEqual(
       {error, response_too_large},
       adk_openapi_toolset:execute(
         ResponseToolset, <<"getPet">>, #{<<"petId">> => <<"one">>})),
    _ = receive_transport_request(),
    ResponseTransport ! stop.

status_redirect_and_json_handling() ->
    Parent = self(),
    assert_transport_outcome(
      Parent, fun(_Request) -> json_response(500,
                                            #{<<"secret">> => <<"hidden">>}) end,
      {error, {http_status, 500}}),
    assert_transport_outcome(
      Parent,
      fun(_Request) ->
          {ok, #{status => 302,
                 headers => [{<<"location">>, <<"https://evil.example">>}],
                 body => <<>>}}
      end,
      {error, {redirect_rejected, 302}}),
    assert_transport_outcome(
      Parent,
      fun(_Request) ->
          {ok, #{status => 200,
                 headers => [{<<"content-type">>, <<"application/json">>}],
                 body => <<"not-json">>}}
      end,
      {error, invalid_json_response}),
    assert_transport_outcome(
      Parent, fun(_Request) -> json_response(200, #{<<"age">> => 4}) end,
      {error, response_schema_mismatch}),
    assert_transport_outcome(
      Parent, fun(_Request) -> json_response(204, #{}) end,
      {error, {unexpected_http_status, 204}}).

assert_transport_outcome(Parent, Handler, Expected) ->
    Transport = start_transport(Parent, Handler),
    {ok, Toolset} = adk_openapi_toolset:compile(
                      base_spec(), compile_opts(Transport)),
    ?assertEqual(Expected,
                 adk_openapi_toolset:execute(
                   Toolset, <<"getPet">>, #{<<"petId">> => <<"one">>})),
    {_Worker, Request} = receive_transport_request(),
    ?assertEqual(false, maps:get(follow_redirects, Request)),
    Transport ! stop.

compile_opts(Transport) ->
    #{transport => {adk_openapi_test_transport, Transport},
      allowed_hosts => [<<"api.example.com">>]}.

base_spec() ->
    #{<<"openapi">> => <<"3.1.0">>,
      <<"info">> => #{<<"title">> => <<"Pets">>,
                      <<"version">> => <<"1">>},
      <<"servers">> => [#{<<"url">> =>
                              <<"https://api.example.com/v1">>}],
      <<"paths">> => #{
        <<"/pets/{petId}">> => #{
          <<"parameters">> => [path_parameter()],
          <<"get">> => #{
            <<"operationId">> => <<"getPet">>,
            <<"description">> => <<"Fetch one pet">>,
            <<"parameters">> => [
              #{<<"name">> => <<"verbose">>, <<"in">> => <<"query">>,
                <<"schema">> => #{<<"type">> => <<"boolean">>}}
            ],
            <<"responses">> => success_responses(<<"200">>)},
          <<"post">> => #{
            <<"operationId">> => <<"updatePet">>,
            <<"summary">> => <<"Update one pet">>,
            <<"parameters">> => [
              #{<<"name">> => <<"limit">>, <<"in">> => <<"query">>,
                <<"schema">> => #{<<"type">> => <<"integer">>}},
              #{<<"name">> => <<"tags">>, <<"in">> => <<"query">>,
                <<"explode">> => true,
                <<"schema">> => #{<<"type">> => <<"array">>,
                                  <<"items">> =>
                                      #{<<"type">> => <<"string">>}}},
              #{<<"name">> => <<"X-Trace">>, <<"in">> => <<"header">>,
                <<"schema">> => #{<<"type">> => <<"string">>}}
            ],
            <<"requestBody">> => #{
              <<"required">> => true,
              <<"content">> => #{<<"application/json">> =>
                #{<<"schema">> =>
                    #{<<"$ref">> =>
                          <<"#/components/schemas/PetUpdate">>}}}},
            <<"responses">> => success_responses(<<"200">>)}
        }},
      <<"components">> => #{
        <<"schemas">> => #{
          <<"PetUpdate">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
              <<"name">> => #{<<"type">> => <<"string">>},
              <<"age">> => #{<<"type">> => <<"integer">>}},
            <<"required">> => [<<"name">>],
            <<"additionalProperties">> => false},
          <<"Pet">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
              <<"name">> => #{<<"type">> => <<"string">>},
              <<"age">> => #{<<"type">> => <<"integer">>}},
            <<"required">> => [<<"name">>]}
        }}
    }.

path_parameter() ->
    #{<<"name">> => <<"petId">>, <<"in">> => <<"path">>,
      <<"required">> => true,
      <<"schema">> => #{<<"type">> => <<"string">>}}.

success_responses(Status) ->
    #{Status => #{
       <<"description">> => <<"Success">>,
       <<"content">> => #{<<"application/json">> =>
         #{<<"schema">> => #{<<"$ref">> =>
                                   <<"#/components/schemas/Pet">>}}}}}.

auth_spec() ->
    Response = #{<<"200">> => #{
      <<"description">> => <<"Success">>,
      <<"content">> => #{<<"application/json">> =>
        #{<<"schema">> => #{
          <<"type">> => <<"object">>,
          <<"properties">> => #{
            <<"echo">> => #{<<"type">> => <<"string">>},
            <<"access_token">> => #{<<"type">> => <<"string">>}},
          <<"required">> => [<<"echo">>]}}}}},
    Operation = fun(Id, Security) ->
        #{<<"operationId">> => Id,
          <<"security">> => Security,
          <<"responses">> => Response}
    end,
    #{<<"openapi">> => <<"3.0.3">>,
      <<"info">> => #{<<"title">> => <<"Auth">>,
                      <<"version">> => <<"1">>},
      <<"servers">> => [#{<<"url">> =>
                              <<"https://api.example.com">>}],
      <<"paths">> => #{
        <<"/api">> => #{<<"get">> =>
          Operation(<<"apiOperation">>,
                    [#{<<"ApiKeyAuth">> => []}])},
        <<"/api-query">> => #{<<"get">> =>
          Operation(<<"apiQueryOperation">>,
                    [#{<<"ApiQueryAuth">> => []}])},
        <<"/bearer">> => #{<<"get">> =>
          Operation(<<"bearerOperation">>,
                    [#{<<"BearerAuth">> => []}])},
        <<"/oauth">> => #{<<"get">> =>
          Operation(<<"oauthOperation">>,
                    [#{<<"OAuth">> => [<<"read:pets">>]}])}
      },
      <<"components">> => #{<<"securitySchemes">> => #{
        <<"ApiKeyAuth">> => #{<<"type">> => <<"apiKey">>,
                              <<"in">> => <<"header">>,
                              <<"name">> => <<"X-API-Key">>},
        <<"ApiQueryAuth">> => #{<<"type">> => <<"apiKey">>,
                                <<"in">> => <<"query">>,
                                <<"name">> => <<"api_key">>},
        <<"BearerAuth">> => #{<<"type">> => <<"http">>,
                              <<"scheme">> => <<"bearer">>},
        <<"OAuth">> => #{<<"type">> => <<"oauth2">>,
                         <<"flows">> => #{<<"clientCredentials">> => #{
                           <<"tokenUrl">> => <<"https://auth.example/token">>,
                           <<"scopes">> =>
                               #{<<"read:pets">> => <<"Read pets">>}}}}
      }}}.

update_operation(Spec, Method, Fun) ->
    Paths = maps:get(<<"paths">>, Spec),
    Path = maps:get(<<"/pets/{petId}">>, Paths),
    Operation = maps:get(Method, Path),
    Spec#{<<"paths">> =>
      Paths#{<<"/pets/{petId}">> =>
        Path#{Method => Fun(Operation)}}}.

remove_path_parameter(Spec) ->
    Paths = maps:get(<<"paths">>, Spec),
    Path = maps:get(<<"/pets/{petId}">>, Paths),
    Spec#{<<"paths">> =>
      Paths#{<<"/pets/{petId}">> =>
        maps:remove(<<"parameters">>, Path)}}.

set_server(Spec, Url) ->
    Spec#{<<"servers">> => [#{<<"url">> => Url}]}.

json_response(Status, Value) ->
    {ok, #{status => Status,
           headers => [{<<"content-type">>, <<"application/json">>}],
           body => jsx:encode(Value)}}.

start_transport(Parent, Handler) ->
    spawn(fun() -> transport_loop(Parent, Handler) end).

transport_loop(Parent, Handler) ->
    receive
        {openapi_transport_request, Worker, Ref, Request} ->
            Parent ! {captured_transport_request, Worker, Request},
            case Handler(Request) of
                no_reply -> ok;
                Reply -> Worker ! {openapi_transport_reply, Ref, Reply}
            end,
            transport_loop(Parent, Handler);
        stop -> ok
    end.

start_auth(Parent) ->
    spawn(fun() -> auth_loop(Parent) end).

auth_loop(Parent) ->
    receive
        {openapi_auth_request, Worker, Ref, Request} ->
            Parent ! {captured_auth_request, Worker, Request},
            Credential = case maps:get(scheme_type, Request) of
                api_key -> {api_key, expected_secret(api_key)};
                bearer -> {bearer, expected_secret(bearer)};
                oauth2 -> {bearer, expected_secret(oauth2)}
            end,
            Worker ! {openapi_auth_reply, Ref, {ok, Credential}},
            auth_loop(Parent);
        stop -> ok
    end.

expected_secret(api_key) -> <<"api-secret">>;
expected_secret(bearer) -> <<"bearer-secret">>;
expected_secret(oauth2) -> <<"oauth-secret">>.

request_credential(Request) ->
    Headers = maps:from_list(maps:get(headers, Request)),
    case maps:find(<<"x-api-key">>, Headers) of
        {ok, Value} -> Value;
        error ->
            case maps:find(<<"authorization">>, Headers) of
                {ok, Value} -> Value;
                error ->
                    #{query := Query} = uri_string:parse(maps:get(url, Request)),
                    maps:get(<<"api_key">>,
                             maps:from_list(uri_string:dissect_query(Query)))
            end
    end.

assert_auth_applied(api_key, header, Request) ->
    Headers = maps:from_list(maps:get(headers, Request)),
    ?assertEqual(expected_secret(api_key),
                 maps:get(<<"x-api-key">>, Headers));
assert_auth_applied(api_key, query, Request) ->
    #{query := Query} = uri_string:parse(maps:get(url, Request)),
    ?assertEqual(expected_secret(api_key),
                 maps:get(<<"api_key">>,
                          maps:from_list(uri_string:dissect_query(Query))));
assert_auth_applied(Type, _Location, Request) ->
    Headers = maps:from_list(maps:get(headers, Request)),
    ?assertEqual(<<"Bearer ", (expected_secret(Type))/binary>>,
                 maps:get(<<"authorization">>, Headers)).

receive_transport_request() ->
    receive
        {captured_transport_request, Worker, Request} -> {Worker, Request}
    after 2000 -> error(missing_transport_request)
    end.

maybe_receive_transport_request(Timeout) ->
    receive
        {captured_transport_request, Worker, Request} -> {Worker, Request}
    after Timeout -> no_transport_request
    end.

receive_auth_request() ->
    receive
        {captured_auth_request, Worker, Request} -> {Worker, Request}
    after 2000 -> error(missing_auth_request)
    end.

contains_binary(Binary, Needle) when is_binary(Binary) ->
    binary:match(Binary, Needle) =/= nomatch;
contains_binary(Map, Needle) when is_map(Map) ->
    lists:any(fun({Key, Value}) -> contains_binary(Key, Needle) orelse
                                   contains_binary(Value, Needle)
              end, maps:to_list(Map));
contains_binary(List, Needle) when is_list(List) ->
    lists:any(fun(Value) -> contains_binary(Value, Needle) end, List);
contains_binary(Tuple, Needle) when is_tuple(Tuple) ->
    contains_binary(tuple_to_list(Tuple), Needle);
contains_binary(_Value, _Needle) -> false.
