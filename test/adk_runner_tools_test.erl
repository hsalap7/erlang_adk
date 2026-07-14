-module(adk_runner_tools_test).
-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-export([on_tool_start/2, before_tool/3,
         after_tool/4, on_tool_end/2]).

-define(APP, <<"runner_tool_app">>).
-define(USER, <<"runner_user">>).

runner_tool_execution_test_() ->
    {setup,
     fun setup/0,
     fun(_) -> ok end,
     [
      fun test_runner_executes_tools_recursively/0,
      fun test_runner_callback_lifecycle/0,
      fun test_runner_sub_agent_callback_lifecycle/0,
      fun test_runner_sub_agent_history_is_invocation_scoped/0,
      fun test_tool_execution_options_are_validated/0,
      fun test_serial_is_default_for_parallel_safe_tools/0,
      fun test_parallel_runner_is_bounded_and_commits_in_order/0,
      fun test_unsafe_tool_is_a_parallel_barrier/0,
      fun test_parallel_callbacks_are_exactly_once_and_ordered/0,
      fun test_parallel_crash_and_timeout_are_error_values/0,
      fun test_runner_cancel_stops_parallel_tool_processes/0,
      fun test_runner_deadline_stops_parallel_tool_processes/0,
      fun test_pause_is_barrier_and_later_calls_are_not_started/0
     ]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    erlang_adk_session:init().

%% Dummy agent that first returns tool_calls, then on second call returns final text.
dummy_tool_agent_loop(CallCount) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvId}} ->
            case CallCount of
                0 ->
                    %% First call: request a tool execution
                    Calls = [{<<"dummy_tool">>, #{<<"arg">> => <<"val">>}, undefined}],
                    AgentEvent = adk_event:new(<<"agent">>, {tool_calls, Calls}, #{invocation_id => InvId}),
                    gen_server:reply(From, {tool_calls, AgentEvent, Calls}),
                    dummy_tool_agent_loop(1);
                _ ->
                    %% Second call: return final response
                    FinalEvent = adk_event:new(<<"agent">>, <<"Tool executed successfully">>, #{invocation_id => InvId, is_final => true}),
                    gen_server:reply(From, {ok, FinalEvent}),
                    dummy_tool_agent_loop(CallCount + 1)
            end;
        {'$gen_call', From, get_tools} ->
            gen_server:reply(From, {ok, [dummy_tool], #{}}),
            dummy_tool_agent_loop(CallCount);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"agent">>, #{}, [dummy_tool], #{}}),
            dummy_tool_agent_loop(CallCount);
        stop ->
            ok;
        _ ->
            dummy_tool_agent_loop(CallCount)
    end.

test_runner_executes_tools_recursively() ->
    AgentPid = spawn(fun() -> dummy_tool_agent_loop(0) end),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session),
    SessionId = <<"runner_tool_sess">>,
    
    %% This should:
    %% 1. Agent returns tool_calls
    %% 2. Runner executes dummy_tool
    %% 3. Runner loops back, agent returns final text
    Result = adk_runner:run(Runner, ?USER, SessionId, <<"Execute tool">>),
    ?assertEqual({ok, <<"Tool executed successfully">>}, Result),
    
    %% Verify events were recorded (user + agent_tool_call + tool_response + agent_final = 4)
    {ok, Session} = erlang_adk_session:get_session(?APP, ?USER, SessionId),
    Events = maps:get(events, Session),
    ?assert(length(Events) >= 4),
    
    %% Gracefully terminate the mock agent
    AgentPid ! stop.

test_runner_callback_lifecycle() ->
    persistent_term:put({adk_callback_lifecycle_test, target}, self()),
    {ok, AgentPid} = erlang_adk:spawn_agent(
                       <<"RunnerCallbackAgent">>,
                       #{provider => adk_llm_dummy,
                         callbacks => [adk_callback_lifecycle_test]},
                       [dummy_tool]),
    Runner = adk_runner:new(AgentPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        ?assertEqual(
           {ok, <<"Tool executed">>},
           adk_runner:run(Runner, ?USER, <<"runner_callback_sess">>,
                          <<"Trigger tool">>)),
        Events = receive_callback_events(10, []),
        ?assertEqual(1, count_callback(on_agent_start, Events)),
        ?assertEqual(1, count_callback(on_agent_end, Events)),
        ?assertEqual(2, count_callback(before_model, Events)),
        ?assertEqual(2, count_callback(after_model, Events)),
        ?assertEqual(1, count_callback(on_tool_start, Events)),
        ?assertEqual(1, count_callback(before_tool, Events)),
        ?assertEqual(1, count_callback(after_tool, Events)),
        ?assertEqual(1, count_callback(on_tool_end, Events))
    after
        _ = catch erlang_adk:stop_agent(AgentPid),
        persistent_term:erase({adk_callback_lifecycle_test, target}),
        _ = erlang_adk_session:delete_session(
              ?APP, ?USER, <<"runner_callback_sess">>)
    end.

test_runner_sub_agent_callback_lifecycle() ->
    persistent_term:put({adk_callback_lifecycle_test, target}, self()),
    {ok, SubPid} = erlang_adk:spawn_agent(
                     <<"RunnerCallbackSubWorker">>,
                     #{provider => adk_llm_probe,
                       response => <<"specialist response">>}, []),
    {ok, MasterPid} = erlang_adk:spawn_agent(
                        <<"RunnerCallbackSubMaster">>,
                        #{provider => adk_llm_probe,
                          mode => sub_agent_call,
                          call_name => <<"RunnerCallbackSubWorker">>,
                          callbacks => [adk_callback_lifecycle_test],
                          sub_agents => #{<<"RunnerCallbackSubWorker">> => SubPid}},
                        []),
    SessionId = <<"runner_sub_callback_sess">>,
    Runner = adk_runner:new(MasterPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        ?assertEqual({ok, <<"delegation complete">>},
                     adk_runner:run(
                       Runner, ?USER, SessionId, <<"delegate">>)),
        Events = receive_callback_events(10, []),
        ?assertEqual(1, count_callback(on_tool_start, Events)),
        ?assertEqual(1, count_callback(before_tool, Events)),
        ?assertEqual(1, count_callback(after_tool, Events)),
        ?assertEqual(1, count_callback(on_tool_end, Events))
    after
        _ = catch erlang_adk:stop_agent(MasterPid),
        _ = catch erlang_adk:stop_agent(SubPid),
        persistent_term:erase({adk_callback_lifecycle_test, target}),
        _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId)
    end.

test_runner_sub_agent_history_is_invocation_scoped() ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    ChildName = <<"RunnerIsolationChild_", Suffix/binary>>,
    MasterName = <<"RunnerIsolationMaster_", Suffix/binary>>,
    SessionA = <<"runner-isolation-a-", Suffix/binary>>,
    SessionB = <<"runner-isolation-b-", Suffix/binary>>,
    UserA = <<"runner-isolation-user-a">>,
    UserB = <<"runner-isolation-user-b">>,
    SecretA = <<"session-a-secret">>,
    MessageB = <<"session-b-request">>,
    {ok, ChildPid} = erlang_adk:spawn_agent(
                       ChildName,
                       #{provider => adk_llm_probe,
                         test_pid => self(),
                         response => <<"child-result">>}, []),
    {ok, MasterPid} = erlang_adk:spawn_agent(
                        MasterName,
                        #{provider => adk_llm_probe,
                          mode => sub_agent_echo_call,
                          call_name => ChildName,
                          sub_agents => #{ChildName => ChildPid}}, []),
    Runner = adk_runner:new(MasterPid, ?APP, erlang_adk_session,
                            #{run_timeout => 2000}),
    try
        ?assertEqual(
           {ok, <<"delegation complete">>},
           adk_runner:run(Runner, UserA, SessionA, SecretA)),
        FirstHistory = receive_probe_history(),
        ?assert(lists:member(SecretA, history_contents(FirstHistory))),

        ?assertEqual(
           {ok, <<"delegation complete">>},
           adk_runner:run(Runner, UserB, SessionB, MessageB)),
        SecondHistory = receive_probe_history(),
        ?assert(lists:member(MessageB, history_contents(SecondHistory))),
        ?assertNot(lists:member(SecretA, history_contents(SecondHistory)))
    after
        _ = catch erlang_adk:stop_agent(MasterPid),
        _ = catch erlang_adk:stop_agent(ChildPid),
        _ = erlang_adk_session:delete_session(?APP, UserA, SessionA),
        _ = erlang_adk_session:delete_session(?APP, UserB, SessionB)
    end.

receive_probe_history() ->
    receive
        {probe_generate, History, _Tools} -> History
    after 1000 ->
        ?assert(false)
    end.

history_contents(History) ->
    [Content || #{content := Content} <- History].

receive_callback_events(0, Acc) -> Acc;
receive_callback_events(Remaining, Acc) ->
    receive
        {callback, Event} ->
            receive_callback_events(Remaining - 1, [Event | Acc])
    after 1000 ->
        Acc
    end.

count_callback(Event, Events) ->
    length([ok || Seen <- Events, Seen =:= Event]).

test_tool_execution_options_are_validated() ->
    ?assertError(
       {invalid_tool_execution, parallel},
       adk_runner:new(
         self(), ?APP, erlang_adk_session,
         #{tool_execution => parallel})),
    SerialMap = #{mode => serial},
    ?assertError(
       {invalid_tool_execution, SerialMap},
       adk_runner:new(
         self(), ?APP, erlang_adk_session,
         #{tool_execution => SerialMap})),
    ZeroConcurrency = #{mode => parallel, max_concurrency => 0},
    ?assertError(
       {invalid_tool_execution, ZeroConcurrency},
       adk_runner:new(
         self(), ?APP, erlang_adk_session,
         #{tool_execution => ZeroConcurrency})),
    InvalidTimeout = #{mode => parallel, tool_timeout => invalid},
    ?assertError(
       {invalid_tool_execution, InvalidTimeout},
       adk_runner:new(
         self(), ?APP, erlang_adk_session,
         #{tool_execution => InvalidTimeout})).

test_serial_is_default_for_parallel_safe_tools() ->
    {Table, SessionId} = start_probe(<<"runner_serial_default">>),
    Calls = [parallel_call(<<"one">>, 30),
             parallel_call(<<"two">>, 5)],
    try
        {Result, Events} = run_batch(
                             Calls, [adk_runner_parallel_tool],
                             #{run_timeout => 2000}, #{}, SessionId),
        ?assertEqual({ok, <<"batch complete">>}, Result),
        ?assertEqual(1, max_seen(Table)),
        ?assertEqual([<<"call-one">>, <<"call-two">>],
                     tool_event_call_ids(Events))
    after
        stop_probe(Table, SessionId)
    end.

test_parallel_runner_is_bounded_and_commits_in_order() ->
    {Table, SessionId} = start_probe(<<"runner_parallel_bound">>),
    Calls = [parallel_call(<<"one">>, 80),
             parallel_call(<<"two">>, 10),
             parallel_call(<<"three">>, 20),
             parallel_call(<<"four">>, 1)],
    Policy = #{mode => parallel, max_concurrency => 2,
               tool_timeout => 1000},
    try
        {Result, Events} = run_batch(
                             Calls, [adk_runner_parallel_tool],
                             #{run_timeout => 2000,
                               tool_execution => Policy},
                             #{}, SessionId),
        ?assertEqual({ok, <<"batch complete">>}, Result),
        ?assertEqual(2, max_seen(Table)),
        ?assertEqual(
           [<<"call-one">>, <<"call-two">>,
            <<"call-three">>, <<"call-four">>],
           tool_event_call_ids(Events)),
        Messages = collect_probe_messages(8, []),
        Started = [{Id, Context}
                   || {runner_tool_started, Id, _Pid, Context} <- Messages],
        ?assertEqual(
           lists:sort([<<"one">>, <<"two">>, <<"three">>, <<"four">>]),
           lists:sort([Id || {Id, _Context} <- Started])),
        lists:foreach(
          fun({Id, Context}) ->
              ?assertEqual(SessionId, maps:get(session_id, Context)),
              ?assertEqual(?USER, maps:get(user_id, Context)),
              ?assertEqual(<<"call-", Id/binary>>,
                           maps:get(call_id, Context)),
              ?assert(is_binary(maps:get(invocation_id, Context)))
          end, Started)
    after
        stop_probe(Table, SessionId)
    end.

test_unsafe_tool_is_a_parallel_barrier() ->
    {Table, SessionId} = start_probe(<<"runner_unsafe_barrier">>),
    Calls = [parallel_call(<<"safe-one">>, 60),
             parallel_call(<<"safe-two">>, 10),
             unsafe_call(<<"unsafe">>, 5),
             parallel_call(<<"safe-after">>, 1)],
    Policy = #{mode => parallel, max_concurrency => 2,
               tool_timeout => 1000},
    try
        {Result, _Events} = run_batch(
                              Calls,
                              [adk_runner_parallel_tool,
                               adk_runner_unsafe_tool],
                              #{run_timeout => 2000,
                                tool_execution => Policy},
                              #{}, SessionId),
        ?assertEqual({ok, <<"batch complete">>}, Result),
        Messages = collect_probe_messages(8, []),
        Markers = [probe_marker(Message) || Message <- Messages],
        UnsafeStart = marker_position(
                        {started, <<"unsafe">>}, Markers),
        ?assert(marker_position(
                  {finished, <<"safe-one">>}, Markers) < UnsafeStart),
        ?assert(marker_position(
                  {finished, <<"safe-two">>}, Markers) < UnsafeStart),
        UnsafeFinish = marker_position(
                         {finished, <<"unsafe">>}, Markers),
        ?assert(UnsafeFinish < marker_position(
                                 {started, <<"safe-after">>}, Markers))
    after
        stop_probe(Table, SessionId)
    end.

test_parallel_callbacks_are_exactly_once_and_ordered() ->
    {Table, SessionId} = start_probe(<<"runner_parallel_callbacks">>),
    persistent_term:put({?MODULE, callback_target}, self()),
    Calls = [parallel_call(<<"one">>, 40),
             parallel_call(<<"two">>, 5),
             parallel_call(<<"three">>, 1)],
    Policy = #{mode => parallel, max_concurrency => 3,
               tool_timeout => 1000},
    try
        {Result, _Events} = run_batch(
                              Calls, [adk_runner_parallel_tool],
                              #{run_timeout => 2000,
                                tool_execution => Policy},
                              #{callbacks => [?MODULE]}, SessionId),
        ?assertEqual({ok, <<"batch complete">>}, Result),
        Sequence = receive_runner_callbacks(12, []),
        ?assertEqual(
           [{on_tool_start, <<"one">>},
            {before_tool, <<"one">>},
            {on_tool_start, <<"two">>},
            {before_tool, <<"two">>},
            {on_tool_start, <<"three">>},
            {before_tool, <<"three">>},
            {after_tool, <<"one">>},
            {on_tool_end, <<"one">>},
            {after_tool, <<"two">>},
            {on_tool_end, <<"two">>},
            {after_tool, <<"three">>},
            {on_tool_end, <<"three">>}],
           Sequence)
    after
        persistent_term:erase({?MODULE, callback_target}),
        stop_probe(Table, SessionId)
    end.

test_parallel_crash_and_timeout_are_error_values() ->
    {Table, SessionId} = start_probe(<<"runner_parallel_errors">>),
    Calls = [
        parallel_call(<<"crash">>, 0, <<"crash">>),
        parallel_call(<<"timeout">>, 0, <<"block">>),
        parallel_call(<<"success">>, 1)
    ],
    Policy = #{mode => parallel, max_concurrency => 3,
               tool_timeout => 25},
    try
        {Result, Events} = run_batch(
                             Calls, [adk_runner_parallel_tool],
                             #{run_timeout => 2000,
                               tool_execution => Policy},
                             #{}, SessionId),
        ?assertEqual({ok, <<"batch complete">>}, Result),
        ?assertEqual([false, false, true],
                     tool_event_successes(Events)),
        ?assertEqual(
           [<<"call-crash">>, <<"call-timeout">>, <<"call-success">>],
           tool_event_call_ids(Events))
    after
        stop_probe(Table, SessionId)
    end.

test_runner_cancel_stops_parallel_tool_processes() ->
    {Table, SessionId} = start_probe(<<"runner_parallel_cancel">>),
    Calls = [parallel_call(<<"block-one">>, 0, <<"block">>),
             parallel_call(<<"block-two">>, 0, <<"block">>)],
    Agent = spawn(
              fun() -> batch_agent_loop(
                         Calls, [adk_runner_parallel_tool], #{}, initial)
              end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 5000,
                 tool_execution =>
                     #{mode => parallel, max_concurrency => 2,
                       tool_timeout => 5000}}),
    try
        {ok, StreamPid} = adk_runner:run_async(
                            Runner, ?USER, SessionId, <<"cancel batch">>),
        ToolPids = collect_started_tool_pids(2, []),
        Monitors = [{Pid, erlang:monitor(process, Pid)}
                    || Pid <- ToolPids],
        ok = adk_runner:cancel(StreamPid, runner_cancel),
        receive
            {adk_error, StreamPid, {cancelled, runner_cancel}} -> ok
        after 1000 ->
            ?assert(false)
        end,
        lists:foreach(
          fun({Pid, Ref}) ->
              receive
                  {'DOWN', Ref, process, Pid, _Reason} -> ok
              after 1000 ->
                  ?assert(false)
              end
          end, Monitors),
        assert_no_runner_terminal(StreamPid)
    after
        Agent ! stop,
        stop_probe(Table, SessionId)
    end.

test_runner_deadline_stops_parallel_tool_processes() ->
    {Table, SessionId} = start_probe(<<"runner_parallel_deadline">>),
    Calls = [parallel_call(<<"deadline-one">>, 0, <<"block">>),
             parallel_call(<<"deadline-two">>, 0, <<"block">>)],
    Agent = spawn(
              fun() -> batch_agent_loop(
                         Calls, [adk_runner_parallel_tool], #{}, initial)
              end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 40,
                 tool_execution =>
                     #{mode => parallel, max_concurrency => 2,
                       tool_timeout => 5000}}),
    try
        {ok, StreamPid} = adk_runner:run_async(
                            Runner, ?USER, SessionId, <<"deadline batch">>),
        ToolPids = collect_started_tool_pids(2, []),
        Monitors = [{Pid, erlang:monitor(process, Pid)}
                    || Pid <- ToolPids],
        receive
            {adk_error, StreamPid, timeout} -> ok
        after 1000 ->
            ?assert(false)
        end,
        lists:foreach(
          fun({Pid, Ref}) ->
              receive
                  {'DOWN', Ref, process, Pid, _Reason} -> ok
              after 1000 ->
                  ?assert(false)
              end
          end, Monitors),
        assert_no_runner_terminal(StreamPid)
    after
        Agent ! stop,
        stop_probe(Table, SessionId)
    end.

test_pause_is_barrier_and_later_calls_are_not_started() ->
    {Table, SessionId} = start_probe(<<"runner_parallel_pause">>),
    Calls = [
        parallel_call(<<"before">>, 5),
        {<<"request_human_approval">>,
         #{<<"action_summary">> => <<"Publish release">>},
         <<"approval-signature">>, <<"approval-call">>},
        parallel_call(<<"after">>, 1)
    ],
    Agent = spawn(
              fun() -> batch_agent_loop(
                         Calls,
                         [adk_runner_parallel_tool,
                          adk_long_running_tool],
                         #{}, initial)
              end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session,
               #{run_timeout => 2000,
                 tool_execution =>
                     #{mode => parallel, max_concurrency => 2,
                       tool_timeout => 1000}}),
    try
        {ok, StreamPid} = adk_runner:run_async(
                            Runner, ?USER, SessionId,
                            <<"pause in batch">>),
        PauseEvent = await_runner_pause(StreamPid),
        receive
            {runner_tool_finished, <<"before">>, _BeforePid} -> ok
        after 1000 ->
            ?assert(false)
        end,
        receive
            {runner_tool_started, <<"after">>, _AfterPid0, _Context0} ->
                ?assert(false)
        after 75 ->
            ok
        end,
        {ok, PausedSession} = erlang_adk_session:get_session(
                                ?APP, ?USER, SessionId),
        PausedIds = tool_event_call_ids(
                      maps:get(events, PausedSession)),
        ?assertEqual([<<"call-before">>], PausedIds),

        InvocationId = PauseEvent#adk_event.invocation_id,
        {ok, ResumePid} = adk_runner:resume(
                            Runner, ?USER, SessionId, InvocationId,
                            <<"Approved">>),
        ok = await_runner_done(ResumePid),
        receive
            {runner_tool_started, <<"after">>, _AfterPid, _AfterContext} ->
                ok
        after 1000 ->
            ?assert(false)
        end,
        {ok, CompletedSession} = erlang_adk_session:get_session(
                                   ?APP, ?USER, SessionId),
        ?assertEqual(
           [<<"call-before">>, <<"approval-call">>, <<"call-after">>],
           tool_event_call_ids(maps:get(events, CompletedSession)))
    after
        Agent ! stop,
        stop_probe(Table, SessionId)
    end.

on_tool_start(_Name, Args) ->
    notify_runner_callback(on_tool_start, maps:get(<<"id">>, Args)).

before_tool(_Name, Args, _Context) ->
    notify_runner_callback(before_tool, maps:get(<<"id">>, Args)),
    continue.

after_tool(_Name, Args, _Context, _Result) ->
    notify_runner_callback(after_tool, maps:get(<<"id">>, Args)),
    continue.

on_tool_end(_Name, Result) ->
    notify_runner_callback(on_tool_end, callback_result_id(Result)).

callback_result_id({ok, #{<<"id">> := Id}}) -> Id;
callback_result_id({error, {parallel_probe_crash, Id}}) -> Id;
callback_result_id(_Result) -> undefined.

notify_runner_callback(Hook, Id) ->
    case persistent_term:get({?MODULE, callback_target}, undefined) of
        Pid when is_pid(Pid) -> Pid ! {runner_callback, Hook, Id};
        _ -> ok
    end,
    ok.

batch_agent_loop(Calls, Tools, Config, Stage) ->
    receive
        {'$gen_call', From, {run_with_events, _History, InvId}}
          when Stage =:= initial ->
            Event = adk_event:new(
                      <<"batch-agent">>, {tool_calls, Calls},
                      #{invocation_id => InvId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            batch_agent_loop(Calls, Tools, Config, waiting);
        {'$gen_call', From, {run_with_events, _History, InvId}} ->
            Event = adk_event:new(
                      <<"batch-agent">>, <<"batch complete">>,
                      #{invocation_id => InvId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            batch_agent_loop(Calls, Tools, Config, complete);
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From, {ok, <<"batch-agent">>, Config, Tools, #{}}),
            batch_agent_loop(Calls, Tools, Config, Stage);
        stop ->
            ok;
        _ ->
            batch_agent_loop(Calls, Tools, Config, Stage)
    end.

run_batch(Calls, Tools, RunnerOpts, AgentConfig, SessionId) ->
    Agent = spawn(
              fun() -> batch_agent_loop(
                         Calls, Tools, AgentConfig, initial)
              end),
    Runner = adk_runner:new(
               Agent, ?APP, erlang_adk_session, RunnerOpts),
    try
        Result = adk_runner:run(
                   Runner, ?USER, SessionId, <<"execute batch">>),
        {ok, Session} = erlang_adk_session:get_session(
                          ?APP, ?USER, SessionId),
        {Result, maps:get(events, Session)}
    after
        Agent ! stop
    end.

parallel_call(Id, Delay) ->
    parallel_call(Id, Delay, <<"success">>).

parallel_call(Id, Delay, Mode) ->
    {<<"parallel_probe">>,
     #{<<"id">> => Id, <<"delay">> => Delay, <<"mode">> => Mode},
     <<"sig-", Id/binary>>, <<"call-", Id/binary>>}.

unsafe_call(Id, Delay) ->
    {<<"unsafe_probe">>,
     #{<<"id">> => Id, <<"delay">> => Delay},
     <<"sig-", Id/binary>>, <<"call-", Id/binary>>}.

start_probe(SessionPrefix) ->
    flush_probe_messages(),
    Table = ets:new(
              adk_runner_parallel_metrics,
              [set, public, {write_concurrency, true}]),
    persistent_term:put({adk_runner_parallel_tool, metrics}, Table),
    persistent_term:put({adk_runner_parallel_tool, target}, self()),
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    {Table, <<SessionPrefix/binary, "-", Suffix/binary>>}.

stop_probe(Table, SessionId) ->
    persistent_term:erase({adk_runner_parallel_tool, target}),
    persistent_term:erase({adk_runner_parallel_tool, metrics}),
    _ = catch ets:delete(Table),
    _ = erlang_adk_session:delete_session(
          ?APP, ?USER, SessionId),
    flush_probe_messages(),
    ok.

max_seen(Table) ->
    Values = [Value || {{seen, _Ref}, Value} <- ets:tab2list(Table)],
    lists:max(Values).

collect_probe_messages(0, Acc) ->
    lists:reverse(Acc);
collect_probe_messages(Remaining, Acc) ->
    receive
        {runner_tool_started, _Id, _Pid, _Context} = Message ->
            collect_probe_messages(Remaining - 1, [Message | Acc]);
        {runner_tool_finished, _Id, _Pid} = Message ->
            collect_probe_messages(Remaining - 1, [Message | Acc])
    after 1000 ->
        ?assert(false)
    end.

collect_started_tool_pids(0, Acc) ->
    lists:reverse(Acc);
collect_started_tool_pids(Remaining, Acc) ->
    receive
        {runner_tool_started, _Id, Pid, _Context} ->
            collect_started_tool_pids(Remaining - 1, [Pid | Acc])
    after 1000 ->
        ?assert(false)
    end.

probe_marker({runner_tool_started, Id, _Pid, _Context}) ->
    {started, Id};
probe_marker({runner_tool_finished, Id, _Pid}) ->
    {finished, Id}.

marker_position(Marker, Markers) ->
    marker_position(Marker, Markers, 1).

marker_position(Marker, [Marker | _], Position) ->
    Position;
marker_position(Marker, [_ | Rest], Position) ->
    marker_position(Marker, Rest, Position + 1).

receive_runner_callbacks(0, Acc) ->
    lists:reverse(Acc);
receive_runner_callbacks(Remaining, Acc) ->
    receive
        {runner_callback, Hook, Id} ->
            receive_runner_callbacks(
              Remaining - 1, [{Hook, Id} | Acc])
    after 1000 ->
        ?assert(false)
    end.

tool_event_call_ids(Events) ->
    [CallId ||
     #adk_event{author = <<"tool">>,
                content = {tool_response, _Name, _Result,
                           _Signature, CallId}} <- Events].

tool_event_successes(Events) ->
    [maps:get(<<"success">>, Result) ||
     #adk_event{author = <<"tool">>,
                content = {tool_response, _Name, Result,
                           _Signature, _CallId}} <- Events].

await_runner_pause(StreamPid) ->
    receive
        {adk_event, StreamPid, _Event} ->
            await_runner_pause(StreamPid);
        {adk_paused, StreamPid, PauseEvent} ->
            PauseEvent;
        {adk_error, StreamPid, Reason} ->
            erlang:error({unexpected_runner_error, Reason})
    after 1000 ->
        ?assert(false)
    end.

await_runner_done(StreamPid) ->
    receive
        {adk_event, StreamPid, _Event} ->
            await_runner_done(StreamPid);
        {adk_done, StreamPid} ->
            ok;
        {adk_error, StreamPid, Reason} ->
            erlang:error({unexpected_runner_error, Reason})
    after 1000 ->
        ?assert(false)
    end.

assert_no_runner_terminal(StreamPid) ->
    receive
        {adk_done, StreamPid} -> ?assert(false);
        {adk_paused, StreamPid, _} -> ?assert(false);
        {adk_error, StreamPid, _} -> ?assert(false)
    after 50 ->
        ok
    end.

flush_probe_messages() ->
    receive
        {runner_tool_started, _Id, _Pid, _Context} ->
            flush_probe_messages();
        {runner_tool_finished, _Id, _Pid} ->
            flush_probe_messages();
        {runner_callback, _Hook, _Id} ->
            flush_probe_messages()
    after 0 ->
        ok
    end.
