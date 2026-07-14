-module(readme_examples_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

readme_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun example_modules_compile_and_load/0,
        fun provider_capability_contract/0,
        fun multimodal_content_contract/0,
        fun direct_agent_and_provider_error/0,
        fun agent_contracts_and_context_policy/0,
        fun correlated_async_delegation/0,
        fun sequential_parallel_and_loop/0,
        fun explicit_planning_runtime/0,
        fun sub_agent_and_agent_as_tool/0,
        fun bounded_graph_workflow/0,
        fun sync_and_async_runner/0,
        fun supervised_run_api/0,
        fun ambient_background_runtime/0,
        fun tool_confirmation_contract/0,
        fun suspension_and_pkce_contract/0,
        fun runner_provider_streaming/0,
        fun supervised_content_streaming/0,
        fun session_scopes_and_temp_state/0,
        fun session_query_pagination_and_rewind/0,
        fun callbacks_and_telemetry/0,
        fun deterministic_streaming/0,
        fun openapi_toolset_as_agent_tools/0,
        fun mcp_stdio_fixture/0,
        fun mcp_streamable_http_fixture/0,
        fun plugins_observability_and_eval_sets/0,
        fun lightweight_evaluation/0,
        fun deterministic_retry/0,
        fun memory_and_artifacts/0,
        fun dedicated_suite_mapping/0
    ]}.

setup() ->
    {ok, _StartedApps} = application:ensure_all_started(erlang_adk),
    Modules = [readme_weather_tool, readme_release_tool,
               readme_audit_callback,
               readme_policy_plugin, readme_observability_exporter,
               readme_agent_eval_adapter, readme_exact_metric,
               readme_planner, readme_plan_executor],
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
    {ok, ReleaseRequirement} =
        adk_tool_confirmation:module_requirement(
          readme_release_tool,
          #{<<"environment">> => <<"production">>,
            <<"dry_run">> => false}, #{}),
    ?assert(adk_tool_confirmation:is_required(ReleaseRequirement)),
    ?assert(
        erlang:function_exported(
            readme_audit_callback, before_model, 3
        )
    ),
    ?assert(
        erlang:function_exported(
            readme_audit_callback, after_model, 2
        )
    ),
    ?assert(erlang:function_exported(readme_planner, plan, 4)),
    ?assert(erlang:function_exported(readme_plan_executor, execute, 4)).

provider_capability_contract() ->
    {ok, Capabilities} = adk_llm:capabilities(adk_llm_gemini),
    ?assertEqual(true, maps:get(streaming, Capabilities)),
    ?assertEqual(true, maps:get(function_calling, Capabilities)),
    ?assertEqual(true, maps:get(structured_output, Capabilities)),
    ?assertEqual(true, maps:get(multimodal, Capabilities)),
    ?assertEqual(true, maps:get(thinking, Capabilities)),
    ?assertEqual(true, maps:get(safety_settings, Capabilities)),
    ?assertEqual(true, maps:get(google_search_grounding, Capabilities)),
    ?assertEqual([google_search], maps:get(builtin_tools, Capabilities)),
    ?assertEqual(1, maps:get(content_schema_version, Capabilities)),
    ?assertEqual(false, maps:get(live, Capabilities)),
    ?assertEqual(
       ok,
       adk_llm:validate_config(
         #{provider => adk_llm_gemini,
           model => <<"gemini-3.1-flash-lite">>,
           response_mime_type => <<"application/json">>,
           response_schema => #{<<"type">> => <<"object">>},
           safety_settings =>
               [#{category => hate_speech,
                  threshold => block_low_and_above},
                #{category => harassment,
                  threshold => block_only_high}]})),
    ?assertEqual(
       {error, {unknown_gemini_options, [temperatur]}},
       adk_llm:validate_config(
         #{provider => adk_llm_gemini, temperatur => 0.2})).

multimodal_content_contract() ->
    TinyPng = base64:decode(
        <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">>),
    {ok, PromptPart} = adk_content:text(<<"Describe this image briefly.">>),
    {ok, ImagePart} = adk_content:inline_data(<<"image/png">>, TinyPng),
    {ok, FilePart} = adk_content:file_data(
                       <<"application/pdf">>,
                       <<"gs://adk-fixtures/example.pdf">>),
    {ok, MultimodalPrompt} = adk_content:new(
                               [PromptPart, ImagePart, FilePart]),
    {ok, GeminiParts} = adk_llm_gemini_content:encode(
                           MultimodalPrompt, #{}),
    ?assertMatch([#{<<"text">> := _},
                  #{<<"inlineData">> := _},
                  #{<<"fileData">> := _}], GeminiParts),
    {ok, MultimodalPrompt} = adk_llm_gemini_content:decode(
                               GeminiParts, #{}),
    Json = jsx:encode(MultimodalPrompt),
    {ok, MultimodalPrompt} = adk_content:validate(
                               jsx:decode(Json, [return_maps])),
    ?assert(erlang:function_exported(
              adk_llm_gemini, stream_content, 4)),
    ?assertMatch(
       {error, {invalid_content_part, _,
                {unsupported_uri_scheme, <<"file">>}}},
       adk_content:file_data(
         <<"image/png">>, <<"file:///tmp/private.png">>)).

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
        ?assert(lists:any(
                  fun(#{<<"name">> := <<"get_weather">>}) -> true;
                     (_) -> false
                  end, ModelTools))
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

agent_contracts_and_context_policy() ->
    AppName = unique_binary(<<"readme_contract_app">>),
    UserId = <<"readme-contract-user">>,
    SessionId = <<"contract-session">>,
    {ok, _} = erlang_adk_session:create_session(
                AppName, UserId,
                #{session_id => SessionId,
                  state => #{<<"user:name">> => <<"Ada">>}}),
    ok = erlang_adk_session:add_event(
           AppName, UserId, SessionId,
           adk_event:new(
             <<"agent">>, binary:copy(<<"old context ">>, 300))),
    Config = #{
        provider => adk_llm_agent_spec_probe,
        test_pid => self(),
        instructions =>
            <<"Answer {user:name} concisely using the requested JSON shape.">>,
        input_schema => #{
            type => object,
            properties => #{<<"topic">> =>
                                #{type => string, minLength => 1}},
            required => [<<"topic">>],
            additionalProperties => false},
        output_schema => #{
            type => object,
            properties => #{<<"answer">> =>
                                #{type => string, minLength => 1}},
            required => [<<"answer">>],
            additionalProperties => false},
        output_key => <<"user:last_answer">>,
        history_policy => exclude,
        generation_config => #{
            max_output_tokens => 128,
            thinking_config => #{thinking_level => low},
            safety_settings =>
                [#{category => harassment,
                   threshold => block_medium_and_above}]},
        response => <<"{\"answer\":\"OTP\"}">>
    },
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       <<"ReadmeContractAgent">>, Config, []),
    Runner = adk_runner:new(
               AgentPid, AppName, erlang_adk_session,
               #{context_policy => #{max_bytes => 1200,
                                     max_tokens => 300,
                                     overflow => truncate}}),
    try
        Input = jsx:encode(
                  #{<<"topic">> => <<"supervision trees">>}),
        {ok, Response} = adk_runner:run(
                           Runner, UserId, SessionId, Input),
        ?assertEqual(#{<<"answer">> => <<"OTP">>},
                     jsx:decode(Response, [return_maps])),
        receive
            {agent_spec_probe, EffectiveConfig, History, []} ->
                ?assertEqual(128,
                             maps:get(max_tokens, EffectiveConfig)),
                ?assertEqual(#{thinking_level => low},
                             maps:get(thinking_config, EffectiveConfig)),
                ?assertEqual(
                   [#{category => harassment,
                      threshold => block_medium_and_above}],
                   maps:get(safety_settings, EffectiveConfig)),
                ?assertEqual([system, user],
                             [maps:get(role, Message)
                              || Message <- History]),
                [System, Current] = History,
                ?assertEqual(
                   <<"Answer Ada concisely using the requested JSON shape.">>,
                   maps:get(content, System)),
                ?assertEqual(Input, maps:get(content, Current))
        after 1000 ->
            ?assert(false)
        end,
        {ok, Stored} = erlang_adk_session:get_session(
                         AppName, UserId, SessionId),
        ?assertEqual(
           #{<<"answer">> => <<"OTP">>},
           maps:get(<<"user:last_answer">>, maps:get(state, Stored)))
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(
              AppName, UserId, SessionId)
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

explicit_planning_runtime() ->
    Planner = #{module => readme_planner,
                target => undefined,
                config => #{}},
    Executor = #{module => readme_plan_executor,
                 target => undefined,
                 config => #{}},
    Goal = #{<<"task">> => <<"prepare release">>},
    Context = #{<<"invocation_id">> => <<"planning-readme">>},
    {ok, PlanningResult} = erlang_adk:run_planning(
                             Planner, Executor, Goal, Context,
                             #{max_steps => 4,
                               max_replans => 1,
                               timeout_ms => 5000}),
    ?assertEqual(<<"completed">>,
                 maps:get(<<"status">>, PlanningResult)),
    ?assertEqual(1, maps:get(<<"steps_executed">>, PlanningResult)),
    ?assertEqual(
       #{<<"goal">> => Goal,
         <<"invocation_id">> => <<"planning-readme">>},
       maps:get(<<"result">>, PlanningResult)).

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
        global_instruction =>
            <<"You are part of the Erlang documentation team.">>,
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
        #{run_timeout => 2000,
          admission_control => #{overflow => queue,
                                 queue_timeout => 5000},
          runtime_policy =>
              #{id => <<"readme-runner-policy">>,
                agents => #{allow => [AgentName]},
                tools => #{allow => []},
                max_argument_bytes => 32768,
                max_content_bytes => 262144},
          context_policy => #{max_bytes => 32768,
                              max_tokens => 8192,
                              overflow => truncate}}
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

supervised_run_api() ->
    AppName = unique_binary(<<"readme_supervised_run_app">>),
    UserId = <<"readme-run-user">>,
    SessionId = <<"supervised-session">>,
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       <<"ReadmeSupervisedRunAgent">>,
                       #{provider => adk_llm_probe,
                         response => <<"supervised response">>}, []),
    Runner = adk_runner:new(
               AgentPid, AppName, erlang_adk_session,
               #{run_timeout => 2000,
                 max_llm_calls => 4,
                 max_tool_rounds => 2}),
    try
        {ok, RunId} = adk_run:start(
                        Runner, UserId, SessionId, <<"Hello">>,
                        #{retention_ms => 2000,
                          max_buffered_events => 16}),
        ?assertMatch(<<"run-", _/binary>>, RunId),
        ok = adk_run:subscribe(RunId),
        ?assertEqual(
           {completed, <<"supervised response">>},
           collect_supervised_run(RunId, [])),
        {ok, Status} = adk_run:status(RunId),
        ?assertEqual(completed, maps:get(state, Status)),
        ?assertEqual(2, maps:get(event_count, Status))
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(
              AppName, UserId, SessionId)
    end.

ambient_background_runtime() ->
    AppName = unique_binary(<<"readme_ambient_app">>),
    Trigger = unique_binary(<<"readme-inbox-events">>),
    UserId = unique_binary(<<"background-worker">>),
    AgentName = unique_binary(<<"ReadmeAmbientAgent">>),
    Config = #{provider => adk_llm_probe,
               response => <<"ambient response">>,
               test_pid => self()},
    {ok, AgentPid} = erlang_adk:spawn_agent(AgentName, Config, []),
    Runner = adk_runner:new(AgentPid, AppName, erlang_adk_session,
                            #{run_timeout => 2000}),
    Options = #{max_concurrency => 2,
                max_queue => 8,
                event_timeout => 2000,
                retention_ms => 5000,
                max_retained => 16,
                max_event_bytes => 1048576,
                session_policy => #{mode => per_event,
                                    user_id => UserId,
                                    prefix => <<"inbox-">>},
                retry => #{max_attempts => 2,
                           initial_delay => 1,
                           max_delay => 2,
                           backoff_factor => 2.0,
                           attempt_timeout => 1000,
                           max_heap_words => 100000,
                           jitter => none}},
    try
        ok = adk_ambient:register_trigger(Trigger, Runner, Options),
        Delivery = #{payload => <<"Summarize message 42">>,
                     idempotency_key => <<"mailbox:42:v1">>,
                     metadata => #{source => <<"local-queue">>}},
        {ok, AmbientRef} = adk_ambient:submit(Trigger, Delivery),
        {completed, #{run_id := AmbientRunId,
                      output := <<"ambient response">>}} =
            adk_ambient:await(AmbientRef, 2000),
        ?assertMatch(<<"run-", _/binary>>, AmbientRunId),
        {_History, _Tools} = receive_probe_generate(),
        ?assertEqual({ok, AmbientRef, duplicate},
                     adk_ambient:submit(Trigger, Delivery)),
        {ok, #{state := terminal,
               attempts := 1,
               session_id := SessionId}} =
            adk_ambient:status(AmbientRef),

        {ok, SchedulePid} = adk_trigger_schedule:start(
                              Trigger, <<"hourly-inbox-summary">>,
                              3600000,
                              #{payload => <<"Summarize the last hour">>},
                              #{initial_delay_ms => 3600000}),
        {ok, #{type := schedule, interval_ms := 3600000}} =
            adk_trigger_schedule:status(SchedulePid),
        ok = adk_trigger_schedule:stop(SchedulePid),
        ok = adk_ambient:unregister_trigger(Trigger),
        ok = erlang_adk_session:delete_session(
               AppName, UserId, SessionId)
    after
        _ = adk_ambient:unregister_trigger(Trigger),
        safe_stop_agent(AgentPid)
    end.

runner_provider_streaming() ->
    AppName = unique_binary(<<"readme_streaming_runner_app">>),
    UserId = <<"readme-stream-user">>,
    SessionId = <<"streaming-session">>,
    AgentName = unique_binary(<<"ReadmeStreamingRunnerAgent">>),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       AgentName,
                       #{provider => adk_llm_stream_probe,
                         chunks => [<<"light">>, <<"weight">>]}, []),
    Runner = adk_runner:new(
               AgentPid, AppName, erlang_adk_session,
               #{streaming_mode => text,
                 max_stream_output_bytes => 16777216,
                 run_timeout => 2000}),
    try
        {ok, RunId} = adk_run:start(
                        Runner, UserId, SessionId, <<"Explain processes">>,
                        #{retention_ms => 2000,
                          max_buffered_events => 16}),
        ok = adk_run:subscribe(RunId),
        {Events, Outcome} = collect_streaming_run(RunId, []),
        ?assertEqual({completed, <<"lightweight">>}, Outcome),
        ?assertEqual(
           [<<"light">>, <<"weight">>],
           [Content || #adk_event{partial = true,
                                  content = Content} <- Events]),
        ?assertEqual(
           [<<"lightweight">>],
           [Content || #adk_event{is_final = true,
                                  content = Content} <- Events])
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(
              AppName, UserId, SessionId)
    end.

supervised_content_streaming() ->
    AppName = unique_binary(<<"readme_content_run_app">>),
    UserId = <<"readme-content-user">>,
    SessionId = <<"multimodal-session">>,
    AgentName = unique_binary(<<"ReadmeContentRunnerAgent">>),
    {ok, PromptText} = adk_content:text(<<"Describe this image briefly.">>),
    {ok, PromptImage} = adk_content:inline_data(
                          <<"image/png">>, <<1, 2, 3>>),
    {ok, MultimodalPrompt} = adk_content:new([PromptText, PromptImage]),
    {ok, FirstText} = adk_content:text(<<"look ">>),
    {ok, SecondText} = adk_content:text(<<"here">>),
    {ok, ResultImage} = adk_content:inline_data(
                          <<"image/png">>, <<4, 5, 6>>),
    {ok, FirstDelta} = adk_content:new([FirstText]),
    {ok, SecondDelta} = adk_content:new([SecondText, ResultImage]),
    {ok, ExpectedContent} = adk_content:new(
                              [FirstText#{<<"text">> => <<"look here">>},
                               ResultImage]),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       AgentName,
                       #{provider => adk_llm_stream_probe,
                         content_chunks => [FirstDelta, SecondDelta]}, []),
    Runner = adk_runner:new(
               AgentPid, AppName, erlang_adk_session,
               #{streaming_mode => content,
                 max_stream_output_bytes => 16777216,
                 run_timeout => 2000}),
    try
        {ok, RunId} = adk_run:start(
                        Runner, UserId, SessionId, MultimodalPrompt,
                        #{retention_ms => 2000,
                          max_buffered_events => 16}),

        %% A subscription and await are independent. Drain the subscribed
        %% protocol explicitly so the caller does not leave replay messages in
        %% its mailbox, then unsubscribe the retained terminal run.
        ok = adk_run:subscribe(RunId),
        ?assertEqual(
           {completed, ExpectedContent},
           adk_run:await(RunId, 2000)),
        {InitialEvents, InitialOutcome} = collect_streaming_run(RunId, []),
        ?assertEqual({completed, ExpectedContent}, InitialOutcome),
        ok = adk_run:unsubscribe(RunId),
        assert_content_stream_events(
          InitialEvents, FirstDelta, SecondDelta, ExpectedContent),

        %% A later subscription receives the same bounded replay and terminal
        %% outcome. It too is drained and explicitly detached.
        ok = adk_run:subscribe(RunId),
        {ReplayEvents, ReplayOutcome} = collect_streaming_run(RunId, []),
        ?assertEqual({completed, ExpectedContent}, ReplayOutcome),
        ?assertEqual(InitialEvents, ReplayEvents),
        ok = adk_run:unsubscribe(RunId),
        {ok, Status} = adk_run:status(RunId),
        ?assertEqual(0, maps:get(subscriber_count, Status)),
        assert_no_run_messages(RunId),
        {ok, ExpectedContent} = adk_content:validate(ExpectedContent)
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(
              AppName, UserId, SessionId)
    end.

assert_content_stream_events(Events, FirstDelta, SecondDelta,
                             ExpectedContent) ->
    ?assertEqual(
       [FirstDelta, SecondDelta],
       [Content || #adk_event{partial = true,
                              content = Content} <- Events]),
    ?assertEqual(
       [ExpectedContent],
       [Content || #adk_event{is_final = true,
                              content = Content} <- Events]).

assert_no_run_messages(RunId) ->
    receive
        {adk_run_event, RunId, _Sequence, _Event} ->
            ?assert(false);
        {adk_run_terminal, RunId, _Sequence, _Outcome} ->
            ?assert(false)
    after 0 ->
        ok
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
                <<"app:release">> => <<"0.3.0">>,
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
            <<"0.3.0">>,
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

session_query_pagination_and_rewind() ->
    AppName = unique_binary(<<"readme_query_app">>),
    UserId = <<"readme-query-user">>,
    SourceId = <<"query-a">>,
    BranchId = <<"query-a-before-answer">>,
    CursorSecret = adk_session_query:new_cursor_secret(),
    {ok, _} = erlang_adk_session:create_session(
                AppName, UserId, #{session_id => SourceId}),
    try
        First = adk_event:with_state_delta(
                  adk_event:new(<<"user">>, <<"question">>),
                  #{<<"step">> => 1}),
        Second = adk_event:with_state_delta(
                   adk_event:new(
                     <<"agent">>, <<"answer">>, #{is_final => true}),
                   #{<<"step">> => 2}),
        ok = erlang_adk_session:add_event(
               AppName, UserId, SourceId, First),
        ok = erlang_adk_session:add_event(
               AppName, UserId, SourceId, Second),
        {ok, SessionPage} = adk_session_query:list(
                              erlang_adk_session, AppName, UserId,
                              #{limit => 10,
                                cursor_secret => CursorSecret}),
        ?assertMatch([_ | _], maps:get(sessions, SessionPage)),
        {ok, EventPage} = adk_session_query:get(
                            erlang_adk_session, AppName, UserId, SourceId,
                            #{event_limit => 1,
                              cursor_secret => CursorSecret}),
        EventCursor = maps:get(
                        next_cursor, maps:get(event_page, EventPage)),
        ?assert(is_binary(EventCursor)),
        ?assertEqual(
           {ok, #{version => 1,
                  source_session_id => SourceId,
                  session_id => BranchId,
                  events_copied => 1,
                  state_strategy => event_deltas_only,
                  destructive => false}},
           adk_session_query:rewind(
             erlang_adk_session, AppName, UserId, SourceId,
             {index, 1}, #{target_session_id => BranchId})),
        {ok, SourceAfter} = erlang_adk_session:get_session(
                              AppName, UserId, SourceId),
        ?assertEqual(2, length(maps:get(events, SourceAfter)))
    after
        _ = erlang_adk_session:delete_session(
              AppName, UserId, SourceId),
        _ = erlang_adk_session:delete_session(
              AppName, UserId, BranchId)
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
    ok = readme_audit_callback:set_observer(Self),
    {ok, AgentPid} = erlang_adk:spawn_agent(
        AgentName,
        #{
            provider => adk_llm_probe,
            response => <<"callback response">>,
            callbacks => [readme_audit_callback]
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
        ok = readme_audit_callback:clear_observer(),
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

openapi_toolset_as_agent_tools() ->
    {ok, Json} = file:read_file(
                   "examples/readme_petstore_openapi.json"),
    Spec = jsx:decode(Json, [return_maps]),
    Transport = start_readme_openapi_transport(),
    {ok, Toolset} = adk_openapi_toolset:compile(
                      Spec,
                      #{transport =>
                            {adk_openapi_test_transport, Transport},
                        allowed_hosts =>
                            [<<"petstore3.swagger.io">>]}),
    {ok, Tools} = adk_toolset:new(adk_openapi_toolset, Toolset),
    AgentName = unique_binary(<<"ReadmeOpenapiAgent">>),
    {ok, Agent} = erlang_adk:spawn_agent(
                    AgentName,
                    #{provider => adk_llm_probe,
                      mode => tool_call,
                      call_name => <<"getPetById">>,
                      call_args => #{<<"petId">> => 1},
                      response => <<"Pet one is available">>,
                      test_pid => self()},
                    [Tools]),
    try
        ?assertEqual(
           {ok, <<"Pet one is available">>},
           erlang_adk:prompt(Agent, <<"Find pet 1">>)),
        {_FirstHistory, ModelTools} = receive_probe_generate(),
        ?assert(lists:any(
                  fun(#{<<"name">> := <<"getPetById">>}) -> true;
                     (_) -> false
                  end, ModelTools)),
        receive
            {readme_openapi_request, Request} ->
                ?assertEqual(<<"GET">>, maps:get(method, Request)),
                ?assertNotEqual(
                   nomatch,
                   binary:match(maps:get(url, Request), <<"/pet/1">>))
        after 1000 ->
            ?assert(false)
        end,
        _ = receive_probe_generate()
    after
        safe_stop_agent(Agent),
        Transport ! stop
    end.

start_readme_openapi_transport() ->
    Parent = self(),
    spawn(fun() -> readme_openapi_transport_loop(Parent) end).

readme_openapi_transport_loop(Parent) ->
    receive
        {openapi_transport_request, Worker, Ref, Request} ->
            Parent ! {readme_openapi_request, Request},
            Worker ! {openapi_transport_reply, Ref,
                      {ok, #{status => 200,
                             headers =>
                                 [{<<"content-type">>,
                                   <<"application/json">>}],
                             body =>
                                 <<"{\"id\":1,\"name\":\"Ada\","
                                   "\"status\":\"available\"}">>}}},
            readme_openapi_transport_loop(Parent);
        stop -> ok
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

mcp_streamable_http_fixture() ->
    Token = <<"readme-mcp-token-at-least-16-bytes">>,
    Resource = #{uri => <<"memo://otp">>,
                 name => <<"otp-note">>,
                 mime_type => <<"text/plain">>,
                 read => fun() -> {ok, <<"Supervise every long-lived process.">>} end},
    Prompt = #{name => <<"explain">>,
               arguments => [#{<<"name">> => <<"topic">>,
                               <<"required">> => true}],
               get => fun(#{<<"topic">> := Topic}) ->
                   {ok, #{<<"messages">> =>
                              [#{<<"role">> => <<"user">>,
                                 <<"content">> =>
                                     #{<<"type">> => <<"text">>,
                                       <<"text">> => <<"Explain ", Topic/binary>>}}]}}
               end},
    {ok, McpServer} = adk_mcp_server:start(
                        <<"streamable_http">>,
                        #{ip => {127, 0, 0, 1}, port => 0,
                          auth_token => Token,
                          tools => [readme_weather_tool],
                          resources => [Resource], prompts => [Prompt]}),
    try
        {ok, #{url := McpUrl}} = adk_mcp_server:endpoint(McpServer),
        AuthFun = fun() ->
            [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
        end,
        {ok, HttpMcpClient} = adk_mcp_client:connect(
                                <<"streamable_http">>, McpUrl,
                                #{auth_fun => AuthFun}),
        try
            {ok, McpToolset} = adk_toolset:new(
                                 adk_mcp_client, HttpMcpClient),
            {ok, [_]} = adk_toolset:expand_tools([McpToolset]),
            {ok, [WeatherTool]} = adk_mcp_client:list_tools(HttpMcpClient),
            ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, WeatherTool)),
            {ok, WeatherResult} = adk_mcp_client:execute_tool(
                                    HttpMcpClient, <<"get_weather">>,
                                    #{<<"city">> => <<"Pune">>}),
            ?assertEqual(false, maps:get(<<"isError">>, WeatherResult)),
            {ok, [_]} = adk_mcp_client:list_resources(HttpMcpClient),
            {ok, #{<<"contents">> := [_]}} =
                adk_mcp_client:read_resource(HttpMcpClient, <<"memo://otp">>),
            {ok, [_]} = adk_mcp_client:list_prompts(HttpMcpClient),
            {ok, #{<<"messages">> := [_]}} = adk_mcp_client:get_prompt(
                                                    HttpMcpClient,
                                                    <<"explain">>,
                                                    #{<<"topic">> => <<"OTP">>})
        after
            safe_close_mcp(HttpMcpClient)
        end
    after
        ok = adk_mcp_server:stop(McpServer)
    end.

plugins_observability_and_eval_sets() ->
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"ReadmeCrossCuttingAgent">>,
                    #{provider => adk_llm_probe,
                      model => <<"probe-model">>,
                      response => <<"ERLANG">>}, []),
    Plugin = #{id => <<"readme-policy">>,
               module => readme_policy_plugin,
               mode => observe, failure_policy => closed,
               timeout_ms => 1000, max_heap_words => 100000,
               config => #{notify => self()}},
    Exporter = #{id => <<"readme-exporter">>,
                 module => readme_observability_exporter,
                 failure_policy => closed,
                 timeout_ms => 1000, max_heap_words => 100000,
                 config => #{target => self()}},
    Runner = adk_runner:new(
               Agent, <<"readme-cross-cutting">>, erlang_adk_session,
               #{plugins => [Plugin],
                 observability => #{exporters => [Exporter],
                                    capture_content => false,
                                    attributes =>
                                        #{environment => <<"test">>}}}),
    try
        ?assertEqual(
           {ok, <<"ERLANG">>},
           adk_runner:run(
             Runner, <<"readme-user">>, <<"readme-plugin-session">>,
             <<"Reply with exactly: ERLANG">>)),
        PluginContext = receive_readme_plugin(),
        ?assert(is_binary(maps:get(<<"run_id">>, PluginContext))),
        ?assert(is_binary(maps:get(<<"invocation_id">>, PluginContext))),
        Observation = receive_readme_observation(),
        ?assertEqual(false,
                     maps:get(<<"content_captured">>, Observation)),
        ObservationMetadata = maps:get(<<"metadata">>, Observation),
        ?assertEqual(maps:get(<<"run_id">>, PluginContext),
                     maps:get(<<"run_id">>, ObservationMetadata)),

        {ok, EvalSet} = adk_eval_set:new(
                          <<"readme-multi-turn">>, <<"1">>,
                          [#{id => <<"exact-dialogue">>,
                             turns =>
                                 [#{id => <<"first">>,
                                    input => <<"Reply with exactly: ERLANG">>,
                                    expected => <<"ERLANG">>},
                                  #{id => <<"second">>,
                                    input => <<"Again, exactly: ERLANG">>,
                                    expected => <<"ERLANG">>}]}]),
        Adapter = #{module => readme_agent_eval_adapter,
                    target => Agent, config => #{}},
        Metrics = [#{id => <<"exact">>, module => readme_exact_metric,
                     kind => metric, threshold => 1.0, config => #{}}],
        {ok, EvalResult} = adk_eval_set:run(
                             Adapter, EvalSet, Metrics,
                             #{concurrency => 1,
                               pass_rate_threshold => 1.0}),
        ?assertEqual(true, maps:get(<<"passed">>, EvalResult)),
        ?assertMatch({ok, _}, adk_eval_set:decode_result(
                                  jsx:decode(
                                    jsx:encode(EvalResult),
                                    [return_maps])))
    after
        safe_stop_agent(Agent),
        flush_readme_cross_cutting_messages()
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

memory_and_artifacts() ->
    {ok, MemoryPid} = adk_memory_ets:init(#{}),
    AppName = unique_binary(<<"readme_memory_app">>),
    UserId = <<"readme-memory-user">>,
    SessionId = <<"memory-session">>,
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       <<"ReadmeMemoryAgent">>,
                       #{provider => adk_llm_probe,
                         response => <<"memory-aware response">>,
                         test_pid => self()}, []),
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

        Runner = adk_runner:new(
                   AgentPid, AppName, erlang_adk_session,
                   #{memory_svc => {adk_memory_ets, MemoryPid},
                     memory_retrieval =>
                         #{limit => 5,
                           filter => #{<<"topic">> => <<"otp">>},
                           on_error => fail},
                     memory_ingestion => on_success,
                     service_timeout => 1000,
                     run_timeout => 2000}),
        ?assertEqual(
           {ok, <<"memory-aware response">>},
           adk_runner:run(
             Runner, UserId, SessionId,
             <<"What restarts children?">>)),
        receive
            {probe_generate, History, _Tools} ->
                System = [Content || #{role := system,
                                       content := Content} <- History],
                ?assert(lists:any(
                          fun(Content) ->
                              binary:match(
                                unicode:characters_to_binary(Content),
                                <<"OTP supervision trees restart children">>)
                              =/= nomatch
                          end, System))
        after 1000 ->
            ?assert(false)
        end,

        {ok, ArtifactPid} = adk_artifact_ets:start_link(#{}),
        Scope = {session, AppName, UserId, <<"artifact-session">>},
        try
            {ok, FirstMeta} = adk_artifact_ets:put(
                                ArtifactPid, Scope,
                                <<"reports/result.txt">>, <<"first">>,
                                #{mime_type => <<"text/plain">>,
                                  metadata =>
                                      #{<<"source">> => <<"readme">>}}),
            ?assertEqual(1, maps:get(version, FirstMeta)),
            ?assert(is_binary(maps:get(digest, FirstMeta))),
            {ok, #{version := 2}} = adk_artifact_ets:put(
                                       ArtifactPid, Scope,
                                       <<"reports/result.txt">>,
                                       <<"second">>, #{}),
            {ok, Latest} = adk_artifact_ets:get(
                             ArtifactPid, Scope,
                             <<"reports/result.txt">>, latest),
            ?assertEqual(<<"second">>, maps:get(data, Latest))
        after
            _ = adk_artifact_ets:stop(ArtifactPid)
        end,

        ArtifactRoot = filename:join(
                         os:getenv("TMPDIR", "/tmp"),
                         "erlang-adk-readme-artifacts-" ++
                             integer_to_list(
                               erlang:unique_integer(
                                 [positive, monotonic]))),
        {ok, FsArtifactPid} = adk_artifact_fs:start_link(
                                #{root => ArtifactRoot,
                                  max_artifact_bytes => 1048576}),
        try
            {ok, #{version := 1}} = adk_artifact_fs:put(
                                       FsArtifactPid, Scope,
                                       <<"reports/durable.txt">>,
                                       <<"ready">>,
                                       #{mime_type => <<"text/plain">>}),
            {ok, #{data := <<"ready">>}} = adk_artifact_fs:get(
                                               FsArtifactPid, Scope,
                                               <<"reports/durable.txt">>,
                                               latest)
        after
            _ = adk_artifact_fs:stop(FsArtifactPid),
            _ = file:del_dir_r(ArtifactRoot)
        end,

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
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(
              AppName, UserId, SessionId),
        stop_memory(MemoryPid)
    end.

tool_confirmation_contract() ->
    AppName = unique_binary(<<"readme_confirmation_app">>),
    UserId = <<"readme-confirmation-user">>,
    SessionId = unique_binary(<<"confirmation-session">>),
    AgentName = unique_binary(<<"ReadmeConfirmationAgent">>),
    Args = #{<<"environment">> => <<"production">>,
             <<"dry_run">> => false},
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       AgentName,
                       #{provider => adk_llm_probe,
                         mode => tool_call,
                         call_name => <<"publish_release">>,
                         call_args => Args,
                         call_id => <<"readme-release-call">>},
                       [readme_release_tool]),
    Runner = adk_runner:new(
               AgentPid, AppName, erlang_adk_session,
               #{run_timeout => 2000}),
    try
        {ok, PausedRun} = adk_run:start(
                            Runner, UserId, SessionId,
                            <<"Publish the prepared production release.">>,
                            #{retention_ms => 2000}),
        {paused, PauseEvent} = adk_run:await(PausedRun, 2000),
        PublicPause = maps:get(<<"pause">>, PauseEvent#adk_event.actions),
        Details = maps:get(<<"details">>, PublicPause),
        ?assertEqual(<<"tool_confirmation">>,
                     maps:get(<<"type">>, Details)),
        ?assertMatch(<<"tool-confirm-", _/binary>>,
                     maps:get(<<"action_id">>, Details)),
        {ok, ResumedRun} = adk_run:resume(
                             PausedRun,
                             #{<<"confirmed">> => true},
                             #{retention_ms => 2000}),
        ?assertEqual({completed, <<"tool complete">>},
                     adk_run:await(ResumedRun, 2000)),
        ?assertEqual(
           {error, {already_resumed, ResumedRun}},
           adk_run:resume(PausedRun, #{<<"confirmed">> => true}))
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(
              AppName, UserId, SessionId)
    end.

suspension_and_pkce_contract() ->
    ?assertThrow(
       {adk_pause, {long_running, <<"export-42">>},
        <<"The external export is running.">>},
       adk_suspension:long_running(
         <<"export-42">>, <<"The external export is running.">>)),
    Principal = unique_binary(<<"readme-pkce-user">>),
    Provider = <<"calendar">>,
    Correlation = <<"calendar-consent-42">>,
    {ok, Pkce} = adk_suspension:prepare_pkce(
                   adk_credential_store_ets,
                   adk_credential_store_ets,
                   Principal, Provider, Correlation),
    FlowRef = maps:get(<<"credential_flow_ref">>, Pkce),
    Challenge = maps:get(<<"pkce_challenge">>, Pkce),
    ?assertEqual(<<"S256">>, maps:get(<<"pkce_method">>, Pkce)),
    ?assert(byte_size(Challenge) >= 43),
    RefreshToken = <<"readme-private-refresh-token">>,
    try
        {ok, FlowRef} = adk_suspension:complete_pkce(
                          adk_credential_store_ets,
                          adk_credential_store_ets,
                          Principal, Provider, FlowRef, Correlation,
                          #{kind => oauth_refresh_token,
                            client_id => <<"calendar-client">>,
                            refresh_token => RefreshToken}),
        {ok, Stored} = adk_credential_store_ets:fetch(
                         adk_credential_store_ets,
                         Principal, Provider, FlowRef),
        ?assertEqual(false, maps:is_key(code_verifier, Stored)),
        ?assertEqual(RefreshToken, maps:get(refresh_token, Stored)),
        ?assertEqual(
           {error, credential_flow_already_completed},
           adk_suspension:complete_pkce(
             adk_credential_store_ets, adk_credential_store_ets,
             Principal, Provider, FlowRef, Correlation,
             #{kind => oauth_refresh_token,
               refresh_token => <<"replayed">>}))
    after
        _ = adk_credential_store_ets:delete(
              adk_credential_store_ets,
              Principal, Provider, FlowRef)
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
        adk_run_test,
        adk_artifact_ets_test,
        adk_agent_runtime_spec_test,
        adk_openapi_toolset_test,
        adk_openapi_production_adapters_test,
        adk_oidc_security_test,
        adk_a2a_v1_codec_test,
        adk_a2a_v1_server_test,
        adk_a2a_v1_http_test,
        adk_auth_rotation_test,
        adk_suspension_test,
        adk_session_query_test,
        adk_runner_services_test,
        adk_hitl_test,
        erlang_adk_session_mnesia_test,
        erlang_adk_startup_test,
        erlang_adk_tests
    ],
    lists:foreach(
        fun(Module) ->
            ?assertEqual({module, Module}, code:ensure_loaded(Module))
        end,
        DedicatedModules
    ).

receive_readme_plugin() ->
    receive
        {adk_plugin, before_run, Context} -> Context
    after 1000 ->
        erlang:error(readme_plugin_timeout)
    end.

receive_readme_observation() ->
    receive
        {adk_observation, Envelope} -> Envelope
    after 1000 ->
        erlang:error(readme_observation_timeout)
    end.

flush_readme_cross_cutting_messages() ->
    receive
        {adk_plugin, _, _} -> flush_readme_cross_cutting_messages();
        {adk_observation, _} -> flush_readme_cross_cutting_messages()
    after 0 ->
        ok
    end.

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

collect_supervised_run(RunId, Sequences) ->
    receive
        {adk_run_event, RunId, Sequence, #adk_event{}} ->
            collect_supervised_run(RunId, [Sequence | Sequences]);
        {adk_run_terminal, RunId, _Sequence, Outcome} ->
            ?assertEqual([1, 2], lists:reverse(Sequences)),
            Outcome
    after 2000 ->
        {error, timeout}
    end.

collect_streaming_run(RunId, Events) ->
    receive
        {adk_run_event, RunId, _Sequence, #adk_event{} = Event} ->
            collect_streaming_run(RunId, [Event | Events]);
        {adk_run_terminal, RunId, _Sequence, Outcome} ->
            {lists:reverse(Events), Outcome}
    after 2000 ->
        {lists:reverse(Events), {error, timeout}}
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
    <<Prefix/binary, "_", Suffix/binary>>.
