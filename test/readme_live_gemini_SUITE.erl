-module(readme_live_gemini_SUITE).
-behaviour(adk_llm).
-include("../include/adk_event.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([generate/3, stream/4, stream_content/4,
         capabilities/0, validate_config/1]).
-export([retryable_rate_limit/1]).
-export([
    direct_text/1,
    google_search_grounding/1,
    thinking_configuration/1,
    multimodal_content/1,
    weather_tool_round_trip/1,
    streaming/1,
    async_delegation/1,
    concurrent_orchestration/1,
    sub_agent_and_agent_tool/1,
    runner_sync_async/1,
    human_approval/1,
    mnesia_runner/1,
    callbacks_telemetry_and_eval/1,
    http_endpoint/1
]).

-define(MODEL, <<"gemini-3.1-flash-lite">>).
-define(TIMEOUT, 120000).
-define(RATE_LIMITER, readme_live_gemini_rate_limiter).
-define(DEFAULT_REQUEST_INTERVAL_MS, 4200).
-define(LIVE_REQUEST_TIMEOUT_MS, 15000).
-define(TRANSPORT_TIMEOUT_RETRIES, 1).

suite() ->
    [{timetrap, {minutes, 8}}].

all() ->
    [direct_text,
     google_search_grounding,
     thinking_configuration,
     multimodal_content,
     weather_tool_round_trip,
     streaming,
     async_delegation,
     concurrent_orchestration,
     sub_agent_and_agent_tool,
     runner_sync_async,
     human_approval,
     mnesia_runner,
     callbacks_telemetry_and_eval,
     http_endpoint].

init_per_suite(Config) ->
    case {os:getenv("ERLANG_ADK_LIVE_GEMINI"),
          os:getenv("GEMINI_API_KEY")} of
        {"1", Key} when is_list(Key), Key =/= [] ->
            application:set_env(erlang_adk, a2a_enabled, false),
            application:set_env(erlang_adk, agent_call_timeout, ?TIMEOUT),
            application:set_env(erlang_adk, agent_turn_timeout, ?TIMEOUT),
            {ok, _} = application:ensure_all_started(erlang_adk),
            ok = compile_example(readme_weather_tool),
            ok = compile_example(readme_audit_callback),
            ok = start_rate_limiter(request_interval_ms()),
            [{model, ?MODEL} | Config];
        {"1", _} ->
            {skip, "GEMINI_API_KEY is not available to the test process"};
        _ ->
            {skip, "set ERLANG_ADK_LIVE_GEMINI=1 to run paid live tests"}
    end.

end_per_suite(_Config) ->
    stop_rate_limiter(),
    lists:foreach(
      fun(Module) ->
          _ = code:purge(Module),
          _ = code:delete(Module)
      end,
      [readme_weather_tool, readme_audit_callback]),
    _ = application:stop(erlang_adk),
    _ = application:unset_env(erlang_adk, a2a_enabled),
    _ = application:unset_env(erlang_adk, a2a_port),
    _ = application:unset_env(erlang_adk, agent_call_timeout),
    _ = application:unset_env(erlang_adk, agent_turn_timeout),
    ok.

%% The live suite deliberately uses itself as a thin provider wrapper. This
%% keeps quota pacing out of production code while applying it to every Gemini
%% turn, including calls made from agents, Runner workers and parallel flows.
capabilities() ->
    adk_llm_gemini:capabilities().

validate_config(Config) ->
    adk_llm_gemini:validate_config(gemini_config(Config)).

generate(Config, Memory, Tools) ->
    live_request(
      fun() ->
          adk_llm_gemini:generate(gemini_config(Config), Memory, Tools)
      end,
      ?TRANSPORT_TIMEOUT_RETRIES).

stream(Config, Memory, Tools, Callback) ->
    live_request(
      fun() ->
          adk_llm_gemini:stream(
            gemini_config(Config), Memory, Tools, Callback)
      end,
      0).

stream_content(Config, Memory, Tools, Callback) ->
    live_request(
      fun() ->
          adk_llm_gemini:stream_content(
            gemini_config(Config), Memory, Tools, Callback)
      end,
      0).

direct_text(_Config) ->
    Config = provider_config(),
    History = [#{role => user,
                 content => <<"Reply with one short sentence about Erlang OTP.">>}],
    Text = expect_text(adk_llm:generate(Config, History, []), direct_text),
    assert(nonempty_text(Text), {empty_direct_text, Text}),
    ok.

google_search_grounding(_Config) ->
    Config = (provider_config())#{builtin_tools => [google_search],
                                  max_tokens => 384},
    History = [#{role => user,
                 content =>
                     <<"Use Google Search before answering: what is the "
                       "latest stable Erlang/OTP release? Reply briefly.">>}],
    Result = adk_llm:generate(Config, History, []),
    case adk_provider_result:decode(Result) of
        {ok, {ok, Answer}, ProviderMetadata} ->
            assert(nonempty_text(Answer),
                   {empty_grounded_answer, Answer}),
            assert(maps:get(<<"provider">>, ProviderMetadata, undefined)
                       =:= <<"gemini">>,
                   {invalid_grounding_provider, ProviderMetadata}),
            assert(maps:get(<<"type">>, ProviderMetadata, undefined)
                       =:= <<"google_search_grounding">>,
                   {invalid_grounding_type, ProviderMetadata}),
            Grounding = maps:get(<<"metadata">>, ProviderMetadata, #{}),
            Chunks = maps:get(<<"groundingChunks">>, Grounding, []),
            Queries = maps:get(<<"webSearchQueries">>, Grounding, []),
            assert(Chunks =/= [] orelse Queries =/= [],
                   {missing_grounding_evidence, Grounding}),
            ok;
        {error, Reason} ->
            ct:fail({google_search_grounding, Reason});
        not_provider_result ->
            ct:fail({google_search_not_used, Result})
    end.

thinking_configuration(_Config) ->
    Config = (gemini_config(provider_config()))#{
        thinking_config => #{thinking_level => high,
                             include_thoughts => true}
    },
    Result = live_request(
               fun() ->
                   adk_llm_gemini:generate(
                     Config,
                     [#{role => user,
                        content =>
                            <<"Answer in one short sentence: why use OTP?">>}],
                     [])
               end,
               ?TRANSPORT_TIMEOUT_RETRIES),
    assert_thinking_response(Result),
    ok.

multimodal_content(_Config) ->
    TinyPng = base64:decode(
        <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">>),
    {ok, PromptPart} = adk_content:text(
                         <<"Describe this one-pixel image in one sentence.">>),
    {ok, ImagePart} = adk_content:inline_data(<<"image/png">>, TinyPng),
    {ok, Prompt} = adk_content:new([PromptPart, ImagePart]),
    History = [#{role => user, content => Prompt}],
    GeminiConfig = gemini_config(provider_config()),
    Text = expect_text(
             live_request(
               fun() -> adk_llm_gemini:generate(
                          GeminiConfig, History, []) end,
               ?TRANSPORT_TIMEOUT_RETRIES),
             multimodal_generate),
    assert(nonempty_text(Text), {empty_multimodal_response, Text}),
    Self = self(),
    StreamResult = live_request(
                     fun() ->
                         adk_llm_gemini:stream_content(
                           GeminiConfig, History, [],
                           fun(Delta) ->
                               Self ! {live_content_delta, Delta}
                           end)
                     end, 0),
    assert(StreamResult =:= ok,
           {unexpected_multimodal_stream_result, StreamResult}),
    Deltas = collect_content_deltas([]),
    assert(Deltas =/= [], no_multimodal_stream_deltas),
    lists:foreach(
      fun(Delta) ->
          assert(adk_content:validate(Delta) =:= {ok, Delta},
                 {invalid_multimodal_stream_delta, Delta})
      end, Deltas),
    StreamText = iolist_to_binary(
                   lists:append(
                     [adk_llm_gemini_content:text_parts(Delta)
                      || Delta <- Deltas])),
    assert(nonempty_text(StreamText),
           {empty_multimodal_stream_text, Deltas}),
    ok.

weather_tool_round_trip(_Config) ->
    Name = unique(<<"LiveWeatherAgent">>),
    SessionId = unique(<<"live-weather-session">>),
    Instructions =
        <<"When the user asks for weather, call get_weather exactly once. "
          "After receiving its result, answer briefly and do not call it again.">>,
    AgentConfig = (provider_config())#{instructions => Instructions,
                                       session_id => SessionId},
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       Name, AgentConfig, [readme_weather_tool]),
    try
        Text = expect_text(
                 erlang_adk:prompt(
                   AgentPid,
                   <<"Use get_weather for Tokyo before answering.">>),
                 weather_tool_prompt),
        assert(nonempty_text(Text), {empty_weather_response, Text}),
        Memory = erlang_adk_session:load(SessionId),
        Calls = lists:append(
                  [AgentCalls ||
                      #{role := agent,
                        content := {tool_calls, AgentCalls}} <- Memory]),
        WeatherCalls = [Call || Call <- Calls,
                                call_name(Call) =:= <<"get_weather">>],
        assert(WeatherCalls =/= [], {weather_tool_not_called, Memory}),
        ToolResponses = [Content || #{role := tool, content := Content} <- Memory],
        assert(lists:any(fun is_weather_response/1, ToolResponses),
               {weather_response_not_recorded, ToolResponses}),
        assert_call_correlation(WeatherCalls, ToolResponses)
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete(SessionId)
    end.

streaming(_Config) ->
    Self = self(),
    Callback = fun(Chunk) -> Self ! {live_stream_chunk, Chunk} end,
    Result = adk_llm:stream(
               provider_config(),
               [#{role => user,
                  content => <<"Reply with a short greeting from Erlang.">>}],
               [], Callback),
    assert(Result =:= ok, {unexpected_stream_result, Result}),
    Chunks = collect_chunks([]),
    assert(Chunks =/= [], no_stream_chunks),
    Combined = iolist_to_binary(Chunks),
    assert(nonempty_text(Combined), {empty_stream_text, Chunks}),
    assert(unicode:characters_to_binary(Combined) =:= Combined,
           {invalid_stream_unicode, Combined}),
    ok.

async_delegation(_Config) ->
    Name = unique(<<"LiveAsyncAgent">>),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       Name,
                       (provider_config())#{
                         instructions => <<"Answer concisely.">>}, []),
    Ref = make_ref(),
    try
        ok = erlang_adk:delegate(
               AgentPid, <<"Summarize OTP in one sentence.">>, self(), Ref),
        receive
            {agent_response, Ref, AgentPid, {ok, Text}} ->
                assert(nonempty_text(Text), {empty_delegate_response, Text});
            {agent_response, Ref, AgentPid, {error, Reason}} ->
                ct:fail({delegate_failed, Reason})
        after ?TIMEOUT ->
            ct:fail(delegate_timeout)
        end
    after
        safe_stop_agent(AgentPid)
    end.

concurrent_orchestration(_Config) ->
    {ok, First} = constant_agent(<<"LiveSeqFirst">>, <<"STAGE_ONE">>),
    {ok, Second} = constant_agent(<<"LiveSeqSecond">>, <<"STAGE_TWO">>),
    {ok, ParallelA} = constant_agent(<<"LiveParallelA">>, <<"PARALLEL_A">>),
    {ok, ParallelB} = constant_agent(<<"LiveParallelB">>, <<"PARALLEL_B">>),
    {ok, Writer} = constant_agent(<<"LiveWriter">>, <<"LIVE_DRAFT">>),
    {ok, Reviewer} = constant_agent(<<"LiveReviewer">>, <<"APPROVED">>),
    Pids = [First, Second, ParallelA, ParallelB, Writer, Reviewer],
    try
        {ok, SeqText} = erlang_adk:sequential(
                          [First, Second], <<"pipeline input">>),
        assert(nonempty_text(SeqText), {empty_sequential_result, SeqText}),
        ParallelResults = erlang_adk:parallel(
                            [ParallelA, ParallelB],
                            <<"parallel input">>, ?TIMEOUT),
        assert(length(ParallelResults) =:= 2,
               {invalid_parallel_count, ParallelResults}),
        assert([Pid || {Pid, _} <- ParallelResults] =:= [ParallelA, ParallelB],
               {parallel_order_changed, ParallelResults}),
        lists:foreach(
          fun({_Pid, Text}) ->
              assert(nonempty_text(Text), {empty_parallel_result, Text})
          end,
          ParallelResults),
        {ok, Draft} = erlang_adk:loop(
                        Writer, Reviewer, <<"Write a tiny draft.">>, 2),
        assert(is_binary(Draft), {loop_result_not_binary, Draft}),
        assert(nonempty_text(Draft), {empty_loop_draft, Draft})
    after
        lists:foreach(fun safe_stop_agent/1, lists:reverse(Pids))
    end.

sub_agent_and_agent_tool(_Config) ->
    SpecialistName = unique(<<"LiveSpecialist">>),
    CoordinatorName = unique(<<"LiveCoordinator">>),
    SessionId = unique(<<"live-coordinator-session">>),
    {ok, SpecialistPid} = erlang_adk:spawn_agent(
                            SpecialistName,
                            (provider_config())#{
                              instructions =>
                                <<"Answer specialist requests briefly.">>}, []),
    CoordinatorConfig = (provider_config())#{
        session_id => SessionId,
        instructions =>
            <<"Always delegate the user's request to the only specialist tool. "
              "After the tool result, answer briefly without calling it again.">>,
        sub_agents => #{
            SpecialistName => #{pid => SpecialistPid,
                                description => <<"Erlang specialist">>}
        }
    },
    {ok, CoordinatorPid} = erlang_adk:spawn_agent(
                             CoordinatorName, CoordinatorConfig, []),
    try
        Coordinated = expect_text(
                        erlang_adk:prompt(
                          CoordinatorPid,
                          <<"Ask the specialist to explain supervisors.">>),
                        coordinator_prompt),
        assert(nonempty_text(Coordinated),
               {empty_coordinator_response, Coordinated}),
        Memory = erlang_adk_session:load(SessionId),
        assert(memory_called_tool(Memory, SpecialistName),
               {specialist_not_called, Memory}),
        Direct = expect_text(
                   adk_agent_tool:execute(
                     SpecialistPid,
                     #{<<"prompt">> => <<"Explain rest_for_one briefly.">>}, #{}),
                   agent_as_tool),
        assert(nonempty_text(Direct), {empty_agent_tool_response, Direct})
    after
        safe_stop_agent(CoordinatorPid),
        safe_stop_agent(SpecialistPid),
        _ = erlang_adk_session:delete(SessionId)
    end.

runner_sync_async(_Config) ->
    Name = unique(<<"LiveRunnerAgent">>),
    App = unique(<<"live-runner-app">>),
    User = <<"live-user">>,
    SyncSession = unique(<<"live-sync-session">>),
    AsyncSession = unique(<<"live-async-session">>),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       Name,
                       (provider_config())#{
                         instructions => <<"Answer in one short sentence.">>}, []),
    Runner = adk_runner:new(
               AgentPid, App, erlang_adk_session,
               #{run_timeout => ?TIMEOUT,
                 streaming_mode => text}),
    try
        SyncText = expect_text(
                     adk_runner:run(
                       Runner, User, SyncSession, <<"What is OTP?">>),
                     runner_sync),
        assert(nonempty_text(SyncText), {empty_runner_sync, SyncText}),
        {ok, StreamPid} = adk_runner:run_async(
                            Runner, User, AsyncSession,
                            <<"What is a supervisor?">>),
        {done, AsyncEvents} = drain_runner(StreamPid, []),
        ModelDeltas =
            [Event || #adk_event{author = Author,
                                 partial = true,
                                 is_final = false} = Event <- AsyncEvents,
                      Author =:= Name],
        FinalEvents =
            [Event || #adk_event{is_final = true} = Event <- AsyncEvents],
        assert(ModelDeltas =/= [],
               {runner_missing_streamed_model_delta, AsyncEvents}),
        assert(length(FinalEvents) =:= 1,
               {runner_invalid_final_event_count,
                length(FinalEvents), AsyncEvents}),
        {ok, Stored} = erlang_adk_session:get_session(
                         App, User, AsyncSession),
        StoredEvents = maps:get(events, Stored),
        assert(length(StoredEvents) >= 2,
               {runner_events_not_persisted, StoredEvents})
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(App, User, SyncSession),
        _ = erlang_adk_session:delete_session(App, User, AsyncSession)
    end.

human_approval(_Config) ->
    Name = unique(<<"LiveApprovalAgent">>),
    App = unique(<<"live-approval-app">>),
    User = <<"live-user">>,
    Session = unique(<<"live-approval-session">>),
    Instructions =
        <<"Before performing a requested operation, call request_human_approval "
          "exactly once. After its function response is present, answer briefly "
          "and never call the function again.">>,
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       Name,
                       (provider_config())#{instructions => Instructions},
                       [adk_long_running_tool]),
    Runner = adk_runner:new(
               AgentPid, App, erlang_adk_session,
               #{run_timeout => ?TIMEOUT}),
    try
        case adk_runner:run(
               Runner, User, Session,
               <<"Publish the staged documentation after approval.">>) of
            {paused, PauseEvent} ->
                Pause = maps:get(<<"pause">>, PauseEvent#adk_event.actions),
                assert(maps:get(<<"tool_name">>, Pause) =:=
                           <<"request_human_approval">>,
                       {wrong_pause_tool, Pause}),
                ContinuationId = maps:get(<<"continuation_id">>, Pause),
                assert(ContinuationId =:=
                           PauseEvent#adk_event.invocation_id,
                       {pause_continuation_mismatch,
                        ContinuationId,
                        PauseEvent#adk_event.invocation_id}),
                {ok, ResumePid} = adk_runner:resume(
                                    Runner, User, Session,
                                    ContinuationId,
                                    #{approved => true,
                                      approver => <<"live-test">>}),
                {done, ResumeEvents} = drain_runner(ResumePid, []),
                assert(lists:any(
                         fun(Event) -> Event#adk_event.is_final =:= true end,
                         ResumeEvents),
                       {resume_missing_final_event, ResumeEvents});
            Other ->
                ct:fail({expected_human_approval_pause, Other})
        end
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session:delete_session(App, User, Session)
    end.

mnesia_runner(_Config) ->
    ok = erlang_adk_session_mnesia:init(),
    Name = unique(<<"LiveMnesiaAgent">>),
    App = unique(<<"live-mnesia-app">>),
    User = <<"live-user">>,
    Session = unique(<<"live-mnesia-session">>),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       Name,
                       (provider_config())#{
                         instructions => <<"Answer briefly.">>}, []),
    Runner = adk_runner:new(
               AgentPid, App, erlang_adk_session_mnesia,
               #{run_timeout => ?TIMEOUT}),
    try
        Text = expect_text(
                 adk_runner:run(
                   Runner, User, Session, <<"Say hello from Mnesia.">>),
                 mnesia_runner),
        assert(nonempty_text(Text), {empty_mnesia_runner_response, Text}),
        {ok, Stored} = erlang_adk_session_mnesia:get_session(
                         App, User, Session),
        assert(length(maps:get(events, Stored)) >= 2,
               {mnesia_events_not_persisted, Stored})
    after
        safe_stop_agent(AgentPid),
        _ = erlang_adk_session_mnesia:delete_session(App, User, Session)
    end.

callbacks_telemetry_and_eval(_Config) ->
    Name = unique(<<"LiveCallbackEvalAgent">>),
    HandlerId = unique(<<"live-telemetry-handler">>),
    Self = self(),
    Handler = fun(_Event, Measurements, Metadata, _HandlerConfig) ->
        Self ! {live_telemetry, Measurements, Metadata}
    end,
    ok = telemetry:attach(
           HandlerId, [erlang_adk, agent, prompt, stop], Handler, #{}),
    ok = readme_audit_callback:set_observer(Self),
    AgentConfig = (provider_config())#{
        instructions => <<"Answer each request briefly.">>,
        callbacks => [readme_audit_callback]
    },
    {ok, AgentPid} = erlang_adk:spawn_agent(Name, AgentConfig, []),
    try
        Text = expect_text(
                 erlang_adk:prompt(AgentPid, <<"Say hello.">>),
                 callback_prompt),
        assert(nonempty_text(Text), {empty_callback_response, Text}),
        receive {before_model, _ToolCount} -> ok
        after ?TIMEOUT -> ct:fail(before_model_callback_missing)
        end,
        receive {after_model, {ok, _ProviderText}} -> ok
        after ?TIMEOUT -> ct:fail(after_model_callback_missing)
        end,
        receive
            {live_telemetry, Measurements, Metadata} ->
                assert(is_integer(maps:get(duration, Measurements)),
                       {invalid_telemetry_measurements, Measurements}),
                assert(maps:get(agent, Metadata) =:= Name,
                       {invalid_telemetry_metadata, Metadata})
        after ?TIMEOUT ->
            ct:fail(prompt_telemetry_missing)
        end,
        Dataset = [#{input => <<"Reply with a short nonempty token.">>,
                     expected => nonempty,
                     metadata => #{case_id => live}}],
        Metric = fun(_Expected, Actual) ->
            case nonempty_text(Actual) of true -> 1.0; false -> 0.0 end
        end,
        {ok, Report} = adk_eval:run(
                         AgentPid, Dataset, Metric,
                         #{concurrency => 1, timeout => ?TIMEOUT}),
        assert(maps:get(average_score, Report) =:= 1.0,
               {live_evaluation_failed, Report})
    after
        ok = readme_audit_callback:clear_observer(),
        _ = telemetry:detach(HandlerId),
        safe_stop_agent(AgentPid)
    end.

http_endpoint(_Config) ->
    Port = free_port(),
    _ = application:stop(erlang_adk),
    application:set_env(erlang_adk, a2a_enabled, true),
    application:set_env(erlang_adk, a2a_port, Port),
    {ok, _} = application:ensure_all_started(erlang_adk),
    Name = unique(<<"LiveHttpAgent">>),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       Name,
                       (provider_config())#{
                         instructions => <<"Answer briefly.">>}, []),
    Url = "http://localhost:" ++ integer_to_list(Port) ++ "/a2a/prompt",
    try
        timer:sleep(100),
        Text = expect_text(
                 erlang_adk_a2a_client:prompt(
                   Url, Name, <<"Hello from live HTTP.">>),
                 http_endpoint),
        assert(nonempty_text(Text), {empty_http_response, Text})
    after
        safe_stop_agent(AgentPid),
        _ = application:stop(erlang_adk)
    end.

provider_config() ->
    #{provider => ?MODULE,
      model => ?MODEL,
      request_timeout => ?LIVE_REQUEST_TIMEOUT_MS,
      max_tokens => 512}.

gemini_config(Config) ->
    Config#{provider => adk_llm_gemini, model => ?MODEL}.

live_request(Fun, TransportRetriesLeft) ->
    ok = acquire_request_slot(),
    case Fun() of
        {error, timeout} when TransportRetriesLeft > 0 ->
            ct:pal(
              "Gemini transport timed out after ~p ms; retrying once",
              [?LIVE_REQUEST_TIMEOUT_MS]),
            live_request(Fun, TransportRetriesLeft - 1);
        Result ->
            case TransportRetriesLeft > 0
                 andalso retryable_rate_limit(Result) of
                true ->
                    Backoff = max(request_interval_ms(), 10000),
                    ct:pal(
                      "Gemini returned HTTP 429; backing off ~p ms and "
                      "retrying once",
                      [Backoff]),
                    timer:sleep(Backoff),
                    live_request(Fun, TransportRetriesLeft - 1);
                false ->
                    Result
            end
    end.

%% Direct adapter calls expose the raw HTTP tuple. Calls which have already
%% crossed adk_llm's provider boundary expose the bounded structural failure.
%% Match both without inspecting or logging the response body.
retryable_rate_limit({error, {http_status, 429, _Body}}) -> true;
retryable_rate_limit({error, {adk_failure, #{status := 429}}}) -> true;
retryable_rate_limit(_) -> false.

request_interval_ms() ->
    case os:getenv("ERLANG_ADK_LIVE_GEMINI_INTERVAL_MS") of
        false ->
            ?DEFAULT_REQUEST_INTERVAL_MS;
        Value ->
            case string:to_integer(Value) of
                {Interval, []} when Interval >= 0 -> Interval;
                _ ->
                    ct:fail(
                      {invalid_live_gemini_interval_ms, Value,
                       "expected a non-negative integer"})
            end
    end.

start_rate_limiter(Interval) ->
    stop_rate_limiter(),
    Pid = spawn(
            fun() ->
                rate_limiter_loop(
                  Interval, erlang:monotonic_time(millisecond))
            end),
    true = register(?RATE_LIMITER, Pid),
    ok.

stop_rate_limiter() ->
    case whereis(?RATE_LIMITER) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            Pid ! stop,
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 5000 ->
                demonitor(Ref, [flush]),
                ok
            end
    end.

acquire_request_slot() ->
    case whereis(?RATE_LIMITER) of
        undefined ->
            ct:fail(live_gemini_rate_limiter_not_started);
        Pid ->
            Ref = make_ref(),
            Pid ! {acquire, self(), Ref},
            receive
                {request_slot, Ref} -> ok
            after ?TIMEOUT ->
                ct:fail(live_gemini_rate_limiter_timeout)
            end
    end.

rate_limiter_loop(Interval, NextAllowed) ->
    receive
        {acquire, From, Ref} ->
            Now = erlang:monotonic_time(millisecond),
            timer:sleep(max(0, NextAllowed - Now)),
            From ! {request_slot, Ref},
            GrantedAt = erlang:monotonic_time(millisecond),
            rate_limiter_loop(Interval, GrantedAt + Interval);
        stop ->
            ok
    end.

constant_agent(Prefix, Token) ->
    Name = unique(Prefix),
    Instructions = <<"Reply with exactly ", Token/binary,
                     " and no other text.">>,
    erlang_adk:spawn_agent(
      Name, (provider_config())#{instructions => Instructions}, []).

expect_text({ok, Text}, _Label) -> Text;
expect_text({error, Reason}, Label) -> ct:fail({Label, Reason});
expect_text(Other, Label) -> ct:fail({Label, unexpected_result, Other}).

nonempty_text(Text) when is_binary(Text) ->
    byte_size(string:trim(Text)) > 0;
nonempty_text(Text) when is_list(Text) ->
    nonempty_text(unicode:characters_to_binary(Text));
nonempty_text(_) ->
    false.

assert_thinking_response({ok, Text}) when is_binary(Text); is_list(Text) ->
    assert(nonempty_text(Text), {empty_thinking_response, Text});
assert_thinking_response({ok, Content}) when is_map(Content) ->
    assert(adk_content:validate(Content) =:= {ok, Content},
           {invalid_thinking_content, Content}),
    Visible = [Text || #{<<"type">> := <<"text">>,
                         <<"text">> := Text} = Part
                          <- adk_content:parts(Content),
                      maps:get(<<"thought">>, Part, false) =/= true],
    assert(Visible =/= [] andalso nonempty_text(iolist_to_binary(Visible)),
           {missing_visible_thinking_answer, Content});
assert_thinking_response({error, Reason}) ->
    ct:fail({thinking_configuration, Reason});
assert_thinking_response(Other) ->
    ct:fail({thinking_configuration, unexpected_result, Other}).

collect_chunks(Acc) ->
    receive
        {live_stream_chunk, Chunk} -> collect_chunks([Chunk | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

collect_content_deltas(Acc) ->
    receive
        {live_content_delta, Delta} ->
            collect_content_deltas([Delta | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

drain_runner(StreamPid, Acc) ->
    receive
        {adk_event, StreamPid, Event} ->
            drain_runner(StreamPid, [Event | Acc]);
        {adk_done, StreamPid} ->
            {done, lists:reverse(Acc)};
        {adk_paused, StreamPid, PauseEvent} ->
            {paused, PauseEvent, lists:reverse(Acc)};
        {adk_error, StreamPid, Reason} ->
            ct:fail({runner_stream_failed, Reason})
    after ?TIMEOUT ->
        ct:fail(runner_stream_timeout)
    end.

call_name({Name, _Args}) -> Name;
call_name({Name, _Args, _Signature}) -> Name;
call_name({Name, _Args, _Signature, _CallId}) -> Name.

call_id({_Name, _Args}) -> undefined;
call_id({_Name, _Args, _Signature}) -> undefined;
call_id({_Name, _Args, _Signature, CallId}) -> CallId.

is_weather_response({tool_response, <<"get_weather">>, _Result, _Signature}) -> true;
is_weather_response({tool_response, <<"get_weather">>, _Result,
                     _Signature, _CallId}) -> true;
is_weather_response(_) -> false.

assert_call_correlation(Calls, Responses) ->
    Ids = [Id || Call <- Calls, (Id = call_id(Call)) =/= undefined],
    lists:foreach(
      fun(Id) ->
          assert(lists:any(
                   fun
                       ({tool_response, <<"get_weather">>, _, _, Id0})
                         when Id0 =:= Id -> true;
                       (_) -> false
                   end,
                   Responses),
                 {missing_correlated_weather_response, Id, Responses})
      end,
      Ids),
    ok.

memory_called_tool(Memory, Name) ->
    lists:any(
      fun
          (#{role := agent, content := {tool_calls, Calls}}) ->
              lists:any(fun(Call) -> call_name(Call) =:= Name end, Calls);
          (_) -> false
      end,
      Memory).

safe_stop_agent(Pid) when is_pid(Pid) ->
    _ = catch erlang_adk:stop_agent(Pid),
    ok.

compile_example(Module) ->
    %% Common Test changes the current working directory to its log directory.
    %% Resolve examples from the application build directory so this suite works
    %% both through `rebar3 ct` and when invoked from another directory.
    AppBuildDir = code:lib_dir(erlang_adk),
    ProjectRoot = filename:absname(
                    filename:join(
                      [AppBuildDir, "..", "..", "..", ".."])),
    Path = filename:join(
             [ProjectRoot, "examples", atom_to_list(Module) ++ ".erl"]),
    Result = compile:file(Path, [binary, return_errors, return_warnings]),
    Beam = case Result of
        {ok, Module, Binary} -> Binary;
        {ok, Module, Binary, _Warnings} -> Binary;
        {error, Errors, Warnings} ->
            ct:fail({example_compile_failed, Module, Errors, Warnings})
    end,
    _ = code:purge(Module),
    _ = code:delete(Module),
    {module, Module} = code:load_binary(Module, Path, Beam),
    ok.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "_", Suffix/binary>>.

free_port() ->
    {ok, Socket} = gen_tcp:listen(
                     0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, {_Address, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    Port.

assert(true, _Reason) -> ok;
assert(false, Reason) -> ct:fail(Reason).
