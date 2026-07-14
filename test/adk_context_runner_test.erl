-module(adk_context_runner_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"context-runner-app">>).
-define(USER, <<"context-runner-user">>).

context_runner_test_() ->
    {setup,
     fun() ->
         {ok, _} = application:ensure_all_started(erlang_adk),
         erlang_adk_session:init(),
         ok
     end,
     [fun artifact_attachment_is_ephemeral_and_effect_is_durable/0,
      fun memory_v2_preload_is_exactly_scoped/0,
      fun model_selected_memory_load_is_exactly_scoped/0,
      fun memory_v2_ingestion_is_async_and_idempotent/0,
      fun automatic_compaction_replaces_exact_session_prefix/0,
      fun context_cache_options_are_strictly_validated/0,
      fun context_cache_scope_and_handle_are_provider_private/0]}.

artifact_attachment_is_ephemeral_and_effect_is_durable() ->
    SessionId = unique(<<"artifact-session">>),
    AgentName = unique(<<"ArtifactAttachmentAgent">>),
    Scope = {session, ?APP, ?USER, SessionId},
    Secret = <<"artifact-secret-bytes">>,
    {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
    {ok, Meta} = adk_artifact_ets:put(
                   ArtifactPid, Scope, <<"diagram.bin">>, Secret,
                   #{mime_type => <<"application/octet-stream">>}),
    {ok, Agent} = erlang_adk:spawn_agent(
                    AgentName,
                    #{provider => adk_llm_probe,
                      mode => tool_call,
                      call_name => <<"load_artifacts">>,
                      call_args =>
                          #{<<"artifacts">> =>
                                [#{<<"name">> => <<"diagram.bin">>,
                                   <<"version">> =>
                                       maps:get(version, Meta)}]},
                      response => <<"attachment inspected">>,
                      test_pid => self()},
                    [adk_load_artifacts_tool]),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{artifact_svc => {adk_artifact_ets, ArtifactPid},
                 context_policy =>
                     #{max_bytes => 1048576, overflow => error}}),
    try
        ?assertEqual(
           {ok, <<"attachment inspected">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"inspect artifact">>)),
        [_First, Second] = receive_probe_histories(2, []),
        AttachmentContents =
            [Content || #{role := user, content := Content} <- Second,
                        is_map(Content),
                        maps:is_key(<<"schema_version">>, Content)],
        ?assertMatch([_], AttachmentContents),
        [AttachmentContent] = AttachmentContents,
        Parts = adk_content:parts(AttachmentContent),
        ?assertEqual([<<"text">>, <<"inline_data">>],
                     [maps:get(<<"type">>, Part) || Part <- Parts]),
        [_, Inline] = Parts,
        ?assertEqual(Secret, base64:decode(maps:get(<<"data">>, Inline))),

        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        [ToolEvent] = [Event || Event = #adk_event{author = <<"tool">>}
                                   <- Events],
        [Effect] = maps:get(<<"context_effects">>,
                            ToolEvent#adk_event.actions),
        ?assertEqual(<<"artifact_attachment">>, maps:get(<<"kind">>, Effect)),
        ?assertEqual(maps:get(version, Meta),
                     maps:get(<<"version">>, Effect)),
        ?assertEqual(nomatch, binary:match(term_to_binary(Events), Secret))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = adk_artifact_ets:stop(ArtifactPid),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

memory_v2_preload_is_exactly_scoped() ->
    SessionId = unique(<<"memory-preload">>),
    AgentName = unique(<<"MemoryScopeAgent">>),
    OtherUser = unique(<<"other-user">>),
    {ok, MemoryPid} = adk_memory_ets:start_link(#{}),
    {ok, _} = adk_memory_ets:add_entry(
                MemoryPid, {user, ?APP, ?USER},
                #{content => <<"launch color is teal">>, metadata => #{}}, #{}),
    {ok, _} = adk_memory_ets:add_entry(
                MemoryPid, {user, ?APP, OtherUser},
                #{content => <<"launch color is private-red">>,
                  metadata => #{}}, #{}),
    {ok, Agent} = erlang_adk:spawn_agent(
                    AgentName,
                    #{provider => adk_llm_probe,
                      response => <<"scoped answer">>, test_pid => self()}, []),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{memory_svc => {adk_memory_ets, MemoryPid},
                 memory_retrieval => #{limit => 5, on_error => fail}}),
    try
        ?assertEqual({ok, <<"scoped answer">>},
                     adk_runner:run(
                       Runner, ?USER, SessionId, <<"launch color">>)),
        [History] = receive_probe_histories(1, []),
        [System] = [Content || #{role := system, content := Content}
                                  <- History],
        ?assert(binary:match(System, <<"launch color is teal">>) =/= nomatch),
        ?assertEqual(nomatch, binary:match(System, <<"private-red">>))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = adk_memory_ets:stop(MemoryPid),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

model_selected_memory_load_is_exactly_scoped() ->
    SessionId = unique(<<"memory-tool">>),
    AgentName = unique(<<"MemoryToolAgent">>),
    OtherUser = unique(<<"memory-tool-other-user">>),
    Query = <<"shared-query">>,
    OwnedContent = <<"shared-query belongs only to the active user">>,
    OtherSecret = <<"shared-query cross-user-secret-must-not-escape">>,
    {ok, MemoryPid} = adk_memory_ets:start_link(#{}),
    {ok, _} = adk_memory_ets:add_entry(
                MemoryPid, {user, ?APP, ?USER},
                #{content => OwnedContent, metadata => #{}}, #{}),
    {ok, _} = adk_memory_ets:add_entry(
                MemoryPid, {user, ?APP, OtherUser},
                #{content => OtherSecret, metadata => #{}}, #{}),
    {ok, Agent} = erlang_adk:spawn_agent(
                    AgentName,
                    #{provider => adk_llm_probe,
                      mode => tool_call,
                      call_name => <<"load_memory">>,
                      call_args => #{<<"query">> => Query,
                                     <<"limit">> => 5},
                      response => <<"memory tool complete">>,
                      test_pid => self()},
                    [adk_load_memory_tool]),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{memory_svc => {adk_memory_ets, MemoryPid}}),
    try
        ?assertEqual(
           {ok, <<"memory tool complete">>},
           adk_runner:run(
             Runner, ?USER, SessionId, <<"select relevant memory">>)),
        [_First, Second] = receive_probe_histories(2, []),
        [ToolContent] = [Content || #{role := tool, content := Content}
                                      <- Second],
        ToolResult = load_memory_tool_result(ToolContent),
        ?assertEqual(true, maps:get(<<"success">>, ToolResult)),
        MemoryResult = maps:get(<<"result">>, ToolResult),
        ?assertEqual(true, maps:get(<<"success">>, MemoryResult)),
        ?assertEqual(true,
                     maps:get(<<"untrusted_reference_data">>,
                              MemoryResult)),
        Hits = maps:get(<<"hits">>, MemoryResult),
        ?assertEqual(
           [OwnedContent],
           [maps:get(<<"content">>, Hit) || Hit <- Hits]),
        ?assertNot(contains_exact(OtherSecret, Second)),

        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        ?assert(contains_exact(OwnedContent, Events)),
        ?assertNot(contains_exact(OtherSecret, Events))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = adk_memory_ets:stop(MemoryPid),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

load_memory_tool_result(
  {tool_response, <<"load_memory">>, Result}) -> Result;
load_memory_tool_result(
  {tool_response, <<"load_memory">>, Result, _Signature}) -> Result;
load_memory_tool_result(
  {tool_response, <<"load_memory">>, Result, _Signature, _CallId}) ->
    Result.

memory_v2_ingestion_is_async_and_idempotent() ->
    SessionId = unique(<<"memory-ingest">>),
    AgentName = unique(<<"MemoryIngestAgent">>),
    Scope = {user, ?APP, ?USER},
    {ok, MemoryPid} = adk_memory_ets:start_link(#{}),
    {ok, Agent} = erlang_adk:spawn_agent(
                    AgentName,
                    #{provider => adk_llm_probe,
                      response => <<"remembered response">>}, []),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{memory_svc => {adk_memory_ets, MemoryPid},
                 memory_ingestion => on_success}),
    try
        ?assertEqual({ok, <<"remembered response">>},
                     adk_runner:run(
                       Runner, ?USER, SessionId, <<"remember this fact">>)),
        Hits = await_memory(MemoryPid, Scope, <<"remember fact">>, 50),
        ?assert(length(Hits) >= 1),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        {ok, First} = adk_memory_ets:add_events(
                        MemoryPid, Scope, SessionId, Events, #{}),
        ?assertEqual(0, maps:get(added, First)),
        ?assert(maps:get(duplicates, First) >= 1)
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = adk_memory_ets:stop(MemoryPid),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

automatic_compaction_replaces_exact_session_prefix() ->
    SessionId = unique(<<"context-compaction">>),
    AgentName = unique(<<"ContextCompactionAgent">>),
    {ok, _} = erlang_adk_session:create_session(
                ?APP, ?USER, #{session_id => SessionId}),
    Old1 = adk_event:new(<<"user">>, <<"old context one">>),
    Old2 = adk_event:new(<<"agent">>, <<"old context two">>),
    Old3 = adk_event:new(<<"user">>, <<"recent context">>),
    [ok = erlang_adk_session:add_event(
            ?APP, ?USER, SessionId, Event)
     || Event <- [Old1, Old2, Old3]],
    {ok, Agent} = erlang_adk:spawn_agent(
                    AgentName,
                    #{provider => adk_llm_probe,
                      response => <<"compacted answer">>,
                      test_pid => self()}, []),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{context_compaction =>
                     #{compactor => adk_context_lifecycle_test_compactor,
                       event_threshold => 4,
                       retain_recent_exchanges => 1}}),
    try
        ?assertEqual(
           {ok, <<"compacted answer">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"current input">>)),
        [History] = receive_probe_histories(1, []),
        ?assert(lists:any(
                  fun(#{content := <<"Bounded summary of older context.">>}) ->
                          true;
                     (_) -> false
                  end, History)),
        ?assertNot(lists:any(
                     fun(#{content := <<"old context one">>}) -> true;
                        (#{content := <<"old context two">>}) -> true;
                        (_) -> false
                     end, History)),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        [Summary] = [Event || Event = #adk_event{actions = Actions}
                                  <- Events,
                             maps:is_key(
                               <<"context_compaction_checkpoint">>, Actions)],
        ?assertEqual(<<"Bounded summary of older context.">>,
                     Summary#adk_event.content),
        ?assertNot(lists:member(Old1, Events)),
        ?assertNot(lists:member(Old2, Events))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

context_cache_options_are_strictly_validated() ->
    {ok, Cache} = adk_context_cache:start_link(#{}),
    Valid = #{cache => Cache,
              provider => adk_context_cache_fake_provider,
              ttl_ms => 60000,
              policy => #{}},
    try
        ?assertError(
           {invalid_context_cache, {unknown_keys, [unexpected]}},
           adk_runner:new(
             self(), ?APP, erlang_adk_session,
             #{context_cache => Valid#{unexpected => true}})),
        ?assertError(
           {invalid_context_cache, cache},
           adk_runner:new(
             self(), ?APP, erlang_adk_session,
             #{context_cache => Valid#{cache => not_a_pid}})),
        ?assertError(
           {invalid_context_cache, provider},
           adk_runner:new(
             self(), ?APP, erlang_adk_session,
             #{context_cache => Valid#{provider => <<"not-a-module">>}})),
        ?assertError(
           {invalid_context_cache, ttl_ms},
           adk_runner:new(
             self(), ?APP, erlang_adk_session,
             #{context_cache => Valid#{ttl_ms => 0}})),
        ?assertError(
           {invalid_context_cache, policy},
           adk_runner:new(
             self(), ?APP, erlang_adk_session,
             #{context_cache => Valid#{policy => #{owner => self()}}}))
    after
        adk_context_cache:stop(Cache)
    end.

context_cache_scope_and_handle_are_provider_private() ->
    SessionId = unique(<<"context-cache">>),
    AgentName = unique(<<"ContextCacheAgent">>),
    Model = <<"gemini-3.1-flash-lite">>,
    PolicyInput = #{context_version => 2,
                    prefix_mode => stable},
    Policy = #{<<"context_version">> => 2,
               <<"prefix_mode">> => <<"stable">>},
    ServiceTimeout = 5000,
    TtlMs = 60000,
    {ok, Cache} = adk_context_cache:start_link(#{}),
    ok = adk_llm_context_cache_probe:set_callback_target(self()),
    {ok, Agent} = erlang_adk:spawn_agent(
                    AgentName,
                    #{provider => adk_llm_context_cache_probe,
                      model => Model,
                      callbacks => [adk_llm_context_cache_probe],
                      response => <<"cache-scoped response">>,
                      test_pid => self()}, []),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{service_timeout => ServiceTimeout,
                 context_cache =>
                     #{cache => Cache,
                       provider => adk_context_cache_gemini,
                       ttl_ms => TtlMs,
                       policy => PolicyInput}}),
    Before = erlang:monotonic_time(millisecond),
    try
        ?assertEqual(
           {ok, <<"cache-scoped response">>},
           adk_runner:run(
             Runner, ?USER, SessionId, <<"exercise context cache">>)),
        After = erlang:monotonic_time(millisecond),
        ProviderConfig = receive_provider_config(),
        CallbackConfig = receive_callback_config(),

        CacheConfig = maps:get(context_cache, ProviderConfig),
        ?assertEqual(
           [cache, deadline_ms, provider, scope, ttl_ms],
           lists:sort(maps:keys(CacheConfig))),
        ?assertEqual(Cache, maps:get(cache, CacheConfig)),
        ?assertEqual(adk_context_cache_gemini,
                     maps:get(provider, CacheConfig)),
        ?assertEqual(TtlMs, maps:get(ttl_ms, CacheConfig)),
        ?assertEqual(
           #{app => ?APP,
             user => ?USER,
             model => Model,
             policy => Policy},
           maps:get(scope, CacheConfig)),
        Deadline = maps:get(deadline_ms, CacheConfig),
        ?assert(is_integer(Deadline)),
        ?assert(Deadline > Before),
        ?assert(Deadline > After),
        ?assert(Deadline =< After + ServiceTimeout),
        GeminiConfig = (maps:without(
                          [response, test_pid], ProviderConfig))#{
                         provider => adk_llm_gemini,
                         api_key => <<"unit-test-key">>},
        ?assertEqual(ok, adk_llm_gemini:validate_config(GeminiConfig)),

        ?assertNot(maps:is_key(context_cache, CallbackConfig)),
        ?assertNot(contains_exact(Cache, CallbackConfig)),
        ?assertNot(contains_pid(CallbackConfig)),

        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        ?assertNot(contains_map_key(context_cache, Events)),
        ?assertNot(contains_map_key(<<"context_cache">>, Events)),
        ?assertNot(contains_exact(Cache, Events)),
        ?assertNot(contains_pid(Events))
    after
        ok = adk_llm_context_cache_probe:clear_callback_target(),
        _ = catch erlang_adk:stop_agent(Agent),
        _ = catch adk_context_cache:stop(Cache),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

receive_provider_config() ->
    receive
        {context_cache_provider_config, Config, _History, _Tools} -> Config
    after 2000 ->
        error(missing_context_cache_provider_config)
    end.

receive_callback_config() ->
    receive
        {context_cache_callback_config, Config} -> Config
    after 2000 ->
        error(missing_context_cache_callback_config)
    end.

contains_exact(Expected, Expected) -> true;
contains_exact(Expected, Map) when is_map(Map) ->
    lists:any(fun(Value) -> contains_exact(Expected, Value) end,
              maps:values(Map));
contains_exact(Expected, Tuple) when is_tuple(Tuple) ->
    contains_exact(Expected, tuple_to_list(Tuple));
contains_exact(Expected, List) when is_list(List) ->
    lists:any(fun(Value) -> contains_exact(Expected, Value) end, List);
contains_exact(_Expected, _Value) -> false.

contains_pid(Pid) when is_pid(Pid) -> true;
contains_pid(Map) when is_map(Map) ->
    lists:any(fun contains_pid/1, maps:values(Map));
contains_pid(Tuple) when is_tuple(Tuple) ->
    contains_pid(tuple_to_list(Tuple));
contains_pid(List) when is_list(List) ->
    lists:any(fun contains_pid/1, List);
contains_pid(_Value) -> false.

contains_map_key(Key, Map) when is_map(Map) ->
    maps:is_key(Key, Map) orelse
        lists:any(fun(Value) -> contains_map_key(Key, Value) end,
                  maps:values(Map));
contains_map_key(Key, Tuple) when is_tuple(Tuple) ->
    contains_map_key(Key, tuple_to_list(Tuple));
contains_map_key(Key, List) when is_list(List) ->
    lists:any(fun(Value) -> contains_map_key(Key, Value) end, List);
contains_map_key(_Key, _Value) -> false.

receive_probe_histories(0, Acc) -> lists:reverse(Acc);
receive_probe_histories(Count, Acc) ->
    receive
        {probe_generate, History, _Tools} ->
            receive_probe_histories(Count - 1, [History | Acc])
    after 2000 ->
        error({missing_probe_history, Count})
    end.

await_memory(_Pid, _Scope, _Query, 0) -> [];
await_memory(Pid, Scope, Query, Attempts) ->
    case adk_memory_ets:search(Pid, Scope, Query,
                               #{filter => #{}, limit => 10}) of
        {ok, []} ->
            timer:sleep(10),
            await_memory(Pid, Scope, Query, Attempts - 1);
        {ok, Hits} -> Hits
    end.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "_", Suffix/binary>>.
