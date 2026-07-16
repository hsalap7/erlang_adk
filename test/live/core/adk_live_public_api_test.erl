-module(adk_live_public_api_test).
-include_lib("eunit/include/eunit.hrl").

supervised_public_live_api_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Principal = <<"public-live-principal">>,
    SessionId = <<"public-live-",
                  (integer_to_binary(
                     erlang:unique_integer([positive])))/binary>>,
    Config = #{provider => adk_live_gemini,
               provider_config => #{},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => self()}},
    {ok, Session} = erlang_adk:start_live_session(
                      SessionId, Principal, Config),
    Handle = receive
        {adk_live_fake_transport, opened, Opened} -> Opened
    after 1000 -> erlang:error(live_transport_open_timeout)
    end,
    receive
        {adk_live_fake_transport, sent, Handle, SetupFrame} ->
            #{<<"setup">> := _} = jsx:decode(SetupFrame, [return_maps])
    after 1000 -> erlang:error(live_setup_timeout)
    end,
    {ok, _} = erlang_adk:live_subscribe(
                Session, Principal, #{messages => 4, bytes => 1048576}),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    Sequence = receive
        {adk_live_event, SessionId, Seq, Event} ->
            ?assertEqual(ready, adk_live_event:kind(Event)),
            Seq
    after 1000 -> erlang:error(live_ready_timeout)
    end,
    ok = erlang_adk:live_ack(Session, Principal, Sequence),
    {ok, 1} = erlang_adk:live_send_text(
                Session, Principal, <<"hello">>),
    receive
        {adk_live_fake_transport, sent, Handle, TextFrame} ->
            #{<<"realtimeInput">> := #{<<"text">> := <<"hello">>}} =
                jsx:decode(TextFrame, [return_maps])
    after 1000 -> erlang:error(live_text_timeout)
    end,
    {ok, #{state := active}} = erlang_adk:live_status(
                                Session, Principal),
    {ok, #{state := active}} = erlang_adk:live_status(
                                Session, Principal, 1000),
    ?assertEqual({error, invalid_live_status_timeout},
                 erlang_adk:live_status(Session, Principal, 0)),
    ?assertEqual({error, not_found},
                 erlang_adk:live_status(Session, <<"other">>)),
    ok = erlang_adk:close_live_session(Session, Principal, test_complete).
