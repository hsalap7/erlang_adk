-module(adk_model_http_headers_test).

-include_lib("eunit/include/eunit.hrl").

-define(MAX_HEADER_BYTES, 65536).
-define(MAX_API_KEY_BYTES, 32768).

aggregate_byte_boundary_is_exact_test() ->
    AtLimit = [{<<"x">>, binary:copy(<<"a">>, ?MAX_HEADER_BYTES - 1)}],
    ?assertEqual(ok, adk_model_http_headers:validate(AtLimit)),
    OverLimit = [{<<"x">>, binary:copy(<<"a">>, ?MAX_HEADER_BYTES)}],
    ?assertEqual(
       {error, invalid_model_http_headers},
       adk_model_http_headers:validate(OverLimit)).

header_count_boundary_is_exact_test() ->
    Headers = [{<<"x-", (integer_to_binary(Index))/binary>>, <<"v">>}
               || Index <- lists:seq(1, 128)],
    ?assertEqual(ok, adk_model_http_headers:validate(Headers)),
    ?assertEqual(
       {error, invalid_model_http_headers},
       adk_model_http_headers:validate(
         Headers ++ [{<<"x-over-limit">>, <<"v">>}])).

authority_duplicates_and_injection_are_rejected_test() ->
    Invalid = [
        not_a_header_list,
        [{<<"host">>, <<"provider.example">>}],
        [{<<"Host">>, <<"provider.example">>}],
        [{<<":authority">>, <<"provider.example">>}],
        [{<<":Authority">>, <<"provider.example">>}],
        [{<<"x-id">>, <<"one">>}, {<<"X-ID">>, <<"two">>}],
        [{<<"bad name">>, <<"value">>}],
        [{<<"x-id">>, <<"ok\r\ninjected: yes">>}],
        [{<<"x-id">>, <<"ok">>} | invalid_tail]
    ],
    lists:foreach(
      fun(Headers) ->
          ?assertEqual(
             {error, invalid_model_http_headers},
             adk_model_http_headers:validate(Headers))
      end, Invalid).

credential_limit_leaves_adapter_header_headroom_test() ->
    ApiKey = binary:copy(<<"k">>, ?MAX_API_KEY_BYTES),
    ?assertEqual(
       {ok, ApiKey},
       adk_model_http_client:resolve_explicit_api_key(#{api_key => ApiKey})),
    ?assertEqual(
       {error, invalid_api_key},
       adk_model_http_client:resolve_explicit_api_key(
         #{api_key => <<ApiKey/binary, "x">>})),
    FullOpenAiHeaders =
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>},
         {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
         {<<"openai-organization">>, binary:copy(<<"o">>, 1024)},
         {<<"openai-project">>, binary:copy(<<"p">>, 1024)}],
    ?assertEqual(ok,
                 adk_model_http_headers:validate(FullOpenAiHeaders)).

client_rejects_invalid_headers_before_injected_transport_test() ->
    Config =
        #{base_url => <<"https://model.example/v1">>,
          http_transport =>
              {adk_model_fixture_transport,
               {self(), {response, 200, #{<<"ok">> => true}}}}},
    ?assertEqual(
       {error, invalid_model_http_headers},
       adk_model_http_client:request(
         Config, <<"/responses">>,
         [{<<"Host">>, <<"attacker.example">>}], #{})),
    receive
        {model_http_request, _Request} ->
            ?assert(false)
    after 0 -> ok
    end.
