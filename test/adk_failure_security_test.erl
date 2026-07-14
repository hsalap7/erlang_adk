-module(adk_failure_security_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-export([explode/1]).

-define(APP, <<"failure-security-app">>).
-define(USER, <<"failure-security-user">>).

failure_security_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun structural_failure_never_retains_seed/0,
      fun large_failure_map_is_bounded/0,
      fun callback_view_is_allowlist_based/0,
      fun provider_atom_error_is_preserved_but_body_is_not/0,
      fun callback_logger_never_receives_exception_data/0,
      fun task_supervisor_and_status_hide_work/0,
      fun task_handoff_rejects_wrong_and_duplicate_identity/0,
      fun provider_failure_is_absent_from_runtime_callback_plugin_and_api/0,
      fun tool_failure_is_absent_from_callbacks_plugins_events_and_model_response/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    flush_messages(),
    ok.

cleanup(_) ->
    adk_failure_security_callback:clear_observer(),
    persistent_term:erase({adk_failure_security_tool, seed}),
    _ = logger:remove_handler(adk_failure_capture),
    case ets:whereis(adk_sessions) of
        undefined -> ok;
        _ -> ets:delete_all_objects(adk_sessions)
    end,
    flush_messages().

structural_failure_never_retains_seed() ->
    Seed = seed(),
    Failure = adk_failure:exception(
                provider, request, error,
                {http_error, 503,
                 #{body => <<"prefix-", Seed/binary>>,
                   request_id => <<"request-safe-1">>,
                   authorization => Seed}}),
    assert_seed_absent(Seed, Failure),
    {adk_failure, Metadata} = Failure,
    ?assertEqual(provider, maps:get(component, Metadata)),
    ?assertEqual(request, maps:get(operation, Metadata)),
    ?assertEqual(error, maps:get(class, Metadata)),
    ?assertEqual(http_error, maps:get(reason, Metadata)),
    ?assertEqual(503, maps:get(status, Metadata)),
    Correlation = maps:get(correlation, Metadata),
    Fingerprint = maps:get(request_id, Correlation),
    ?assertEqual(24, byte_size(Fingerprint)),
    ?assertNotEqual(<<"request-safe-1">>, Fingerprint),
    assert_seed_absent(
      Seed, adk_failure:model_response(provider, request, Failure)).

large_failure_map_is_bounded() ->
    Seed = seed(),
    Large = maps:from_list(
              [{Index, #{payload => <<Seed/binary, Index:32>>}}
               || Index <- lists:seq(1, 20000)]),
    Started = erlang:monotonic_time(millisecond),
    Failure = adk_failure:external(provider, oversized_body, Large),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    assert_seed_absent(Seed, Failure),
    ?assert(byte_size(term_to_binary(Failure)) < 512),
    %% The classifier touches at most a fixed number of entries at each depth.
    ?assert(Elapsed < 1000).

callback_view_is_allowlist_based() ->
    Seed = seed(),
    PrivateRef = make_ref(),
    Config = #{provider => adk_llm_probe,
               model => <<"safe-model">>, temperature => 0.2,
               api_key => Seed, callback_pid => self(),
               credential_store => {secret_store, Seed},
               http_client => self(), private_ref => PrivateRef,
               arbitrary_provider_body => Seed,
               callback_config =>
                   #{action => halt, api_key => Seed,
                     observer_pid => self(), safe_flag => true}},
    View = adk_callback_view:config(Config),
    ?assertEqual(adk_llm_probe, maps:get(provider, View)),
    ?assertEqual(<<"safe-model">>, maps:get(model, View)),
    ?assertEqual(0.2, maps:get(temperature, View)),
    ?assertNot(maps:is_key(api_key, View)),
    ?assertNot(maps:is_key(callback_pid, View)),
    ?assertNot(maps:is_key(credential_store, View)),
    ?assertNot(maps:is_key(http_client, View)),
    ?assertNot(maps:is_key(private_ref, View)),
    CallbackConfig = maps:get(callback_config, View),
    ?assertEqual(halt, maps:get(action, CallbackConfig)),
    ?assertEqual(true, maps:get(safe_flag, CallbackConfig)),
    ?assertNot(maps:is_key(api_key, CallbackConfig)),
    ?assertNot(maps:is_key(observer_pid, CallbackConfig)),
    assert_seed_absent(Seed, View).

provider_atom_error_is_preserved_but_body_is_not() ->
    ?assertEqual(
       {error, missing_api_key},
       adk_llm:generate(
         #{provider => adk_llm_probe, mode => error,
           reason => missing_api_key}, [], [])),
    Seed = seed(),
    Compound = adk_llm:generate(
                 #{provider => adk_llm_probe, mode => error,
                   reason => {http_error, 500, Seed}}, [], []),
    ?assertMatch({error, {adk_failure, _}}, Compound),
    assert_seed_absent(Seed, Compound).

callback_logger_never_receives_exception_data() ->
    Seed = seed(),
    ok = logger:add_handler(
           adk_failure_capture, adk_failure_test_logger,
           #{level => all, config => #{observer => self()}}),
    ?assertEqual(continue,
                 adk_callbacks:run([?MODULE], explode, [Seed])),
    Log = receive
        {captured_log, Event} -> Event
    after 1000 ->
        error(callback_log_missing)
    end,
    assert_seed_absent(Seed, Log),
    ok = logger:remove_handler(adk_failure_capture).

explode(Seed) ->
    erlang:error({callback_seed, Seed, #{body => Seed}}).

task_supervisor_and_status_hide_work() ->
    Seed = seed(),
    Parent = self(),
    Work = fun() ->
        _Captured = Seed,
        Parent ! {security_task_started, self()},
        receive never -> ok end
    end,
    {ok, TaskRef} = adk_task:start(
                      Work, #{retention_ms => 1000}),
    receive {security_task_started, _Execution} -> ok
    after 1000 -> error(task_not_started)
    end,
    {ok, Worker} = adk_task_registry:lookup(TaskRef),
    {ok, ChildSpec} = supervisor:get_childspec(adk_task_sup, TaskRef),
    #{start := {adk_task_worker, start_link, StartArgs}} = ChildSpec,
    %% OTP may replace completed dynamic child arguments with `undefined'.
    %% Neither representation can contain the work closure or options.
    ?assert(StartArgs =:= [TaskRef] orelse StartArgs =:= undefined),
    assert_seed_absent(Seed, ChildSpec),
    Status = sys:get_status(Worker),
    assert_seed_absent(Seed, Status),
    ok = adk_task:cancel(TaskRef, {cancel_body, Seed}),
    Outcome = adk_task:await(TaskRef, 1000),
    assert_seed_absent(Seed, Outcome).

task_handoff_rejects_wrong_and_duplicate_identity() ->
    TaskRef = <<"manual-security-task">>,
    WrongRef = <<"wrong-security-task">>,
    {ok, Worker} = adk_task_worker:start_link(TaskRef),
    Opts = #{deadline => infinity, retention_ms => 1000,
             notify => undefined, owner => undefined,
             cancel_on_owner_down => false},
    ?assertEqual(
       {error, invalid_task_handoff},
       adk_task_worker:handoff(Worker, WrongRef, fun() -> ok end, Opts)),
    ?assertEqual(
       {error, invalid_task_handoff},
       adk_task_worker:handoff(Worker, TaskRef, not_work, Opts)),
    ok = adk_task_worker:handoff(
           Worker, TaskRef,
           fun() -> receive never -> ok end end, Opts),
    ?assertEqual(
       {error, handoff_already_completed},
       adk_task_worker:handoff(Worker, TaskRef, fun() -> ok end, Opts)),
    ok = gen_statem:call(Worker, {cancel, test_complete}, 1000),
    unlink(Worker).

provider_failure_is_absent_from_runtime_callback_plugin_and_api() ->
    Seed = seed(),
    ok = adk_failure_security_callback:set_observer(self()),
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"FailureSecurityProviderAgent">>,
                    #{provider => adk_llm_probe, mode => error,
                      reason => {http_error, 503,
                                 #{body => Seed, authorization => Seed}},
                      api_key => Seed, callback_pid => self(),
                      private_ref => make_ref(),
                      callback_config => #{safe_flag => true,
                                           api_key => Seed},
                      callbacks => [adk_failure_security_callback]}, []),
    Plugin = plugin_descriptor(),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{plugins => [Plugin]}),
    try
        {ok, _Name, RuntimeConfig, _Tools, _SubAgents} =
            adk_agent:get_runtime(Agent),
        assert_seed_absent(Seed, RuntimeConfig),
        ?assertNot(maps:is_key(api_key, RuntimeConfig)),
        Result = adk_runner:run(
                   Runner, ?USER, <<"provider-session">>, <<"hello">>),
        ?assertMatch({error, {adk_failure, _}}, Result),
        assert_seed_absent(Seed, Result),
        CallbackConfig = receive_matching(
                           fun({security_callback, before_model, Value}) ->
                                   {ok, Value};
                              (_) -> false
                           end),
        ?assertNot(maps:is_key(api_key, CallbackConfig)),
        assert_seed_absent(Seed, CallbackConfig),
        CallbackFailure = receive_matching(
                            fun({security_callback, on_error, Value}) ->
                                    {ok, Value};
                               (_) -> false
                            end),
        assert_seed_absent(Seed, CallbackFailure),
        PluginFailure = receive_matching(
                          fun({security_plugin, on_model_error, Value}) ->
                                  {ok, Value};
                             (_) -> false
                          end),
        assert_seed_absent(Seed, PluginFailure)
    after
        _ = catch erlang_adk:stop_agent(Agent)
    end.

tool_failure_is_absent_from_callbacks_plugins_events_and_model_response() ->
    Seed = seed(),
    persistent_term:put({adk_failure_security_tool, seed}, Seed),
    ok = adk_failure_security_callback:set_observer(self()),
    {ok, Agent} = erlang_adk:spawn_agent(
                    <<"FailureSecurityToolAgent">>,
                    #{provider => adk_llm_probe, mode => tool_call,
                      call_name => <<"secret_failure_tool">>,
                      call_args => #{}, response => <<"done">>,
                      callbacks => [adk_failure_security_callback]},
                    [adk_failure_security_tool]),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{plugins => [plugin_descriptor()]}),
    SessionId = <<"tool-session">>,
    try
        ?assertEqual(
           {ok, <<"done">>},
           adk_runner:run(Runner, ?USER, SessionId, <<"use tool">>)),
        CallbackValue = receive_matching(
                          fun({security_callback, on_tool_end, Value}) ->
                                  {ok, Value};
                             (_) -> false
                          end),
        assert_seed_absent(Seed, CallbackValue),
        PluginValue = receive_matching(
                        fun({security_plugin, on_tool_error, Value}) ->
                                {ok, Value};
                           (_) -> false
                        end),
        assert_seed_absent(Seed, PluginValue),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        Events = maps:get(events, Session),
        assert_seed_absent(Seed, Events),
        ToolEvents = [Event || Event = #adk_event{author = <<"tool">>}
                                   <- Events],
        ?assertEqual(1, length(ToolEvents))
    after
        _ = catch erlang_adk:stop_agent(Agent),
        _ = erlang_adk_session:delete_session(
              ?APP, ?USER, SessionId)
    end.

plugin_descriptor() ->
    #{id => <<"failure-security-plugin">>,
      module => adk_failure_security_plugin,
      mode => observe, failure_policy => closed,
      timeout_ms => 1000, max_heap_words => 100000,
      config => #{observer => self()}}.

receive_matching(Matcher) ->
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    receive_matching(Matcher, Deadline, []).

receive_matching(Matcher, Deadline, Skipped) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        Message ->
            case Matcher(Message) of
                {ok, Value} ->
                    restore_messages(Skipped),
                    Value;
                false -> receive_matching(
                           Matcher, Deadline, [Message | Skipped])
            end
    after Timeout ->
        restore_messages(Skipped),
        error(expected_security_message_missing)
    end.

restore_messages(Messages) ->
    lists:foreach(fun(Message) -> self() ! Message end,
                  lists:reverse(Messages)).

seed() ->
    <<"seeded-secret-credential-DO-NOT-LEAK">>.

assert_seed_absent(Seed, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Seed)).

flush_messages() ->
    receive _ -> flush_messages()
    after 0 -> ok
    end.
