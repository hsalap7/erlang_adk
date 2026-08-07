-module(adk_google_adc_test).

-include_lib("eunit/include/eunit.hrl").

explicit_oauth_bearer_is_bounded_test() ->
    ?assertEqual(ok, adk_google_adc:validate_config(
                       #{api_key => <<"oauth-token">>})),
    ?assertEqual({ok, <<"oauth-token">>},
                 adk_google_adc:access_token(
                   #{api_key => <<"oauth-token">>})),
    ?assertEqual(
       {error, invalid_vertex_oauth_token},
       adk_google_adc:validate_config(#{api_key => <<"bad\ntoken">>})).

injected_adc_provider_is_lazy_and_checked_test() ->
    Config = #{credential_source => google_adc,
               adc_token_provider =>
                   {adk_google_adc_fixture,
                    {notify, self(),
                     {ok, #{access_token => <<"adc-token">>}}}}},
    ?assertEqual(ok, adk_google_adc:validate_config(Config)),
    receive google_adc_requested -> ?assert(false) after 0 -> ok end,
    ?assertEqual({ok, <<"adc-token">>},
                 adk_google_adc:access_token(Config)),
    receive google_adc_requested -> ok after 1000 -> ?assert(false) end.

adc_failures_are_data_free_test() ->
    Secret = <<"must-not-leak-from-adc-provider">>,
    Cases = [
        {error, {provider_error, Secret}},
        {ok, <<"bad\ntoken">>},
        {ok, binary:copy(<<"x">>, 32769)},
        {raise, Secret}
    ],
    lists:foreach(
      fun(Result) ->
          Error = adk_google_adc:access_token(
                    #{credential_source => google_adc,
                      adc_token_provider =>
                          {adk_google_adc_fixture, Result}}),
          ?assertEqual({error, vertex_adc_token_unavailable}, Error),
          ?assertEqual(nomatch,
                       binary:match(term_to_binary(Error), Secret))
      end, Cases).

credential_modes_are_exclusive_test() ->
    ?assertEqual(
       {error, vertex_oauth_credential_required},
       adk_google_adc:validate_config(#{})),
    ?assertEqual(
       {error, conflicting_vertex_oauth_credentials},
       adk_google_adc:validate_config(
         #{api_key => <<"token">>, credential_source => google_adc})),
    ?assertEqual(
       {error, invalid_vertex_adc_token_provider},
       adk_google_adc:validate_config(
         #{adc_token_provider => {adk_google_adc_fixture, ignored}})).
