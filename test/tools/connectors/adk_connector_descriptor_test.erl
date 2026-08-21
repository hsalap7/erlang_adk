-module(adk_connector_descriptor_test).

-include_lib("eunit/include/eunit.hrl").

registry_only_descriptor_test() ->
    Raw = #{connector_id => <<"github_prod">>,
            service_ref => #{kind => mcp, id => <<"github_mcp_prod">>},
            credential_ref => #{kind => credential,
                                id => <<"github_app_prod">>}},
    {ok, Descriptor} = adk_connector_descriptor:validate(Raw, mcp),
    ?assertEqual(Raw, Descriptor),
    Description = adk_connector_descriptor:describe(Descriptor),
    ?assertEqual(<<"github_prod">>,
                 maps:get(<<"connector_id">>, Description)).

raw_transport_and_secret_fields_fail_closed_test() ->
    Base = #{connector_id => <<"github_prod">>,
             service_ref => #{kind => mcp, id => <<"github_mcp_prod">>},
             credential_ref => none},
    ?assertEqual(
       {error, invalid_connector_descriptor_keys},
       adk_connector_descriptor:validate(
         Base#{url => <<"https://example.invalid">>}, mcp)),
    ?assertEqual(
       {error, invalid_connector_descriptor_keys},
       adk_connector_descriptor:validate(Base#{token => <<"secret">>}, mcp)),
    ?assertEqual(
       {error, invalid_connector_credential_ref},
       adk_connector_descriptor:validate(
         Base#{credential_ref => #{token => <<"secret">>}}, mcp)),
    ?assertEqual(
       {error, invalid_connector_service_ref},
       adk_connector_descriptor:validate(Base, native)).
