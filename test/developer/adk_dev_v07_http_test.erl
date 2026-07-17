-module(adk_dev_v07_http_test).

-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, adk_dev_v07_http_test_listener).
-define(TOKEN, <<"v07-developer-token-0123456789">>).
-define(PRINCIPAL, <<"v07-live-principal">>).

dev_v07_http_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(State) ->
         [{"observability is authenticated and metadata-only",
           ?_test(observability_case(State))},
          {"developer UI exposes bounded Live and observability controls",
           ?_test(ui_v07_case(State))},
          {"evaluation reports render and compare through a pure boundary",
           ?_test(evaluation_view_case(State))},
          {"Live discovery is principal-exact and pid-free",
           ?_test(live_discovery_case(State))},
          {"Live text control preserves provider framing",
           ?_test(live_text_case(State))},
          {"CLI inspects observability/Live and sends bounded text",
           ?_test(cli_v07_case(State))},
          {"Live SSE refuses replay and omits raw audio",
           ?_test(live_sse_case(State))},
          {"Live developer access must be explicitly configured",
           ?_test(live_config_validation_case())}]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Table = ets:new(adk_dev_v07_live_messages,
                    [ordered_set, public]),
    Relay = spawn_link(fun() -> relay_messages(Table) end),
    SessionId = unique(<<"dev-live">>),
    Config = #{provider => adk_live_gemini,
               provider_config => #{},
               transport => adk_live_fake_transport,
               transport_opts => #{test_pid => Relay}},
    {ok, Session} = adk_live_session_sup:start_session(
                      SessionId, ?PRINCIPAL, Config),
    Handle = await_opened(Table, 100),
    _Setup = take_sent(Table, Handle, 100),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    ok = wait_active(Session, 100),
    DevConfig = #{auth_token => ?TOKEN,
                  live_principal => ?PRINCIPAL,
                  live_credit => #{messages => 4, bytes => 4194304},
                  sse_heartbeat_ms => 20,
                  sse_max_events => 16,
                  sse_max_bytes => 1048576,
                  sse_max_duration_ms => 2000},
    {ok, _} = cowboy:start_clear(
                ?LISTENER, [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(DevConfig)}}),
    #{port => ranch:get_port(?LISTENER), session => Session,
      session_id => SessionId, handle => Handle,
      relay => Relay, table => Table}.

cleanup(#{session := Session, relay := Relay, table := Table}) ->
    _ = cowboy:stop_listener(?LISTENER),
    _ = catch adk_live_session:close(Session, ?PRINCIPAL, test_cleanup),
    Relay ! {stop, self()},
    receive
        {relay_stopped, Relay} -> ok
    after 1000 ->
        error(live_relay_cleanup_timeout)
    end,
    ets:delete(Table),
    ok.

observability_case(State) ->
    {401, _, _} = request(
                    State, get, <<"/dev/v1/observability">>, [], <<>>),
    {200, _, Body} = request(
                       State, get, <<"/dev/v1/observability">>,
                       auth(), <<>>),
    Payload = jsx:decode(Body, [return_maps]),
    ?assertEqual(2, maps:get(<<"schema_version">>, Payload)),
    ?assertEqual(false, maps:get(<<"content_captured">>, Payload)),
    ?assert(maps:is_key(<<"metrics">>, Payload)),
    ?assert(maps:is_key(<<"export_bus">>, Payload)),
    ?assertEqual(nomatch, binary:match(Body, ?TOKEN)),
    ?assertEqual(nomatch, binary:match(Body, ?PRINCIPAL)).

ui_v07_case(State) ->
    {200, _, Body} = request(State, get, <<"/dev">>, [], <<>>),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"Gemini Live sessions">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"/dev/v1/live/sessions">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body,
                                 <<"raw audio bytes are never rendered">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"/dev/v1/observability">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"Evaluation reports">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"/dev/v1/evaluation/render">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"stopLiveStream">>)),
    ?assertEqual(nomatch, binary:match(Body, ?TOKEN)),
    ?assertEqual(nomatch, binary:match(Body, ?PRINCIPAL)).

evaluation_view_case(State) ->
    Report = evaluation_result(),
    RenderPath = <<"/dev/v1/evaluation/render">>,
    JsonRequest = jsx:encode(
                    #{<<"report">> => Report,
                      <<"format">> => <<"json">>}),
    {200, JsonHeaders, JsonBody} = request(
                                         State, post, RenderPath,
                                         json_auth(), JsonRequest),
    ?assertEqual(<<"application/json; charset=utf-8">>,
                 header(<<"content-type">>, JsonHeaders)),
    ?assertEqual(Report, jsx:decode(JsonBody, [return_maps])),
    MarkdownRequest = jsx:encode(
                        #{<<"report">> => Report,
                          <<"format">> => <<"markdown">>}),
    {200, MarkdownHeaders, Markdown} = request(
                                        State, post, RenderPath,
                                        json_auth(), MarkdownRequest),
    ?assertEqual(<<"text/markdown; charset=utf-8">>,
                 header(<<"content-type">>, MarkdownHeaders)),
    ?assertNotEqual(nomatch,
                    binary:match(Markdown, <<"# Evaluation report">>)),
    Compare = jsx:encode(
                #{<<"baseline">> => Report, <<"current">> => Report,
                  <<"options">> => #{}}),
    {200, _, ComparedBody} = request(
                               State, post,
                               <<"/dev/v1/evaluation/compare">>,
                               json_auth(), Compare),
    Compared = jsx:decode(ComparedBody, [return_maps]),
    ?assertEqual(true, maps:get(<<"passed">>, Compared)),
    Forged = jsx:encode(
               #{<<"report">> => #{<<"module">> => <<"os">>},
                 <<"format">> => <<"json">>}),
    {400, _, ErrorBody} = request(
                            State, post, RenderPath, json_auth(), Forged),
    ?assertEqual(<<"invalid_evaluation_report">>, error_code(ErrorBody)).

live_discovery_case(State = #{session_id := SessionId}) ->
    {200, _, Body} = request(
                       State, get, <<"/dev/v1/live/sessions">>,
                       auth(), <<>>),
    Payload = jsx:decode(Body, [return_maps]),
    Sessions = maps:get(<<"sessions">>, Payload),
    ?assert(lists:any(
              fun(Status) ->
                  maps:get(<<"session_id">>, Status) =:= SessionId
              end, Sessions)),
    ?assertEqual(nomatch, binary:match(Body, <<"pid">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"api_key">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"resumption_handle">>)).

live_text_case(State = #{session_id := SessionId, handle := Handle,
                         table := Table}) ->
    Path = <<"/dev/v1/live/sessions/", SessionId/binary, "/text">>,
    {202, _, Body} = request(
                       State, post, Path, json_auth(),
                       jsx:encode(#{<<"text">> => <<"hello live">>})),
    ?assertEqual(true,
                 maps:get(<<"accepted">>,
                          jsx:decode(Body, [return_maps]))),
    Frame = take_sent(Table, Handle, 100),
    #{<<"realtimeInput">> := #{<<"text">> := <<"hello live">>}} =
        jsx:decode(Frame, [return_maps]),
    {400, _, _} = request(
                    State, post, Path, json_auth(),
                    jsx:encode(#{<<"text">> => <<"hello">>,
                                 <<"extra">> => true})).

cli_v07_case(#{port := Port, session_id := SessionId,
               handle := Handle, table := Table}) ->
    OldToken = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    Base = "http://127.0.0.1:" ++ integer_to_list(Port),
    try
        true = os:putenv("ERLANG_ADK_DEV_TOKEN",
                         binary_to_list(?TOKEN)),
        {ok, Observation} = adk_cli:command(
                              ["inspect", "observability", "--url", Base]),
        ?assertEqual(2, maps:get(<<"schema_version">>, Observation)),
        {ok, Live} = adk_cli:command(
                       ["inspect", "live", "--url", Base]),
        ?assert(lists:any(
                  fun(Status) ->
                      maps:get(<<"session_id">>, Status) =:= SessionId
                  end, maps:get(<<"sessions">>, Live))),
        {ok, Accepted} = adk_cli:command(
                           ["live", "send", binary_to_list(SessionId),
                            "--text", "from cli", "--url", Base]),
        ?assertEqual(true, maps:get(<<"accepted">>, Accepted)),
        Frame = take_sent(Table, Handle, 100),
        #{<<"realtimeInput">> := #{<<"text">> := <<"from cli">>}} =
            jsx:decode(Frame, [return_maps])
    after
        restore_env("ERLANG_ADK_DEV_TOKEN", OldToken)
    end.

live_sse_case(State = #{port := Port, session_id := SessionId,
                        handle := Handle}) ->
    Path = <<"/dev/v1/live/sessions/", SessionId/binary, "/events">>,
    {409, _, ReplayBody} = request(
                             State, get, Path,
                             [{<<"last-event-id">>, <<"1">>} | auth()],
                             <<>>),
    ?assertEqual(<<"live_event_replay_unsupported">>,
                 error_code(ReplayBody)),
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn, 2000),
    Ref = gun:get(
            Conn, Path,
            [{<<"accept">>, <<"text/event-stream">>} | auth()]),
    {response, nofin, 200, _} = gun:await(Conn, Ref, 2000),
    {data, nofin, Attached} = gun:await(Conn, Ref, 2000),
    ?assertNotEqual(nomatch, binary:match(Attached, <<"event: attached">>)),
    Raw = <<"raw-audio-secret">>,
    AudioFrame =
        #{<<"serverContent">> =>
              #{<<"modelTurn">> =>
                    #{<<"parts">> =>
                          [#{<<"inlineData">> =>
                                 #{<<"mimeType">> =>
                                       <<"audio/pcm;rate=24000">>,
                                   <<"data">> => base64:encode(Raw)}}]}}},
    adk_live_fake_transport:inject(Handle, AudioFrame),
    AudioChunk = await_chunk_containing(
                   Conn, Ref, <<"media_omitted">>, 10, <<>>),
    ?assertNotEqual(nomatch,
                    binary:match(AudioChunk, <<"\"media_omitted\":true">>)),
    ?assertEqual(nomatch, binary:match(AudioChunk, Raw)),
    ?assertEqual(nomatch,
                 binary:match(AudioChunk, base64:encode(Raw))),
    PrivateSignature = <<"PRIVATE_THOUGHT_SIGNATURE">>,
    adk_live_fake_transport:inject(
      Handle,
      #{<<"serverContent">> =>
            #{<<"modelTurn">> =>
                  #{<<"parts">> =>
                        [#{<<"text">> => <<"public live text">>,
                           <<"thought">> => false,
                           <<"thoughtSignature">> => PrivateSignature}]}}}),
    ContentChunk = await_chunk_containing(
                     Conn, Ref, <<"public live text">>, 10, <<>>),
    ?assertEqual(nomatch,
                 binary:match(ContentChunk, PrivateSignature)),
    VariantOne = <<"PRIVATE_VARIANT_ONE">>,
    VariantTwo = <<"PRIVATE_VARIANT_TWO">>,
    adk_live_fake_transport:inject(
      Handle,
      #{<<"toolCall">> =>
            #{<<"functionCalls">> =>
                  [#{<<"id">> => <<"private-filter-call">>,
                     <<"name">> => <<"privacy_probe">>,
                     <<"args">> =>
                         #{<<"Thought-Signature">> => VariantOne,
                           <<"nested">> =>
                               #{<<"THOUGHT_SIGNATURE">> => VariantTwo}}}]}}),
    ToolChunk = await_chunk_containing(
                  Conn, Ref, <<"privacy_probe">>, 10, <<>>),
    ?assertEqual(nomatch, binary:match(ToolChunk, VariantOne)),
    ?assertEqual(nomatch, binary:match(ToolChunk, VariantTwo)),
    gun:close(Conn).

live_config_validation_case() ->
    {ok, Config} = adk_dev_router:validate_config(
                     #{auth_token => ?TOKEN}),
    ?assertEqual(undefined, maps:get(live_principal, Config)),
    ?assertEqual(#{messages => 16, bytes => 4194304},
                 maps:get(live_credit, Config)),
    ?assertEqual(
       {error, invalid_dev_platform_config},
       adk_dev_router:validate_config(
         #{auth_token => ?TOKEN, live_principal => <<>>})),
    ?assertEqual(
       {error, invalid_dev_platform_config},
       adk_dev_router:validate_config(
         #{auth_token => ?TOKEN,
           live_credit => #{messages => 0, bytes => 1}})).

await_chunk_containing(_Conn, _Ref, _Needle, 0, Acc) ->
    error({live_sse_chunk_not_received, Acc});
await_chunk_containing(Conn, Ref, Needle, Attempts, Acc) ->
    case gun:await(Conn, Ref, 2000) of
        {data, _Fin, Data} ->
            Combined = <<Acc/binary, Data/binary>>,
            case binary:match(Combined, Needle) of
                nomatch -> await_chunk_containing(
                             Conn, Ref, Needle, Attempts - 1, Combined);
                _ -> Combined
            end;
        Other -> error({live_sse_failed, Other, Acc})
    end.

wait_active(_Session, 0) -> {error, timeout};
wait_active(Session, Attempts) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{state := active}} -> ok;
        _ -> receive after 5 -> wait_active(Session, Attempts - 1) end
    end.

relay_messages(Table) ->
    receive
        {stop, Owner} when is_pid(Owner) ->
            Owner ! {relay_stopped, self()},
            ok;
        Message ->
            Key = erlang:unique_integer([positive, monotonic]),
            true = ets:insert(Table, {Key, Message}),
            relay_messages(Table)
    end.

await_opened(_Table, 0) -> error(live_transport_not_opened);
await_opened(Table, Attempts) ->
    case [{Key, Handle}
          || {Key, {adk_live_fake_transport, opened, Handle}} <-
                 ets:tab2list(Table)] of
        [{Key, Handle} | _] ->
            true = ets:delete(Table, Key),
            Handle;
        [] -> receive after 5 -> await_opened(Table, Attempts - 1) end
    end.

take_sent(_Table, _Handle, 0) -> error(live_frame_not_sent);
take_sent(Table, Handle, Attempts) ->
    case [{Key, Frame}
          || {Key, {adk_live_fake_transport, sent, SentHandle, Frame}} <-
                 ets:tab2list(Table),
             SentHandle =:= Handle] of
        [{Key, Frame} | _] ->
            true = ets:delete(Table, Key),
            Frame;
        [] -> receive after 5 -> take_sent(
                                  Table, Handle, Attempts - 1) end
    end.

request(#{port := Port}, Method, Path, Headers, Body) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn, 2000),
    Ref = case Method of
        get -> gun:get(Conn, Path, Headers);
        post -> gun:post(Conn, Path, Headers, Body)
    end,
    try
        case gun:await(Conn, Ref, 3000) of
            {response, fin, Status, ResponseHeaders} ->
                {Status, ResponseHeaders, <<>>};
            {response, nofin, Status, ResponseHeaders} ->
                {ok, ResponseBody} = gun:await_body(Conn, Ref, 3000),
                {Status, ResponseHeaders, ResponseBody}
        end
    after
        gun:close(Conn)
    end.

auth() ->
    [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}].

json_auth() ->
    [{<<"content-type">>, <<"application/json">>} | auth()].

error_code(Body) ->
    Payload = jsx:decode(Body, [return_maps]),
    maps:get(<<"code">>, maps:get(<<"error">>, Payload)).

header(Name, Headers) -> proplists:get_value(Name, Headers).

evaluation_result() ->
    {ok, Set} = adk_eval_set:new(
                  <<"dev-http-eval">>, <<"1">>,
                  [#{id => <<"case">>, input => <<"actual">>,
                     expected => <<"expected">>}]),
    Adapter = #{module => adk_eval_set_test_adapter,
                target => ignored, config => #{mode => echo_expected}},
    {ok, Report} = adk_eval_set:run(
                     Adapter, Set,
                     [#{id => <<"response">>,
                        criterion => exact_response}], #{}),
    Report.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
