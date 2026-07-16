-module(adk_live_observability_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"live-observability-principal">>).

metadata_only_live_spans_and_metrics_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    MetricName = adk_live_observability_metrics_test,
    {ok, Metrics} = adk_observability_metrics:start_link(
                      #{name => MetricName, max_instruments => 16,
                        max_series_per_instrument => 32}),
    unlink(Metrics),
    Exporter = #{id => <<"live-observability-test">>,
                 module => adk_observability_test_exporter,
                 config => #{test_pid => self(), label => live_observability},
                 timeout_ms => 1000, max_heap_words => 100000,
                 failure_policy => open},
    Tool = #{type => function, name => <<"weather">>,
             parameters => #{<<"type">> => <<"object">>}},
    ToolExecution = #{enabled => true,
                      executor => adk_live_test_tool_executor,
                      policy => sequential,
                      allowed_tools => [<<"weather">>],
                      options => #{test_pid => self()},
                      timeout_ms => 1000,
                      max_heap_words => 100000,
                      max_response_bytes => 4096},
    Config = #{provider => adk_live_gemini,
               provider_config => #{tools => [Tool]},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => self()},
               tool_execution => ToolExecution,
               observability => #{delivery => sync,
                                  exporters => [Exporter],
                                  metrics => MetricName}},
    try
        {ok, Session} = adk_live_session_sup:start_session(
                          unique_id(), ?PRINCIPAL, Config),
        Handle = receive
            {adk_live_fake_transport, opened, Opened} -> Opened
        after 1000 -> ?assert(false)
        end,
        _Setup = receive_sent(Handle),
        adk_live_fake_transport:inject(
          Handle, #{<<"setupComplete">> => #{}}),
        wait_for_active(Session, 100),

        PrivateMedia = <<"PRIVATE_MEDIA_12">>,
        {ok, InputAudio} = adk_live_media:audio_pcm(
                             PrivateMedia, 16000, 1),
        {ok, _} = adk_live_session:send_audio(
                    Session, ?PRINCIPAL, InputAudio),
        _InputFrame = receive_sent(Handle),
        adk_live_fake_transport:inject(
          Handle,
          #{<<"serverContent">> =>
                #{<<"modelTurn">> =>
                      #{<<"parts">> =>
                            [#{<<"inlineData">> =>
                                   #{<<"mimeType">> =>
                                         <<"audio/pcm;rate=24000">>,
                                     <<"data">> =>
                                         base64:encode(PrivateMedia)}}]}}}),

        PrivateArgument = <<"PRIVATE_TOOL_ARGUMENT">>,
        adk_live_fake_transport:inject(
          Handle,
          #{<<"toolCall">> =>
                #{<<"functionCalls">> =>
                      [#{<<"id">> => <<"observed-call">>,
                         <<"name">> => <<"weather">>,
                         <<"args">> =>
                             #{<<"private">> => PrivateArgument}}]}}),
        Worker = receive
            {live_tool_started, Pid, <<"observed-call">>, <<"weather">>,
             #{<<"private">> := PrivateArgument}} -> Pid
        after 1000 -> ?assert(false)
        end,
        PrivateResult = <<"PRIVATE_TOOL_RESULT">>,
        Worker ! {live_tool_complete, <<"observed-call">>,
                  #{<<"private">> => PrivateResult}},
        _ResponseFrame = receive_sent(Handle),
        ok = adk_live_session:close(Session, ?PRINCIPAL, done),

        Signals = receive_signals([], 100),
        EndNames = [maps:get(<<"name">>, Signal) || Signal <- Signals,
                    maps:get(<<"phase">>, Signal, undefined) =:= <<"end">>],
        ?assert(lists:member(<<"gen_ai.live_connect">>, EndNames)),
        ?assert(lists:member(<<"gen_ai.live_receive">>, EndNames)),
        ?assert(lists:member(<<"gen_ai.execute_tool">>, EndNames)),
        ?assert(lists:all(
                  fun(Signal) ->
                      maps:get(<<"schema_version">>, Signal) =:= 2 andalso
                      maps:get(<<"signal">>, Signal) =:= <<"span">>
                  end, Signals)),
        assert_absent(Signals,
                      [PrivateMedia, PrivateArgument, PrivateResult,
                       <<"resumption-handle">>, <<"api-key">>]),

        Snapshot = adk_observability_metrics:snapshot(MetricName),
        Instruments = maps:get(<<"instruments">>, Snapshot),
        ?assert(maps:is_key(<<"erlang_adk.live.lifecycle.count">>,
                           Instruments)),
        ?assert(maps:is_key(<<"erlang_adk.live.media.bytes">>,
                           Instruments)),
        ?assert(maps:is_key(<<"erlang_adk.live.media.frames">>,
                           Instruments)),
        ?assert(maps:is_key(<<"erlang_adk.live.tool.count">>,
                           Instruments)),
        assert_absent(Snapshot,
                      [PrivateMedia, PrivateArgument, PrivateResult,
                       <<"observed-call">>])
    after
        gen_server:stop(Metrics)
    end.

live_observability_rejects_content_capture_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Config = #{provider => adk_live_gemini,
               provider_config => #{},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => self()},
               observability => #{capture_content => true}},
    ?assertEqual(
       {error, {invalid_live_observability_option, capture_content}},
       adk_live_session_sup:start_session(
         unique_id(), ?PRINCIPAL, Config)).

receive_sent(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, Frame} -> Frame
    after 1000 -> ?assert(false)
    end.

receive_signals(Acc, Wait) ->
    receive
        {exported, live_observability, Signal} ->
            receive_signals([Signal | Acc], Wait)
    after Wait ->
        lists:reverse(Acc)
    end.

assert_absent(Term, Values) ->
    Binary = term_to_binary(Term),
    lists:foreach(
      fun(Value) -> ?assertEqual(nomatch, binary:match(Binary, Value)) end,
      Values).

wait_for_active(_Session, 0) -> ?assert(false);
wait_for_active(Session, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{state := active}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_active(Session, Remaining - 1)
    end.

unique_id() ->
    <<"live-observability-",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
