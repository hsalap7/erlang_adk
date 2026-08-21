%% @doc Default Runner-backed bridge for a registered Erlang ADK agent.
%%
%% A2A contextId is the durable Runner session id and the authenticated scope
%% digest becomes the Runner user id.  Raw principals are never used as a
%% persistence key.  Follow-up messages resume a single persisted HITL
%% continuation in that session.  Calls made through the old direct two-field
%% request shape retain the prompt/2 compatibility behaviour.
-module(adk_a2a_v1_agent_executor).

-include("adk_event.hrl").

-export([execute/2]).

-ifdef(TEST).
-export([test_artifact_delta_events/2]).
-endif.

-define(DEFAULT_APP_NAME, <<"a2a">>).

execute(Request = #{message := Message}, Emit) when is_function(Emit, 1) ->
    case configured_agent() of
        {ok, Agent} ->
            case runner_request(Request) of
                true -> execute_runner(Agent, Request, Emit);
                false -> legacy_prompt(Agent, Message)
            end;
        {failed, _} = Failed -> Failed
    end.

configured_agent() ->
    case application:get_env(erlang_adk, a2a_v1_agent_name) of
        {ok, AgentName} when is_binary(AgentName) ->
            case adk_agent_registry:lookup(AgentName) of
                {ok, Agent} -> {ok, Agent};
                {error, not_found} -> {failed, agent_not_found}
            end;
        _ -> {failed, agent_not_configured}
    end.

runner_request(#{task_id := TaskId, context_id := ContextId,
                 scope := Scope}) ->
    valid_id(TaskId) andalso valid_id(ContextId) andalso
    is_binary(Scope) andalso byte_size(Scope) =:= 32;
runner_request(_) -> false.

execute_runner(Agent, Request, Emit) ->
    case build_runner(Agent) of
        {ok, Runner} ->
            UserId = base64url(maps:get(scope, Request)),
            SessionId = maps:get(context_id, Request),
            case runner_input(Request) of
                {ok, start, Input} ->
                    start_and_collect(Runner, UserId, SessionId,
                                      Input, Emit);
                {ok, resume, Input} ->
                    resume_and_collect(Runner, UserId, SessionId,
                                       Input, Emit);
                {error, _} = Error -> Error
            end;
        {failed, _} = Failed -> Failed
    end.

build_runner(Agent) ->
    AppName = application:get_env(erlang_adk, a2a_v1_app_name,
                                  ?DEFAULT_APP_NAME),
    case {valid_id(AppName), erlang_adk:runtime_runner_spec()} of
        {true, {ok, #{session_service := SessionService,
                      runner_options := Options}}}
          when is_atom(SessionService), is_map(Options) ->
            try adk_runner:new(Agent, AppName, SessionService, Options) of
                Runner -> {ok, Runner}
            catch
                _:_ -> {failed, runner_configuration_invalid}
            end;
        {false, _} -> {failed, a2a_app_name_invalid};
        {_, {error, _}} -> {failed, runtime_services_unavailable};
        _ -> {failed, runtime_services_invalid}
    end.

runner_input(#{continuation := true, message := Message}) ->
    case message_resume_value(Message) of
        {ok, Value} -> {ok, resume, Value};
        {error, _} = Error -> Error
    end;
runner_input(#{message := Message}) ->
    case message_text(Message) of
        {ok, Text} -> {ok, start, Text};
        {error, _} = Error -> Error
    end.

start_and_collect(Runner, UserId, SessionId, Input, Emit) ->
    try adk_runner:run_async(Runner, UserId, SessionId, Input) of
        {ok, Stream} -> collect(Stream, Emit, undefined)
    catch
        _:_ -> {failed, runner_start_failed}
    end.

resume_and_collect(Runner, UserId, SessionId, Input, Emit) ->
    try adk_runner:resume(Runner, UserId, SessionId, Input) of
        {ok, Stream} -> collect(Stream, Emit, undefined);
        {error, no_paused_invocation} -> {failed, continuation_not_found};
        {error, ambiguous_paused_invocation} ->
            {failed, ambiguous_continuation};
        {error, _} -> {failed, continuation_rejected}
    catch
        _:_ -> {failed, runner_resume_failed}
    end.

collect(Stream, Emit, Final0) ->
    Monitor = erlang:monitor(process, Stream),
    Owner = self(),
    Guard = spawn(fun() -> cancellation_guard(Owner, Stream) end),
    try collect_loop(Stream, Monitor, Emit, Final0)
    after Guard ! finished end.

collect_loop(Stream, Monitor, Emit, Final0) ->
    receive
        {adk_event, Stream, Event = #adk_event{}} ->
            Final = case Event#adk_event.is_final of
                true -> Event#adk_event.content;
                false -> Final0
            end,
            maybe_emit_progress(Event, Emit),
            collect_loop(Stream, Monitor, Emit, Final);
        {adk_done, Stream} ->
            erlang:demonitor(Monitor, [flush]),
            {ok, completed_output(Final0)};
        {adk_paused, Stream, PauseEvent = #adk_event{}} ->
            erlang:demonitor(Monitor, [flush]),
            {input_required, pause_message(PauseEvent)};
        {adk_error, Stream, {cancelled, _}} ->
            erlang:demonitor(Monitor, [flush]),
            {failed, cancelled};
        {adk_error, Stream, _Reason} ->
            erlang:demonitor(Monitor, [flush]),
            {failed, runner_failed};
        {'DOWN', Monitor, process, Stream, normal} ->
            {failed, runner_ended_without_terminal};
        {'DOWN', Monitor, process, Stream, _Reason} ->
            {failed, runner_stream_down}
    end.

maybe_emit_progress(#adk_event{author = <<"user">>}, _Emit) -> ok;
maybe_emit_progress(Event, Emit) ->
    State = <<"TASK_STATE_WORKING">>,
    Message = #{<<"parts">> =>
                    [#{<<"data">> =>
                           #{<<"type">> => <<"runner_progress">>,
                             <<"author">> => Event#adk_event.author,
                             <<"partial">> => Event#adk_event.partial,
                             <<"final">> => Event#adk_event.is_final},
                       <<"mediaType">> => <<"application/json">>}]},
    _ = Emit({status, State, Message}),
    emit_artifact_deltas(Event, Emit),
    ok.

emit_artifact_deltas(#adk_event{id = EventId, actions = Actions}, Emit) ->
    Effects = maps:get(<<"context_effects">>, Actions, []),
    lists:foreach(
      fun(Artifact) -> _ = Emit({artifact, Artifact, false, true}) end,
      artifact_delta_events(Effects, EventId, 1)).

artifact_delta_events([], _EventId, _Index) -> [];
artifact_delta_events(
  [#{<<"kind">> := <<"artifact_delta">>} = Effect | Rest],
  EventId, Index) ->
    ArtifactId = <<"runner-artifact-", EventId/binary, "-",
                   (integer_to_binary(Index))/binary>>,
    Artifact0 = #{<<"artifactId">> => ArtifactId,
                  <<"parts">> =>
                      [#{<<"data">> => Effect,
                         <<"mediaType">> =>
                             <<"application/vnd.erlang-adk.artifact-delta+json">>}]},
    Artifact = case maps:get(<<"name">>, Effect, undefined) of
        Name when is_binary(Name), Name =/= <<>> ->
            Artifact0#{<<"name">> => Name};
        _ -> Artifact0
    end,
    [Artifact | artifact_delta_events(Rest, EventId, Index + 1)];
artifact_delta_events([_ | Rest], EventId, Index) ->
    artifact_delta_events(Rest, EventId, Index + 1);
artifact_delta_events(_Malformed, _EventId, _Index) -> [].

pause_message(PauseEvent) ->
    Pause = maps:get(<<"pause">>, PauseEvent#adk_event.actions, #{}),
    #{<<"parts">> =>
          [#{<<"data">> => #{<<"type">> => <<"hitl">>,
                                <<"pause">> => Pause},
             <<"mediaType">> => <<"application/json">>}]}.

completed_output(undefined) -> <<>>;
completed_output(Value) -> Value.

legacy_prompt(Agent, Message) ->
    case message_text(Message) of
        {ok, Prompt} -> erlang_adk:prompt(Agent, Prompt);
        {error, _} = Error -> Error
    end.

message_text(#{<<"parts">> := Parts}) ->
    Text = [Value || #{<<"text">> := Value} <- Parts],
    case Text of
        [] -> {error, text_input_required};
        _ -> {ok, iolist_to_binary(lists:join(<<"\n">>, Text))}
    end.

message_resume_value(#{<<"parts">> := Parts}) ->
    Data = [Value || #{<<"data">> := Value} <- Parts],
    case Data of
        [Value] -> {ok, Value};
        [] -> message_text(#{<<"parts">> => Parts});
        _ -> {error, exactly_one_resume_value_required}
    end.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                          byte_size(Value) =< 512 ->
    unicode:characters_to_binary(Value, utf8, utf8) =:= Value;
valid_id(_) -> false.

base64url(Binary) ->
    Encoded = base64:encode(Binary),
    NoPadding = binary:replace(Encoded, <<"=">>, <<>>, [global]),
    binary:replace(binary:replace(NoPadding, <<"+">>, <<"-">>, [global]),
                   <<"/">>, <<"_">>, [global]).

cancellation_guard(Owner, Stream) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    StreamMonitor = erlang:monitor(process, Stream),
    receive
        finished ->
            erlang:demonitor(OwnerMonitor, [flush]),
            erlang:demonitor(StreamMonitor, [flush]),
            ok;
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            _ = catch adk_runner:cancel(Stream, a2a_task_cancelled),
            erlang:demonitor(StreamMonitor, [flush]),
            ok;
        {'DOWN', StreamMonitor, process, Stream, _Reason} ->
            erlang:demonitor(OwnerMonitor, [flush]),
            ok
    end.

-ifdef(TEST).
test_artifact_delta_events(EventId, Actions)
  when is_binary(EventId), is_map(Actions) ->
    artifact_delta_events(
      maps:get(<<"context_effects">>, Actions, []), EventId, 1).
-endif.
