-module(adk_dev_http_test).
-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, adk_dev_http_test_listener).
-define(BYTE_LISTENER, adk_dev_http_byte_limit_listener).
-define(DURATION_LISTENER, adk_dev_http_duration_limit_listener).
-define(TOKEN, <<"0123456789abcdef-local-dev-token">>).
-define(COMPLETE_AGENT, <<"DevComplete">>).
-define(BLOCK_AGENT, <<"DevBlock">>).
-define(RESUME_AGENT, <<"DevResume">>).

adk_dev_http_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(State) ->
         [{"static UI is self-contained", ?_test(static_ui_case(State))},
          {"SSE limits are validated", ?_test(sse_config_validation_case())},
          {"bearer and origin policy", ?_test(auth_case(State))},
          {"agent discovery is authenticated and pid-free",
           ?_test(agent_discovery_case(State))},
          {"request body limit", ?_test(body_limit_case(State))},
          {"start, status, and cancel", ?_test(run_lifecycle_case(State))},
          {"SSE bounded replay and reconnect", ?_test(sse_replay_case(State))},
          {"SSE stale cursor reports replay gap",
           ?_test(sse_replay_gap_case(State))},
          {"SSE disconnect does not cancel", ?_test(sse_detach_case(State))},
          {"SSE byte limit closes without cancelling",
           ?_test(sse_byte_limit_closes_without_cancelling_case(State))},
          {"SSE duration limit closes without cancelling",
           ?_test(sse_duration_limit_closes_without_cancelling_case(State))},
          {"paused run resumes with a linked run ID",
           ?_test(resume_run_case(State))},
          {"session inspection is scope-isolated",
           ?_test(session_isolation_case(State))},
          {"session lifecycle is scoped, idempotent, and bounded",
           ?_test(session_lifecycle_case(State))}]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    Complete = spawn(fun() -> completing_agent_loop(10) end),
    Block = spawn(fun blocking_agent_loop/0),
    Resume = spawn(fun() -> resumable_agent_loop(initial) end),
    ok = register_agent(?COMPLETE_AGENT, Complete),
    ok = register_agent(?BLOCK_AGENT, Block),
    ok = register_agent(?RESUME_AGENT, Resume),
    Config = dev_test_config(
               #{sse_heartbeat_ms => 20,
                 sse_max_events => 2,
                 sse_max_bytes => 1048576,
                 sse_max_duration_ms => 5000}),
    {ok, _} = cowboy:start_clear(
                ?LISTENER, [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    #{port => ranch:get_port(?LISTENER),
      complete => Complete,
      block => Block,
      resume => Resume}.

cleanup(#{complete := Complete, block := Block, resume := Resume}) ->
    _ = cowboy:stop_listener(?LISTENER),
    ok = adk_agent_registry:unregister_name(?COMPLETE_AGENT),
    ok = adk_agent_registry:unregister_name(?BLOCK_AGENT),
    ok = adk_agent_registry:unregister_name(?RESUME_AGENT),
    Complete ! stop,
    Block ! stop,
    Resume ! stop,
    ok.

static_ui_case(State) ->
    {200, Headers, Body} = request(State, get, <<"/dev">>, [], <<>>),
    ?assertEqual(
       nomatch,
       binary:match(Body, ?TOKEN)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"Erlang ADK Developer Console">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/dev/v1/runs">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/dev/v1/agents">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Create/switch session">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Delete session">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Apply state delta">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"Human approval">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"last-event-id">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"terminalSeen">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Body, <<"run_event_replay_gap">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"https://">>)),
    Csp = header(<<"content-security-policy">>, Headers),
    ?assertNotEqual(nomatch, binary:match(Csp, <<"connect-src 'self'">>)),
    ?assertNotEqual(nomatch, binary:match(Csp, <<"script-src 'nonce-">>)),
    {405, _, _} = request(State, post, <<"/dev">>, [], <<>>).

sse_config_validation_case() ->
    Base = #{auth_token => ?TOKEN},
    {ok, Validated} = adk_dev_router:validate_config(Base),
    ?assertEqual(128, maps:get(sse_max_events, Validated)),
    ?assertEqual(1048576, maps:get(sse_max_bytes, Validated)),
    ?assertEqual(300000, maps:get(sse_max_duration_ms, Validated)),
    lists:foreach(
      fun(Key) ->
          ?assertEqual(
             {error, invalid_dev_platform_config},
             adk_dev_router:validate_config(Base#{Key => 0}))
      end,
      [sse_max_events, sse_max_bytes, sse_max_duration_ms]),
    ?assertEqual(
       {error, invalid_dev_platform_config},
       adk_dev_router:validate_config(Base#{sse_max_events => 10001})),
    ?assertEqual(
       {error, invalid_dev_platform_config},
       adk_dev_router:validate_config(Base#{sse_max_bytes => 16777217})),
    ?assertEqual(
       {error, invalid_dev_platform_config},
       adk_dev_router:validate_config(
         Base#{sse_max_duration_ms => 3600001})).

auth_case(State) ->
    Path = <<"/dev/v1/runs/not-a-run">>,
    {401, MissingHeaders, MissingBody} =
        request(State, get, Path, [], <<>>),
    ?assertNotEqual(undefined,
                    header(<<"www-authenticate">>, MissingHeaders)),
    ?assertEqual(<<"unauthorized">>, error_code(MissingBody)),

    %% A URI token is never an authentication channel.
    {401, _, _} = request(
                    State, get,
                    <<Path/binary, "?access_token=", ?TOKEN/binary>>,
                    [], <<>>),
    {403, _, WrongBody} = request(
                             State, get, Path,
                             auth_header(<<"wrong-token-value">>), <<>>),
    ?assertEqual(<<"forbidden">>, error_code(WrongBody)),
    {401, _, _} = request(
                    State, get, Path,
                    [{<<"authorization">>, <<"Basic ", ?TOKEN/binary>>}], <<>>),

    BadOrigin = [{<<"origin">>, <<"https://attacker.invalid">>}
                 | auth_header(?TOKEN)],
    {403, _, _} = request(State, get, Path, BadOrigin, <<>>),
    {404, _, _} = request(State, get, Path, auth_header(?TOKEN), <<>>).

agent_discovery_case(State) ->
    {401, _, _} = request(State, get, <<"/dev/v1/agents">>, [], <<>>),
    {200, _, Body} = request(
                       State, get, <<"/dev/v1/agents">>,
                       auth_header(?TOKEN), <<>>),
    Payload = jsx:decode(Body, [return_maps]),
    Names = [maps:get(<<"name">>, Agent)
             || Agent <- maps:get(<<"agents">>, Payload)],
    ?assert(lists:member(?COMPLETE_AGENT, Names)),
    ?assert(lists:member(?BLOCK_AGENT, Names)),
    ?assert(lists:member(?RESUME_AGENT, Names)),
    ?assertEqual(lists:sort(Names), Names),
    ?assertEqual(nomatch, binary:match(Body, <<"pid">>)),
    {405, _, _} = request(
                    State, post, <<"/dev/v1/agents">>,
                    auth_header(?TOKEN), <<"">>).

body_limit_case(State) ->
    Oversized = binary:copy(<<"x">>, 1025),
    Headers = [{<<"content-type">>, <<"application/json">>}
               | auth_header(?TOKEN)],
    {413, ResponseHeaders, Body} =
        request(State, post, <<"/dev/v1/runs">>, Headers, Oversized),
    ?assertEqual(<<"close">>, header(<<"connection">>, ResponseHeaders)),
    ?assertEqual(<<"payload_too_large">>, error_code(Body)).

run_lifecycle_case(State) ->
    Session = unique(<<"lifecycle">>),
    try
        {202, Headers, StartedBody} =
            start_run(State, ?BLOCK_AGENT, <<"app">>, <<"user">>,
                      Session, <<"wait">>),
        Started = jsx:decode(StartedBody, [return_maps]),
        RunId = maps:get(<<"run_id">>, Started),
        ?assertMatch(<<"run-", _/binary>>, RunId),
        ?assertEqual(<<"/dev/v1/runs/", RunId/binary>>,
                     header(<<"location">>, Headers)),

        {200, _, StatusBody} = request(
                                 State, get, run_path(RunId),
                                 auth_header(?TOKEN), <<>>),
        ?assertEqual(<<"running">>,
                     maps:get(<<"state">>,
                              jsx:decode(StatusBody, [return_maps]))),

        {202, _, _} = request(State, delete, run_path(RunId),
                              auth_header(?TOKEN), <<>>),
        {ok, Cancelled} = await_http_state(State, RunId, <<"cancelled">>, 100),
        Outcome = maps:get(<<"outcome">>, Cancelled),
        ?assertEqual(<<"cancelled">>, maps:get(<<"type">>, Outcome)),
        ?assertEqual(<<"developer_cancelled">>,
                     maps:get(<<"reason">>, Outcome)),
        {409, _, _} = request(State, delete, run_path(RunId),
                              auth_header(?TOKEN), <<>>)
    after
        _ = erlang_adk_session:delete_session(<<"app">>, <<"user">>, Session)
    end.

sse_replay_case(State) ->
    Session = unique(<<"replay">>),
    try
        {202, _, StartedBody} =
            start_run(State, ?COMPLETE_AGENT, <<"app">>, <<"user">>,
                      Session, <<"hello">>),
        RunId = maps:get(<<"run_id">>,
                         jsx:decode(StartedBody, [return_maps])),
        {ok, Completed} = await_http_state(
                            State, RunId, <<"completed">>, 100),
        ?assertEqual(<<"Response text">>,
                     maps:get(<<"text">>, maps:get(<<"outcome">>, Completed))),

        FirstBody = completed_stream(State, RunId, []),
        FirstIds = sse_ids(FirstBody),
        %% This listener deliberately caps each connection at two run events.
        %% The terminal outcome remains retained for the next Last-Event-ID
        %% request rather than accumulating in Cowboy's connection queue.
        ?assertEqual([1, 2], FirstIds),
        ?assertNotEqual(nomatch, binary:match(FirstBody, <<"event: event">>)),
        ?assertEqual(nomatch,
                     binary:match(FirstBody, <<"event: terminal">>)),

        Tail = completed_stream(
                 State, RunId,
                 [{<<"last-event-id">>, integer_to_binary(lists:last(FirstIds))}]),
        ?assertEqual([3], sse_ids(Tail)),
        ?assertNotEqual(nomatch, binary:match(Tail, <<"event: terminal">>)),

        Cursor = hd(FirstIds),
        Reconnected = completed_stream(
                        State, RunId,
                        [{<<"last-event-id">>, integer_to_binary(Cursor)}]),
        ?assertEqual([2, 3], sse_ids(Reconnected)),
        ?assertNotEqual(nomatch,
                        binary:match(Reconnected, <<"event: terminal">>)),
        ?assertEqual(nomatch,
                     binary:match(
                       Reconnected,
                       <<"id: ", (integer_to_binary(Cursor))/binary, "\n">>))
    after
        _ = erlang_adk_session:delete_session(<<"app">>, <<"user">>, Session)
    end.

sse_replay_gap_case(State = #{complete := Agent}) ->
    App = <<"gap-app">>,
    User = <<"gap-user">>,
    Session = unique(<<"gap">>),
    Runner = adk_runner:new(
               Agent, App, erlang_adk_session,
               #{run_timeout => 5000}),
    try
        {ok, RunId} = adk_run:start(
                        Runner, User, Session, <<"produce retained gap">>,
                        #{retention_ms => 10000,
                          max_buffered_events => 1}),
        {completed, <<"Response text">>} = adk_run:await(RunId, 2000),

        {409, _, GapBody} = request(
                              State, get,
                              <<(run_path(RunId))/binary, "/events">>,
                              auth_header(?TOKEN), <<>>),
        GapError = maps:get(
                     <<"error">>, jsx:decode(GapBody, [return_maps])),
        ?assertEqual(<<"run_event_replay_gap">>,
                     maps:get(<<"code">>, GapError)),
        Gap = maps:get(<<"details">>, GapError),
        ?assertEqual(0, maps:get(<<"after_sequence">>, Gap)),
        ?assertEqual(2, maps:get(<<"oldest_available_sequence">>, Gap)),
        ?assertEqual(3, maps:get(<<"latest_sequence">>, Gap)),
        ?assertEqual(true, maps:get(<<"terminal">>, Gap)),

        {409, _, AheadBody} = request(
                                State, get,
                                <<(run_path(RunId))/binary, "/events">>,
                                [{<<"last-event-id">>, <<"99">>}
                                 | auth_header(?TOKEN)], <<>>),
        ?assertEqual(
           <<"run_event_cursor_ahead">>, error_code(AheadBody))
    after
        _ = erlang_adk_session:delete_session(App, User, Session)
    end.

sse_detach_case(State) ->
    Session = unique(<<"detach">>),
    try
        {202, _, StartedBody} =
            start_run(State, ?BLOCK_AGENT, <<"app">>, <<"user">>,
                      Session, <<"keep running">>),
        RunId = maps:get(<<"run_id">>,
                         jsx:decode(StartedBody, [return_maps])),
        {Conn, StreamRef} = open_stream(State, RunId, []),
        {response, nofin, 200, _} = gun:await(Conn, StreamRef, 2000),
        %% Observe at least one replayed event or heartbeat before detaching.
        {data, _Fin, _Chunk} = gun:await(Conn, StreamRef, 2000),
        gun:close(Conn),
        ok = await_subscriber_count(RunId, 0, 100),
        {ok, RuntimeStatus} = adk_run:status(RunId),
        ?assertEqual(running, maps:get(state, RuntimeStatus)),

        {202, _, _} = request(State, delete, run_path(RunId),
                              auth_header(?TOKEN), <<>>),
        {ok, _} = await_http_state(State, RunId, <<"cancelled">>, 100)
    after
        _ = erlang_adk_session:delete_session(<<"app">>, <<"user">>, Session)
    end.

sse_byte_limit_closes_without_cancelling_case(State) ->
    with_test_listener(
      ?BYTE_LISTENER, State,
      #{sse_heartbeat_ms => 20,
        sse_max_events => 128,
        sse_max_bytes => 1,
        sse_max_duration_ms => 5000},
      fun(ByteState) ->
          Session = unique(<<"byte-limit">>),
          try
              {202, _, StartedBody} =
                  start_run(ByteState, ?BLOCK_AGENT, <<"app">>, <<"user">>,
                            Session, <<"remain alive after byte limit">>),
              RunId = maps:get(
                        <<"run_id">>,
                        jsx:decode(StartedBody, [return_maps])),
              %% The first encoded event is larger than one byte. The stream
              %% closes without emitting a partial frame or acknowledging it.
              ?assertEqual(<<>>, bounded_stream(ByteState, RunId)),
              ok = await_subscriber_count(RunId, 0, 100),
              {ok, RuntimeStatus} = adk_run:status(RunId),
              ?assertEqual(running, maps:get(state, RuntimeStatus)),
              {202, _, _} = request(
                              ByteState, delete, run_path(RunId),
                              auth_header(?TOKEN), <<>>),
              {ok, _} = await_http_state(
                          ByteState, RunId, <<"cancelled">>, 100)
          after
              _ = erlang_adk_session:delete_session(
                    <<"app">>, <<"user">>, Session)
          end
      end).

sse_duration_limit_closes_without_cancelling_case(State) ->
    with_test_listener(
      ?DURATION_LISTENER, State,
      #{sse_heartbeat_ms => 10,
        sse_max_events => 128,
        sse_max_bytes => 1048576,
        sse_max_duration_ms => 60},
      fun(DurationState) ->
          Session = unique(<<"duration-limit">>),
          try
              {202, _, StartedBody} =
                  start_run(DurationState, ?BLOCK_AGENT,
                            <<"app">>, <<"user">>, Session,
                            <<"remain alive after duration limit">>),
              RunId = maps:get(
                        <<"run_id">>,
                        jsx:decode(StartedBody, [return_maps])),
              StartedAt = erlang:monotonic_time(millisecond),
              Body = bounded_stream(DurationState, RunId),
              Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
              ?assertNotEqual(nomatch, binary:match(Body, <<"id: 1">>)),
              ?assert(Elapsed >= 30),
              ?assert(Elapsed < 1500),
              ok = await_subscriber_count(RunId, 0, 100),
              {ok, RuntimeStatus} = adk_run:status(RunId),
              ?assertEqual(running, maps:get(state, RuntimeStatus)),
              {202, _, _} = request(
                              DurationState, delete, run_path(RunId),
                              auth_header(?TOKEN), <<>>),
              {ok, _} = await_http_state(
                          DurationState, RunId, <<"cancelled">>, 100)
          after
              _ = erlang_adk_session:delete_session(
                    <<"app">>, <<"user">>, Session)
          end
      end).

resume_run_case(State) ->
    Session = unique(<<"resume">>),
    try
        {202, _, StartedBody} =
            start_run(State, ?RESUME_AGENT, <<"app">>, <<"user">>,
                      Session, <<"publish">>),
        PausedRunId = maps:get(
                        <<"run_id">>,
                        jsx:decode(StartedBody, [return_maps])),
        {ok, _Paused} = await_http_state(
                          State, PausedRunId, <<"paused">>, 100),

        Decision = #{<<"approved">> => true},
        {202, ResumeHeaders, ResumeBody} =
            resume_run(State, PausedRunId, Decision),
        Resumed = jsx:decode(ResumeBody, [return_maps]),
        ResumedRunId = maps:get(<<"run_id">>, Resumed),
        ?assertNotEqual(PausedRunId, ResumedRunId),
        ?assertEqual(PausedRunId, maps:get(<<"parent_run_id">>, Resumed)),
        ?assertEqual(<<"/dev/v1/runs/", ResumedRunId/binary>>,
                     header(<<"location">>, ResumeHeaders)),

        {ok, Completed} = await_http_state(
                            State, ResumedRunId, <<"completed">>, 100),
        ?assertEqual(
           <<"Release published">>,
           maps:get(<<"text">>, maps:get(<<"outcome">>, Completed))),
        ?assertEqual(PausedRunId,
                     maps:get(<<"parent_run_id">>, Completed)),

        {409, _, ReplayBody} =
            resume_run(State, PausedRunId, Decision),
        ReplayError = maps:get(
                        <<"error">>,
                        jsx:decode(ReplayBody, [return_maps])),
        ?assertEqual(<<"run_already_resumed">>,
                     maps:get(<<"code">>, ReplayError)),
        ?assertEqual(ResumedRunId,
                     maps:get(<<"resumed_run_id">>, ReplayError))
    after
        _ = erlang_adk_session:delete_session(
              <<"app">>, <<"user">>, Session)
    end.

session_isolation_case(State) ->
    App = unique(<<"scope-app">>),
    Session = <<"shared-session-id">>,
    UserA = <<"alice">>,
    UserB = <<"bob">>,
    try
        {ok, _} = erlang_adk_session:create_session(
                    App, UserA,
                    #{session_id => Session,
                      state => #{<<"profile">> => <<"alice-only">>,
                                 <<"client_secret">> =>
                                     <<"must-not-be-rendered">>}}),
        {ok, _} = erlang_adk_session:create_session(
                    App, UserB,
                    #{session_id => Session,
                      state => #{<<"profile">> => <<"bob-only">>}}),
        {200, _, AliceBody} = request(
                                State, get,
                                session_path(App, UserA, Session),
                                auth_header(?TOKEN), <<>>),
        ?assertNotEqual(nomatch, binary:match(AliceBody, <<"alice-only">>)),
        ?assertEqual(nomatch, binary:match(AliceBody, <<"bob-only">>)),
        ?assertEqual(nomatch,
                     binary:match(AliceBody, <<"must-not-be-rendered">>)),
        ?assertNotEqual(nomatch, binary:match(AliceBody, <<"[REDACTED]">>)),
        {200, _, BobBody} = request(
                              State, get,
                              session_path(App, UserB, Session),
                              auth_header(?TOKEN), <<>>),
        ?assertNotEqual(nomatch, binary:match(BobBody, <<"bob-only">>)),
        ?assertEqual(nomatch, binary:match(BobBody, <<"alice-only">>)),
        {404, _, _} = request(
                        State, get,
                        session_path(App, <<"mallory">>, Session),
                        auth_header(?TOKEN), <<>>)
    after
        _ = erlang_adk_session:delete_session(App, UserA, Session),
        _ = erlang_adk_session:delete_session(App, UserB, Session)
    end.

session_lifecycle_case(State) ->
    App = unique(<<"lifecycle-app">>),
    User = <<"session-owner">>,
    OtherUser = <<"other-owner">>,
    SessionIds = [<<"session-a">>, <<"session-b">>, <<"session-c">>],
    CollectionPath = sessions_path(App, User),
    Headers = [{<<"content-type">>, <<"application/json">>}
               | auth_header(?TOKEN)],
    try
        lists:foreach(
          fun(SessionId) ->
              Body = jsx:encode(#{<<"session_id">> => SessionId}),
              {201, _, CreatedBody} = request(
                                         State, post, CollectionPath,
                                         Headers, Body),
              ?assertEqual(
                 SessionId,
                 maps:get(<<"id">>,
                          jsx:decode(CreatedBody, [return_maps])))
          end, SessionIds),

        %% Creation is idempotent and never overwrites session state.
        {200, _, _} = request(
                        State, post, CollectionPath, Headers,
                        jsx:encode(#{<<"session_id">> => hd(SessionIds)})),
        {400, _, InvalidBody} = request(
                                  State, post, CollectionPath, Headers,
                                  jsx:encode(
                                    #{<<"session_id">> => <<"forbidden">>,
                                      <<"state">> =>
                                          #{<<"access_token">> =>
                                                <<"never-store-me">>}})),
        ?assertEqual(<<"invalid_session_request">>,
                     error_code(InvalidBody)),
        ?assertEqual(nomatch,
                     binary:match(InvalidBody, <<"never-store-me">>)),

        {200, _, ListedBody} = request(
                                 State, get, CollectionPath,
                                 auth_header(?TOKEN), <<>>),
        Listed = jsx:decode(ListedBody, [return_maps]),
        ?assertEqual(3, maps:get(<<"total">>, Listed)),
        ?assertEqual(true, maps:get(<<"truncated">>, Listed)),
        ?assertEqual(2, length(maps:get(<<"sessions">>, Listed))),
        {200, _, EmptyOtherBody} = request(
                                     State, get,
                                     sessions_path(App, OtherUser),
                                     auth_header(?TOKEN), <<>>),
        ?assertEqual(
           [], maps:get(<<"sessions">>,
                        jsx:decode(EmptyOtherBody, [return_maps]))),

        First = hd(SessionIds),
        StatePath = <<(session_path(App, User, First))/binary, "/state">>,
        {200, _, UpdatedBody} = request(
                                  State, post, StatePath, Headers,
                                  jsx:encode(
                                    #{<<"state_delta">> =>
                                          #{<<"draft">> => <<"ready">>}})),
        Updated = jsx:decode(UpdatedBody, [return_maps]),
        ?assertEqual(
           <<"ready">>,
           maps:get(<<"draft">>, maps:get(<<"state">>, Updated))),
        {400, _, SecretBody} = request(
                                 State, post, StatePath, Headers,
                                 jsx:encode(
                                   #{<<"state_delta">> =>
                                         #{<<"access_token">> =>
                                               <<"never-store-this-token">>}})),
        ?assertEqual(<<"forbidden_state_key">>, error_code(SecretBody)),
        ?assertEqual(nomatch,
                     binary:match(SecretBody,
                                  <<"never-store-this-token">>)),
        {200, _, _} = request(
                        State, get, session_path(App, User, First),
                        auth_header(?TOKEN), <<>>),
        {200, _, DeletedBody} = request(
                                  State, delete,
                                  session_path(App, User, First),
                                  auth_header(?TOKEN), <<>>),
        ?assertEqual(true,
                     maps:get(<<"deleted">>,
                              jsx:decode(DeletedBody, [return_maps]))),
        {404, _, _} = request(
                        State, delete,
                        session_path(App, User, First),
                        auth_header(?TOKEN), <<>>)
    after
        lists:foreach(
          fun(SessionId) ->
              _ = erlang_adk_session:delete_session(
                    App, User, SessionId)
          end, SessionIds)
    end.

start_run(State, Agent, App, User, Session, Message) ->
    Body = jsx:encode(#{<<"agent_name">> => Agent,
                        <<"app_name">> => App,
                        <<"user_id">> => User,
                        <<"session_id">> => Session,
                        <<"message">> => Message}),
    Headers = [{<<"content-type">>, <<"application/json">>}
               | auth_header(?TOKEN)],
    request(State, post, <<"/dev/v1/runs">>, Headers, Body).

resume_run(State, RunId, ToolResponse) ->
    Body = jsx:encode(#{<<"tool_response">> => ToolResponse}),
    Headers = [{<<"content-type">>, <<"application/json">>}
               | auth_header(?TOKEN)],
    request(State, post,
            <<(run_path(RunId))/binary, "/resume">>, Headers, Body).

completed_stream(State, RunId, ExtraHeaders) ->
    {Conn, Ref} = open_stream(State, RunId, ExtraHeaders),
    try
        {response, nofin, 200, _} = gun:await(Conn, Ref, 2000),
        collect_stream(Conn, Ref, <<>>)
    after
        gun:close(Conn)
    end.

bounded_stream(State, RunId) ->
    {Conn, Ref} = open_stream(State, RunId, []),
    try
        case gun:await(Conn, Ref, 2000) of
            {response, fin, 200, _} -> <<>>;
            {response, nofin, 200, _} -> collect_stream(Conn, Ref, <<>>)
        end
    after
        gun:close(Conn)
    end.

open_stream(#{port := Port}, RunId, ExtraHeaders) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn, 2000),
    Headers = [{<<"accept">>, <<"text/event-stream">>}
               | auth_header(?TOKEN) ++ ExtraHeaders],
    Ref = gun:get(Conn, <<(run_path(RunId))/binary, "/events">>, Headers),
    {Conn, Ref}.

collect_stream(Conn, Ref, Acc) ->
    case gun:await(Conn, Ref, 2000) of
        {data, nofin, Data} ->
            collect_stream(Conn, Ref, <<Acc/binary, Data/binary>>);
        {data, fin, Data} ->
            <<Acc/binary, Data/binary>>;
        {error, Reason} ->
            error({stream_failed, Reason, Acc})
    end.

request(#{port := Port}, Method, Path, Headers, Body) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn, 2000),
    Ref = case Method of
        get -> gun:get(Conn, Path, Headers);
        post -> gun:post(Conn, Path, Headers, Body);
        delete -> gun:delete(Conn, Path, Headers)
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

await_http_state(_State, _RunId, _Expected, 0) ->
    {error, timeout};
await_http_state(State, RunId, Expected, Attempts) ->
    case request(State, get, run_path(RunId), auth_header(?TOKEN), <<>>) of
        {200, _, Body} ->
            Status = jsx:decode(Body, [return_maps]),
            case maps:get(<<"state">>, Status) of
                Expected -> {ok, Status};
                _ -> pause_then(fun() ->
                                    await_http_state(
                                      State, RunId, Expected, Attempts - 1)
                                end)
            end;
        _ ->
            pause_then(fun() ->
                           await_http_state(
                             State, RunId, Expected, Attempts - 1)
                       end)
    end.

await_subscriber_count(_RunId, _Expected, 0) ->
    {error, timeout};
await_subscriber_count(RunId, Expected, Attempts) ->
    case adk_run:status(RunId) of
        {ok, #{subscriber_count := Expected}} -> ok;
        _ -> pause_then(fun() ->
                            await_subscriber_count(
                              RunId, Expected, Attempts - 1)
                        end)
    end.

pause_then(Fun) ->
    receive after 5 -> Fun() end.

sse_ids(Body) ->
    case re:run(Body, <<"id: ([0-9]+)">>,
                [global, {capture, [1], binary}]) of
        {match, Matches} ->
            [binary_to_integer(Id) || [Id] <- Matches];
        nomatch -> []
    end.

run_path(RunId) -> <<"/dev/v1/runs/", RunId/binary>>.

session_path(App, User, Session) ->
    <<"/dev/v1/sessions/", App/binary, "/", User/binary, "/",
      Session/binary>>.

sessions_path(App, User) ->
    <<"/dev/v1/sessions/", App/binary, "/", User/binary>>.

auth_header(Token) ->
    [{<<"authorization">>, <<"Bearer ", Token/binary>>}].

header(Name, Headers) -> proplists:get_value(Name, Headers).

error_code(Body) ->
    Decoded = jsx:decode(Body, [return_maps]),
    maps:get(<<"code">>, maps:get(<<"error">>, Decoded)).

register_agent(Name, Pid) ->
    ok = adk_agent_registry:unregister_name(Name),
    case adk_agent_registry:register_name(Name, Pid) of
        yes -> ok;
        no -> error({agent_registration_failed, Name})
    end.

dev_test_config(Overrides) ->
    maps:merge(
      #{auth_token => ?TOKEN,
        session_service => erlang_adk_session,
        runner_options => #{run_timeout => 5000},
        run_options => #{retention_ms => 10000,
                         max_buffered_events => 8,
                         cancel_grace_ms => 20},
        max_body_bytes => 1024,
        max_field_bytes => 128,
        max_session_results => 2},
      Overrides).

with_test_listener(Name, State, Overrides, Fun) ->
    Config = dev_test_config(Overrides),
    {ok, _} = cowboy:start_clear(
                Name, [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    ScopedState = State#{port => ranch:get_port(Name)},
    try Fun(ScopedState)
    after
        _ = cowboy:stop_listener(Name)
    end.

completing_agent_loop(Delay) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, ?COMPLETE_AGENT, #{}, [], #{}}),
            completing_agent_loop(Delay);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            erlang:send_after(Delay, self(), {reply_final, From, InvocationId}),
            completing_agent_loop(Delay);
        {reply_final, From, InvocationId} ->
            Event = adk_event:new(
                      ?COMPLETE_AGENT, <<"Response text">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            completing_agent_loop(Delay);
        stop -> ok;
        _ -> completing_agent_loop(Delay)
    end.

blocking_agent_loop() ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, ?BLOCK_AGENT, #{}, [], #{}}),
            blocking_agent_loop();
        {'$gen_call', _From, {run_with_events, _History, _InvocationId}} ->
            blocking_agent_loop();
        stop -> ok;
        _ -> blocking_agent_loop()
    end.

resumable_agent_loop(initial) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, ?RESUME_AGENT, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(initial);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Calls = [{<<"request_human_approval">>,
                      #{<<"action_summary">> => <<"Publish release">>},
                      undefined, <<"dev-approval-call">>}],
            Event = adk_event:new(
                      ?RESUME_AGENT, {tool_calls, Calls},
                      #{invocation_id => InvocationId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            resumable_agent_loop(paused);
        stop -> ok;
        _ -> resumable_agent_loop(initial)
    end;
resumable_agent_loop(paused) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, ?RESUME_AGENT, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(paused);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      ?RESUME_AGENT, <<"Release published">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            resumable_agent_loop(done);
        stop -> ok;
        _ -> resumable_agent_loop(paused)
    end;
resumable_agent_loop(done) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, ?RESUME_AGENT, #{},
                     [adk_long_running_tool], #{}}),
            resumable_agent_loop(done);
        stop -> ok;
        _ -> resumable_agent_loop(done)
    end.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
