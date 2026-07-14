-module(adk_runner_continuation_restore_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/adk_event.hrl").

-define(APP, <<"runner-restore-app">>).
-define(USER, <<"runner-restore-user">>).

continuation_restore_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun invalid_confirmation_surfaces_update_error_case/0,
      fun malformed_state_surfaces_invalid_update_reply_case/0,
      fun admission_failure_surfaces_update_exception_case/0]}.

setup() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    ok = erlang_adk_session:init(),
    ok.

cleanup(_Setup) ->
    ok.

invalid_confirmation_surfaces_update_error_case() ->
    SessionId = unique(<<"invalid-confirmation">>),
    Secret = <<"restore-backend-private-error">>,
    {Agent, Runner, Pause} = start_confirmation_pause(SessionId),
    InvocationId = Pause#adk_event.invocation_id,
    try
        ok = adk_fault_session_service:set_update_state_fault(
               SessionId, {error, Secret}),
        Result = adk_runner:resume(
                   Runner, ?USER, SessionId, InvocationId,
                   #{<<"confirmed">> => <<"invalid">>}),
        assert_restore_failure(Result, external, binary_failure),
        assert_secret_absent(Secret, Result),

        ok = adk_fault_session_service:clear_update_state_fault(SessionId),
        ?assertEqual(
           {error, no_paused_invocation},
           adk_runner:resume(
             Runner, ?USER, SessionId, InvocationId,
             #{<<"confirmed">> => true}))
    after
        stop_case(Agent, SessionId)
    end.

malformed_state_surfaces_invalid_update_reply_case() ->
    SessionId = unique(<<"malformed-state">>),
    InvocationId = <<"malformed-continuation">>,
    Key = continuation_key(InvocationId),
    Secret = <<"invalid-reply-private-payload">>,
    Agent = spawn(fun() -> agent_loop(idle) end),
    Runner = adk_runner:new(
               Agent, ?APP, adk_fault_session_service,
               #{run_timeout => 2000}),
    try
        {ok, _} = erlang_adk_session:create_session(
                    ?APP, ?USER, #{session_id => SessionId}),
        ok = erlang_adk_session:update_state(
               ?APP, ?USER, SessionId,
               #{Key => <<"not-a-pause-map">>}),
        ok = adk_fault_session_service:set_update_state_fault(
               SessionId,
               {invalid, #{<<"private">> => Secret}}),
        Result = adk_runner:resume(
                   Runner, ?USER, SessionId, InvocationId,
                   #{<<"confirmed">> => true}),
        assert_restore_failure(
          Result, external, invalid_update_state_reply),
        assert_secret_absent(Secret, Result)
    after
        stop_case(Agent, SessionId)
    end.

admission_failure_surfaces_update_exception_case() ->
    SessionId = unique(<<"admission-failure">>),
    Secret = <<"raised-private-restoration-payload">>,
    {Agent, PauseRunner, Pause} = start_confirmation_pause(SessionId),
    InvocationId = Pause#adk_event.invocation_id,
    ResumeRunner = adk_runner:new(
                     Agent, ?APP, adk_fault_session_service,
                     #{run_timeout => 2000,
                       admission_control =>
                           #{server => adk_missing_admission_controller,
                             overflow => reject}}),
    try
        ok = adk_fault_session_service:set_update_state_fault(
               SessionId,
               {raise, {injected_restore_exception, Secret}}),
        {ok, Stream} = adk_runner:resume(
                         ResumeRunner, ?USER, SessionId, InvocationId,
                         #{<<"confirmed">> => true}),
        Reason = await_error(Stream),
        Result = {error, Reason},
        assert_restore_failure(
          Result, error, injected_restore_exception),
        assert_secret_absent(Secret, Result),
        ?assertEqual(
           {error, no_paused_invocation},
           begin
               ok = adk_fault_session_service:clear_update_state_fault(
                      SessionId),
               adk_runner:resume(
                 PauseRunner, ?USER, SessionId, InvocationId,
                 #{<<"confirmed">> => true})
           end)
    after
        stop_case(Agent, SessionId)
    end.

start_confirmation_pause(SessionId) ->
    Agent = spawn(fun() -> agent_loop(initial) end),
    Runner = adk_runner:new(
               Agent, ?APP, adk_fault_session_service,
               #{run_timeout => 2000}),
    {ok, Stream} = adk_runner:run_async(
                     Runner, ?USER, SessionId, <<"confirm">>),
    {Agent, Runner, await_pause(Stream)}.

agent_loop(Stage) ->
    receive
        {'$gen_call', From, get_runtime} ->
            gen_server:reply(
              From,
              {ok, <<"RestoreAgent">>, #{},
               [adk_static_confirmation_tool], #{}}),
            agent_loop(Stage);
        {'$gen_call', From, {run_with_events, _History, InvocationId}}
          when Stage =:= initial ->
            Calls = [{<<"static_confirmation_probe">>,
                      #{<<"id">> => <<"restore-probe">>},
                      <<"signature">>, <<"restore-call">>}],
            Event = adk_event:new(
                      <<"RestoreAgent">>, {tool_calls, Calls},
                      #{invocation_id => InvocationId}),
            gen_server:reply(From, {tool_calls, Event, Calls}),
            agent_loop(waiting);
        {'$gen_call', From, {run_with_events, _History, InvocationId}} ->
            Event = adk_event:new(
                      <<"RestoreAgent">>, <<"complete">>,
                      #{invocation_id => InvocationId, is_final => true}),
            gen_server:reply(From, {ok, Event}),
            agent_loop(complete);
        stop ->
            ok
    end.

await_pause(Stream) ->
    receive
        {adk_event, Stream, _Event} -> await_pause(Stream);
        {adk_paused, Stream, Pause} -> Pause;
        {adk_error, Stream, Reason} ->
            error({unexpected_runner_error, Reason})
    after 2000 ->
        error(pause_timeout)
    end.

await_error(Stream) ->
    receive
        {adk_event, Stream, _Event} -> await_error(Stream);
        {adk_error, Stream, Reason} -> Reason;
        {adk_done, Stream} -> error(unexpected_runner_completion);
        {adk_paused, Stream, _Pause} -> error(unexpected_runner_pause)
    after 2000 ->
        error(error_timeout)
    end.

assert_restore_failure(
  {error, {continuation_restore_failed, {adk_failure, Metadata}}},
  Class, Reason) ->
    ?assertEqual(runner, maps:get(component, Metadata)),
    ?assertEqual(continuation_restore, maps:get(operation, Metadata)),
    ?assertEqual(Class, maps:get(class, Metadata)),
    ?assertEqual(Reason, maps:get(reason, Metadata));
assert_restore_failure(Other, _Class, _Reason) ->
    error({expected_structural_restore_failure, Other}).

assert_secret_absent(Secret, Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), Secret)).

continuation_key(InvocationId) ->
    <<"__adk_runner_continuation:", InvocationId/binary>>.

stop_case(Agent, SessionId) ->
    Agent ! stop,
    ok = adk_fault_session_service:clear_update_state_fault(SessionId),
    _ = erlang_adk_session:delete_session(?APP, ?USER, SessionId),
    ok.

unique(Prefix) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<Prefix/binary, "-", Suffix/binary>>.
