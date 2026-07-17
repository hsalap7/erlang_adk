-module(adk_live_default_transport_fixture_provider).
-behaviour(adk_live_provider).

-export([capabilities/0, validate_config/1, transport/0,
         setup_frame/1, encode_client/2, decode_server/2]).

capabilities() ->
    #{live => true,
      input_modalities => [text],
      response_modalities => [text],
      input_audio_sample_rate => 32000}.

validate_config(Config) when is_map(Config) ->
    {ok, Config#{model => <<"default-transport-fixture">>}};
validate_config(_Config) ->
    {error, invalid_fixture_config}.

transport() -> adk_live_fake_transport.

setup_frame(_Config) -> {ok, <<"fixture-setup">>}.

encode_client({text, Text}, _Config) when is_binary(Text) -> {ok, Text};
encode_client(_Action, _Config) -> {error, unsupported_fixture_action}.

decode_server(<<"fixture-ready">>, _Config) ->
    {ok, [#{kind => setup_complete, payload => #{}}]};
decode_server(_Frame, _Config) -> {ok, []}.
