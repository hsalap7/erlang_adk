-module(adk_tool_confirmation_test).

-include_lib("eunit/include/eunit.hrl").
-include("adk_event.hrl").

-export([on_tool_start/2, before_tool/3, after_tool/4, on_tool_end/2]).

-define(APP, <<"tool-confirmation-app">>).
-define(USER, <<"tool-confirmation-user">>).

tool_confirmation_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun static_approval_executes_once_after_callbacks_case/0,
      fun rejection_skips_callbacks_and_execution_case/0,
      fun invalid_stable_resume_preserves_single_use_continuation_case/0,
      fun conditional_false_executes_without_pause_case/0,
      fun malformed_args_and_policy_denial_bypass_confirmation_case/0,
      fun confirmation_evaluation_failure_fails_closed_case/0,
      fun confirmation_is_parallel_barrier_case/0,
      fun approval_reresolves_dynamic_catalog_case/0,
      fun resolved_module_cannot_weaken_confirmation_case/0,
      fun approved_tool_can_enter_second_long_running_pause_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_Setup) ->
    persistent_term:erase({?MODULE, target}),
    persistent_term:erase({adk_runner_parallel_tool, target}),
    flush_probe_messages(),
    ok.

static_approval_executes_once_after_callbacks_case() ->
    enable_probes(),
    SessionId = unique(<<"static-approve">>),
    SecretId = <<"private-release-731">>,
    Call = {<<"static_confirmation_probe">>, #{<<"id">> => SecretId},
            <<"static-sig">>, <<"static-call">>},
    Plugin = probe_plugin(),
    {Agent, Runner} = start_agent(
                        [Call], [adk_static_confirmation_tool],
                        #{callbacks => [?MODULE]}, #{plugins => [Plugin]}),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, SessionId, <<"confirm static">>),
        Pause = await_pause(Stream),
        Details = pause_details(Pause),
        ?assertEqual(<<"tool_confirmation">>,
                     maps:get(<<"type">>, Details)),
        ActionId = maps:get(<<"action_id">>, Details),
        ?assertEqual(nomatch, binary:match(ActionId, SecretId)),
        assert_no_lifecycle_or_execution(),
        ?assertEqual([], tool_plugin_calls(collect_plugin_calls([]))),

        {ok, Resumed} = adk_runner:resume(
                          Runner, ?USER, SessionId,
                          Pause#adk_event.invocation_id,
                          #{confirmed => true}),
        ok = await_done(Resumed),
        ?assertEqual(
           [{on_tool_start, <<"static_confirmation_probe">>},
            {before_tool, <<"static_confirmation_probe">>},
            {executed, static, SecretId},
            {after_tool, <<"static_confirmation_probe">>},
            {on_tool_end, <<"static_confirmation_probe">>}],
           collect_lifecycle(5, [])),
        ?assertEqual(2,
                     length(tool_plugin_calls(collect_plugin_calls([])))),
        ?assertEqual(
           {error, no_paused_invocation},
           adk_runner:resume(
             Runner, ?USER, SessionId,
             Pause#adk_event.invocation_id, #{<<"confirmed">> => true})),
        [Response] = tool_responses(SessionId),
        ?assertEqual(<<"static-call">>, response_call_id(Response)),
        ?assertEqual(true, response_success(Response))
    after
        stop_case(Agent, SessionId)
    end.

rejection_skips_callbacks_and_execution_case() ->
    enable_probes(),
    SessionId = unique(<<"reject">>),
    Id = <<"reject-side-effect">>,
    Call = conditional_call(Id, true, <<"success">>, <<"reject-call">>),
    Plugin = probe_plugin(),
    {Agent, Runner} = start_agent(
                        [Call], [adk_conditional_confirmation_tool],
                        #{callbacks => [?MODULE]}, #{plugins => [Plugin]}),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, SessionId, <<"reject it">>),
        Pause = await_pause(Stream),
        Details = pause_details(Pause),
        ActionId = maps:get(<<"action_id">>, Details),
        receive
            {confirmation_checked, Id, ConfirmationContext} ->
                ?assertMatch([_RootName],
                             maps:get('$adk_agent_path',
                                      ConfirmationContext))
        after 1000 -> error(confirmation_not_checked)
        end,
        assert_no_confirmation_check(Id),
        assert_no_lifecycle_or_execution(),
        ?assertEqual([], tool_plugin_calls(collect_plugin_calls([]))),

        ?assertEqual(
           {error, invalid_tool_confirmation_response},
           adk_runner:resume(
             Runner, ?USER, SessionId,
             Pause#adk_event.invocation_id,
             #{<<"confirmed">> => <<"no">>})),
        assert_no_lifecycle_or_execution(),

        {ok, Resumed} = adk_runner:resume(
                          Runner, ?USER, SessionId,
                          Pause#adk_event.invocation_id,
                          #{<<"confirmed">> => false}),
        ok = await_done(Resumed),
        assert_no_lifecycle_or_execution(),
        ?assertEqual([], tool_plugin_calls(collect_plugin_calls([]))),
        [Response] = tool_responses(SessionId),
        Result = response_result(Response),
        ?assertEqual(false, maps:get(<<"success">>, Result)),
        ?assertEqual(
           #{<<"kind">> => <<"tool_confirmation_rejected">>,
             <<"action_id">> => ActionId},
           maps:get(<<"error">>, Result))
    after
        stop_case(Agent, SessionId)
    end.

invalid_stable_resume_preserves_single_use_continuation_case() ->
    enable_probes(),
    SessionId = unique(<<"stable-invalid">>),
    Id = <<"stable-static">>,
    Call = {<<"static_confirmation_probe">>, #{<<"id">> => Id},
            undefined, <<"stable-call">>},
    {Agent, Runner} = start_agent(
                        [Call], [adk_static_confirmation_tool], #{}, #{}),
    try
        {ok, PausedRun} = adk_run:start(
                            Runner, ?USER, SessionId,
                            <<"stable confirmation">>,
                            #{retention_ms => 3000}),
        {paused, _Pause} = adk_run:await(PausedRun, 2000),
        ?assertEqual(
           {error, invalid_tool_confirmation_response},
           adk_run:resume(
             PausedRun, #{<<"confirmed">> => <<"yes">>},
             #{retention_ms => 3000})),
        {ok, StillPaused} = adk_run:status(PausedRun),
        ?assertEqual(undefined, maps:get(resumed_to, StillPaused)),
        assert_no_lifecycle_or_execution(),

        {ok, ResumedRun} = adk_run:resume(
                             PausedRun, #{<<"confirmed">> => true},
                             #{retention_ms => 3000}),
        ?assertEqual({completed, <<"confirmation batch complete">>},
                     adk_run:await(ResumedRun, 2000)),
        receive
            {confirmation_tool_executed, static, Id, _Pid, _Context} -> ok
        after 1000 -> error(approved_tool_not_executed)
        end,
        receive
            {confirmation_tool_executed, static, Id, _Pid2, _Context2} ->
                error(duplicate_tool_execution)
        after 30 -> ok
        end,
        ?assertEqual(
           {error, {already_resumed, ResumedRun}},
           adk_run:resume(PausedRun, #{<<"confirmed">> => true}))
    after
        stop_case(Agent, SessionId)
    end.

conditional_false_executes_without_pause_case() ->
    enable_probes(),
    SessionId = unique(<<"conditional-false">>),
    Id = <<"read-only-call">>,
    Call = conditional_call(Id, false, <<"success">>, <<"read-call">>),
    {Agent, Runner} = start_agent(
                        [Call], [adk_conditional_confirmation_tool], #{}, #{}),
    try
        ?assertEqual(
           {ok, <<"confirmation batch complete">>},
           adk_runner:run(
             Runner, ?USER, SessionId, <<"no confirmation needed">>)),
        receive {confirmation_checked, Id, _} -> ok
        after 1000 -> error(conditional_callback_not_called)
        end,
        receive
            {confirmation_tool_executed, conditional, Id, _Pid, _Context} -> ok
        after 1000 -> error(conditional_tool_not_executed)
        end
    after
        stop_case(Agent, SessionId)
    end.

malformed_args_and_policy_denial_bypass_confirmation_case() ->
    enable_probes(),
    InvalidSession = unique(<<"invalid-args">>),
    InvalidCall =
        {<<"conditional_confirmation_probe">>,
         #{<<"confirm">> => true}, undefined, <<"invalid-call">>},
    {InvalidAgent, InvalidRunner} = start_agent(
                                      [InvalidCall],
                                      [adk_conditional_confirmation_tool],
                                      #{callbacks => [?MODULE]}, #{}),
    try
        ?assertEqual(
           {ok, <<"confirmation batch complete">>},
           adk_runner:run(
             InvalidRunner, ?USER, InvalidSession, <<"invalid args">>)),
        assert_no_confirmation_or_tool_activity(),
        [InvalidResponse] = tool_responses(InvalidSession),
        ?assertEqual(
           <<"invalid_tool_arguments">>,
           maps:get(<<"type">>,
                    maps:get(<<"error">>,
                             response_result(InvalidResponse))))
    after
        stop_case(InvalidAgent, InvalidSession)
    end,

    PolicySession = unique(<<"policy-denied">>),
    Name = unique(<<"PolicyConfirmationAgent">>),
    Id = <<"policy-side-effect">>,
    PolicyCall = conditional_call(
                   Id, true, <<"success">>, <<"policy-call">>),
    Policy = #{agents => #{allow => [Name]},
               tools => #{allow => all,
                          deny => [<<"conditional_confirmation_probe">>]}},
    {PolicyAgent, PolicyRunner} = start_named_agent(
                                    Name, [PolicyCall],
                                    [adk_conditional_confirmation_tool],
                                    #{callbacks => [?MODULE]},
                                    #{runtime_policy => Policy}),
    try
        ?assertEqual(
           {ok, <<"confirmation batch complete">>},
           adk_runner:run(
             PolicyRunner, ?USER, PolicySession, <<"policy denied">>)),
        assert_no_confirmation_or_tool_activity(),
        [PolicyResponse] = tool_responses(PolicySession),
        ?assertEqual(
           <<"runtime_policy_denied">>,
           maps:get(<<"kind">>,
                    maps:get(<<"error">>,
                             response_result(PolicyResponse))))
    after
        stop_case(PolicyAgent, PolicySession)
    end.

confirmation_evaluation_failure_fails_closed_case() ->
    enable_probes(),
    SessionId = unique(<<"evaluation-failure">>),
    Id = <<"confirmation-error">>,
    Call = conditional_call(Id, true, <<"success">>, <<"error-call">>),
    {Agent, Runner} = start_agent(
                        [Call], [adk_conditional_confirmation_tool],
                        #{callbacks => [?MODULE]}, #{}),
    try
        ?assertEqual(
           {ok, <<"confirmation batch complete">>},
           adk_runner:run(
             Runner, ?USER, SessionId, <<"confirmation error">>)),
        receive {confirmation_checked, Id, _Context} -> ok
        after 1000 -> error(confirmation_not_checked)
        end,
        assert_no_lifecycle_or_execution(),
        [Response] = tool_responses(SessionId),
        ?assertEqual(
           <<"tool_confirmation_evaluation_failed">>,
           maps:get(<<"kind">>,
                    maps:get(<<"error">>, response_result(Response))))
    after
        stop_case(Agent, SessionId)
    end.

confirmation_is_parallel_barrier_case() ->
    enable_probes(),
    persistent_term:put({adk_runner_parallel_tool, target}, self()),
    SessionId = unique(<<"parallel-barrier">>),
    Calls = [parallel_call(<<"before">>, 5),
             conditional_call(
               <<"middle">>, true, <<"success">>, <<"confirm-middle">>),
             parallel_call(<<"after">>, 1)],
    RunnerOpts = #{tool_execution =>
                       #{mode => parallel, max_concurrency => 3,
                         tool_timeout => 1000}},
    {Agent, Runner} = start_agent(
                        Calls,
                        [adk_runner_parallel_tool,
                         adk_conditional_confirmation_tool],
                        #{}, RunnerOpts),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, SessionId, <<"parallel barrier">>),
        Pause = await_pause(Stream),
        receive {runner_tool_finished, <<"before">>, _Pid0} -> ok
        after 1000 -> error(before_tool_not_finished)
        end,
        ?assert(collect_confirmation_checks(<<"middle">>, 0) >= 1),
        receive
            {runner_tool_started, <<"after">>, _Pid1, _Context1} ->
                error(tool_started_past_confirmation_barrier)
        after 50 -> ok
        end,

        {ok, Resumed} = adk_runner:resume(
                          Runner, ?USER, SessionId,
                          Pause#adk_event.invocation_id,
                          #{<<"confirmed">> => true}),
        ok = await_done(Resumed),
        ?assertEqual(1,
                     collect_confirmation_checks(<<"middle">>, 0)),
        receive
            {confirmation_tool_executed, conditional, <<"middle">>,
             _ConfirmPid, _ConfirmContext} -> ok
        after 1000 -> error(confirmed_tool_not_executed)
        end,
        receive
            {runner_tool_started, <<"after">>, _AfterPid, _AfterContext} -> ok
        after 1000 -> error(tool_after_barrier_not_started)
        end,
        ?assertEqual(
           [<<"call-before">>, <<"confirm-middle">>, <<"call-after">>],
           [response_call_id(Response) || Response <-
                                            tool_responses(SessionId)])
    after
        persistent_term:erase({adk_runner_parallel_tool, target}),
        stop_case(Agent, SessionId)
    end.

approval_reresolves_dynamic_catalog_case() ->
    enable_probes(),
    SessionId = unique(<<"catalog-drift">>),
    Catalog = spawn(fun() -> catalog_loop(<<"dynamic_echo">>) end),
    Confirmation = #{required => true,
                     hint => <<"Approve dynamic side effect">>},
    {ok, Toolset} = adk_toolset:new(
                      adk_test_toolset,
                      {mutable_confirmation, Catalog, self(), Confirmation}),
    Call = {<<"dynamic_echo">>, #{<<"text">> => <<"private-dynamic">>},
            undefined, <<"dynamic-confirm-call">>},
    {Agent, Runner} = start_agent([Call], [Toolset], #{}, #{}),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, SessionId, <<"dynamic approval">>),
        Pause = await_pause(Stream),
        ok = set_catalog_name(Catalog, <<"dynamic_echo_v2">>),
        {ok, Resumed} = adk_runner:resume(
                          Runner, ?USER, SessionId,
                          Pause#adk_event.invocation_id,
                          #{<<"confirmed">> => true}),
        ok = await_done(Resumed),
        receive
            {dynamic_tool_executed, _Pid, _Args, _Context} ->
                error(stale_resolved_call_executed)
        after 30 -> ok
        end,
        [Response] = tool_responses(SessionId),
        ?assertEqual(false, response_success(Response))
    after
        Catalog ! stop,
        stop_case(Agent, SessionId)
    end.

resolved_module_cannot_weaken_confirmation_case() ->
    enable_probes(),
    ok = adk_resolved_confirmation_tool:set_target(self()),
    SessionId = unique(<<"resolved-module-confirmation">>),
    Name = unique(<<"ResolvedModuleAgent">>),
    {ok, Toolset} = adk_toolset:new(
                      adk_test_toolset,
                      {resolved_module, self(),
                       adk_resolved_confirmation_tool, false}),
    Call = {<<"dynamic_echo">>, #{<<"text">> => <<"local-module">>},
            undefined, <<"resolved-module-call">>},
    {Agent, Runner} = start_named_agent(
                        Name, [Call], [Toolset], #{}, #{}),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, SessionId,
                         <<"resolved local module">>),
        Pause = await_pause(Stream),
        receive
            {resolved_module_resolved, _InitialArgs, ResolverContext} ->
                ?assertEqual(
                   false,
                   maps:is_key('$adk_agent_path', ResolverContext))
        after 1000 ->
            error(dynamic_module_not_resolved)
        end,
        receive
            {resolved_module_confirmation_checked, _ConfirmArgs,
             ConfirmationContext} ->
                ?assertEqual(
                   [Name], maps:get('$adk_agent_path',
                                    ConfirmationContext)),
                ?assertEqual(
                   erlang_adk_session,
                   maps:get(state_ref, ConfirmationContext))
        after 1000 ->
            error(resolved_module_confirmation_not_checked)
        end,
        receive
            {resolved_module_executed, _, _} ->
                error(unconfirmed_resolved_module_executed)
        after 30 -> ok
        end,

        {ok, Resumed} = adk_runner:resume(
                          Runner, ?USER, SessionId,
                          Pause#adk_event.invocation_id,
                          #{<<"confirmed">> => true}),
        ok = await_done(Resumed),
        receive
            {resolved_module_resolved, _ApprovedArgs,
             ApprovedResolverContext} ->
                ?assertEqual(
                   false,
                   maps:is_key('$adk_agent_path',
                               ApprovedResolverContext))
        after 1000 ->
            error(dynamic_module_not_reresolved)
        end,
        receive
            {resolved_module_confirmation_checked, _ApprovedConfirmArgs,
             ApprovedConfirmationContext} ->
                ?assertEqual(
                   [Name], maps:get('$adk_agent_path',
                                    ApprovedConfirmationContext))
        after 1000 ->
            error(resolved_module_confirmation_not_rechecked)
        end,
        receive
            {resolved_module_executed, _ExecutionArgs, ExecutionContext} ->
                ?assertEqual(
                   [Name], maps:get('$adk_agent_path', ExecutionContext)),
                ?assertEqual(
                   erlang_adk_session, maps:get(state_ref,
                                                ExecutionContext))
        after 1000 ->
            error(approved_resolved_module_not_executed)
        end
    after
        ok = adk_resolved_confirmation_tool:clear_target(),
        stop_case(Agent, SessionId)
    end.

approved_tool_can_enter_second_long_running_pause_case() ->
    enable_probes(),
    SessionId = unique(<<"second-pause">>),
    Id = <<"long">>,
    Call = conditional_call(
             Id, true, <<"long_running">>, <<"long-confirm-call">>),
    {Agent, Runner} = start_agent(
                        [Call], [adk_conditional_confirmation_tool],
                        #{callbacks => [?MODULE]}, #{}),
    try
        {ok, Stream} = adk_runner:run_async(
                         Runner, ?USER, SessionId, <<"start long tool">>),
        FirstPause = await_pause(Stream),
        ?assertEqual(<<"tool_confirmation">>,
                     maps:get(<<"type">>, pause_details(FirstPause))),
        receive {confirmation_checked, Id, _} -> ok
        after 1000 -> error(confirmation_not_checked)
        end,

        {ok, ApprovedStream} = adk_runner:resume(
                                 Runner, ?USER, SessionId,
                                 FirstPause#adk_event.invocation_id,
                                 #{<<"confirmed">> => true}),
        SecondPause = await_pause(ApprovedStream),
        SecondDetails = pause_details(SecondPause),
        OperationId = <<"confirmation-op-", Id/binary>>,
        ?assertEqual(<<"long_running">>,
                     maps:get(<<"type">>, SecondDetails)),
        ?assertEqual(OperationId,
                     maps:get(<<"operation_id">>, SecondDetails)),
        ?assertEqual([], tool_responses(SessionId)),
        ?assertEqual(
           [{on_tool_start, <<"conditional_confirmation_probe">>},
            {before_tool, <<"conditional_confirmation_probe">>},
            {executed, conditional, Id}],
           collect_lifecycle(3, [])),
        assert_no_after_callbacks(),

        Completion = #{<<"operation_id">> => OperationId,
                       <<"status">> => <<"completed">>,
                       <<"result">> => #{<<"published">> => true}},
        {ok, CompletedStream} = adk_runner:resume(
                                  Runner, ?USER, SessionId,
                                  SecondPause#adk_event.invocation_id,
                                  Completion),
        ok = await_done(CompletedStream),
        ?assertEqual(
           [{after_tool, <<"conditional_confirmation_probe">>},
            {on_tool_end, <<"conditional_confirmation_probe">>}],
           collect_lifecycle(2, [])),
        [_Response] = tool_responses(SessionId),
        receive
            {confirmation_tool_executed, conditional, Id, _Pid, _Context} ->
                error(duplicate_long_running_execution)
        after 30 -> ok
        end
    after
        stop_case(Agent, SessionId)
    end.

on_tool_start(Name, _Args) ->
    notify({tool_lifecycle, on_tool_start, Name}),
    ok.

before_tool(Name, _Args, _Context) ->
    notify({tool_lifecycle, before_tool, Name}),
    continue.

after_tool(Name, _Args, _Context, _Result) ->
    notify({tool_lifecycle, after_tool, Name}),
    continue.

on_tool_end(Name, _Result) ->
    notify({tool_lifecycle, on_tool_end, Name}),
    ok.

notify(Message) ->
    case persistent_term:get({?MODULE, target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.

enable_probes() ->
    flush_probe_messages(),
    persistent_term:put({?MODULE, target}, self()),
    ok.

probe_plugin() ->
    #{id => <<"confirmation-plugin-probe">>,
      module => adk_plugin_test_plugin,
      config => #{test_pid => self(), label => confirmation_plugin}}.

collect_plugin_calls(Acc) ->
    receive
        {plugin_called, confirmation_plugin, _Context, _Value} = Message ->
            collect_plugin_calls([Message | Acc])
    after 30 -> lists:reverse(Acc)
    end.

tool_plugin_calls(Messages) ->
    [Message || Message =
                    {plugin_called, confirmation_plugin,
                     #{<<"tool">> := _Tool}, _Value} <- Messages].

start_agent(Calls, Tools, Config, RunnerOpts) ->
    start_named_agent(unique(<<"ConfirmationAgent">>), Calls, Tools,
                      Config, RunnerOpts).

start_named_agent(Name, Calls, Tools, Config, RunnerOpts) ->
    Agent = spawn(
              fun() -> agent_loop(Name, Calls, Tools, Config, initial) end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               maps:merge(#{run_timeout => 3000}, RunnerOpts)),
    {Agent, Runner}.

agent_loop(Name, Calls, Tools, Config, Stage) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(From, {ok, Name, Config, Tools, #{}}),
            agent_loop(Name, Calls, Tools, Config, Stage);
        {'$gen_call', From, {run_with_events, _History, InvocationId}}
          when Stage =:= initial ->
            Event = adk_event:new(
                      Name, {tool_calls, Calls},
                      #{invocation_id => InvocationId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            agent_loop(Name, Calls, Tools, Config, waiting);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      Name, <<"confirmation batch complete">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            agent_loop(Name, Calls, Tools, Config, complete);
        stop ->
            ok;
        _Other ->
            agent_loop(Name, Calls, Tools, Config, Stage)
    end.

conditional_call(Id, Confirm, Mode, CallId) ->
    {<<"conditional_confirmation_probe">>,
     #{<<"id">> => Id, <<"confirm">> => Confirm, <<"mode">> => Mode},
     <<"conditional-signature">>, CallId}.

parallel_call(Id, Delay) ->
    {<<"parallel_probe">>,
     #{<<"id">> => Id, <<"delay">> => Delay, <<"mode">> => <<"success">>},
     <<"parallel-signature">>, <<"call-", Id/binary>>}.

pause_details(Pause) ->
    PublicPause = maps:get(<<"pause">>, Pause#adk_event.actions),
    maps:get(<<"details">>, PublicPause).

await_pause(Stream) ->
    receive
        {adk_event, Stream, _Event} -> await_pause(Stream);
        {adk_paused, Stream, Pause} -> Pause;
        {adk_error, Stream, Reason} -> error({unexpected_runner_error, Reason})
    after 2000 ->
        error(pause_timeout)
    end.

await_done(Stream) ->
    receive
        {adk_event, Stream, _Event} -> await_done(Stream);
        {adk_done, Stream} -> ok;
        {adk_paused, Stream, Pause} -> error({unexpected_pause, Pause});
        {adk_error, Stream, Reason} -> error({unexpected_runner_error, Reason})
    after 2000 ->
        error(done_timeout)
    end.

collect_lifecycle(0, Acc) -> lists:reverse(Acc);
collect_lifecycle(Remaining, Acc) ->
    receive
        {tool_lifecycle, Hook, Name} ->
            collect_lifecycle(Remaining - 1, [{Hook, Name} | Acc]);
        {confirmation_tool_executed, Kind, Id, _Pid, _Context} ->
            collect_lifecycle(Remaining - 1,
                              [{executed, Kind, Id} | Acc])
    after 1000 ->
        error({lifecycle_timeout, Remaining, lists:reverse(Acc)})
    end.

assert_no_lifecycle_or_execution() ->
    receive
        {tool_lifecycle, _Hook, _Name} -> error(unexpected_tool_callback);
        {confirmation_tool_executed, _Kind, _Id, _Pid, _Context} ->
            error(unexpected_tool_execution)
    after 30 -> ok
    end.

assert_no_confirmation_or_tool_activity() ->
    receive
        {confirmation_checked, _Id, _Context} ->
            error(unexpected_confirmation_check);
        {tool_lifecycle, _Hook, _Name} ->
            error(unexpected_tool_callback);
        {confirmation_tool_executed, _Kind, _Id, _Pid, _Context} ->
            error(unexpected_tool_execution)
    after 30 -> ok
    end.

assert_no_confirmation_check(Id) ->
    receive
        {confirmation_checked, Id, _Context} ->
            error(duplicate_confirmation_check)
    after 30 -> ok
    end.

collect_confirmation_checks(Id, Count) ->
    receive
        {confirmation_checked, Id, _Context} ->
            collect_confirmation_checks(Id, Count + 1)
    after 30 -> Count
    end.

assert_no_after_callbacks() ->
    receive
        {tool_lifecycle, after_tool, _Name} ->
            error(unexpected_after_tool_before_completion);
        {tool_lifecycle, on_tool_end, _Name} ->
            error(unexpected_on_tool_end_before_completion)
    after 30 -> ok
    end.

tool_responses(SessionId) ->
    {ok, Session} = erlang_adk_session:get_session(
                      ?APP, ?USER, SessionId),
    [Event || Event = #adk_event{author = <<"tool">>} <-
                  maps:get(events, Session, [])].

response_result(#adk_event{content =
                               {tool_response, _Name, Result,
                                _Signature, _CallId}}) -> Result;
response_result(#adk_event{content =
                               {tool_response, _Name, Result,
                                _Signature}}) -> Result.

response_call_id(#adk_event{content =
                                {tool_response, _Name, _Result,
                                 _Signature, CallId}}) -> CallId.

response_success(Response) ->
    maps:get(<<"success">>, response_result(Response)).

catalog_loop(Name) ->
    receive
        {get_catalog_name, From, Ref} ->
            From ! {catalog_name, Ref, Name},
            catalog_loop(Name);
        {set_catalog_name, From, Ref, NextName} ->
            From ! {catalog_name_set, Ref},
            catalog_loop(NextName);
        stop -> ok
    end.

set_catalog_name(Catalog, Name) ->
    Ref = make_ref(),
    Catalog ! {set_catalog_name, self(), Ref, Name},
    receive {catalog_name_set, Ref} -> ok
    after 1000 -> error(catalog_update_timeout)
    end.

stop_case(Agent, SessionId) ->
    Agent ! stop,
    _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId),
    persistent_term:erase({?MODULE, target}),
    flush_probe_messages(),
    ok.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, Suffix/binary>>.

flush_probe_messages() ->
    receive
        {tool_lifecycle, _Hook, _Name} -> flush_probe_messages();
        {confirmation_checked, _Id, _Context} -> flush_probe_messages();
        {confirmation_tool_executed, _Kind, _Id, _Pid, _Context} ->
            flush_probe_messages();
        {runner_tool_started, _Id, _Pid, _Context} -> flush_probe_messages();
        {runner_tool_finished, _Id, _Pid} -> flush_probe_messages();
        {dynamic_tool_executed, _Pid, _Args, _Context} ->
            flush_probe_messages();
        {resolved_module_resolved, _Args, _Context} ->
            flush_probe_messages();
        {resolved_module_confirmation_checked, _Args, _Context} ->
            flush_probe_messages();
        {resolved_module_executed, _Args, _Context} ->
            flush_probe_messages();
        {plugin_called, confirmation_plugin, _Context, _Value} ->
            flush_probe_messages()
    after 0 -> ok
    end.
