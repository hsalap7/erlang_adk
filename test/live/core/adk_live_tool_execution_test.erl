-module(adk_live_tool_execution_test).

-include_lib("eunit/include/eunit.hrl").

-define(PRINCIPAL, <<"live-tool-principal">>).

live_tool_execution_test_() ->
    {setup,
     fun() -> application:ensure_all_started(erlang_adk) end,
     fun(_Started) -> ok end,
     [fun manual_is_default_and_opt_in_is_strict_case/0,
      fun sequential_execution_preserves_call_order_case/0,
      fun concurrent_execution_overlaps_and_correlates_case/0,
      fun cancellation_kills_worker_and_unknown_name_is_not_executed_case/0,
      fun reconnect_cancels_execution_without_replay_case/0,
      fun executor_timeout_returns_bounded_structural_response_case/0]}.

manual_is_default_and_opt_in_is_strict_case() ->
    {Session, Handle} = start_ready([function_tool(<<"weather">>)], disabled),
    inject_calls(Handle, [call(<<"manual-1">>, <<"weather">>)]),
    assert_no_tool_start(),
    {ok, 1} = adk_live_session:send_tool_response(
                Session, ?PRINCIPAL, <<"manual-1">>, <<"weather">>,
                #{<<"ok">> => true}),
    Response = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(<<"manual-1">>, maps:get(<<"id">>, Response)),
    {ok, #{tool_execution_policy := manual}} =
        adk_live_session:status(Session, ?PRINCIPAL, 1000),
    ?assertEqual({error, invalid_live_status_timeout},
                 adk_live_session:status(Session, ?PRINCIPAL, 0)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done),

    Invalid = (base_config([function_tool(<<"weather">>)]))#{
                tool_execution => execution(
                                    sequential, [<<"undeclared">>], #{})},
    ?assertEqual(
       {error, invalid_live_tool_execution},
       adk_live_session_sup:start_session(
         unique_id(<<"invalid-live-tool">>), ?PRINCIPAL, Invalid)).

sequential_execution_preserves_call_order_case() ->
    Tools = [function_tool(<<"weather">>), function_tool(<<"clock">>)],
    Execution = execution(sequential, [<<"weather">>, <<"clock">>], #{}),
    {Session, Handle} = start_ready(Tools, Execution),
    inject_calls(Handle,
                 [call(<<"seq-1">>, <<"weather">>),
                  call(<<"seq-2">>, <<"clock">>)]),
    {First, <<"seq-1">>} = receive_tool_start(),
    assert_no_tool_start(),
    ?assertEqual(
       {error, tool_call_managed_by_executor},
       adk_live_session:send_tool_response(
         Session, ?PRINCIPAL, <<"seq-1">>, <<"weather">>, #{})),
    First ! {live_tool_complete, <<"seq-1">>, #{<<"temperature">> => 29}},
    FirstResponse = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(<<"seq-1">>, maps:get(<<"id">>, FirstResponse)),
    {Second, <<"seq-2">>} = receive_tool_start(),
    Second ! {live_tool_complete, <<"seq-2">>, #{<<"time">> => <<"12:00">>}},
    SecondResponse = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(<<"seq-2">>, maps:get(<<"id">>, SecondResponse)),
    {ok, Status} = adk_live_session:status(Session, ?PRINCIPAL),
    ?assertEqual(sequential, maps:get(tool_execution_policy, Status)),
    ?assertEqual(0, maps:get(active_tool_workers, Status)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

concurrent_execution_overlaps_and_correlates_case() ->
    Tools = [function_tool(<<"weather">>), function_tool(<<"clock">>)],
    Execution0 = execution(concurrent, [<<"weather">>, <<"clock">>], #{}),
    Execution = Execution0#{max_concurrency => 2},
    {Session, Handle} = start_ready(Tools, Execution),
    inject_calls(Handle,
                 [call(<<"con-1">>, <<"weather">>),
                  call(<<"con-2">>, <<"clock">>)]),
    {WorkerA, IdA} = receive_tool_start(),
    {WorkerB, IdB} = receive_tool_start(),
    ?assertEqual([<<"con-1">>, <<"con-2">>], lists:sort([IdA, IdB])),
    {ok, #{active_tool_workers := 2,
           tool_execution_policy := concurrent}} =
        adk_live_session:status(Session, ?PRINCIPAL),
    WorkerB ! {live_tool_complete, IdB, #{<<"worker">> => <<"b">>}},
    ResponseB = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(IdB, maps:get(<<"id">>, ResponseB)),
    WorkerA ! {live_tool_complete, IdA, #{<<"worker">> => <<"a">>}},
    ResponseA = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(IdA, maps:get(<<"id">>, ResponseA)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

cancellation_kills_worker_and_unknown_name_is_not_executed_case() ->
    Execution = execution(sequential, [<<"weather">>], #{}),
    {Session, Handle} = start_ready(
                          [function_tool(<<"weather">>)], Execution),
    inject_calls(Handle, [call(<<"cancel-1">>, <<"weather">>)]),
    {Worker, <<"cancel-1">>} = receive_tool_start(),
    Monitor = erlang:monitor(process, Worker),
    adk_live_fake_transport:inject(
      Handle,
      #{<<"toolCallCancellation">> => #{<<"ids">> => [<<"cancel-1">>]}}),
    receive
        {'DOWN', Monitor, process, Worker, killed} -> ok
    after 1000 -> ?assert(false)
    end,
    assert_no_sent_frame(Handle),

    %% A model-invented name is still surfaced for trusted manual handling but
    %% can never cross the automatic executor allowlist.
    inject_calls(Handle, [call(<<"unknown-1">>, <<"clock">>)]),
    assert_no_tool_start(),
    {ok, 1} = adk_live_session:send_tool_response(
                Session, ?PRINCIPAL, <<"unknown-1">>, <<"clock">>,
                #{<<"handled">> => false}),
    UnknownResponse = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(<<"unknown-1">>, maps:get(<<"id">>, UnknownResponse)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

reconnect_cancels_execution_without_replay_case() ->
    Tools = [function_tool(<<"weather">>)],
    Execution = execution(sequential, [<<"weather">>], #{}),
    Config = (base_config(Tools))#{
               provider_config => #{tools => Tools,
                                    session_resumption => true},
               tool_execution => Execution,
               max_reconnect_attempts => 1,
               reconnect_backoff_ms => 10},
    {ok, Session} = adk_live_session_sup:start_session(
                      unique_id(<<"live-tool-reconnect">>),
                      ?PRINCIPAL, Config),
    Handle = receive
        {adk_live_fake_transport, opened, Opened} -> Opened
    after 1000 -> ?assert(false)
    end,
    _Setup = receive_sent(Handle),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    wait_for_active(Session, 100),
    adk_live_fake_transport:inject(
      Handle,
      #{<<"sessionResumptionUpdate">> =>
            #{<<"newHandle">> => <<"private-resumption-handle">>,
              <<"resumable">> => true}}),
    wait_for_resumable(Session, 100),
    inject_calls(Handle, [call(<<"reconnect-1">>, <<"weather">>)]),
    {Worker, <<"reconnect-1">>} = receive_tool_start(),
    Monitor = erlang:monitor(process, Worker),
    ok = adk_live_fake_transport:disconnect(Handle, network_lost),
    receive
        {'DOWN', Monitor, process, Worker, killed} -> ok
    after 1000 -> ?assert(false)
    end,
    NewHandle = receive
        {adk_live_fake_transport, opened, Reopened} when Reopened =/= Handle ->
            Reopened
    after 1000 -> ?assert(false)
    end,
    _ResumeSetup = receive_sent(NewHandle),
    adk_live_fake_transport:inject(
      NewHandle, #{<<"setupComplete">> => #{}}),
    wait_for_active(Session, 100),
    assert_no_sent_frame(NewHandle),
    inject_calls(NewHandle,
                 [call(<<"reconnect-1">>, <<"weather">>)]),
    assert_no_tool_start(),
    assert_no_sent_frame(NewHandle),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

executor_timeout_returns_bounded_structural_response_case() ->
    Execution0 = execution(sequential, [<<"weather">>], #{}),
    Execution = Execution0#{timeout_ms => 30, max_response_bytes => 256},
    {Session, Handle} = start_ready(
                          [function_tool(<<"weather">>)], Execution),
    inject_calls(Handle, [call(<<"timeout-1">>, <<"weather">>)]),
    {_Worker, <<"timeout-1">>} = receive_tool_start(),
    Response = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(<<"timeout-1">>, maps:get(<<"id">>, Response)),
    ?assertEqual(
       #{<<"error">> => <<"tool_execution_failed">>,
         <<"type">> => <<"timeout">>},
       maps:get(<<"response">>, Response)),

    inject_calls(Handle, [call(<<"large-1">>, <<"weather">>)]),
    {LargeWorker, <<"large-1">>} = receive_tool_start(),
    LargeWorker ! {live_tool_complete, <<"large-1">>,
                   #{<<"value">> => binary:copy(<<"x">>, 512)}},
    LargeResponse = decode_tool_response(receive_sent(Handle)),
    ?assertEqual(
       #{<<"error">> => <<"tool_execution_failed">>,
         <<"type">> => <<"response_too_large">>},
       maps:get(<<"response">>, LargeResponse)),
    ok = adk_live_session:close(Session, ?PRINCIPAL, done).

start_ready(Tools, ToolExecution) ->
    Config0 = base_config(Tools),
    Config = case ToolExecution of
        disabled -> Config0;
        _ -> Config0#{tool_execution => ToolExecution}
    end,
    {ok, Session} = adk_live_session_sup:start_session(
                      unique_id(<<"live-tool">>), ?PRINCIPAL, Config),
    Handle = receive
        {adk_live_fake_transport, opened, Opened} -> Opened
    after 1000 -> ?assert(false)
    end,
    _Setup = receive_sent(Handle),
    adk_live_fake_transport:inject(
      Handle, #{<<"setupComplete">> => #{}}),
    wait_for_active(Session, 100),
    {Session, Handle}.

base_config(Tools) ->
    #{provider => adk_live_gemini,
      provider_config => #{tools => Tools},
      transport => adk_live_fake_transport,
      transport_opts => #{test_pid => self()}}.

execution(Policy, AllowedTools, ExtraOptions) ->
    maps:merge(
      #{enabled => true,
        executor => adk_live_test_tool_executor,
        policy => Policy,
        allowed_tools => AllowedTools,
        options => #{test_pid => self()},
        timeout_ms => 1000,
        max_heap_words => 100000,
        max_response_bytes => 4096}, ExtraOptions).

function_tool(Name) ->
    #{type => function, name => Name,
      description => <<"Live test function">>,
      parameters => #{<<"type">> => <<"object">>}}.

call(Id, Name) ->
    #{<<"id">> => Id, <<"name">> => Name, <<"args">> => #{}}.

inject_calls(Handle, Calls) ->
    adk_live_fake_transport:inject(
      Handle, #{<<"toolCall">> => #{<<"functionCalls">> => Calls}}).

receive_tool_start() ->
    receive
        {live_tool_started, Worker, Id, _Name, #{}} -> {Worker, Id}
    after 1000 -> ?assert(false)
    end.

assert_no_tool_start() ->
    receive
        {live_tool_started, _Worker, _Id, _Name, _Args} -> ?assert(false)
    after 50 -> ok
    end.

receive_sent(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, Frame} -> Frame
    after 1000 -> ?assert(false)
    end.

assert_no_sent_frame(Handle) ->
    receive
        {adk_live_fake_transport, sent, Handle, _Frame} -> ?assert(false)
    after 50 -> ok
    end.

decode_tool_response(Frame) ->
    #{<<"toolResponse">> := #{<<"functionResponses">> := [Response]}} =
        jsx:decode(Frame, [return_maps]),
    Response.

wait_for_active(_Session, 0) -> ?assert(false);
wait_for_active(Session, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{state := active}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_active(Session, Remaining - 1)
    end.

wait_for_resumable(_Session, 0) -> ?assert(false);
wait_for_resumable(Session, Remaining) ->
    case adk_live_session:status(Session, ?PRINCIPAL) of
        {ok, #{resumable := true}} -> ok;
        _ ->
            receive after 10 -> ok end,
            wait_for_resumable(Session, Remaining - 1)
    end.

unique_id(Prefix) ->
    <<Prefix/binary, "-", (integer_to_binary(
                             erlang:unique_integer([positive])))/binary>>.
