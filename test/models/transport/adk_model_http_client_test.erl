-module(adk_model_http_client_test).

-include_lib("eunit/include/eunit.hrl").

fixed_sse_query_preserves_transport_policy_test() ->
    drain_transport_messages(),
    Config = fixture_config(
               {stream, 200, [<<"data: ok\n\n">>], <<>>}),
    ?assertMatch(
       {ok, #{status := 200}},
       adk_model_http_client:stream_sse(
         Config, <<"/v1/resource:streamGenerateContent">>,
         [{<<"accept">>, <<"text/event-stream">>}], #{},
         fun(_Chunk) -> ok end)),
    receive
        {model_http_stream_request, Request} ->
            ?assertEqual(
               <<"https://us-central1-aiplatform.googleapis.com/v1/",
                 "resource:streamGenerateContent?alt=sse">>,
               maps:get(url, Request)),
            ?assertEqual(false, maps:get(follow_redirects, Request)),
            ?assertEqual(false, maps:get(allow_private_hosts, Request)),
            ?assertEqual([<<"https">>], maps:get(allowed_schemes, Request)),
            ?assertEqual([<<"us-central1-aiplatform.googleapis.com">>],
                         maps:get(allowed_hosts, Request))
    after 1000 -> ?assert(false)
    end.

fixed_sse_query_does_not_relax_path_or_base_validation_test() ->
    drain_transport_messages(),
    Config = fixture_config({stream, 200, [], <<>>}),
    InvalidPaths = [<<"/path?caller=true">>, <<"/path#fragment">>,
                    <<"/path\nheader">>],
    lists:foreach(
      fun(Path) ->
          ?assertEqual(
             {error, invalid_model_request_path},
             adk_model_http_client:stream_sse(
               Config, Path, [], #{}, fun(_Chunk) -> ok end))
      end, InvalidPaths),
    ?assertEqual(
       {error, invalid_model_base_url},
       adk_model_http_client:stream_sse(
         Config#{base_url => <<"https://example.test?query=1">>},
         <<"/path">>, [], #{}, fun(_Chunk) -> ok end)),
    receive {model_http_stream_request, _} -> ?assert(false) after 0 -> ok end.

ordinary_stream_remains_query_free_test() ->
    drain_transport_messages(),
    Config = fixture_config({stream, 200, [], <<>>}),
    ?assertMatch(
       {ok, #{status := 200}},
       adk_model_http_client:stream(
         Config, <<"/events">>, [], #{}, fun(_Chunk) -> ok end)),
    receive
        {model_http_stream_request, Request} ->
            ?assertEqual(
               <<"https://us-central1-aiplatform.googleapis.com/events">>,
               maps:get(url, Request))
    after 1000 -> ?assert(false)
    end.

fixture_config(Fixture) ->
    #{base_url => <<"https://us-central1-aiplatform.googleapis.com">>,
      http_transport =>
          {adk_model_fixture_transport, {self(), Fixture}}}.

drain_transport_messages() ->
    receive
        {model_http_request, _} -> drain_transport_messages();
        {model_http_stream_request, _} -> drain_transport_messages()
    after 0 -> ok
    end.
