-module(adk_dev_v05_http_test).

-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, adk_dev_v05_http_test_listener).
-define(FALLBACK_LISTENER, adk_dev_v05_fallback_listener).
-define(SCOPE_MISMATCH_LISTENER, adk_dev_v05_scope_mismatch_listener).
-define(TOKEN, <<"v05-local-developer-token-0123456789">>).
-define(MODEL, <<"gemini-3.1-flash-lite">>).

dev_v05_http_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(State) ->
         [?_test(provider_config_case()),
          ?_test(ui_case(State)),
          ?_test(diagnostics_and_context_case(State)),
          ?_test(context_lifecycle_case(State)),
          ?_test(runner_options_compatibility_case(State)),
          ?_test(artifact_case(State)),
          ?_test(memory_case(State)),
          ?_test(resource_scope_mismatch_fails_closed(State)),
          ?_test(cli_case(State))]
     end}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    App = unique(<<"dev-v05-app">>),
    User = unique(<<"dev-v05-user">>),
    Session = unique(<<"dev-v05-session">>),
    {ok, _} = erlang_adk_session:create_session(
                App, User,
                #{session_id => Session,
                  state => #{<<"password">> =>
                                 <<"context-secret-must-not-appear">>}}),
    Event = adk_event:new(
              <<"user">>, <<"context-event-content-must-not-appear">>),
    ok = erlang_adk_session:add_event(App, User, Session, Event),
    EventId = maps:get(<<"id">>, adk_event:to_map(Event)),
    Checkpoint =
        #{<<"schema_version">> => 1,
          <<"kind">> => <<"context_compaction_checkpoint">>,
          <<"checkpoint_id">> => <<"checkpoint-1">>,
          <<"summary_event_id">> => <<"summary-1">>,
          <<"trigger">> => <<"event_threshold">>,
          <<"retained_event_count">> => 0,
          <<"retained_user_turns">> => 0,
          <<"summary_bytes">> => 42,
          <<"source">> =>
              #{<<"event_count">> => 1,
                <<"first_event_id">> => EventId,
                <<"last_event_id">> => EventId,
                <<"first_timestamp">> => 100,
                <<"last_timestamp">> => 101,
                <<"fingerprint">> =>
                    <<"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>},
          <<"provider_resource">> =>
              <<"checkpoint-provider-resource-must-not-appear">>,
          <<"summary">> => <<"checkpoint-summary-must-not-appear">>},
    Summary = adk_event:new(
                <<"context_compactor">>,
                <<"compaction-summary-content-must-not-appear">>,
                #{actions =>
                      #{<<"context_compaction_checkpoint">> => Checkpoint}}),
    ok = erlang_adk_session:compact_events(
           App, User, Session, [EventId], Summary),
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    ArtifactRef = {adk_artifact_ets, ArtifactPid},
    ArtifactScope = {session, App, User, Session},
    {ok, _} = adk_artifact_ets:put(
                ArtifactPid, ArtifactScope, <<"report.txt">>,
                <<"artifact-bytes-must-not-appear">>,
                #{mime_type => <<"text/plain">>,
                  metadata => #{<<"password">> =>
                                    <<"artifact-secret-must-not-appear">>}}),
    {ok, _} = adk_artifact_ets:put(
                ArtifactPid, ArtifactScope, <<"cli-delete.txt">>,
                <<"cli-artifact-data-must-not-appear">>, #{}),
    {ok, MemoryPid} = adk_memory_ets:start_link(#{}),
    MemoryRef = {adk_memory_ets, MemoryPid},
    MemoryScope = {user, App, User},
    {ok, MemoryOne} = adk_memory_ets:add_entry(
                        MemoryPid, MemoryScope,
                        #{content => <<"lightweight process supervision">>,
                          metadata => #{<<"password">> =>
                                            <<"memory-secret-must-not-appear">>},
                          provenance => #{session_id => Session,
                                          author => <<"user">>,
                                          timestamp => 100}}, #{}),
    {ok, _MemoryTwo} = adk_memory_ets:add_entry(
                         MemoryPid, MemoryScope,
                         #{content => <<"mailbox isolation and concurrency">>,
                           metadata => #{},
                           provenance => #{session_id => Session,
                                           author => <<"agent">>,
                                           timestamp => 101}}, #{}),
    adk_context_cache_fake_provider:reset(success),
    {ok, CachePid} = adk_context_cache:start_link(#{}),
    CachePolicy = cache_policy(),
    CacheScope = #{app => App, user => User, model => ?MODEL,
                   policy => CachePolicy},
    {ok, _CacheLease, _} = adk_context_cache:acquire(
                             CachePid,
                             adk_context_cache_fake_provider,
                             CacheScope,
                             #{<<"history_prefix">> =>
                                   [<<"cache-prefix-must-not-appear">>]},
                             #{}),
    OtherScope = CacheScope#{user => <<"other-user">>},
    {ok, OtherLease, _} = adk_context_cache:acquire(
                            CachePid,
                            adk_context_cache_fake_provider,
                            OtherScope,
                            #{<<"history_prefix">> =>
                                  [<<"other-cache-prefix-must-not-appear">>]},
                            #{}),
    ProviderConfig = #{app => App, user => User, session => Session,
                       artifact => ArtifactRef, memory => MemoryRef},
    Config = #{auth_token => ?TOKEN,
               session_service => erlang_adk_session,
               runner_options =>
                   #{context_cache =>
                         #{cache => CachePid,
                           provider => adk_context_cache_fake_provider,
                           ttl_ms => 300000,
                           policy => CachePolicy}},
               run_options => #{},
               resource_provider =>
                   {adk_dev_v05_resource_provider, ProviderConfig},
               max_body_bytes => 16384, max_field_bytes => 512,
               max_resource_results => 10,
               diagnostic_timeout_ms => 2000},
    {ok, _} = cowboy:start_clear(
                ?LISTENER, [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    #{port => ranch:get_port(?LISTENER), app => App, user => User,
      session => Session, artifact_pid => ArtifactPid,
      memory_pid => MemoryPid, memory_one => maps:get(id, MemoryOne),
      cache_pid => CachePid, other_cache_lease => OtherLease}.

cleanup(State) ->
    _ = cowboy:stop_listener(?LISTENER),
    _ = adk_context_cache:stop(maps:get(cache_pid, State)),
    _ = adk_artifact_ets:stop(maps:get(artifact_pid, State)),
    _ = adk_memory_ets:stop(maps:get(memory_pid, State)),
    _ = erlang_adk_session:delete_session(
          maps:get(app, State), maps:get(user, State), maps:get(session, State)),
    ok.

provider_config_case() ->
    ?assertEqual(
       {error, invalid_dev_platform_config},
       adk_dev_router:validate_config(
         #{auth_token => ?TOKEN,
           resource_provider => {adk_dev_v05_resource_provider, undefined}})),
    {ok, Checked} = adk_dev_router:validate_config(
                      #{auth_token => ?TOKEN}),
    ?assertEqual(100, maps:get(max_resource_results, Checked)),
    ?assertEqual(5000, maps:get(diagnostic_timeout_ms, Checked)),
    ?assertEqual(undefined, maps:get(resource_provider, Checked)).

ui_case(State) ->
    {200, _, Body} = request(State, get, <<"/dev">>, [], <<>>),
    lists:foreach(
      fun(Text) -> ?assertNotEqual(nomatch, binary:match(Body, Text)) end,
      [<<"Context diagnostics">>, <<"Artifacts">>, <<"Memory">>,
       <<"inspectContext">>, <<"inspectContextLifecycle">>,
       <<"invalidateContextCache">>, <<"deleteArtifact">>,
       <<"eraseMemory">>]),
    ?assertEqual(nomatch, binary:match(Body, ?TOKEN)),
    ?assertEqual(nomatch, binary:match(Body, <<"https://">>)).

diagnostics_and_context_case(State) ->
    {401, _, _} = request(
                    State, get, <<"/dev/v1/diagnostics">>, [], <<>>),
    {200, _, DiagnosticBody} = request(
                                 State, get, <<"/dev/v1/diagnostics">>,
                                 auth(), <<>>),
    Diagnostic = decode(DiagnosticBody),
    ?assertEqual(<<"provider">>,
                 maps:get(<<"artifact">>,
                          maps:get(<<"resources">>, Diagnostic))),
    assert_absent(DiagnosticBody,
                  [<<"artifact-bytes-must-not-appear">>, <<"#Pid">>,
                   <<"context-secret-must-not-appear">>]),
    {App, User, Session} = scope(State),
    Path = <<"/dev/v1/context/", App/binary, "/", User/binary, "/",
             Session/binary>>,
    {200, _, ContextBody} = request(State, get, Path, auth(), <<>>),
    Context = maps:get(<<"context">>, decode(ContextBody)),
    Fingerprint = maps:get(<<"fingerprint">>, Context),
    ?assertEqual(64, byte_size(maps:get(<<"value">>, Fingerprint))),
    ?assertEqual(1, maps:get(<<"input_events">>, Context)),
    assert_absent(ContextBody,
                  [<<"context-event-content-must-not-appear">>,
                   <<"context-secret-must-not-appear">>]),
    ?assertEqual(false, maps:is_key(<<"events">>, Context)),
    ?assertEqual(false, maps:is_key(<<"state">>, Context)).

context_lifecycle_case(State) ->
    {App, User, Session} = scope(State),
    Base = <<"/dev/v1/context/", App/binary, "/", User/binary, "/",
             Session/binary>>,
    LifecyclePath = <<Base/binary, "/lifecycle?model=", ?MODEL/binary>>,
    {401, _, _} = request(State, get, LifecyclePath, [], <<>>),
    {400, _, _} = request(
                    State, get, <<Base/binary, "/lifecycle">>, auth(), <<>>),
    {400, _, _} = request(
                    State, get,
                    <<LifecyclePath/binary, "&unknown=value">>, auth(), <<>>),
    {200, _, Body} = request(State, get, LifecyclePath, auth(), <<>>),
    Lifecycle = decode(Body),
    Compaction = maps:get(<<"compaction">>, Lifecycle),
    ?assertEqual(<<"checkpointed">>, maps:get(<<"status">>, Compaction)),
    PublicCheckpoint = maps:get(<<"checkpoint">>, Compaction),
    ?assertEqual(<<"context_compaction_checkpoint">>,
                 maps:get(<<"kind">>, PublicCheckpoint)),
    ?assertEqual(false, maps:is_key(<<"summary">>, PublicCheckpoint)),
    ?assertEqual(false,
                 maps:is_key(<<"provider_resource">>, PublicCheckpoint)),
    Cache = maps:get(<<"cache">>, Lifecycle),
    ?assertEqual(true, maps:get(<<"configured">>, Cache)),
    ?assertEqual(<<"active">>, maps:get(<<"status">>, Cache)),
    ?assertEqual(1, maps:get(<<"entries">>, Cache)),
    Fingerprint = maps:get(<<"scope_fingerprint">>, Cache),
    ?assertEqual(64, byte_size(Fingerprint)),
    assert_absent(
      Body,
      [<<"compaction-summary-content-must-not-appear">>,
       <<"checkpoint-summary-must-not-appear">>,
       <<"checkpoint-provider-resource-must-not-appear">>,
       <<"cache-prefix-must-not-appear">>,
       <<"provider-cache-resource-">>, <<"#Pid">>, <<"api_key">>]),
    OtherModelPath = <<Base/binary,
                       "/lifecycle?model=gemini-other-model">>,
    {200, _, OtherModelBody} = request(
                                State, get, OtherModelPath, auth(), <<>>),
    ?assertEqual(<<"empty">>,
                 maps:get(<<"status">>,
                          maps:get(<<"cache">>, decode(OtherModelBody)))),
    InvalidatePath = <<Base/binary, "/cache/invalidate">>,
    Confirm = #{<<"app_name">> => App, <<"user_id">> => User,
                <<"session_id">> => Session, <<"model">> => ?MODEL,
                <<"scope_fingerprint">> => Fingerprint},
    WrongPayload = jsx:encode(
                     #{<<"model">> => ?MODEL,
                       <<"confirm">> => Confirm#{<<"user_id">> => <<"wrong">>}}),
    {400, _, _} = request(State, post, InvalidatePath, json_auth(),
                          WrongPayload),
    {200, _, StillActiveBody} = request(
                                  State, get, LifecyclePath, auth(), <<>>),
    ?assertEqual(1, maps:get(<<"entries">>,
                             maps:get(<<"cache">>,
                                      decode(StillActiveBody)))),
    Payload = jsx:encode(
                #{<<"model">> => ?MODEL, <<"confirm">> => Confirm}),
    Oversized = binary:copy(<<"x">>, 17000),
    {413, _, _} = request(
                    State, post, InvalidatePath, json_auth(), Oversized),
    {200, _, InvalidatedBody} = request(
                                  State, post, InvalidatePath, json_auth(),
                                  Payload),
    Invalidated = maps:get(<<"cache">>, decode(InvalidatedBody)),
    ?assertEqual(<<"invalidated">>, maps:get(<<"status">>, Invalidated)),
    ?assertEqual(1, maps:get(<<"entries">>, Invalidated)),
    {200, _, EmptyBody} = request(State, get, LifecyclePath, auth(), <<>>),
    ?assertEqual(<<"empty">>,
                 maps:get(<<"status">>,
                          maps:get(<<"cache">>, decode(EmptyBody)))),
    ?assertMatch(
       {ok, _},
       adk_context_cache:resolve(
         maps:get(cache_pid, State), maps:get(other_cache_lease, State))).

runner_options_compatibility_case(State) ->
    ArtifactRef = {adk_artifact_ets, maps:get(artifact_pid, State)},
    MemoryRef = {adk_memory_ets, maps:get(memory_pid, State)},
    Config = #{auth_token => ?TOKEN,
               session_service => erlang_adk_session,
               runner_options => #{artifact_svc => ArtifactRef,
                                   memory_svc => MemoryRef},
               run_options => #{}, max_resource_results => 10},
    {ok, _} = cowboy:start_clear(
                ?FALLBACK_LISTENER,
                [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    FallbackState = State#{port => ranch:get_port(?FALLBACK_LISTENER)},
    try
        {200, _, DiagnosticBody} = request(
                                     FallbackState, get,
                                     <<"/dev/v1/diagnostics">>, auth(), <<>>),
        Resources = maps:get(<<"resources">>, decode(DiagnosticBody)),
        ?assertEqual(<<"runner_options">>,
                     maps:get(<<"artifact">>, Resources)),
        {App, User, Session} = scope(State),
        ArtifactPath = <<"/dev/v1/artifacts/", App/binary, "/",
                         User/binary, "/", Session/binary, "?limit=10">>,
        {200, _, _} = request(
                        FallbackState, get, ArtifactPath, auth(), <<>>),
        LifecyclePath = <<"/dev/v1/context/", App/binary, "/",
                          User/binary, "/", Session/binary, "/lifecycle">>,
        {200, _, LifecycleBody} = request(
                                      FallbackState, get, LifecyclePath,
                                      auth(), <<>>),
        ?assertEqual(false,
                     maps:get(<<"configured">>,
                              maps:get(<<"cache">>,
                                       decode(LifecycleBody))))
    after
        _ = cowboy:stop_listener(?FALLBACK_LISTENER)
    end.

artifact_case(State) ->
    {App, User, Session} = scope(State),
    Base = <<"/dev/v1/artifacts/", App/binary, "/", User/binary, "/",
             Session/binary>>,
    {200, _, NamesBody} = request(
                            State, get, <<Base/binary, "?limit=1">>,
                            auth(), <<>>),
    Names = decode(NamesBody),
    ?assertEqual(1, length(maps:get(<<"names">>, Names))),
    ?assertNotEqual(null, maps:get(<<"next_cursor">>, Names)),
    {400, _, _} = request(
                    State, get, <<Base/binary, "?limit=999">>, auth(), <<>>),
    VersionPath = <<Base/binary, "/versions?name=report.txt&limit=10">>,
    {200, _, VersionsBody} = request(
                               State, get, VersionPath, auth(), <<>>),
    [Version] = maps:get(<<"versions">>, decode(VersionsBody)),
    ?assertEqual(true, maps:get(<<"metadata_present">>, Version)),
    assert_absent(VersionsBody,
                  [<<"artifact-bytes-must-not-appear">>,
                   <<"artifact-secret-must-not-appear">>]),
    ?assertEqual(false, maps:is_key(<<"data">>, Version)),
    ?assertEqual(false, maps:is_key(<<"metadata">>, Version)),
    Selector = <<"latest">>,
    WrongPayload = jsx:encode(
                     #{<<"name">> => <<"report.txt">>,
                       <<"selector">> => Selector,
                       <<"confirm">> => #{}}),
    JsonHeaders = json_auth(),
    {400, _, _} = request(
                    State, post, <<Base/binary, "/delete">>,
                    JsonHeaders, WrongPayload),
    Confirm = #{<<"app_name">> => App, <<"user_id">> => User,
                <<"session_id">> => Session, <<"name">> => <<"report.txt">>,
                <<"selector">> => Selector},
    Payload = jsx:encode(#{<<"name">> => <<"report.txt">>,
                           <<"selector">> => Selector,
                           <<"confirm">> => Confirm}),
    {200, _, DeletedBody} = request(
                              State, post, <<Base/binary, "/delete">>,
                              JsonHeaders, Payload),
    ?assertEqual(true, maps:get(<<"deleted">>, decode(DeletedBody))).

memory_case(State) ->
    {App, User, _Session} = scope(State),
    Base = <<"/dev/v1/memory/", App/binary, "/", User/binary>>,
    {200, _, StatusBody} = request(State, get, Base, auth(), <<>>),
    Capabilities = maps:get(<<"capabilities">>, decode(StatusBody)),
    ?assertEqual(2, maps:get(<<"contract_version">>, Capabilities)),
    Search = jsx:encode(#{<<"query">> => <<"lightweight process">>,
                          <<"limit">> => 1}),
    {200, _, SearchBody} = request(
                            State, post, <<Base/binary, "/search">>,
                            json_auth(), Search),
    [Hit] = maps:get(<<"hits">>, decode(SearchBody)),
    ?assertEqual(<<"lightweight process supervision">>,
                 maps:get(<<"content">>, Hit)),
    assert_absent(SearchBody,
                  [<<"memory-secret-must-not-appear">>, <<"metadata">>]),
    OtherPath = <<"/dev/v1/memory/", App/binary, "/other-user">>,
    {503, _, _} = request(State, get, OtherPath, auth(), <<>>),
    Id = maps:get(memory_one, State),
    Target = <<"entry">>,
    Confirm = #{<<"app_name">> => App, <<"user_id">> => User,
                <<"target">> => Target, <<"identifier">> => Id},
    Wrong = jsx:encode(#{<<"target">> => Target, <<"id">> => Id,
                         <<"confirm">> => Confirm#{<<"user_id">> =>
                                                       <<"wrong">>}}),
    {400, _, _} = request(
                    State, post, <<Base/binary, "/erase">>,
                    json_auth(), Wrong),
    Correct = jsx:encode(#{<<"target">> => Target, <<"id">> => Id,
                           <<"confirm">> => Confirm}),
    {200, _, ErasedBody} = request(
                            State, post, <<Base/binary, "/erase">>,
                            json_auth(), Correct),
    ?assertEqual(true, maps:get(<<"deleted">>, decode(ErasedBody))).

resource_scope_mismatch_fails_closed(State) ->
    {App, User, Session} = scope(State),
    WrongArtifactScope =
        {session, App, <<"other-user">>, <<"other-session">>},
    WrongMemoryScope = {user, App, <<"other-user">>},
    Probe = {adk_dev_v05_resource_provider,
             #{artifact_scope => WrongArtifactScope,
               memory_scope => WrongMemoryScope}},
    ProviderConfig = #{app => App, user => User, session => Session,
                       artifact => Probe, memory => Probe},
    Config = #{auth_token => ?TOKEN,
               resource_provider =>
                   {adk_dev_v05_resource_provider, ProviderConfig},
               max_resource_results => 10,
               diagnostic_timeout_ms => 2000},
    {ok, _} = cowboy:start_clear(
                ?SCOPE_MISMATCH_LISTENER,
                [{ip, {127, 0, 0, 1}}, {port, 0}],
                #{env => #{dispatch => adk_dev_router:compile(Config)}}),
    ScopeState = State#{port => ranch:get_port(?SCOPE_MISMATCH_LISTENER)},
    try
        ArtifactNamesPath = <<"/dev/v1/artifacts/", App/binary, "/",
                              User/binary, "/", Session/binary>>,
        {503, _, _} = request(
                        ScopeState, get, ArtifactNamesPath, auth(), <<>>),
        ArtifactPath = <<"/dev/v1/artifacts/", App/binary, "/",
                         User/binary, "/", Session/binary,
                         "/versions?name=leaked.txt&limit=10">>,
        {503, _, _} = request(
                        ScopeState, get, ArtifactPath, auth(), <<>>),
        MemoryPath = <<"/dev/v1/memory/", App/binary, "/",
                       User/binary, "/search">>,
        Search = jsx:encode(#{<<"query">> => <<"leaked">>,
                              <<"limit">> => 1}),
        {503, _, _} = request(
                        ScopeState, post, MemoryPath, json_auth(), Search)
    after
        _ = cowboy:stop_listener(?SCOPE_MISMATCH_LISTENER)
    end.

cli_case(State) ->
    OldToken = os:getenv("ERLANG_ADK_DEV_TOKEN"),
    Base = "http://127.0.0.1:" ++ integer_to_list(maps:get(port, State)),
    {App, User, Session} = scope(State),
    AppS = binary_to_list(App),
    UserS = binary_to_list(User),
    SessionS = binary_to_list(Session),
    try
        true = os:putenv("ERLANG_ADK_DEV_TOKEN", binary_to_list(?TOKEN)),
        {ok, _} = adk_cli:command(
                    ["inspect", "diagnostics", "--url", Base]),
        {ok, Context} = adk_cli:command(
                          ["inspect", "context", AppS, UserS, SessionS,
                           "--url", Base]),
        ?assert(maps:is_key(<<"context">>, Context)),
        {ok, Lifecycle} = adk_cli:command(
                            ["inspect", "context-lifecycle", AppS, UserS,
                             SessionS, "--model", binary_to_list(?MODEL),
                             "--url", Base]),
        LifecycleCache = maps:get(<<"cache">>, Lifecycle),
        CacheFingerprint = maps:get(
                             <<"scope_fingerprint">>, LifecycleCache),
        CacheConfirm = jsx:encode(
                         #{<<"app_name">> => App,
                           <<"user_id">> => User,
                           <<"session_id">> => Session,
                           <<"model">> => ?MODEL,
                           <<"scope_fingerprint">> => CacheFingerprint}),
        ?assertEqual(
           {error, confirmation_does_not_match_target},
           adk_cli:command(
             ["context-cache", "invalidate", AppS, UserS, SessionS,
              "--model", binary_to_list(?MODEL),
              "--confirm-json", "{}", "--url", Base])),
        {ok, CacheInvalidated} = adk_cli:command(
                                   ["context-cache", "invalidate", AppS,
                                    UserS, SessionS, "--model",
                                    binary_to_list(?MODEL),
                                    "--confirm-json",
                                    binary_to_list(CacheConfirm),
                                    "--url", Base]),
        ?assertEqual(
           <<"invalidated">>,
           maps:get(<<"status">>,
                    maps:get(<<"cache">>, CacheInvalidated))),
        {ok, _} = adk_cli:command(
                    ["inspect", "artifacts", AppS, UserS, SessionS,
                     "--limit", "10", "--url", Base]),
        {ok, _} = adk_cli:command(
                    ["inspect", "artifact", AppS, UserS, SessionS,
                     "--name", "cli-delete.txt", "--url", Base]),
        {ok, _} = adk_cli:command(
                    ["inspect", "memory", AppS, UserS, "--url", Base]),
        {ok, _} = adk_cli:command(
                    ["memory", "search", AppS, UserS,
                     "--query", "mailbox", "--limit", "5",
                     "--url", Base]),
        ArtifactConfirm = jsx:encode(
                            #{<<"app_name">> => App,
                              <<"user_id">> => User,
                              <<"session_id">> => Session,
                              <<"name">> => <<"cli-delete.txt">>,
                              <<"selector">> => <<"all">>}),
        ?assertEqual(
           {error, confirmation_does_not_match_target},
           adk_cli:command(
             ["artifact", "delete", AppS, UserS, SessionS,
              "cli-delete.txt", "all", "--confirm-json", "{}",
              "--url", Base])),
        {ok, Deleted} = adk_cli:command(
                          ["artifact", "delete", AppS, UserS, SessionS,
                           "cli-delete.txt", "all", "--confirm-json",
                           binary_to_list(ArtifactConfirm), "--url", Base]),
        ?assertEqual(true, maps:get(<<"deleted">>, Deleted)),
        UserConfirm = jsx:encode(
                        #{<<"app_name">> => App, <<"user_id">> => User,
                          <<"target">> => <<"user">>,
                          <<"identifier">> => User}),
        {ok, Erased} = adk_cli:command(
                         ["memory", "erase", AppS, UserS, "user",
                          "--confirm-json", binary_to_list(UserConfirm),
                          "--url", Base]),
        ?assertEqual(true, maps:get(<<"deleted">>, Erased))
    after
        restore_env("ERLANG_ADK_DEV_TOKEN", OldToken)
    end.

scope(State) ->
    {maps:get(app, State), maps:get(user, State), maps:get(session, State)}.

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

auth() -> [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}].

json_auth() -> [{<<"content-type">>, <<"application/json">>} | auth()].

decode(Body) -> jsx:decode(Body, [return_maps]).

assert_absent(Body, Values) ->
    lists:foreach(
      fun(Value) -> ?assertEqual(nomatch, binary:match(Body, Value)) end,
      Values).

unique(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.

cache_policy() ->
    #{context_version => 1, selection => <<"bounded">>}.

restore_env(Name, false) -> true = os:unsetenv(Name);
restore_env(Name, Value) -> true = os:putenv(Name, Value).
