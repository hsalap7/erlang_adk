-module(adk_runner_safety_test).
-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-define(APP, <<"runner-safety-app">>).
-define(USER, <<"runner-safety-user">>).

runner_safety_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun admission_reject_queue_cancel_and_release_case/0,
      fun invalid_runner_safety_options_case/0,
      fun agent_policy_denial_is_audited_before_model_case/0,
      fun hitl_tool_denial_precedes_callbacks_and_pause_case/0,
      fun dynamic_toolset_denial_precedes_live_resolution_case/0,
      fun tool_output_budget_replaces_private_result_case/0,
      fun final_output_budget_prevents_raw_persistence_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_Setup) ->
    persistent_term:erase({adk_runtime_safety_tool, target}),
    ok.

admission_reject_queue_cancel_and_release_case() ->
    {ok, Controller} = adk_admission_control:start_link(
                         #{name => undefined,
                           global_limit => 1,
                           default_agent_limit => 1,
                           overflow => queue,
                           max_queue => 4,
                           default_queue_timeout => 5000}),
    TestPid = self(),
    BlockingAgent = spawn(fun() -> blocking_agent_loop(TestPid) end),
    QueueRunner = adk_runner:new(
                    BlockingAgent, ?APP, erlang_adk_session,
                    #{run_timeout => 5000,
                      admission_control =>
                          #{server => Controller,
                            overflow => queue,
                            queue_timeout => 4000}}),
    RejectRunner = adk_runner:new(
                     BlockingAgent, ?APP, erlang_adk_session,
                     #{run_timeout => 5000,
                       admission_control =>
                           #{server => Controller,
                             overflow => reject}}),
    FirstSession = unique(<<"admission-first">>),
    QueuedSession = unique(<<"admission-queued">>),
    RejectedSession = unique(<<"admission-rejected">>),
    try
        {ok, First} = adk_runner:run_async(
                        QueueRunner, ?USER, FirstSession, <<"hold">>),
        receive
            {blocking_model_entered, FirstWorker, _From}
              when is_pid(FirstWorker) -> ok
        after 1000 -> erlang:error(first_not_admitted)
        end,
        {ok, Queued} = adk_runner:run_async(
                         QueueRunner, ?USER, QueuedSession, <<"queue">>),
        ok = wait_status(
               Controller,
               fun(Status) ->
                   maps:get(active, Status) =:= 1 andalso
                   maps:get(queue_length, Status) =:= 1
               end),
        ?assertEqual(
           {error, {admission_failed, concurrency_limit_reached}},
           adk_runner:run(
             RejectRunner, ?USER, RejectedSession, <<"reject">>)),

        ok = adk_runner:cancel(Queued, queued_cancel),
        receive
            {adk_error, Queued, {cancelled, queued_cancel}} -> ok
        after 1000 -> erlang:error(queued_cancel_timeout)
        end,
        ok = wait_status(
               Controller,
               fun(Status) -> maps:get(queue_length, Status) =:= 0 end),

        ok = adk_runner:cancel(First, active_cancel),
        receive
            {adk_error, First, {cancelled, active_cancel}} -> ok
        after 1000 -> erlang:error(active_cancel_timeout)
        end,
        ok = wait_status(
               Controller,
               fun(Status) -> maps:get(active, Status) =:= 0 end),
        {ok, Status} = adk_admission_control:status(Controller),
        ?assertEqual(0, maps:get(active, Status)),
        ?assertEqual(0, maps:get(queue_length, Status))
    after
        BlockingAgent ! stop,
        cleanup_sessions([FirstSession, QueuedSession, RejectedSession]),
        gen_server:stop(Controller)
    end.

invalid_runner_safety_options_case() ->
    InvalidAdmission = #{overflow => 'maybe'},
    ?assertError(
       {invalid_runner_admission_control, InvalidAdmission},
       adk_runner:new(
         self(), ?APP, erlang_adk_session,
         #{admission_control => InvalidAdmission})),
    ?assertError(
       {invalid_runner_runtime_policy, invalid_max_content_bytes},
       adk_runner:new(
         self(), ?APP, erlang_adk_session,
         #{runtime_policy => #{max_content_bytes => infinity}})).

agent_policy_denial_is_audited_before_model_case() ->
    SessionId = unique(<<"agent-denied">>),
    Secret = <<"private-user-input-must-not-persist">>,
    TestPid = self(),
    TargetAgent = spawn(
                    fun() -> scripted_agent_loop(
                               TestPid, <<"denied-agent">>, [], [],
                               <<"must-not-run">>, #{}, initial)
                    end),
    Runner = adk_runner:new(
               TargetAgent, ?APP, erlang_adk_session,
               #{runtime_policy =>
                     #{agents => #{allow => [<<"other-agent">>]},
                       tools => #{allow => all}}}),
    try
        ?assertMatch(
           {error, {runtime_policy_denied,
                    #{<<"reason">> := <<"not_allowed">>}}},
           adk_runner:run(Runner, ?USER, SessionId, Secret)),
        receive {scripted_model_called, _, _} -> ?assert(false)
        after 30 -> ok
        end,
        Events = session_events(SessionId),
        ?assertEqual(1, length(audit_decisions(Events))),
        assert_no_binary(Secret, Events)
    after
        TargetAgent ! stop,
        cleanup_sessions([SessionId])
    end.

hitl_tool_denial_precedes_callbacks_and_pause_case() ->
    SessionId = unique(<<"hitl-policy-denied">>),
    Name = <<"hitl-policy-agent">>,
    Calls = [{<<"request_human_approval">>,
              #{<<"action_summary">> => <<"Delete production">>},
              <<"sig">>, <<"approval-call">>}],
    TestPid = self(),
    Agent = spawn(
              fun() -> scripted_agent_loop(
                         TestPid, Name, [adk_long_running_tool], Calls,
                         <<"denial handled">>, #{}, initial)
              end),
    Plugin = #{id => <<"tool-callback-probe">>,
               module => adk_plugin_test_plugin,
               config => #{test_pid => self(), label => policy_probe}},
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{runtime_policy =>
                     #{agents => #{allow => [Name]},
                       tools =>
                           #{allow => all,
                             deny => [<<"request_human_approval">>]}},
                 plugins => [Plugin],
                 run_timeout => 2000}),
    try
        ?assertEqual(
           {ok, <<"denial handled">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"dangerous">>)),
        PluginCalls = collect_plugin_calls([]),
        ?assertNot(lists:any(fun is_before_tool_plugin_value/1,
                             PluginCalls)),
        Events = session_events(SessionId),
        [Decision] = audit_decisions(Events),
        ?assertEqual(<<"tool_call">>,
                     maps:get(<<"operation">>, Decision)),
        ?assertEqual(<<"explicitly_denied">>,
                     maps:get(<<"reason">>, Decision)),
        ?assertEqual([], [Event || Event <- Events,
                                  Event#adk_event.author =:= <<"runner">>]),
        [ToolResponse] = tool_responses(Events),
        assert_policy_tool_error(ToolResponse)
    after
        Agent ! stop,
        cleanup_sessions([SessionId]),
        flush_plugin_calls()
    end.

dynamic_toolset_denial_precedes_live_resolution_case() ->
    SessionId = unique(<<"dynamic-policy-denied">>),
    Name = <<"dynamic-policy-agent">>,
    {ok, Toolset} = adk_toolset:new(
                      adk_test_toolset, {resolution_probe, self()}),
    Calls = [{<<"dynamic_echo">>, #{<<"text">> => <<"private">>},
              undefined, <<"dynamic-call">>}],
    TestPid = self(),
    TargetAgent = spawn(
                    fun() -> scripted_agent_loop(
                               TestPid, Name, [Toolset], Calls,
                               <<"dynamic denial handled">>, #{}, initial)
                    end),
    Runner = adk_runner:new(
               TargetAgent, ?APP, erlang_adk_session,
               #{runtime_policy =>
                     #{agents => #{allow => [Name]},
                       tools => #{allow => []}},
                 tool_execution =>
                     #{mode => parallel, max_concurrency => 2,
                       tool_timeout => 1000}}),
    try
        ?assertEqual(
           {ok, <<"dynamic denial handled">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"echo">>)),
        receive {dynamic_tool_resolved, _, _} -> ?assert(false)
        after 30 -> ok
        end,
        receive {dynamic_tool_executed, _, _, _} -> ?assert(false)
        after 30 -> ok
        end,
        [Decision] = audit_decisions(session_events(SessionId)),
        ?assertEqual(<<"dynamic_echo">>,
                     maps:get(<<"subject">>, Decision))
    after
        TargetAgent ! stop,
        cleanup_sessions([SessionId])
    end.

tool_output_budget_replaces_private_result_case() ->
    SessionId = unique(<<"tool-output-budget">>),
    Name = <<"tool-output-agent">>,
    Calls = [{<<"secret_output">>, #{}, undefined, <<"secret-call">>}],
    TestPid = self(),
    persistent_term:put({adk_runtime_safety_tool, target}, self()),
    Agent = spawn(
              fun() -> scripted_agent_loop(
                         TestPid, Name, [adk_runtime_safety_tool], Calls,
                         <<"safe final">>, #{}, initial)
              end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{runtime_policy =>
                     #{agents => #{allow => [Name]},
                       tools => #{allow => [<<"secret_output">>]},
                       max_content_bytes => 64}}),
    try
        ?assertEqual(
           {ok, <<"safe final">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"go">>)),
        receive runtime_safety_tool_executed -> ok
        after 1000 -> erlang:error(tool_not_executed)
        end,
        Events = session_events(SessionId),
        Decisions = audit_decisions(Events),
        ?assert(lists:any(
                  fun(Decision) ->
                      maps:get(<<"subject">>, Decision) =:=
                          <<"tool_result">> andalso
                      maps:get(<<"reason">>, Decision) =:=
                          <<"content_budget_exceeded">>
                  end, Decisions)),
        assert_no_binary(<<"private-tool-output-">>, Events),
        [ToolResponse] = tool_responses(Events),
        assert_policy_tool_error(ToolResponse)
    after
        Agent ! stop,
        persistent_term:erase({adk_runtime_safety_tool, target}),
        cleanup_sessions([SessionId])
    end.

final_output_budget_prevents_raw_persistence_case() ->
    SessionId = unique(<<"final-output-budget">>),
    Name = <<"final-output-agent">>,
    PrivateOutput = <<"private-final-output">>,
    TestPid = self(),
    Agent = spawn(
              fun() -> scripted_agent_loop(
                         TestPid, Name, [], [], PrivateOutput,
                         #{}, initial)
              end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{runtime_policy =>
                     #{agents => #{allow => [Name]},
                       tools => #{allow => all},
                       max_content_bytes => 4}}),
    try
        ?assertMatch(
           {error, {runtime_policy_denied,
                    #{<<"reason">> :=
                          <<"content_budget_exceeded">>}}},
           adk_runner:run(Runner, ?USER, SessionId, <<"go">>)),
        Events = session_events(SessionId),
        assert_no_binary(PrivateOutput, Events),
        ?assert(lists:any(
                  fun(Decision) ->
                      maps:get(<<"subject">>, Decision) =:=
                          <<"model_output">>
                  end, audit_decisions(Events)))
    after
        Agent ! stop,
        cleanup_sessions([SessionId])
    end.

blocking_agent_loop(TestPid) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"admission-agent">>, #{}, [], #{}}),
            blocking_agent_loop(TestPid);
        {'$gen_call', From, {run_with_events, _History, _InvId}} ->
            TestPid ! {blocking_model_entered, element(1, From), From},
            blocking_agent_loop(TestPid);
        stop -> ok;
        _ -> blocking_agent_loop(TestPid)
    end.

scripted_agent_loop(TestPid, Name, Tools, Calls, Final, Config, Stage) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, Config, Tools, #{}}),
            scripted_agent_loop(TestPid, Name, Tools, Calls,
                                Final, Config, Stage);
        {'$gen_call', From, {run_with_events, History, InvId}} ->
            TestPid ! {scripted_model_called, Stage, History},
            case {Stage, Calls} of
                {initial, [_ | _]} ->
                    Event = adk_event:new(
                              Name, {tool_calls, Calls},
                              #{invocation_id => InvId}),
                    gen_server:reply(From, {tool_calls, Event, Calls}),
                    scripted_agent_loop(TestPid, Name, Tools, Calls,
                                        Final, Config, after_tool);
                _ ->
                    Event = adk_event:new(
                              Name, Final,
                              #{invocation_id => InvId, is_final => true}),
                    gen_server:reply(From, {ok, Event}),
                    scripted_agent_loop(TestPid, Name, Tools, Calls,
                                        Final, Config, complete)
            end;
        stop -> ok;
        _ -> scripted_agent_loop(TestPid, Name, Tools, Calls,
                                 Final, Config, Stage)
    end.

wait_status(Server, Predicate) ->
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    wait_status(Server, Predicate, Deadline).

wait_status(Server, Predicate, Deadline) ->
    {ok, Status} = adk_admission_control:status(Server),
    case Predicate(Status) of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error({status_timeout, Status});
                false -> receive after 5 -> ok end,
                         wait_status(Server, Predicate, Deadline)
            end
    end.

session_events(SessionId) ->
    {ok, Session} = erlang_adk_session:get_session(
                      ?APP, ?USER, SessionId),
    maps:get(events, Session).

audit_decisions(Events) ->
    [Decision || #adk_event{actions = Actions} <- Events,
                 {ok, Decision} <-
                     [maps:find(<<"runtime_policy_decision">>, Actions)]].

tool_responses(Events) ->
    [Result || #adk_event{content = Content} <- Events,
               Result <- tool_response_result(Content)].

tool_response_result({tool_response, _Name, Result}) -> [Result];
tool_response_result({tool_response, _Name, Result, _Sig}) -> [Result];
tool_response_result({tool_response, _Name, Result, _Sig, _CallId}) -> [Result];
tool_response_result(_) -> [].

assert_policy_tool_error(Result) ->
    ?assertMatch(
       #{<<"success">> := false,
         <<"error">> :=
             #{<<"kind">> := <<"runtime_policy_denied">>}},
       Result).

assert_no_binary(Binary, Value) ->
    Encoded = iolist_to_binary(
                [case adk_event:encode(Event) of
                     {ok, Map} -> jsx:encode(Map)
                 end || Event <- Value]),
    ?assertEqual(nomatch, binary:match(Encoded, Binary)).

is_before_tool_plugin_value(
  {plugin_called, policy_probe, _Context,
   #{name := <<"request_human_approval">>}}) -> true;
is_before_tool_plugin_value(_) -> false.

collect_plugin_calls(Acc) ->
    receive
        {plugin_called, _, _, _} = Message ->
            collect_plugin_calls([Message | Acc])
    after 20 -> lists:reverse(Acc)
    end.

flush_plugin_calls() ->
    _ = collect_plugin_calls([]),
    ok.

cleanup_sessions(SessionIds) ->
    lists:foreach(
      fun(SessionId) ->
          _ = erlang_adk_session:delete_session(
                ?APP, ?USER, SessionId)
      end, SessionIds).

unique(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(
         erlang:unique_integer([positive, monotonic])))/binary>>.
