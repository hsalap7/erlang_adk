-module(adk_openapi_toolset_boundaries_test).

-include_lib("eunit/include/eunit.hrl").

openapi_toolset_boundaries_test_() ->
    [fun public_and_option_boundaries/0,
     fun spec_and_operation_boundaries/0,
     fun parameter_boundaries/0,
     fun body_response_and_server_boundaries/0,
     fun security_boundaries/0,
     fun scalar_and_resolved_execution/0,
     fun response_and_transport_boundaries/0,
     fun authentication_boundaries/0].

public_and_option_boundaries() ->
    Capabilities = adk_openapi_toolset:capabilities(),
    ?assertEqual([<<"3.0">>, <<"3.1">>],
                 maps:get(openapi_versions, Capabilities)),
    ?assertEqual({error, invalid_openapi_document},
                 adk_openapi_toolset:compile(not_a_map, #{})),
    ?assertEqual({error, invalid_openapi_document},
                 adk_openapi_toolset:compile(#{}, not_a_map)),
    ?assertEqual({error, {invalid_openapi_option, transport}},
                 adk_openapi_toolset:compile(minimal_spec(), #{})),
    Base = compile_opts(json),
    assert_option_error(auth, Base#{auth => invalid}),
    assert_option_error(allow_private_hosts,
                        Base#{allow_private_hosts => enabled}),
    lists:foreach(
      fun(Value) -> assert_option_error(allowed_schemes,
                                        Base#{allowed_schemes => Value}) end,
      [[], [<<"ftp">>], [<<"https">>, <<"HTTPS">>], [<<"https">>, atom]]),
    lists:foreach(
      fun(Value) -> assert_option_error(allowed_hosts,
                                        Base#{allowed_hosts => Value}) end,
      [undefined, [], [atom], [<<"bad..example">>], [<<>>]]),
    ?assertEqual({error, private_host_not_allowed},
                 adk_openapi_toolset:compile(
                   minimal_spec(), Base#{allowed_hosts => [<<"127.0.0.1">>]})),
    lists:foreach(
      fun(Key) -> assert_option_error(Key, Base#{Key => 0}) end,
      [timeout_ms, max_request_body_bytes, max_response_bytes,
       max_spec_bytes, max_operations, max_parameters, max_responses,
       max_schema_depth]),
    assert_option_error(base_url, Base#{base_url => <<>>}),
    assert_option_error(base_url, Base#{base_url => 42}),
    ?assertEqual({error, unsafe_openapi_server},
                 adk_openapi_toolset:compile(
                   minimal_spec(), Base#{base_url =>
                                             <<"https://user@api.example.com">>})),
    ?assertEqual({error, unsafe_openapi_server},
                 adk_openapi_toolset:compile(
                   minimal_spec(), Base#{base_url =>
                                             <<"https://api.example.com?q=1">>})),
    {ok, Toolset} = adk_openapi_toolset:compile(minimal_spec(), Base),
    ?assertEqual({error, unknown_tool},
                 adk_openapi_toolset:schema(Toolset, <<"missing">>)),
    ?assertEqual({error, unknown_tool},
                 adk_openapi_toolset:schema(Toolset, atom)),
    ?assertEqual({error, unknown_tool},
                 adk_openapi_toolset:execute(Toolset, <<"missing">>, #{})),
    ?assertEqual({error, invalid_openapi_execution},
                 adk_openapi_toolset:execute(Toolset, atom, #{}, #{})),
    ?assertEqual({error, invalid_openapi_execution},
                 adk_openapi_toolset:execute(Toolset, <<"getValue">>, [], #{})),
    ?assertEqual({error, unknown_tool},
                 adk_openapi_toolset:resolved_call(
                   Toolset, <<"missing">>, #{}, #{})),
    ?assertEqual({error, invalid_openapi_execution},
                 adk_openapi_toolset:resolved_call(
                   Toolset, atom, #{}, #{})).

spec_and_operation_boundaries() ->
    Opts = compile_opts(json),
    ?assertEqual({error, openapi_document_too_large},
                 adk_openapi_toolset:compile(
                   minimal_spec(), Opts#{max_spec_bytes => 10})),
    ?assertEqual({error, invalid_openapi_document},
                 adk_openapi_toolset:compile(
                   #{<<"openapi">> => {invalid, json}}, Opts)),
    assert_compile_error(invalid_openapi_version,
                         maps:remove(<<"openapi">>, minimal_spec())),
    assert_compile_error(invalid_openapi_version,
                         (minimal_spec())#{<<"openapi">> => 31}),
    assert_compile_error(invalid_openapi_paths,
                         maps:remove(<<"paths">>, minimal_spec())),
    assert_compile_error(invalid_openapi_paths,
                         (minimal_spec())#{<<"paths">> => #{}}),
    assert_compile_error(openapi_has_no_operations,
                         (minimal_spec())#{<<"paths">> =>
                           #{<<"x-extension">> => #{}}}),
    assert_compile_error(invalid_openapi_path,
                         (minimal_spec())#{<<"paths">> =>
                           #{<<"relative">> => #{<<"get">> => operation()}}}),
    assert_compile_error(invalid_openapi_path_item,
                         (minimal_spec())#{<<"paths">> =>
                           #{<<"/value">> => <<"not-an-object">>}}),
    assert_compile_error(invalid_openapi_path_item_key,
                         with_path(fun(Path) -> Path#{<<"unknown">> => true} end)),
    assert_compile_error(invalid_openapi_path_item,
                         with_path(fun(Path) -> Path#{<<"summary">> => 42} end)),
    assert_compile_error(invalid_openapi_operation,
                         with_path(fun(Path) -> Path#{<<"get">> => <<"invalid">>} end)),
    assert_compile_error(invalid_openapi_operation_key,
                         with_operation(fun(Op) -> Op#{<<"unknown">> => true} end)),
    assert_compile_error(invalid_openapi_operation,
                         with_operation(fun(Op) -> Op#{<<"tags">> => [<<"ok">>, 42]} end)),
    assert_compile_error(invalid_openapi_operation,
                         with_operation(fun(Op) -> Op#{<<"deprecated">> => <<"yes">>} end)),
    assert_compile_error(invalid_openapi_operation,
                         with_operation(fun(Op) -> Op#{<<"externalDocs">> => []} end)),
    assert_compile_error(invalid_operation_id,
                         with_operation(fun(Op) -> Op#{<<"operationId">> =>
                                                            <<"9 invalid">>} end)),
    Duplicate = (minimal_spec())#{<<"paths">> =>
      #{<<"/a">> => #{<<"get">> => operation()},
        <<"/b">> => #{<<"post">> => operation()}}},
    assert_compile_error(duplicate_operation_id, Duplicate),
    %% Extension fields are deliberately ignored at each accepted level.
    {ok, _} = adk_openapi_toolset:compile(
                with_operation(fun(Op) -> Op#{<<"x-test">> => true} end), Opts).

parameter_boundaries() ->
    assert_compile_error(invalid_openapi_parameters,
                         with_operation(fun(Op) -> Op#{<<"parameters">> => #{}} end)),
    assert_parameter_error(invalid_openapi_parameter, #{}),
    assert_parameter_error(unsupported_parameter_location,
                           parameter(<<"q">>, <<"cookie">>, string_schema())),
    assert_parameter_error(invalid_openapi_parameter,
                           (parameter(<<"id">>, <<"path">>, string_schema()))#{
                             <<"required">> => false}),
    assert_parameter_error(invalid_openapi_parameter,
                           (parameter(<<"q">>, <<"query">>, string_schema()))#{
                             <<"style">> => <<"simple">>}),
    assert_parameter_error(unsafe_openapi_parameter,
                           parameter(<<"body">>, <<"query">>, string_schema())),
    assert_parameter_error(unsafe_openapi_parameter,
                           parameter(<<"Authorization">>, <<"header">>,
                                     string_schema())),
    assert_parameter_error(unsafe_openapi_parameter,
                           parameter(<<"X API Key">>, <<"query">>, string_schema())),
    assert_parameter_error(unsupported_parameter_schema,
                           parameter(<<"q">>, <<"query">>,
                                     #{<<"type">> => <<"object">>})),
    assert_parameter_error(unsupported_parameter_schema,
                           parameter(<<"q">>, <<"query">>,
                                     #{<<"type">> => <<"array">>})),
    assert_parameter_error(invalid_parameter_schema,
                           parameter(<<"q">>, <<"query">>,
                                     #{<<"$ref">> => <<"#/missing">>})),
    Duplicate = parameter(<<"q">>, <<"query">>, string_schema()),
    assert_compile_error(duplicate_openapi_parameter,
                         with_operation(fun(Op) -> Op#{<<"parameters">> =>
                                                            [Duplicate, Duplicate]} end)),
    Ambiguous = with_operation(fun(Op) -> Op#{<<"parameters">> =>
      [parameter(<<"same">>, <<"query">>, string_schema()),
       parameter(<<"same">>, <<"header">>, string_schema())]} end),
    assert_compile_error(ambiguous_parameter_name, Ambiguous),
    PathSpec = (minimal_spec())#{<<"paths">> =>
      #{<<"/values/{id}">> => #{<<"get">> => operation()}}},
    assert_compile_error(path_parameter_mismatch, PathSpec),
    RepeatedPath = (minimal_spec())#{<<"paths">> =>
      #{<<"/values/{id}/{id}">> => #{<<"get">> =>
        (operation())#{<<"parameters">> =>
          [(parameter(<<"id">>, <<"path">>, string_schema()))#{
             <<"required">> => true}]}}}},
    assert_compile_error(path_parameter_mismatch, RepeatedPath).

body_response_and_server_boundaries() ->
    assert_compile_error(invalid_request_body,
                         with_operation(fun(Op) -> Op#{<<"requestBody">> => 42} end)),
    assert_compile_error(invalid_request_body,
                         with_body(#{<<"required">> => <<"yes">>,
                                     <<"content">> => #{}})),
    assert_compile_error(unsupported_request_media_type,
                         with_body(#{<<"content">> =>
                           #{<<"text/plain">> => #{<<"schema">> => string_schema()}}})),
    assert_compile_error(invalid_request_body_schema,
                         with_body(#{<<"content">> =>
                           #{<<"application/json">> =>
                             #{<<"schema">> => #{<<"$ref">> => <<"#/missing">>}}}})),
    {ok, VendorToolset} = adk_openapi_toolset:compile(
      with_body(#{<<"content">> =>
        #{<<"Application/Problem+Json; charset=utf-8">> =>
          #{<<"schema">> => #{<<"type">> => <<"object">>}}}}),
      compile_opts(json)),
    ?assertMatch([_], adk_openapi_toolset:schemas(VendorToolset)),
    assert_compile_error(invalid_openapi_responses,
                         with_operation(fun(Op) -> maps:remove(<<"responses">>, Op) end)),
    assert_compile_error(invalid_openapi_responses,
                         with_operation(fun(Op) -> Op#{<<"responses">> => #{}} end)),
    assert_compile_error(invalid_response_status,
                         with_responses(#{<<"999">> => response()})),
    assert_compile_error(missing_success_response,
                         with_responses(#{<<"404">> => response()})),
    assert_compile_error(invalid_openapi_response,
                         with_responses(#{<<"200">> => <<"invalid">>})),
    assert_compile_error(invalid_openapi_response,
                         with_responses(#{<<"200">> => #{<<"description">> => 42}})),
    assert_compile_error(invalid_response_schema,
                         with_responses(#{<<"200">> =>
                           (response())#{<<"content">> =>
                             #{<<"application/json">> =>
                               #{<<"schema">> =>
                                 #{<<"$ref">> => <<"#/missing">>}}}}})),
    TooMany = maps:from_list(
                [{integer_to_binary(Code), response()}
                 || Code <- lists:seq(200, 232)]),
    assert_compile_error(invalid_openapi_responses,
                         with_responses(TooMany)),
    assert_compile_error(missing_openapi_server,
                         maps:remove(<<"servers">>, minimal_spec())),
    {ok, _} = adk_openapi_toolset:compile(
                maps:remove(<<"servers">>, minimal_spec()),
                (compile_opts(json))#{base_url =>
                                          <<"https://api.example.com/root">>}),
    assert_compile_error(server_variables_not_supported,
                         set_servers([#{<<"url">> =>
                                          <<"https://api.example.com/{version}">>}])),
    assert_compile_error(multiple_or_invalid_servers,
                         set_servers([#{<<"url">> =>
                                          <<"https://api.example.com">>},
                                      #{<<"url">> =>
                                          <<"https://api.example.com/v2">>}])),
    assert_compile_error(relative_server_without_base_url,
                         set_servers([#{<<"url">> => <<"/v2">>}])),
    {ok, _} = adk_openapi_toolset:compile(
                set_servers([#{<<"url">> => <<"/v2">>}]),
                (compile_opts(json))#{base_url =>
                                          <<"https://api.example.com/root/">>}).

security_boundaries() ->
    assert_compile_error(invalid_openapi_components,
                         (minimal_spec())#{<<"components">> => []}),
    assert_compile_error(invalid_security_schemes,
                         with_schemes([])),
    assert_compile_error(invalid_security_scheme,
                         with_schemes(#{<<>> => api_key_scheme(<<"header">>,
                                                               <<"X-Key">>)})),
    assert_compile_error(unsupported_security_scheme,
                         secured(with_schemes(#{<<"Auth">> =>
                           api_key_scheme(<<"cookie">>, <<"key">>)}),
                           [#{<<"Auth">> => []}])),
    assert_compile_error(unsafe_security_parameter,
                         secured(with_schemes(#{<<"Auth">> =>
                           api_key_scheme(<<"header">>, <<"Host">>)}),
                           [#{<<"Auth">> => []}])),
    assert_compile_error(unsupported_security_scheme,
                         secured(with_schemes(#{<<"Auth">> =>
                           #{<<"type">> => <<"http">>,
                             <<"scheme">> => <<"basic">>}}),
                           [#{<<"Auth">> => []}])),
    assert_compile_error(unsupported_oauth_flow,
                         secured(with_schemes(#{<<"Auth">> =>
                           oauth_scheme(#{<<"deviceCode">> => oauth_flow()})}),
                           [#{<<"Auth">> => []}])),
    assert_compile_error(invalid_oauth_flow,
                         secured(with_schemes(#{<<"Auth">> =>
                           oauth_scheme(#{<<"implicit">> => <<"invalid">>})}),
                           [#{<<"Auth">> => []}])),
    assert_compile_error(invalid_oauth_scopes,
                         secured(with_schemes(#{<<"Auth">> =>
                           oauth_scheme(#{<<"implicit">> =>
                             #{<<"scopes">> => #{<<"read">> => 42}}})}),
                           [#{<<"Auth">> => []}])),
    assert_compile_error(invalid_security_requirement,
                         secured(minimal_spec(), <<"invalid">>)),
    assert_compile_error(invalid_security_requirement,
                         secured(minimal_spec(), [<<"invalid">>])),
    assert_compile_error(unknown_security_scheme,
                         secured(minimal_spec(), [#{<<"Missing">> => []}])),
    ApiSpec = with_schemes(#{<<"Auth">> =>
                              api_key_scheme(<<"header">>, <<"X-Key">>)}),
    assert_compile_error(invalid_security_scopes,
                         secured(ApiSpec, [#{<<"Auth">> => [<<"read">>]}])),
    OAuthSpec = with_schemes(#{<<"Auth">> =>
      oauth_scheme(#{<<"implicit">> => oauth_flow()})}),
    assert_compile_error(invalid_security_scopes,
                         secured(OAuthSpec, [#{<<"Auth">> => [<<"write">>]}])),
    Conflict = with_schemes(
      #{<<"A">> => api_key_scheme(<<"header">>, <<"X-Key">>),
        <<"B">> => api_key_scheme(<<"header">>, <<"X-Key">>)}),
    assert_compile_error(conflicting_security_requirement,
                         secured(Conflict, [#{<<"A">> => [], <<"B">> => []}])).

scalar_and_resolved_execution() ->
    Spec = scalar_spec(),
    {ok, Toolset} = adk_openapi_toolset:compile(Spec, compile_opts(self())),
    {ok, Call} = adk_openapi_toolset:resolved_call(
                   Toolset, <<"sendValues">>,
                   #{<<"ids">> => [<<"a/b">>, <<"c d">>],
                     <<"compact">> => [1, 2],
                     <<"flag">> => true,
                     <<"score">> => 1.5,
                     <<"nullable">> => null,
                     <<"X-Values">> => [<<"a">>, <<"b">>]}, #{}),
    ?assertEqual(false, maps:get(parallel_safe, Call)),
    ?assertEqual(false, maps:get(pause_capable, Call)),
    ?assertEqual({ok, #{<<"status">> => 200,
                        <<"data">> => #{<<"ok">> => true}}},
                 (maps:get(execute, Call))()),
    Request = receive
        {openapi_boundary_request, Captured} -> Captured
    after 1000 ->
        error(missing_openapi_boundary_request)
    end,
    ?assertEqual(
       <<"https://api.example.com/v1/values/a%2Fb,c%20d?compact=1%2C2&flag=true&nullable=null&score=1.5">>,
       maps:get(url, Request)),
    ?assertEqual(<<"a,b">>,
                 maps:get(<<"x-values">>,
                          maps:from_list(maps:get(headers, Request)))),
    {ok, GetToolset} = adk_openapi_toolset:compile(minimal_spec(),
                                                   compile_opts(json)),
    {ok, GetCall} = adk_openapi_toolset:resolved_call(
                      GetToolset, <<"getValue">>, #{}, #{}),
    ?assertEqual(true, maps:get(parallel_safe, GetCall)).

response_and_transport_boundaries() ->
    NoContent = with_responses(#{<<"204">> => response()}),
    ?assertEqual({ok, #{<<"status">> => 204, <<"data">> => null}},
                 execute_with(NoContent, empty)),
    UndefinedMedia = with_responses(#{<<"200">> => response()}),
    ?assertEqual({ok, #{<<"status">> => 200,
                        <<"data">> => #{<<"ok">> => true}}},
                 execute_with(UndefinedMedia, json_header_map)),
    ?assertEqual({error, unsupported_response_content_type},
                 execute_with(UndefinedMedia, json_no_header)),
    ?assertEqual({error, unsupported_response_content_type},
                 execute_with(UndefinedMedia, json_bad_headers)),
    NonJson = with_responses(#{<<"200">> =>
      (response())#{<<"content">> =>
        #{<<"text/plain">> => #{<<"schema">> => string_schema()}}}}),
    ?assertEqual({error, unsupported_response_content_type},
                 execute_with(NonJson, json)),
    lists:foreach(
      fun({Mode, Expected}) ->
          ?assertEqual(Expected, execute_with(minimal_spec(), Mode))
      end,
      [{throw, {error, transport_error}},
       {timeout, {error, timeout}},
       {error, {error, transport_error}},
       {invalid, {error, invalid_transport_response}},
       {invalid_map, {error, invalid_transport_response}}]),
    ClassResponse = with_responses(#{<<"2XX">> => json_response_schema()}),
    ?assertMatch({ok, _}, execute_with(ClassResponse, json)),
    DefaultResponse = with_responses(#{<<"default">> => json_response_schema()}),
    ?assertMatch({ok, _}, execute_with(DefaultResponse, json)).

authentication_boundaries() ->
    HeaderSpec = secured(with_schemes(#{<<"Auth">> =>
      api_key_scheme(<<"header">>, <<"X-Key">>)}),
      [#{<<"Auth">> => []}]),
    ?assertEqual({error, authentication_required},
                 execute_with(HeaderSpec, json)),
    Optional = secured(HeaderSpec, [#{}, #{<<"Auth">> => []}]),
    ?assertMatch({ok, _}, execute_with(Optional, json)),
    lists:foreach(
      fun(Mode) ->
          ?assertEqual({error, authentication_failed},
                       execute_with_auth(HeaderSpec, json, Mode))
      end,
      [throw, error, invalid, empty_api_key, unsafe_api_key]),
    ?assertMatch({ok, _},
                 execute_with_auth(HeaderSpec, json, valid_api_key)),
    QuerySpec = secured(with_schemes(#{<<"Auth">> =>
      api_key_scheme(<<"query">>, <<"key">>)}),
      [#{<<"Auth">> => []}]),
    ?assertEqual({error, authentication_failed},
                 execute_with_auth(QuerySpec, json, invalid_utf8_api_key)),
    BearerSpec = secured(with_schemes(#{<<"Auth">> =>
      #{<<"type">> => <<"http">>, <<"scheme">> => <<"BeArEr">>}}),
      [#{<<"Auth">> => []}]),
    ?assertEqual({error, authentication_failed},
                 execute_with_auth(BearerSpec, json, spaced_bearer)),
    ?assertMatch({ok, _},
                 execute_with_auth(BearerSpec, json, valid_bearer)).

assert_option_error(Key, Opts) ->
    ?assertEqual({error, {invalid_openapi_option, Key}},
                 adk_openapi_toolset:compile(minimal_spec(), Opts)).

assert_compile_error(Reason, Spec) ->
    ?assertEqual({error, Reason},
                 adk_openapi_toolset:compile(Spec, compile_opts(json))).

assert_parameter_error(Reason, Parameter) ->
    assert_compile_error(
      Reason,
      with_operation(fun(Op) -> Op#{<<"parameters">> => [Parameter]} end)).

compile_opts(Mode) ->
    #{transport => {adk_openapi_toolset_boundary_adapter, Mode},
      allowed_hosts => [<<"api.example.com">>]}.

minimal_spec() ->
    #{<<"openapi">> => <<"3.1.0">>,
      <<"servers">> => [#{<<"url">> => <<"https://api.example.com/v1">>}],
      <<"paths">> => #{<<"/value">> => #{<<"get">> => operation()}}}.

operation() ->
    #{<<"operationId">> => <<"getValue">>,
      <<"responses">> => #{<<"200">> => json_response_schema()}}.

response() ->
    #{<<"description">> => <<"response">>}.

json_response_schema() ->
    (response())#{<<"content">> => #{<<"application/json">> =>
      #{<<"schema">> => #{<<"type">> => <<"object">>,
                            <<"properties">> =>
                              #{<<"ok">> => #{<<"type">> => <<"boolean">>}},
                            <<"required">> => [<<"ok">>]}}}}.

string_schema() -> #{<<"type">> => <<"string">>}.

parameter(Name, Location, Schema) ->
    #{<<"name">> => Name, <<"in">> => Location, <<"schema">> => Schema}.

with_path(Fun) ->
    Spec = minimal_spec(),
    Paths = maps:get(<<"paths">>, Spec),
    Path = maps:get(<<"/value">>, Paths),
    Spec#{<<"paths">> => Paths#{<<"/value">> => Fun(Path)}}.

with_operation(Fun) ->
    with_path(fun(Path) ->
        Path#{<<"get">> => Fun(maps:get(<<"get">>, Path))}
    end).

with_body(Body) ->
    with_operation(fun(Op) -> Op#{<<"requestBody">> => Body} end).

with_responses(Responses) when is_map(Responses) ->
    with_operation(fun(Op) -> Op#{<<"responses">> => Responses} end).

set_servers(Servers) -> (minimal_spec())#{<<"servers">> => Servers}.

with_schemes(Schemes) ->
    (minimal_spec())#{<<"components">> => #{<<"securitySchemes">> => Schemes}}.

secured(Spec, Security) ->
    with_operation_in(
      Spec, fun(Op) -> Op#{<<"security">> => Security} end).

with_operation_in(Spec, Fun) ->
    Paths = maps:get(<<"paths">>, Spec),
    Path = maps:get(<<"/value">>, Paths),
    Op = maps:get(<<"get">>, Path),
    Spec#{<<"paths">> => Paths#{<<"/value">> =>
      Path#{<<"get">> => Fun(Op)}}}.

api_key_scheme(Location, Name) ->
    #{<<"type">> => <<"apiKey">>, <<"in">> => Location, <<"name">> => Name}.

oauth_scheme(Flows) ->
    #{<<"type">> => <<"oauth2">>, <<"flows">> => Flows}.

oauth_flow() ->
    #{<<"scopes">> => #{<<"read">> => <<"read data">>}}.

scalar_spec() ->
    Parameters = [
      (parameter(<<"ids">>, <<"path">>,
                 #{<<"type">> => <<"array">>,
                   <<"items">> => string_schema()}))#{<<"required">> => true},
      (parameter(<<"compact">>, <<"query">>,
                 #{<<"type">> => <<"array">>,
                   <<"items">> => #{<<"type">> => <<"integer">>}}))#{
        <<"explode">> => false},
      parameter(<<"flag">>, <<"query">>, #{<<"type">> => <<"boolean">>}),
      parameter(<<"score">>, <<"query">>, #{<<"type">> => <<"number">>}),
      parameter(<<"nullable">>, <<"query">>,
                #{<<"type">> => [<<"string">>, <<"null">>]}),
      parameter(<<"X-Values">>, <<"header">>,
                #{<<"type">> => <<"array">>, <<"items">> => string_schema()})],
    Op = #{<<"operationId">> => <<"sendValues">>,
           <<"parameters">> => Parameters,
           <<"responses">> => #{<<"200">> => json_response_schema()}},
    (minimal_spec())#{<<"paths">> =>
      #{<<"/values/{ids}">> => #{<<"post">> => Op}}}.

execute_with(Spec, TransportMode) ->
    {ok, Toolset} = adk_openapi_toolset:compile(
                      Spec, compile_opts(TransportMode)),
    [Schema] = adk_openapi_toolset:schemas(Toolset),
    Name = maps:get(<<"name">>, Schema),
    adk_openapi_toolset:execute(Toolset, Name, #{}).

execute_with_auth(Spec, TransportMode, AuthMode) ->
    {ok, Toolset} = adk_openapi_toolset:compile(
      Spec, (compile_opts(TransportMode))#{auth =>
        {adk_openapi_toolset_boundary_adapter, AuthMode}}),
    [Schema] = adk_openapi_toolset:schemas(Toolset),
    Name = maps:get(<<"name">>, Schema),
    adk_openapi_toolset:execute(Toolset, Name, #{}).
