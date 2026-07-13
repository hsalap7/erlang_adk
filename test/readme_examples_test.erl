-module(readme_examples_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

readme_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun example_modules_compile_and_load/0,
        fun direct_agent_and_provider_error/0,
        fun correlated_async_delegation/0,
        fun sequential_parallel_and_loop/0,
        fun sub_agent_and_agent_as_tool/0,
        fun bounded_graph_workflow/0,
        fun sync_and_async_runner/0,
        fun session_scopes_and_temp_state/0,
        fun callbacks_and_telemetry/0,
        fun deterministic_streaming/0,
        fun mcp_stdio_fixture/0,
        fun lightweight_evaluation/0,
        fun deterministic_retry/0,
        fun standalone_memory/0,
        fun dedicated_suite_mapping/0
    ]}.

setup() ->
    {ok, _StartedApps} = application:ensure_all_started(erlang_adk),
    Modules = [readme_weather_tool, readme_audit_callback],
    lists:foreach(fun compile_and_load_example/1, Modules),
    Modules.

cleanup(Modules) ->
    lists:foreach(
        fun(Module) ->
            _ = code:purge(Module),
            _ = code:delete(Module)
        end,
        Modules
    ),
    ok.

compile_and_load_example(Module) ->
    Path = filename:absname(
        filename:join("examples", atom_to_list(Module) ++ ".erl")
    ),
    CompileResult = compile:file(
        Path, [binary, return_errors, return_warnings]
    ),
    Binary =
        case CompileResult of
            {ok, Module, Beam} ->
                Beam;
            {ok, Module, Beam, _Warnings} ->
                Beam;
            {error, Errors, Warnings} ->
                erlang:error({example_compile_failed, Module, Errors, Warnings})
        end,
    _ = code:purge(Module),
    _ = code:delete(Module),
    {module, Module} = code:load_binary(Module, Path, Binary),
    ok.

example_modules_compile_and_load() ->
    ?assertMatch(
        #{<<"name">> := <<"get_weather">>},
        readme_weather_tool:schema()
    ),
    ?assertEqual(
        {ok, #{<<"city">> => <<"Tokyo">>, <<"forecast">> => <<"sunny">>}},
        readme_weather_tool:execute(#{<<"city">> => <<"Tokyo">>}, #{})
    ),
    ?assert(
        erlang:function_exported(
            readme_audit_callback, before_model, 3
        )
    ),
    ?assert(
        erlang:function_exported(
            readme_audit_callback, after_model, 2
        )
    ).

direct_agent_and_provider_error() ->
    WeatherName = <<"ReadmeDeterministicWeather">>,
    WeatherConfig = #{
        provider => adk_llm_probe,
        instructions => <<"You are a concise weather assistant.">>,
        response => <<"Tokyo is sunny">>,
        test_pid => self()
    },
    {ok, WeatherPid} = erlang_adk:spawn_agent(
        WeatherName, WeatherConfig, [readme_weather_tool]
    ),
    try
        ?assertEqual(
            {ok, <<"Tokyo is sunny">>},
            erlang_adk:prompt(WeatherPid, <<"What is the weather in Tokyo?">>)
        ),
        {History, ModelTools} = receive_probe_generate(),
        ?assert(
            lists:any(
                fun
                    (
                        #{
                            role := system,
                            content := <<"You are a concise weather assistant.">>
                        }
                    ) ->
                        true;
                    (_) ->
                        false
                end,
                History
            )
        ),
        ?assert(lists:member(readme_weather_tool, ModelTools))
    after
        safe_stop_agent(WeatherPid)
    end,

    ErrorName = <<"ReadmeDeterministicError">>,
    {ok, ErrorPid} = erlang_adk:spawn_agent(
        ErrorName,
        #{
            provider => adk_llm_probe,
            mode => error,
            reason => deterministic_provider_failure
        },
        []
    ),
    try
        ?assertEqual(
            {error, deterministic_provider_failure},
            erlang_adk:prompt(ErrorPid, <<"fail deterministically">>)
        ),
        ?assert(is_process_alive(ErrorPid))
    after
        safe_stop_agent(ErrorPid)
    end.

correlated_async_delegation() ->
    Name = <<"ReadmeCorrelatedDelegate">>,
    {ok, AgentPid} = erlang_adk:spawn_agent(
        Name,
        #{
            provider => adk_llm_probe,
            response => <<"OTP uses supervised processes">>
        },
        []
    ),
    try
        Ref = make_ref(),
        ok = erlang_adk:delegate(
            AgentPid, <<"Summarize OTP.">>, self(), Ref
        ),
        receive
            {agent_response, Ref, AgentPid, {ok, <<"OTP uses supervised processes">>}} ->
                ok;
            {agent_response, Ref, AgentPid, Unexpected} ->
                ?assertEqual(expected_success, Unexpected)
        after 2000 ->
            ?assert(false)
        end
    after
        safe_stop_agent(AgentPid)
    end.

sequential_parallel_and_loop() ->
    {ok, FirstPid} = erlang_adk:spawn_agent(
        <<"ReadmeFirstStage">>,
        #{
            provider => adk_llm_probe,
            response => <<"first-stage">>
        },
        []
    ),
    {ok, SecondPid} = erlang_adk:spawn_agent(
        <<"ReadmeSecondStage">>,
        #{
            provider => adk_llm_probe,
            response => <<"second-stage">>
        },
        []
    ),
    {ok, WriterPid} = erlang_adk:spawn_agent(
        <<"ReadmeLoopWriter">>,
        #{
            provider => adk_llm_probe,
            response => <<"final draft">>
        },
        []
    ),
    {ok, ReviewerPid} = erlang_adk:spawn_agent(
        <<"ReadmeLoopReviewer">>,
        #{
            provider => adk_llm_probe,
            response => <<"APPROVED">>
        },
        []
    ),
    try
        ?assertEqual(
            {ok, <<"second-stage">>},
            erlang_adk:sequential(
                [FirstPid, SecondPid], <<"pipeline input">>
            )
        ),
        ?assertEqual(
            [
                {FirstPid, <<"first-stage">>},
                {SecondPid, <<"second-stage">>}
            ],
            erlang_adk:parallel(
                [FirstPid, SecondPid], <<"parallel input">>, 2000
            )
        ),
        ?assertEqual(
            {ok, <<"final draft">>},
            erlang_adk:loop(
                WriterPid, ReviewerPid, <<"write a draft">>, 3
            )
        )
    after
        stop_agents([FirstPid, SecondPid, WriterPid, ReviewerPid])
    end.

sub_agent_and_agent_as_tool() ->
    SpecialistName = <<"ReadmeSearchSpecialist">>,
    {ok, SpecialistPid} = erlang_adk:spawn_agent(
        SpecialistName,
        #{
            provider => adk_llm_probe,
            response => <<"specialist result">>
        },
        []
    ),
    CoordinatorConfig = #{
        provider => adk_llm_probe,
        mode => sub_agent_call,
        call_name => SpecialistName,
        test_pid => self(),
        sub_agents => #{
            SpecialistName => #{
                pid => SpecialistPid,
                description => <<"Researches Erlang and OTP topics">>
            }
        }
    },
    {ok, CoordinatorPid} = erlang_adk:spawn_agent(
        <<"ReadmeCoordinator">>, CoordinatorConfig, []
    ),
    try
        ?assertEqual(
            {ok, <<"delegation complete">>},
            erlang_adk:prompt(
                CoordinatorPid, <<"Research supervision trees.">>
            )
        ),
        {_FirstHistory, AdvertisedTools} = receive_probe_generate(),
        ?assert(
            lists:any(
                fun
                    (#{<<"name">> := Name}) -> Name =:= SpecialistName;
                    (_) -> false
                end,
                AdvertisedTools
            )
        ),
        {_SecondHistory, _SecondTools} = receive_probe_generate(),

        Schema = adk_agent_tool:schema(
            #{
                name => SpecialistName,
                description => <<"Researches Erlang and OTP topics">>
            }
        ),
        ?assertEqual(SpecialistName, maps:get(<<"name">>, Schema)),
        ?assertEqual(
            {ok, <<"specialist result">>},
            adk_agent_tool:execute(
                SpecialistPid,
                #{<<"prompt">> => <<"Explain rest_for_one.">>},
                #{}
            )
        )
    after
        stop_agents([CoordinatorPid, SpecialistPid])
    end.

bounded_graph_workflow() ->
    Increment = fun(State) ->
        #{<<"count">> => maps:get(<<"count">>, State, 0) + 1}
    end,
    Next = fun(State) ->
        case maps:get(<<"count">>, State) < 3 of
            true -> counter;
            false -> end_node
        end
    end,
    Graph0 = adk_graph:new(),
    Graph1 = adk_graph:add_node(Graph0, counter, Increment),
    Graph2 = adk_graph:add_conditional_edge(Graph1, counter, Next),
    Graph3 = adk_graph:set_entry_point(Graph2, counter),
    {ok, CompiledGraph} = adk_graph:compile(Graph3),
    {ok, FinalState} = adk_graph:run(
        CompiledGraph,
        #{<<"count">> => 0},
        #{max_steps => 10}
    ),
    ?assertEqual(3, maps:get(<<"count">>, FinalState)),
    ?assertEqual(
        {error, {max_steps_exceeded, 2}},
        adk_graph:run(
            CompiledGraph, #{<<"count">> => 0}, #{max_steps => 2}
        )
    ).

sync_and_async_runner() ->
    AppName = unique_binary(<<"readme_runner_app">>),
    UserId = <<"readme-user">>,
    SyncSessionId = <<"sync-session">>,
    AsyncSessionId = <<"async-session">>,
    AgentName = <<"ReadmeRunnerAgent">>,
    {ok, AgentPid} = erlang_adk:spawn_agent(
        AgentName,
        #{
            provider => adk_llm_probe,
            response => <<"runner response">>
        },
        []
    ),
    Runner = adk_runner:new(
        AgentPid,
        AppName,
        erlang_adk_session,
        #{run_timeout => 2000}
    ),
    try
        ?assertEqual(
            {ok, <<"runner response">>},
            adk_runner:run(
                Runner, UserId, SyncSessionId, <<"Hello">>
            )
        ),
        {ok, SyncSession} = erlang_adk_session:get_session(
            AppName, UserId, SyncSessionId
        ),
        ?assertEqual(
            [<<"user">>, AgentName],
            event_authors(maps:get(events, SyncSession))
        ),

        {ok, StreamPid} = adk_runner:run_async(
            Runner,
            UserId,
            AsyncSessionId,
            <<"Explain supervisors.">>
        ),
        try
            {ok, AsyncEvents} = drain_runner(StreamPid, []),
            ?assertEqual(
                [<<"user">>, AgentName],
                event_authors(AsyncEvents)
            ),
            wait_for_exit(StreamPid)
        after
            safe_stop_process(StreamPid)
        end
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(
            AppName, UserId, SyncSessionId
        ),
        _ = erlang_adk_session:delete_session(
            AppName, UserId, AsyncSessionId
        )
    end.

session_scopes_and_temp_state() ->
    AppName = unique_binary(<<"readme_state_app">>),
    UserId = <<"readme-state-user">>,
    SessionId = <<"state-session-1">>,
    FutureSessionId = <<"state-session-2">>,
    {ok, _} = erlang_adk_session:create_session(
        AppName, UserId, #{session_id => SessionId}
    ),
    try
        ok = erlang_adk_session:update_state(
            AppName,
            UserId,
            SessionId,
            #{
                <<"theme">> => <<"local">>,
                <<"user:preferences">> => <<"dark">>,
                <<"app:release">> => <<"0.2.5">>,
                <<"temp:lookup">> => <<"in-flight">>
            }
        ),
        {ok, StoredSession} = erlang_adk_session:get_session(
            AppName, UserId, SessionId
        ),
        StoredState = maps:get(state, StoredSession),
        ?assertEqual(
            <<"dark">>,
            maps:get(<<"user:preferences">>, StoredState)
        ),
        ?assertEqual(
            <<"in-flight">>,
            maps:get(<<"temp:lookup">>, StoredState)
        ),

        {ok, FutureSession} = erlang_adk_session:create_session(
            AppName,
            UserId,
            #{session_id => FutureSessionId}
        ),
        FutureState = maps:get(state, FutureSession),
        ?assertEqual(
            <<"dark">>,
            maps:get(<<"user:preferences">>, FutureState)
        ),
        ?assertEqual(
            <<"0.2.5">>,
            maps:get(<<"app:release">>, FutureState)
        ),
        ?assertEqual(error, maps:find(<<"theme">>, FutureState)),
        ?assertEqual(error, maps:find(<<"temp:lookup">>, FutureState)),

        ok = erlang_adk_session:clear_temp_state(
            AppName, UserId, SessionId
        ),
        {ok, ClearedSession} = erlang_adk_session:get_session(
            AppName, UserId, SessionId
        ),
        ?assertEqual(
            error,
            maps:find(
                <<"temp:lookup">>,
                maps:get(state, ClearedSession)
            )
        ),
        ?assertEqual(
            {error, not_found},
            erlang_adk_session:update_state(
                AppName, UserId, <<"missing-session">>, #{<<"x">> => 1}
            )
        )
    after
        _ = erlang_adk_session:delete_session(
            AppName, UserId, SessionId
        ),
        _ = erlang_adk_session:delete_session(
            AppName, UserId, FutureSessionId
        )
    end.

callbacks_and_telemetry() ->
    Self = self(),
    AgentName = <<"ReadmeCallbackTelemetryAgent">>,
    HandlerId = unique_binary(<<"readme-prompt-handler">>),
    TelemetryHandler = fun(_Event, Measurements, Metadata, _Config) ->
        Self ! {readme_telemetry, Measurements, Metadata}
    end,
    ok = telemetry:attach(
        HandlerId,
        [erlang_adk, agent, prompt, stop],
        TelemetryHandler,
        #{}
    ),
    {ok, AgentPid} = erlang_adk:spawn_agent(
        AgentName,
        #{
            provider => adk_llm_probe,
            response => <<"callback response">>,
            callbacks => [readme_audit_callback],
            callback_pid => Self
        },
        []
    ),
    try
        ?assertEqual(
            {ok, <<"callback response">>},
            erlang_adk:prompt(AgentPid, <<"Say hello.">>)
        ),
        receive
            {before_model, 0} -> ok
        after 1000 -> ?assert(false)
        end,
        receive
            {after_model, {ok, <<"callback response">>}} -> ok
        after 1000 -> ?assert(false)
        end,
        receive
            {readme_telemetry, Measurements, Metadata} ->
                ?assert(maps:get(duration, Measurements) >= 0),
                ?assertEqual(AgentName, maps:get(agent, Metadata))
        after 1000 ->
            ?assert(false)
        end
    after
        _ = telemetry:detach(HandlerId),
        safe_stop_agent(AgentPid)
    end.

deterministic_streaming() ->
    StreamHistory = [
        #{role => system, content => <<"Be concise.">>},
        #{role => user, content => <<"Explain OTP.">>}
    ],
    Self = self(),
    ChunkCallback = fun(Chunk) -> Self ! {readme_stream_chunk, Chunk} end,
    ok = adk_llm:stream(
        #{
            provider => adk_llm_probe,
            response => <<"decoded probe chunk">>
        },
        StreamHistory,
        [],
        ChunkCallback
    ),
    receive
        {readme_stream_chunk, <<"decoded probe chunk">>} -> ok
    after 1000 ->
        ?assert(false)
    end.

mcp_stdio_fixture() ->
    FixtureCommand = unicode:characters_to_binary(
        filename:absname("test/mcp_stdio_fixture.sh")
    ),
    {ok, McpClient} = adk_mcp_client:connect(
        <<"stdio">>, FixtureCommand
    ),
    try
        {ok, [McpTool]} = adk_mcp_client:list_tools(McpClient),
        ?assertEqual(<<"search">>, maps:get(<<"name">>, McpTool)),
        {ok, McpResult} = adk_mcp_client:execute_tool(
            McpClient,
            <<"search">>,
            #{<<"query">> => <<"erlang">>}
        ),
        ?assertEqual(false, maps:get(<<"isError">>, McpResult))
    after
        safe_close_mcp(McpClient)
    end.

lightweight_evaluation() ->
    {ok, EvalPid} = erlang_adk:spawn_agent(
        <<"ReadmeEvalAgent">>,
        #{
            provider => adk_llm_probe,
            response => <<"ERLANG">>
        },
        []
    ),
    try
        Dataset = [
            #{
                input => <<"Reply with exactly: ERLANG">>,
                expected => <<"ERLANG">>,
                metadata => #{case_id => 1}
            }
        ],
        ExactMetric = fun(Expected, Actual) ->
            case unicode:characters_to_binary(Actual) =:= Expected of
                true -> 1.0;
                false -> 0.0
            end
        end,
        {ok, EvalReport} = adk_eval:run(
            EvalPid,
            Dataset,
            ExactMetric,
            #{concurrency => 1, timeout => 2000}
        ),
        ?assertEqual(1.0, maps:get(average_score, EvalReport)),
        [EvalRow] = maps:get(results, EvalReport),
        ?assertEqual(#{case_id => 1}, maps:get(metadata, EvalRow))
    after
        safe_stop_agent(EvalPid)
    end.

deterministic_retry() ->
    AttemptCounter = atomics:new(1, []),
    Flaky = fun() ->
        case atomics:add_get(AttemptCounter, 1, 1) of
            Attempt when Attempt < 3 -> {error, temporary};
            _ -> {ok, recovered}
        end
    end,
    ?assertEqual(
        {ok, recovered},
        adk_retry:execute(
            Flaky,
            #{
                max_attempts => 5,
                initial_delay => 1,
                max_delay => 10,
                backoff_factor => 2.0
            }
        )
    ),
    ?assertEqual(3, atomics:get(AttemptCounter, 1)).

standalone_memory() ->
    {ok, MemoryPid} = adk_memory_ets:init(#{}),
    try
        {ok, MemoryId} = adk_memory_ets:add(
            MemoryPid,
            <<"OTP supervision trees restart children">>,
            #{<<"topic">> => <<"otp">>}
        ),
        {ok, [MemoryHit]} = adk_memory_ets:search(
            MemoryPid,
            <<"supervision">>,
            #{<<"topic">> => <<"otp">>},
            5
        ),
        ?assertEqual(MemoryId, maps:get(id, MemoryHit)),
        ok = adk_memory_ets:delete(MemoryPid, MemoryId),
        ?assertEqual(
            {ok, []},
            adk_memory_ets:search(
                MemoryPid,
                <<"supervision">>,
                #{<<"topic">> => <<"otp">>},
                5
            )
        )
    after
        stop_memory(MemoryPid)
    end.

dedicated_suite_mapping() ->
    %% Live Gemini is deliberately excluded here. adk_llm_gemini_test covers
    %% mock HTTP/SSE payloads, status errors, chunks, signatures, IDs, and TLS
    %% wire configuration; a real call still needs the user's key and network.
    %% adk_hitl_test covers approval pause/resume, correlation, and single claim.
    %% erlang_adk_session_mnesia_test covers the persistent session backend.
    %% erlang_adk_tests covers the project-specific HTTP endpoint, including
    %% its Unicode round trip. Loading these modules keeps this mapping honest.
    DedicatedModules = [
        adk_llm_gemini_test,
        adk_hitl_test,
        erlang_adk_session_mnesia_test,
        erlang_adk_tests
    ],
    lists:foreach(
        fun(Module) ->
            ?assertEqual({module, Module}, code:ensure_loaded(Module))
        end,
        DedicatedModules
    ).

receive_probe_generate() ->
    receive
        {probe_generate, History, Tools} -> {History, Tools}
    after 1000 ->
        erlang:error(probe_generate_timeout)
    end.

drain_runner(StreamPid, Events) ->
    receive
        {adk_event, StreamPid, Event} ->
            drain_runner(StreamPid, [Event | Events]);
        {adk_done, StreamPid} ->
            {ok, lists:reverse(Events)};
        {adk_paused, StreamPid, PauseEvent} ->
            {paused, PauseEvent};
        {adk_error, StreamPid, Reason} ->
            {error, Reason}
    after 2000 ->
        {error, timeout}
    end.

event_authors(Events) ->
    [Event#adk_event.author || Event <- Events].

wait_for_exit(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush]),
        erlang:error({process_did_not_exit, Pid})
    end.

safe_stop_agent(Pid) when is_pid(Pid) ->
    _ = catch erlang_adk:stop_agent(Pid),
    ok.

stop_agents(Pids) ->
    lists:foreach(fun safe_stop_agent/1, lists:reverse(Pids)).

safe_close_mcp(Pid) ->
    _ = catch adk_mcp_client:close(Pid),
    ok.

safe_stop_process(Pid) when is_pid(Pid) ->
    case erlang:is_process_alive(Pid) of
        true ->
            _ = catch exit(Pid, kill),
            ok;
        false ->
            ok
    end.

stop_memory(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    ok = adk_memory_ets:stop(Pid),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush]),
        erlang:error({memory_did_not_stop, Pid})
    end.

unique_binary(Prefix) ->
    Suffix = integer_to_binary(
        erlang:unique_integer([positive, monotonic])
    ),
    <<Prefix/binary, "-", Suffix/binary>>.
