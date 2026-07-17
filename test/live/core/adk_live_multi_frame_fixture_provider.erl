-module(adk_live_multi_frame_fixture_provider).
-behaviour(adk_live_provider).

-export([capabilities/0, validate_config/1, setup_frame/1,
         encode_client/2, decode_server/2]).

capabilities() ->
    #{live => true, input_modalities => [text],
      response_modalities => [text]}.

validate_config(Config) when is_map(Config) ->
    {ok, Config#{model => <<"fixture-live-model">>}};
validate_config(_) ->
    {error, invalid_fixture_config}.

setup_frame(_Config) ->
    {ok, <<"fixture-setup">>}.

encode_client({text, <<"multi">>}, _Config) ->
    {ok, [<<"normal-1">>, <<"normal-2">>, <<"normal-3">>]};
encode_client({text, <<"single">>}, _Config) ->
    {ok, <<"single">>};
encode_client({text, <<"wide">>}, _Config) ->
    {ok, [binary:copy(<<"a">>, 600), binary:copy(<<"b">>, 600)]};
encode_client({text, <<"empty-list">>}, _Config) ->
    {ok, []};
encode_client({text, <<"invalid-member">>}, _Config) ->
    {ok, [<<"valid">>, invalid]};
encode_client({text, <<"improper">>}, _Config) ->
    {ok, [<<"valid">> | <<"invalid-tail">>]};
encode_client(activity_start, _Config) ->
    {ok, [<<"control-1">>, <<"control-2">>]};
encode_client(activity_end, #{single_end := true}) ->
    {ok, <<"later-control-single">>};
encode_client(activity_end, _Config) ->
    {ok, [<<"later-control-1">>, <<"later-control-2">>]};
encode_client(audio_stream_end, _Config) ->
    ignored;
encode_client(_Action, _Config) ->
    {error, unsupported_fixture_action}.

decode_server(<<"fixture-ready">>, _Config) ->
    {ok, [#{kind => setup_complete, payload => #{}}]};
decode_server(_Frame, _Config) ->
    {ok, []}.
