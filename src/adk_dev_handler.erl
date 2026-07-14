%% @doc HTTP boundary for the opt-in local ADK developer platform.
%%
%% The handler is deliberately provider-neutral.  Agents are resolved through
%% the stable binary-name registry, while execution and replay are delegated to
%% adk_run.  The bearer credential is never accepted from the URI.
-module(adk_dev_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-include("../include/adk_event.hrl").

-define(JSON, <<"application/json; charset=utf-8">>).
-define(SSE, <<"text/event-stream; charset=utf-8">>).

-spec init(cowboy_req:req(), map()) ->
    {ok, cowboy_req:req(), map()}.
init(Req0, State = #{endpoint := ui}) ->
    handle_ui(Req0, State);
init(Req0, State) ->
    case authorize_api(Req0, State) of
        ok -> dispatch(Req0, State);
        {error, unauthorized} ->
            error_reply(
              401, <<"unauthorized">>, <<"Bearer authentication required">>,
              #{<<"www-authenticate">> =>
                    <<"Bearer realm=\"erlang_adk_dev\"">>}, Req0, State);
        {error, forbidden} ->
            error_reply(403, <<"forbidden">>, <<"Access denied">>,
                        #{}, Req0, State);
        {error, unavailable} ->
            error_reply(503, <<"developer_api_unavailable">>,
                        <<"Developer API authentication is not configured">>,
                        #{}, Req0, State)
    end.

authorize_api(Req, State) ->
    case adk_dev_auth:authorize(Req, State) of
        ok ->
            case adk_dev_auth:same_origin(Req) of
                true -> ok;
                false -> {error, forbidden}
            end;
        {error, _} = Error -> Error
    end.

dispatch(Req, State = #{endpoint := runs}) ->
    handle_runs(Req, State);
dispatch(Req, State = #{endpoint := agents}) ->
    handle_agents(Req, State);
dispatch(Req, State = #{endpoint := diagnostics}) ->
    handle_diagnostics(Req, State);
dispatch(Req, State = #{endpoint := context_diagnostic}) ->
    handle_context_diagnostic(Req, State);
dispatch(Req, State = #{endpoint := context_lifecycle}) ->
    handle_context_lifecycle(Req, State);
dispatch(Req, State = #{endpoint := context_cache_invalidate}) ->
    handle_context_cache_invalidate(Req, State);
dispatch(Req, State = #{endpoint := artifacts}) ->
    handle_artifacts(Req, State);
dispatch(Req, State = #{endpoint := artifact_versions}) ->
    handle_artifact_versions(Req, State);
dispatch(Req, State = #{endpoint := artifact_delete}) ->
    handle_artifact_delete(Req, State);
dispatch(Req, State = #{endpoint := memory_status}) ->
    handle_memory_status(Req, State);
dispatch(Req, State = #{endpoint := memory_search}) ->
    handle_memory_search(Req, State);
dispatch(Req, State = #{endpoint := memory_erase}) ->
    handle_memory_erase(Req, State);
dispatch(Req, State = #{endpoint := run}) ->
    handle_run(Req, State);
dispatch(Req, State = #{endpoint := run_events}) ->
    handle_run_events(Req, State);
dispatch(Req, State = #{endpoint := run_resume}) ->
    handle_run_resume(Req, State);
dispatch(Req, State = #{endpoint := sessions}) ->
    handle_sessions(Req, State);
dispatch(Req, State = #{endpoint := session_state}) ->
    handle_session_state(Req, State);
dispatch(Req, State = #{endpoint := session}) ->
    handle_session(Req, State).

handle_agents(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            Names = lists:sort(
                      [Name || {Name, Pid} <- adk_agent_registry:list(),
                               is_binary(Name), is_pid(Pid),
                               is_process_alive(Pid),
                               adk_agent_registry:whereis_name(Name) =:= Pid]),
            Agents = [#{<<"name">> => Name} || Name <- Names],
            json_reply(200,
                       #{<<"schema_version">> => 1,
                         <<"agents">> => Agents,
                         <<"total">> => length(Agents)},
                       #{}, Req0, State);
        _ ->
            method_not_allowed(<<"GET">>, Req0, State)
    end.

handle_ui(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            {Body, Csp} = adk_dev_ui:render(),
            Headers = (security_headers())#{
                <<"content-type">> => <<"text/html; charset=utf-8">>,
                <<"content-security-policy">> => Csp
            },
            Req1 = cowboy_req:reply(200, Headers, Body, Req0),
            {ok, Req1, State};
        _ ->
            method_not_allowed(<<"GET">>, Req0, State)
    end.

handle_runs(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> start_run(Req0, State);
        _ -> method_not_allowed(<<"POST">>, Req0, State)
    end.

start_run(Req0, State) ->
    case is_json_request(Req0) of
        false ->
            error_reply(415, <<"unsupported_media_type">>,
                        <<"Content-Type must be application/json">>,
                        #{}, Req0, State);
        true ->
            Max = maps:get(max_body_bytes, State),
            case body_too_large(Req0, Max) of
                true -> payload_too_large(Req0, State);
                false ->
                    case read_body(Req0, <<>>, Max) of
                        {ok, Body, Req1} -> decode_start(Body, Req1, State);
                        {error, payload_too_large, Req1} ->
                            payload_too_large(Req1, State)
                    end
            end
    end.

decode_start(Body, Req, State) ->
    Decoded = try jsx:decode(Body, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, invalid_json}
    end,
    case Decoded of
        {ok, Payload} when is_map(Payload) ->
            case validate_start_payload(Payload, State) of
                {ok, Fields} -> launch_run(Fields, Req, State);
                {error, Code, Message} ->
                    error_reply(400, Code, Message, #{}, Req, State)
            end;
        _ ->
            error_reply(400, <<"invalid_json">>,
                        <<"Request body must be a JSON object">>,
                        #{}, Req, State)
    end.

validate_start_payload(Payload, State) ->
    Required = [<<"agent_name">>, <<"app_name">>, <<"user_id">>,
                <<"session_id">>, <<"message">>],
    case lists:sort(maps:keys(Payload)) =:= lists:sort(Required) of
        false ->
            {error, <<"invalid_request">>,
             <<"Expected agent_name, app_name, user_id, session_id, and message">>};
        true ->
            Agent = maps:get(<<"agent_name">>, Payload),
            App = maps:get(<<"app_name">>, Payload),
            User = maps:get(<<"user_id">>, Payload),
            Session = maps:get(<<"session_id">>, Payload),
            Message = maps:get(<<"message">>, Payload),
            MaxField = maps:get(max_field_bytes, State),
            MaxMessage = maps:get(max_body_bytes, State),
            case valid_field(Agent, MaxField) andalso
                 valid_field(App, MaxField) andalso
                 valid_field(User, MaxField) andalso
                 valid_field(Session, MaxField) andalso
                 valid_field(Message, MaxMessage) of
                true ->
                    {ok, #{agent => Agent, app => App, user => User,
                           session => Session, message => Message}};
                false ->
                    {error, <<"invalid_request">>,
                     <<"Fields must be non-empty UTF-8 strings within configured limits">>}
            end
    end.

launch_run(#{agent := AgentName, app := AppName, user := UserId,
             session := SessionId, message := Message}, Req, State) ->
    case adk_agent_registry:lookup(AgentName) of
        {error, not_found} ->
            error_reply(404, <<"agent_not_found">>,
                        <<"Agent is not registered">>, #{}, Req, State);
        {ok, AgentPid} ->
            try
                Runner = adk_runner:new(
                           AgentPid, AppName,
                           maps:get(session_service, State),
                           maps:get(runner_options, State)),
                case adk_run:start(Runner, UserId, SessionId, Message,
                                   maps:get(run_options, State)) of
                    {ok, RunId} ->
                        RunPath = <<"/dev/v1/runs/", RunId/binary>>,
                        Body = #{<<"run_id">> => RunId,
                                 <<"state">> => <<"running">>,
                                 <<"status_url">> => RunPath,
                                 <<"events_url">> =>
                                     <<RunPath/binary, "/events">>},
                        json_reply(202, Body,
                                   #{<<"location">> => RunPath}, Req, State);
                    {error, Reason} ->
                        run_start_error(Reason, Req, State)
                end
            catch
                _:_ ->
                    error_reply(500, <<"run_start_failed">>,
                                <<"The run could not be started">>,
                                #{}, Req, State)
            end
    end.

run_start_error(invocation_supervisor_not_started, Req, State) ->
    error_reply(503, <<"run_service_unavailable">>,
                <<"The invocation supervisor is not running">>,
                #{}, Req, State);
run_start_error(_Reason, Req, State) ->
    error_reply(500, <<"run_start_failed">>,
                <<"The run could not be started">>, #{}, Req, State).

handle_run(Req0, State) ->
    case validated_binding(run_id, Req0, State) of
        {error, Req1} -> {ok, Req1, State};
        {ok, RunId} ->
            case cowboy_req:method(Req0) of
                <<"GET">> -> get_run(RunId, Req0, State);
                <<"DELETE">> -> cancel_run(RunId, Req0, State);
                _ -> method_not_allowed(<<"GET, DELETE">>, Req0, State)
            end
    end.

get_run(RunId, Req, State) ->
    case adk_run:status(RunId) of
        {ok, Status} -> json_reply(200, status_json(Status), #{}, Req, State);
        {error, not_found} -> not_found(<<"run_not_found">>, Req, State);
        {error, _} -> service_unavailable(Req, State)
    end.

cancel_run(RunId, Req, State) ->
    case adk_run:cancel(RunId, developer_cancelled) of
        ok ->
            json_reply(202, #{<<"run_id">> => RunId,
                              <<"state">> => <<"cancelling">>},
                       #{}, Req, State);
        {error, already_terminal} ->
            error_reply(409, <<"run_already_terminal">>,
                        <<"The run has already finished">>, #{}, Req, State);
        {error, not_found} -> not_found(<<"run_not_found">>, Req, State);
        {error, _} -> service_unavailable(Req, State)
    end.

handle_run_resume(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case validated_binding(run_id, Req0, State) of
                {error, Req1} -> {ok, Req1, State};
                {ok, RunId} -> read_resume_request(RunId, Req0, State)
            end;
        _ -> method_not_allowed(<<"POST">>, Req0, State)
    end.

read_resume_request(RunId, Req0, State) ->
    case is_json_request(Req0) of
        false ->
            error_reply(415, <<"unsupported_media_type">>,
                        <<"Content-Type must be application/json">>,
                        #{}, Req0, State);
        true ->
            Max = maps:get(max_body_bytes, State),
            case body_too_large(Req0, Max) of
                true -> payload_too_large(Req0, State);
                false ->
                    case read_body(Req0, <<>>, Max) of
                        {ok, Body, Req1} ->
                            decode_resume(RunId, Body, Req1, State);
                        {error, payload_too_large, Req1} ->
                            payload_too_large(Req1, State)
                    end
            end
    end.

decode_resume(RunId, Body, Req, State) ->
    Decoded = try jsx:decode(Body, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, invalid_json}
    end,
    case Decoded of
        {ok, #{<<"tool_response">> := ToolResponse} = Payload}
          when map_size(Payload) =:= 1 ->
            resume_run(RunId, ToolResponse, Req, State);
        _ ->
            error_reply(
              400, <<"invalid_resume_request">>,
              <<"Expected a JSON object containing only tool_response">>,
              #{}, Req, State)
    end.

resume_run(RunId, ToolResponse, Req, State) ->
    case adk_run:resume(
           RunId, ToolResponse, maps:get(run_options, State)) of
        {ok, NewRunId} ->
            RunPath = <<"/dev/v1/runs/", NewRunId/binary>>,
            Body = #{<<"run_id">> => NewRunId,
                     <<"parent_run_id">> => RunId,
                     <<"state">> => <<"running">>,
                     <<"status_url">> => RunPath,
                     <<"events_url">> => <<RunPath/binary, "/events">>},
            json_reply(202, Body, #{<<"location">> => RunPath}, Req, State);
        {error, not_found} ->
            not_found(<<"run_not_found">>, Req, State);
        {error, run_not_paused} ->
            error_reply(409, <<"run_not_paused">>,
                        <<"Only a paused run can be resumed">>, #{}, Req,
                        State);
        {error, {already_resumed, ExistingRunId}} ->
            json_reply(
              409,
              #{<<"error">> =>
                    #{<<"code">> => <<"run_already_resumed">>,
                      <<"message">> =>
                          <<"The paused run has already been resumed">>,
                      <<"resumed_run_id">> => ExistingRunId}},
              #{}, Req, State);
        {error, _Reason} ->
            service_unavailable(Req, State)
    end.

handle_run_events(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            case validated_binding(run_id, Req0, State) of
                {error, Req1} -> {ok, Req1, State};
                {ok, RunId} -> open_event_stream(RunId, Req0, State)
            end;
        _ -> method_not_allowed(<<"GET">>, Req0, State)
    end.

open_event_stream(RunId, Req0, State) ->
    case last_event_id(Req0) of
        {error, invalid_last_event_id} ->
            error_reply(400, <<"invalid_last_event_id">>,
                        <<"Last-Event-ID must be a non-negative integer">>,
                        #{}, Req0, State);
        {ok, Cursor} ->
            case adk_run:subscribe_credit(RunId, Cursor) of
                {ok, Subscription} ->
                    Headers = (security_headers())#{
                        <<"content-type">> => ?SSE,
                        <<"cache-control">> => <<"no-cache, no-transform">>,
                        <<"x-accel-buffering">> => <<"no">>
                    },
                    Req1 = cowboy_req:stream_reply(200, Headers, Req0),
                    Limits = sse_limits(State),
                    try maybe_stream_subscription(
                          RunId, Cursor, Subscription, Limits, Req1) of
                        Req2 -> {ok, Req2, State}
                    after
                        %% This does not cancel the supervised invocation.
                        _ = catch adk_run:unsubscribe(RunId, self())
                    end;
                {error, {replay_gap, Gap}} ->
                    replay_gap_reply(Gap, Req0, State);
                {error, {cursor_ahead, Details}} ->
                    cursor_ahead_reply(Details, Req0, State);
                {error, not_found} ->
                    not_found(<<"run_not_found">>, Req0, State);
                {error, _} ->
                    service_unavailable(Req0, State)
            end
    end.

maybe_stream_subscription(_RunId, Cursor,
                          #{terminal := true, latest_sequence := Cursor},
                          _Limits, Req) ->
    _ = safe_stream_body(<<>>, fin, Req),
    Req;
maybe_stream_subscription(RunId, Cursor, _Subscription, Limits, Req) ->
    sse_loop(RunId, Cursor, Limits, Req).

sse_limits(State) ->
    #{heartbeat_ms => maps:get(sse_heartbeat_ms, State),
      max_events => maps:get(sse_max_events, State),
      max_bytes => maps:get(sse_max_bytes, State),
      max_duration_ms => maps:get(sse_max_duration_ms, State),
      event_count => 0,
      encoded_bytes => 0,
      deadline => erlang:monotonic_time(millisecond) +
                  maps:get(sse_max_duration_ms, State)}.

sse_loop(RunId, Cursor, Limits, Req) ->
    Remaining = maps:get(deadline, Limits) -
                erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            _ = safe_stream_body(<<>>, fin, Req),
            Req;
        false ->
            Wait = min(maps:get(heartbeat_ms, Limits), Remaining),
            sse_receive(RunId, Cursor, Limits, Wait, Req)
    end.

sse_receive(RunId, Cursor, Limits, Wait, Req) ->
    receive
        {adk_run_event, RunId, Seq, Event} when Seq > Cursor ->
            Body = encode_sse(<<"event">>, Seq, event_json(Event)),
            case stream_counted(Body, true, nofin, Limits, Req) of
                {ok, Limits1} ->
                    Ack = adk_run:ack(RunId, Seq),
                    continue_after_ack(
                      Ack, RunId, Seq, Limits1, Req);
                limit -> close_sse(Req);
                closed -> Req
            end;
        {adk_run_event, RunId, _Seq, _Event} ->
            %% Credit delivery should never duplicate a sequence. Ignore a
            %% stale mailbox item defensively without returning credit for it.
            sse_loop(RunId, Cursor, Limits, Req);
        {adk_run_terminal, RunId, Seq, Outcome} when Seq > Cursor ->
            Body = encode_sse(<<"terminal">>, Seq, outcome_json(Outcome)),
            case stream_counted(Body, true, fin, Limits, Req) of
                {ok, _Limits1} -> ok;
                limit -> _ = safe_stream_body(<<>>, fin, Req);
                closed -> ok
            end,
            Req;
        {adk_run_terminal, RunId, _Seq, _Outcome} ->
            _ = safe_stream_body(<<>>, fin, Req),
            Req;
        {adk_run_replay_gap, RunId, Gap} ->
            stream_replay_gap(Gap, Limits, Req)
    after Wait ->
        case erlang:monotonic_time(millisecond) >=
             maps:get(deadline, Limits) of
            true -> close_sse(Req);
            false ->
                Heartbeat = <<": heartbeat\n\n">>,
                case stream_counted(
                       Heartbeat, false, nofin, Limits, Req) of
                    {ok, Limits1} -> sse_loop(RunId, Cursor, Limits1, Req);
                    limit -> close_sse(Req);
                    closed -> Req
                end
        end
    end.

continue_after_ack(ok, RunId, Seq, Limits, Req) ->
    case at_sse_limit(Limits) of
        true -> close_sse(Req);
        false -> sse_loop(RunId, Seq, Limits, Req)
    end;
continue_after_ack({error, {replay_gap, Gap}}, _RunId, _Seq, Limits, Req) ->
    stream_replay_gap(Gap, Limits, Req);
continue_after_ack(_Error, _RunId, _Seq, _Limits, Req) ->
    close_sse(Req).

encode_sse(EventName, Seq, Data) ->
    Json = jsx:encode(Data),
    <<"id: ", (integer_to_binary(Seq))/binary,
      "\nevent: ", EventName/binary,
      "\ndata: ", Json/binary, "\n\n">>.

stream_replay_gap(Gap, Limits, Req) ->
    Json = jsx:encode(replay_gap_json(Gap)),
    Body = <<"event: replay_gap\ndata: ", Json/binary, "\n\n">>,
    case stream_counted(Body, true, fin, Limits, Req) of
        {ok, _Limits1} -> Req;
        limit -> close_sse(Req);
        closed -> Req
    end.

stream_counted(Body, CountsAsEvent, Fin, Limits, Req) ->
    EventIncrement = case CountsAsEvent of true -> 1; false -> 0 end,
    NewEvents = maps:get(event_count, Limits) + EventIncrement,
    NewBytes = maps:get(encoded_bytes, Limits) + byte_size(Body),
    case NewEvents =< maps:get(max_events, Limits) andalso
         NewBytes =< maps:get(max_bytes, Limits) of
        false -> limit;
        true ->
            case safe_stream_body(Body, Fin, Req) of
                ok -> {ok, Limits#{event_count => NewEvents,
                                  encoded_bytes => NewBytes}};
                closed -> closed
            end
    end.

at_sse_limit(Limits) ->
    maps:get(event_count, Limits) >= maps:get(max_events, Limits) orelse
    maps:get(encoded_bytes, Limits) >= maps:get(max_bytes, Limits).

close_sse(Req) ->
    _ = safe_stream_body(<<>>, fin, Req),
    Req.

%% ------------------------------------------------------------------
%% v0.5 scoped resource diagnostics
%% ------------------------------------------------------------------

handle_diagnostics(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            Body = #{<<"schema_version">> => 1,
                     <<"context">> =>
                         json_safe(adk_context_policy:capabilities()),
                     <<"resources">> =>
                         #{<<"artifact">> => resource_source(artifact, State),
                           <<"memory">> => resource_source(memory, State)},
                     <<"scope_required">> => true,
                     <<"artifact_bytes_exposed">> => false},
            json_reply(200, Body, #{}, Req0, State);
        _ -> method_not_allowed(<<"GET">>, Req0, State)
    end.

handle_context_diagnostic(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            case validated_session_bindings(Req0, State) of
                {ok, App, User, Session} ->
                    context_diagnostic(App, User, Session, Req0, State);
                {error, Req1} -> {ok, Req1, State}
            end;
        _ -> method_not_allowed(<<"GET">>, Req0, State)
    end.

context_diagnostic(App, User, Session, Req, State) ->
    Service = maps:get(session_service, State),
    case safe_session_service_call(
           Service, get_session, [App, User, Session]) of
        {ok, SessionMap} when is_map(SessionMap) ->
            Policy = maps:get(diagnostic_context_policy, State),
            case adk_context_policy:build(SessionMap, Policy) of
                {ok, Result} ->
                    json_reply(
                      200,
                      #{<<"schema_version">> => 1,
                        <<"scope">> => session_scope_json(App, User, Session),
                        <<"context">> => public_context_result(Result)},
                      #{}, Req, State);
                {error, _} ->
                    error_reply(
                      422, <<"context_diagnostic_failed">>,
                      <<"The session context could not be analyzed">>,
                      #{}, Req, State)
            end;
        {error, not_found} ->
            not_found(<<"session_not_found">>, Req, State);
        _ -> diagnostic_unavailable(Req, State)
    end.

public_context_result(Result) ->
    Fingerprint = maps:get(context_fingerprint, Result),
    #{<<"version">> => maps:get(version, Result),
      <<"bytes">> => maps:get(bytes, Result),
      <<"estimated_tokens">> => maps:get(estimated_tokens, Result),
      <<"input_events">> => maps:get(input_events, Result),
      <<"output_events">> => maps:get(output_events, Result),
      <<"dropped_events">> => maps:get(dropped_events, Result),
      <<"compressed">> => maps:get(compressed, Result),
      <<"fingerprint">> =>
          #{<<"value">> => maps:get(value, Fingerprint),
            <<"algorithm">> => maps:get(algorithm, Fingerprint),
            <<"encoding">> => maps:get(encoding, Fingerprint),
            <<"context_version">> => maps:get(context_version, Fingerprint),
            <<"event_codec_version">> =>
                maps:get(event_codec_version, Fingerprint)}}.

%% Context lifecycle diagnostics deliberately use a separate endpoint from the
%% context fingerprint view. A lifecycle response contains only whitelisted
%% checkpoint fields and scoped cache counts; it never serializes an event,
%% summary, policy, cache handle, lease, or provider resource.
handle_context_lifecycle(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            case validated_session_bindings(Req0, State) of
                {ok, App, User, Session} ->
                    inspect_context_lifecycle(
                      App, User, Session, Req0, State);
                {error, Req1} -> {ok, Req1, State}
            end;
        _ -> method_not_allowed(<<"GET">>, Req0, State)
    end.

inspect_context_lifecycle(App, User, Session, Req, State) ->
    case lifecycle_model(Req, State) of
        {error, Message} ->
            error_reply(400, <<"invalid_context_lifecycle_query">>,
                        Message, #{}, Req, State);
        {ok, Model} ->
            Service = maps:get(session_service, State),
            case safe_session_service_call(
                   Service, get_session, [App, User, Session]) of
                {ok, SessionMap} when is_map(SessionMap) ->
                    case public_cache_status(App, User, Model, State) of
                        {ok, CacheStatus} ->
                            Events = maps:get(events, SessionMap, []),
                            Compaction = public_compaction_lifecycle(
                                           Events, State),
                            json_reply(
                              200,
                              #{<<"schema_version">> => 1,
                                <<"scope">> => session_scope_json(
                                                   App, User, Session),
                                <<"compaction">> => Compaction,
                                <<"cache">> => CacheStatus},
                              #{}, Req, State);
                        {error, not_configured} ->
                            json_reply(
                              200,
                              #{<<"schema_version">> => 1,
                                <<"scope">> => session_scope_json(
                                                   App, User, Session),
                                <<"compaction">> =>
                                    public_compaction_lifecycle(
                                      maps:get(events, SessionMap, []), State),
                                <<"cache">> =>
                                    #{<<"configured">> => false,
                                      <<"status">> => <<"disabled">>}},
                              #{}, Req, State);
                        {error, _} -> context_cache_unavailable(Req, State)
                    end;
                {error, not_found} ->
                    not_found(<<"session_not_found">>, Req, State);
                _ -> diagnostic_unavailable(Req, State)
            end
    end.

handle_context_cache_invalidate(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case validated_session_bindings(Req0, State) of
                {ok, App, User, Session} ->
                    read_context_cache_invalidation(
                      App, User, Session, Req0, State);
                {error, Req1} -> {ok, Req1, State}
            end;
        _ -> method_not_allowed(<<"POST">>, Req0, State)
    end.

read_context_cache_invalidation(App, User, Session, Req0, State) ->
    case read_json_object(Req0, State) of
        {error, Req1} -> {ok, Req1, State};
        {ok, Payload, Req1} ->
            Model = maps:get(<<"model">>, Payload, undefined),
            case valid_field(Model, maps:get(max_field_bytes, State))
                 andalso lists:sort(maps:keys(Payload)) =:=
                         [<<"confirm">>, <<"model">>] of
                false ->
                    error_reply(
                      400, <<"invalid_context_cache_invalidation">>,
                      <<"Supply a bounded model and exact confirmation">>,
                      #{}, Req1, State);
                true ->
                    invalidate_context_cache(
                      App, User, Session, Model, Payload, Req1, State)
            end
    end.

invalidate_context_cache(App, User, Session, Model, Payload, Req, State) ->
    case configured_context_cache(State) of
        {error, not_configured} -> context_cache_unavailable(Req, State);
        {error, _} -> context_cache_unavailable(Req, State);
        {ok, Config} ->
            Deadline = lifecycle_deadline(State),
            Scope = cache_scope(App, User, Model, Config),
            case call_context_cache(
                   Config, scope_status, [maps:get(provider, Config), Scope],
                   Deadline) of
                {ok, Status} when is_map(Status) ->
                    Fingerprint = maps:get(
                                    <<"scope_fingerprint">>, Status,
                                    undefined),
                    Expected = #{<<"app_name">> => App,
                                 <<"user_id">> => User,
                                 <<"session_id">> => Session,
                                 <<"model">> => Model,
                                 <<"scope_fingerprint">> => Fingerprint},
                    case maps:get(<<"confirm">>, Payload, undefined) =:=
                         Expected andalso is_binary(Fingerprint) of
                        false ->
                            error_reply(
                              400,
                              <<"invalid_context_cache_invalidation">>,
                              <<"Confirmation must exactly match app, user, session, model, and scope fingerprint">>,
                              #{}, Req, State);
                        true ->
                            commit_context_cache_invalidation(
                              Config, Scope, App, User, Session, Model,
                              Fingerprint, Deadline, Req, State)
                    end;
                _ -> context_cache_unavailable(Req, State)
            end
    end.

commit_context_cache_invalidation(Config, Scope, App, User, Session, Model,
                                  Fingerprint, Deadline, Req, State) ->
    case call_context_cache(
           Config, invalidate_scope, [maps:get(provider, Config), Scope],
           Deadline) of
        {ok, Result} when is_map(Result) ->
            json_reply(
              200,
              #{<<"schema_version">> => 1,
                <<"scope">> => session_scope_json(App, User, Session),
                <<"cache">> =>
                    #{<<"configured">> => true,
                      <<"status">> => <<"invalidated">>,
                      <<"model">> => Model,
                      <<"scope_fingerprint">> => Fingerprint,
                      <<"entries">> => maps:get(<<"entries">>, Result, 0),
                      <<"in_flight">> =>
                          maps:get(<<"in_flight">>, Result, 0)}},
              #{}, Req, State);
        _ -> context_cache_unavailable(Req, State)
    end.

lifecycle_model(Req, State) ->
    case checked_query(Req, [<<"model">>]) of
        {ok, Params} ->
            Model = maps:get(<<"model">>, Params, undefined),
            case configured_context_cache(State) of
                {error, not_configured} ->
                    case Model of
                        undefined -> {ok, undefined};
                        _ -> checked_lifecycle_model(Model, State)
                    end;
                {ok, _} -> checked_lifecycle_model(Model, State);
                {error, _} -> {error, <<"Context cache configuration is invalid">>}
            end;
        {error, _} ->
            {error, <<"Only one model query parameter is allowed">>}
    end.

checked_lifecycle_model(Model, State) ->
    case valid_field(Model, maps:get(max_field_bytes, State)) of
        true -> {ok, Model};
        false -> {error, <<"model is required and must be a bounded UTF-8 string">>}
    end.

configured_context_cache(State) ->
    RunnerOptions = maps:get(runner_options, State, #{}),
    case maps:get(context_cache, RunnerOptions, disabled) of
        disabled -> {error, not_configured};
        Options when is_map(Options) ->
            Unknown = maps:keys(
                        maps:without([cache, provider, ttl_ms, policy],
                                     Options)),
            Cache = maps:get(cache, Options, undefined),
            Provider = maps:get(provider, Options, undefined),
            Ttl = maps:get(ttl_ms, Options, 300000),
            Policy0 = maps:get(policy, Options, #{}),
            case {Unknown, is_pid(Cache) andalso is_process_alive(Cache),
                  is_atom(Provider), is_integer(Ttl) andalso Ttl > 0
                                     andalso Ttl =< 86400000,
                  adk_json:normalize(Policy0)} of
                {[], true, true, true, {ok, Policy}}
                  when is_map(Policy) ->
                    {ok, #{cache => Cache, provider => Provider,
                           ttl_ms => Ttl, policy => Policy}};
                _ -> {error, invalid_context_cache_configuration}
            end;
        _ -> {error, invalid_context_cache_configuration}
    end.

cache_scope(App, User, Model, Config) ->
    #{app => App, user => User, model => Model,
      policy => maps:get(policy, Config)}.

public_cache_status(_App, _User, undefined, _State) ->
    {error, not_configured};
public_cache_status(App, User, Model, State) ->
    case configured_context_cache(State) of
        {ok, Config} ->
            Deadline = lifecycle_deadline(State),
            Scope = cache_scope(App, User, Model, Config),
            case call_context_cache(
                   Config, scope_status, [maps:get(provider, Config), Scope],
                   Deadline) of
                {ok, Status} when is_map(Status) ->
                    {ok, #{<<"configured">> => true,
                           <<"semantics">> =>
                               <<"provider_request_prefix_cache">>,
                           <<"response_cache">> => false,
                           <<"status">> =>
                               maps:get(<<"status">>, Status, <<"unknown">>),
                           <<"model">> => Model,
                           <<"scope_fingerprint">> =>
                               maps:get(<<"scope_fingerprint">>, Status),
                           <<"ttl_ms">> => maps:get(ttl_ms, Config),
                           <<"entries">> =>
                               maps:get(<<"entries">>, Status, 0),
                           <<"in_flight">> =>
                               maps:get(<<"in_flight">>, Status, 0),
                           <<"waiters">> =>
                               maps:get(<<"waiters">>, Status, 0)}};
                _ -> {error, unavailable}
            end;
        {error, _} = Error -> Error
    end.

call_context_cache(Config, Function, Args, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        true ->
            Ref = {adk_context_cache, maps:get(cache, Config)},
            adk_service_ref:call(
              Ref, Function, Args ++ [#{deadline_ms => Deadline}],
              Remaining);
        false -> {error, context_cache_deadline_exceeded}
    end.

lifecycle_deadline(State) ->
    erlang:monotonic_time(millisecond)
    + maps:get(diagnostic_timeout_ms, State).

public_compaction_lifecycle(Events, State) when is_list(Events) ->
    case latest_public_checkpoint(lists:reverse(Events), State) of
        {ok, Checkpoint} ->
            #{<<"status">> => <<"checkpointed">>,
              <<"checkpoint">> => Checkpoint};
        none -> #{<<"status">> => <<"none">>}
    end;
public_compaction_lifecycle(_, _State) ->
    #{<<"status">> => <<"unavailable">>}.

latest_public_checkpoint([], _State) -> none;
latest_public_checkpoint([Event | Rest], State) ->
    case event_compaction_checkpoint(Event) of
        Checkpoint when is_map(Checkpoint) ->
            case public_compaction_checkpoint(Checkpoint, State) of
                {ok, Public} -> {ok, Public};
                error -> latest_public_checkpoint(Rest, State)
            end;
        _ -> latest_public_checkpoint(Rest, State)
    end.

event_compaction_checkpoint(#adk_event{actions = Actions}) ->
    maps:get(<<"context_compaction_checkpoint">>, Actions, undefined);
event_compaction_checkpoint(Event) when is_map(Event) ->
    Actions = maps:get(<<"actions">>, Event,
                       maps:get(actions, Event, #{})),
    case is_map(Actions) of
        true -> maps:get(<<"context_compaction_checkpoint">>, Actions,
                         maps:get(context_compaction_checkpoint, Actions,
                                  undefined));
        false -> undefined
    end;
event_compaction_checkpoint(_) -> undefined.

public_compaction_checkpoint(Checkpoint, State) ->
    Max = maps:get(max_field_bytes, State),
    Kind = maps:get(<<"kind">>, Checkpoint, undefined),
    Schema = maps:get(<<"schema_version">>, Checkpoint, undefined),
    case Kind =:= <<"context_compaction_checkpoint">>
         andalso is_integer(Schema) andalso Schema > 0 of
        false -> error;
        true ->
            Base = #{<<"schema_version">> => Schema, <<"kind">> => Kind},
            Fields = copy_checkpoint_fields(
                       Checkpoint,
                       [{<<"checkpoint_id">>, binary},
                        {<<"summary_event_id">>, binary},
                        {<<"trigger">>, binary},
                        {<<"retained_event_count">>, non_negative_integer},
                        {<<"retained_user_turns">>, non_negative_integer},
                        {<<"summary_bytes">>, non_negative_integer}],
                       Max, Base),
            Source = public_checkpoint_source(
                       maps:get(<<"source">>, Checkpoint, undefined), Max),
            {ok, case Source of
                undefined -> Fields;
                _ -> Fields#{<<"source">> => Source}
            end}
    end.

public_checkpoint_source(Source, Max) when is_map(Source) ->
    copy_checkpoint_fields(
      Source,
      [{<<"event_count">>, non_negative_integer},
       {<<"first_event_id">>, binary},
       {<<"last_event_id">>, binary},
       {<<"first_timestamp">>, integer},
       {<<"last_timestamp">>, integer},
       {<<"fingerprint">>, binary}], Max, #{});
public_checkpoint_source(_, _Max) -> undefined.

copy_checkpoint_fields(_Map, [], _Max, Acc) -> Acc;
copy_checkpoint_fields(Map, [{Key, Type} | Rest], Max, Acc) ->
    Acc1 = case maps:find(Key, Map) of
        {ok, Value} ->
            case valid_checkpoint_value(Type, Value, Max) of
                true -> Acc#{Key => Value};
                false -> Acc
            end;
        error -> Acc
    end,
    copy_checkpoint_fields(Map, Rest, Max, Acc1).

valid_checkpoint_value(binary, Value, Max) -> valid_field(Value, Max);
valid_checkpoint_value(integer, Value, _Max) -> is_integer(Value);
valid_checkpoint_value(non_negative_integer, Value, _Max) ->
    is_integer(Value) andalso Value >= 0.

handle_artifacts(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            with_artifact_scope(
              Req0, State,
              fun(App, User, Session, Scope) ->
                  list_artifact_names(
                    App, User, Session, Scope, Req0, State)
              end);
        _ -> method_not_allowed(<<"GET">>, Req0, State)
    end.

handle_artifact_versions(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            with_artifact_scope(
              Req0, State,
              fun(App, User, Session, Scope) ->
                  list_artifact_versions(
                    App, User, Session, Scope, Req0, State)
              end);
        _ -> method_not_allowed(<<"GET">>, Req0, State)
    end.

with_artifact_scope(Req, State, Fun) ->
    case validated_session_bindings(Req, State) of
        {ok, App, User, Session} ->
            Fun(App, User, Session, {session, App, User, Session});
        {error, Req1} -> {ok, Req1, State}
    end.

list_artifact_names(App, User, Session, Scope, Req, State) ->
    case artifact_name_page_options(Req, State) of
        {error, Message} ->
            error_reply(400, <<"invalid_artifact_query">>, Message,
                        #{}, Req, State);
        {ok, Options} ->
            case resolve_resource(artifact, Scope, State) of
                {ok, Ref} ->
                    case call_resource(Ref, list_names,
                                       [Scope, Options], State) of
                        {ok, #{scope := Scope, items := Items} = Page}
                          when is_list(Items) ->
                            case public_artifact_names(
                                   Items, maps:get(limit, Options)) of
                                {ok, Names} ->
                                    json_reply(
                                      200,
                                      #{<<"schema_version">> => 1,
                                        <<"scope">> => session_scope_json(
                                                           App, User, Session),
                                        <<"names">> => Names,
                                        <<"next_cursor">> =>
                                            nullable(maps:get(
                                                       next_cursor, Page,
                                                       undefined))},
                                      #{}, Req, State);
                                error -> diagnostic_unavailable(Req, State)
                            end;
                        _ -> diagnostic_unavailable(Req, State)
                    end;
                {error, _} -> diagnostic_unavailable(Req, State)
            end
    end.

list_artifact_versions(App, User, Session, Scope, Req, State) ->
    case artifact_version_page_options(Req, State) of
        {error, Message} ->
            error_reply(400, <<"invalid_artifact_query">>, Message,
                        #{}, Req, State);
        {ok, Name, Options} ->
            case resolve_resource(artifact, Scope, State) of
                {ok, Ref} ->
                    case call_resource(Ref, list_versions,
                                       [Scope, Name, Options], State) of
                        {ok, #{items := Items} = Page} when is_list(Items) ->
                            case public_artifact_versions(
                                   Items, maps:get(limit, Options), Scope,
                                   []) of
                                {ok, Versions} ->
                                    json_reply(
                                      200,
                                      #{<<"schema_version">> => 1,
                                        <<"scope">> => session_scope_json(
                                                           App, User, Session),
                                        <<"name">> => Name,
                                        <<"versions">> => Versions,
                                        <<"next_cursor">> =>
                                            nullable(maps:get(
                                                       next_cursor, Page,
                                                       undefined))},
                                      #{}, Req, State);
                                error -> diagnostic_unavailable(Req, State)
                            end;
                        {error, not_found} ->
                            not_found(<<"artifact_not_found">>, Req, State);
                        _ -> diagnostic_unavailable(Req, State)
                    end;
                {error, _} -> diagnostic_unavailable(Req, State)
            end
    end.

handle_artifact_delete(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            with_artifact_scope(
              Req0, State,
              fun(App, User, Session, Scope) ->
                  read_artifact_delete(
                    App, User, Session, Scope, Req0, State)
              end);
        _ -> method_not_allowed(<<"POST">>, Req0, State)
    end.

read_artifact_delete(App, User, Session, Scope, Req0, State) ->
    case read_json_object(Req0, State) of
        {error, Req1} -> {ok, Req1, State};
        {ok, Payload, Req1} ->
            case checked_artifact_delete(
                   Payload, App, User, Session) of
                {ok, Name, Selector} ->
                    delete_artifact(
                      Name, Selector, Scope, Req1, State);
                {error, Message} ->
                    error_reply(400, <<"invalid_artifact_delete">>,
                                Message, #{}, Req1, State)
            end
    end.

delete_artifact(Name, Selector, Scope, Req, State) ->
    case resolve_resource(artifact, Scope, State) of
        {ok, Ref} ->
            Timeout = maps:get(diagnostic_timeout_ms, State),
            case call_resource(
                   Ref, delete,
                   [Scope, Name, Selector, #{timeout_ms => Timeout}], State) of
                ok ->
                    json_reply(
                      200,
                      #{<<"deleted">> => true,
                        <<"name">> => Name,
                        <<"selector">> => selector_json(Selector)},
                      #{}, Req, State);
                {error, not_found} ->
                    not_found(<<"artifact_not_found">>, Req, State);
                _ -> diagnostic_unavailable(Req, State)
            end;
        {error, _} -> diagnostic_unavailable(Req, State)
    end.

handle_memory_status(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            with_memory_scope(
              Req0, State,
              fun(App, User, Scope) ->
                  memory_status(App, User, Scope, Req0, State)
              end);
        _ -> method_not_allowed(<<"GET">>, Req0, State)
    end.

memory_status(App, User, Scope, Req, State) ->
    case resolve_resource(memory, Scope, State) of
        {ok, Ref} ->
            case call_resource(Ref, capabilities, [], State) of
                {ok, Capabilities} when is_map(Capabilities) ->
                    memory_status_reply(
                      App, User, Capabilities, Req, State);
                Capabilities when is_map(Capabilities) ->
                    memory_status_reply(
                      App, User, Capabilities, Req, State);
                _ -> diagnostic_unavailable(Req, State)
            end;
        {error, _} -> diagnostic_unavailable(Req, State)
    end.

memory_status_reply(App, User, Capabilities, Req, State) ->
    Public = public_memory_capabilities(Capabilities),
    json_reply(
      200,
      #{<<"schema_version">> => 1,
        <<"scope">> => user_scope_json(App, User),
        <<"capabilities">> =>
            json_safe(adk_secret_redactor:redact(Public))},
      #{}, Req, State).

handle_memory_search(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            with_memory_scope(
              Req0, State,
              fun(App, User, Scope) ->
                  read_memory_search(App, User, Scope, Req0, State)
              end);
        _ -> method_not_allowed(<<"POST">>, Req0, State)
    end.

read_memory_search(App, User, Scope, Req0, State) ->
    case read_json_object(Req0, State) of
        {error, Req1} -> {ok, Req1, State};
        {ok, Payload, Req1} ->
            case checked_memory_search(Payload, State) of
                {ok, Query, Options} ->
                    search_memory(
                      App, User, Scope, Query, Options, Req1, State);
                {error, Message} ->
                    error_reply(400, <<"invalid_memory_search">>, Message,
                                #{}, Req1, State)
            end
    end.

search_memory(App, User, Scope, Query, Options, Req, State) ->
    case resolve_resource(memory, Scope, State) of
        {ok, Ref} ->
            case call_resource(
                   Ref, search, [Scope, Query, Options], State) of
                {ok, Hits} when is_list(Hits) ->
                    case public_memory_hits(
                           Hits, maps:get(limit, Options), Scope, []) of
                        {ok, PublicHits} ->
                            json_reply(
                              200,
                              #{<<"schema_version">> => 1,
                                <<"scope">> => user_scope_json(App, User),
                                <<"hits">> => PublicHits,
                                <<"count">> => length(PublicHits)},
                              #{}, Req, State);
                        error -> diagnostic_unavailable(Req, State)
                    end;
                _ -> diagnostic_unavailable(Req, State)
            end;
        {error, _} -> diagnostic_unavailable(Req, State)
    end.

handle_memory_erase(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            with_memory_scope(
              Req0, State,
              fun(App, User, Scope) ->
                  read_memory_erase(App, User, Scope, Req0, State)
              end);
        _ -> method_not_allowed(<<"POST">>, Req0, State)
    end.

read_memory_erase(App, User, Scope, Req0, State) ->
    case read_json_object(Req0, State) of
        {error, Req1} -> {ok, Req1, State};
        {ok, Payload, Req1} ->
            case checked_memory_erase(Payload, App, User) of
                {ok, Target, Identifier} ->
                    erase_memory(Target, Identifier, Scope, Req1, State);
                {error, Message} ->
                    error_reply(400, <<"invalid_memory_erase">>, Message,
                                #{}, Req1, State)
            end
    end.

erase_memory(Target, Identifier, Scope, Req, State) ->
    case resolve_resource(memory, Scope, State) of
        {ok, Ref} ->
            {Function, Args} = case Target of
                entry -> {delete_entry, [Scope, Identifier]};
                session -> {delete_session, [Scope, Identifier]};
                user -> {delete_user, [Scope]}
            end,
            case call_resource(Ref, Function, Args, State) of
                ok ->
                    json_reply(
                      200,
                      #{<<"deleted">> => true,
                        <<"target">> => atom_binary(Target),
                        <<"identifier">> => Identifier},
                      #{}, Req, State);
                {error, not_found} ->
                    not_found(<<"memory_not_found">>, Req, State);
                _ -> diagnostic_unavailable(Req, State)
            end;
        {error, _} -> diagnostic_unavailable(Req, State)
    end.

with_memory_scope(Req, State, Fun) ->
    case validated_session_scope_bindings(Req, State) of
        {ok, App, User} -> Fun(App, User, {user, App, User});
        {error, Req1} -> {ok, Req1, State}
    end.

resource_source(Kind, State) ->
    case maps:get(resource_provider, State, undefined) of
        {_Module, _Handle} -> <<"provider">>;
        undefined ->
            RunnerOptions = maps:get(runner_options, State, #{}),
            Key = resource_option_key(Kind),
            case maps:get(Key, RunnerOptions, undefined) of
                undefined -> <<"unavailable">>;
                {_Module, _Handle} -> <<"runner_options">>;
                _ -> <<"unavailable">>
            end
    end.

resolve_resource(Kind, Scope, State) ->
    Timeout = maps:get(diagnostic_timeout_ms, State),
    Candidate = case maps:get(resource_provider, State, undefined) of
        undefined ->
            RunnerOptions = maps:get(runner_options, State, #{}),
            case maps:get(resource_option_key(Kind), RunnerOptions,
                          undefined) of
                undefined -> {error, not_configured};
                ConfiguredRef -> {ok, ConfiguredRef}
            end;
        Provider ->
            adk_service_ref:call(
              Provider, resolve, [Kind, Scope], Timeout)
    end,
    case Candidate of
        {ok, ResolvedRef} ->
            validate_diagnostic_service(Kind, ResolvedRef);
        {error, _} = Error -> Error;
        _ -> {error, invalid_resource_provider_reply}
    end.

resource_option_key(artifact) -> artifact_svc;
resource_option_key(memory) -> memory_svc.

validate_diagnostic_service(Kind, {Module, Handle} = Ref)
  when is_atom(Module), Handle =/= undefined ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Missing = [Callback || {Function, Arity} = Callback
                                      <- diagnostic_callbacks(Kind),
                                    not erlang:function_exported(
                                          Module, Function, Arity)],
            case Missing of
                [] -> {ok, Ref};
                _ -> {error, unsupported_resource_service}
            end;
        _ -> {error, resource_service_unavailable}
    end;
validate_diagnostic_service(_Kind, _Ref) ->
    {error, invalid_resource_service}.

diagnostic_callbacks(artifact) ->
    [{capabilities, 1}, {list_names, 3}, {list_versions, 4}, {delete, 5}];
diagnostic_callbacks(memory) ->
    [{capabilities, 1}, {search, 4}, {delete_entry, 3},
     {delete_session, 3}, {delete_user, 2}].

call_resource(Ref, Function, Args, State) ->
    adk_service_ref:call(
      Ref, Function, Args, maps:get(diagnostic_timeout_ms, State)).

artifact_name_page_options(Req, State) ->
    case checked_query(Req, [<<"limit">>, <<"cursor">>]) of
        {error, _} ->
            {error, <<"Only one limit and cursor query parameter are allowed">>};
        {ok, Params} ->
            case page_limit(Params, State) of
                {error, _} ->
                    {error, <<"limit must be a positive bounded integer">>};
                {ok, Limit} ->
                    case maps:get(<<"cursor">>, Params, undefined) of
                        undefined -> {ok, #{limit => Limit}};
                        Cursor ->
                            case adk_artifact_core:validate_name(Cursor) of
                                ok -> {ok, #{limit => Limit, cursor => Cursor}};
                                {error, _} ->
                                    {error, <<"cursor is not a valid artifact name">>}
                            end
                    end
            end
    end.

artifact_version_page_options(Req, State) ->
    case checked_query(Req, [<<"name">>, <<"limit">>, <<"cursor">>]) of
        {error, _} ->
            {error, <<"name, limit, and cursor may each be supplied once">>};
        {ok, Params} ->
            Name = maps:get(<<"name">>, Params, undefined),
            case {adk_artifact_core:validate_name(Name),
                  page_limit(Params, State),
                  version_cursor(Params)} of
                {ok, {ok, Limit}, {ok, undefined}} ->
                    {ok, Name, #{limit => Limit}};
                {ok, {ok, Limit}, {ok, Cursor}} ->
                    {ok, Name, #{limit => Limit, cursor => Cursor}};
                {{error, _}, _, _} ->
                    {error, <<"name is required and must be a valid artifact name">>};
                {_, {error, _}, _} ->
                    {error, <<"limit must be a positive bounded integer">>};
                {_, _, {error, _}} ->
                    {error, <<"cursor must be a positive version integer">>}
            end
    end.

checked_query(Req, Allowed) ->
    try cowboy_req:parse_qs(Req) of
        Pairs when is_list(Pairs) ->
            checked_query_pairs(Pairs, Allowed, #{})
    catch
        _:_ -> {error, invalid_query}
    end.

checked_query_pairs([], _Allowed, Acc) -> {ok, Acc};
checked_query_pairs([{Key, Value} | Rest], Allowed, Acc)
  when is_binary(Key), is_binary(Value) ->
    case lists:member(Key, Allowed) andalso not maps:is_key(Key, Acc) of
        true -> checked_query_pairs(Rest, Allowed, Acc#{Key => Value});
        false -> {error, invalid_query}
    end;
checked_query_pairs(_, _Allowed, _Acc) -> {error, invalid_query}.

page_limit(Params, State) ->
    Maximum = maps:get(max_resource_results, State),
    case maps:get(<<"limit">>, Params, undefined) of
        undefined -> {ok, Maximum};
        Value -> positive_bounded_integer(Value, Maximum)
    end.

version_cursor(Params) ->
    case maps:get(<<"cursor">>, Params, undefined) of
        undefined -> {ok, undefined};
        Value -> positive_bounded_integer(Value, 16#7fffffff)
    end.

positive_bounded_integer(Value, Maximum) when is_binary(Value) ->
    try binary_to_integer(Value) of
        Integer when Integer > 0, Integer =< Maximum -> {ok, Integer};
        _ -> {error, invalid_integer}
    catch
        _:_ -> {error, invalid_integer}
    end;
positive_bounded_integer(_, _) -> {error, invalid_integer}.

public_artifact_names(Items, Limit) ->
    case bounded_proper_list(Items, Limit) andalso
         lists:all(
           fun(Name) -> adk_artifact_core:validate_name(Name) =:= ok end,
           Items) of
        true -> {ok, Items};
        false -> error
    end.

public_artifact_versions(Items, Limit, ExpectedScope, Acc) ->
    case bounded_proper_list(Items, Limit) of
        true -> public_artifact_versions_list(
                  Items, ExpectedScope, Acc);
        false -> error
    end.

public_artifact_versions_list([], _ExpectedScope, Acc) ->
    {ok, lists:reverse(Acc)};
public_artifact_versions_list([Metadata | Rest], ExpectedScope, Acc)
  when is_map(Metadata) ->
    case public_artifact_version(Metadata, ExpectedScope) of
        {ok, Public} ->
            public_artifact_versions_list(
              Rest, ExpectedScope, [Public | Acc]);
        error -> error
    end;
public_artifact_versions_list(_, _ExpectedScope, _Acc) -> error.

public_artifact_version(Metadata, ExpectedScope) ->
    Scope = maps:get(scope, Metadata, undefined),
    Name = maps:get(name, Metadata, undefined),
    Version = maps:get(version, Metadata, undefined),
    Mime = maps:get(mime_type, Metadata, undefined),
    Digest = maps:get(digest, Metadata, undefined),
    Size = maps:get(size, Metadata, undefined),
    CreatedAt = maps:get(created_at, Metadata, undefined),
    UserMetadata = maps:get(metadata, Metadata, #{}),
    case Scope =:= ExpectedScope andalso
         adk_artifact_core:validate_name(Name) =:= ok andalso
         is_integer(Version) andalso Version > 0 andalso
         valid_public_mime(Mime) andalso valid_public_digest(Digest) andalso
         is_integer(Size) andalso Size >= 0 andalso
         is_integer(CreatedAt) andalso CreatedAt >= 0 andalso
         is_map(UserMetadata) of
        true ->
            {ok, #{<<"name">> => Name,
                   <<"version">> => Version,
                   <<"mime_type">> => Mime,
                   <<"digest">> => Digest,
                   <<"size">> => Size,
                   <<"created_at">> => CreatedAt,
                   <<"metadata_present">> => map_size(UserMetadata) > 0}};
        false -> error
    end.

checked_artifact_delete(Payload, App, User, Session) when is_map(Payload) ->
    ExpectedKeys = lists:sort([<<"name">>, <<"selector">>, <<"confirm">>]),
    Name = maps:get(<<"name">>, Payload, undefined),
    SelectorJson = maps:get(<<"selector">>, Payload, undefined),
    Confirm = maps:get(<<"confirm">>, Payload, undefined),
    ExpectedConfirm = #{<<"app_name">> => App,
                        <<"user_id">> => User,
                        <<"session_id">> => Session,
                        <<"name">> => Name,
                        <<"selector">> => SelectorJson},
    case {lists:sort(maps:keys(Payload)) =:= ExpectedKeys,
          adk_artifact_core:validate_name(Name),
          artifact_selector(SelectorJson),
          Confirm =:= ExpectedConfirm} of
        {true, ok, {ok, Selector}, true} -> {ok, Name, Selector};
        _ ->
            {error, <<"Supply name, selector, and an exact scope/name/selector confirmation">>}
    end.

artifact_selector(<<"all">>) -> {ok, all};
artifact_selector(<<"latest">>) -> {ok, latest};
artifact_selector(Value) when is_integer(Value), Value > 0 -> {ok, Value};
artifact_selector(_) -> {error, invalid_selector}.

selector_json(all) -> <<"all">>;
selector_json(latest) -> <<"latest">>;
selector_json(Version) -> Version.

checked_memory_search(Payload, State) when is_map(Payload) ->
    Unknown = maps:without([<<"query">>, <<"filter">>, <<"limit">>],
                           Payload),
    Query = maps:get(<<"query">>, Payload, undefined),
    Filter = maps:get(<<"filter">>, Payload, #{}),
    Limit = maps:get(<<"limit">>, Payload,
                     maps:get(max_resource_results, State)),
    Maximum = maps:get(max_resource_results, State),
    case map_size(Unknown) =:= 0 andalso
         valid_field(Query, maps:get(max_body_bytes, State)) andalso
         is_map(Filter) andalso is_integer(Limit) andalso Limit > 0 andalso
         Limit =< Maximum of
        true -> {ok, Query, #{filter => Filter, limit => Limit}};
        false ->
            {error, <<"Supply query plus an optional object filter and bounded positive limit">>}
    end.

public_memory_hits(Hits, Limit, ExpectedScope, Acc) ->
    case bounded_proper_list(Hits, Limit) of
        true -> public_memory_hits_list(Hits, ExpectedScope, Acc);
        false -> error
    end.

public_memory_hits_list([], _ExpectedScope, Acc) ->
    {ok, lists:reverse(Acc)};
public_memory_hits_list([Hit | Rest], ExpectedScope, Acc) when is_map(Hit) ->
    case public_memory_hit(Hit, ExpectedScope) of
        {ok, Public} ->
            public_memory_hits_list(Rest, ExpectedScope, [Public | Acc]);
        error -> error
    end;
public_memory_hits_list(_, _ExpectedScope, _Acc) -> error.

public_memory_hit(Hit, ExpectedScope) ->
    Scope = maps:get(scope, Hit, undefined),
    Id = maps:get(id, Hit, undefined),
    Content = maps:get(content, Hit, undefined),
    Score = maps:get(score, Hit, 0.0),
    ScoreType = maps:get(score_type, Hit, lexical_overlap),
    Timestamp = maps:get(timestamp, Hit, 0),
    case Scope =:= ExpectedScope andalso
         valid_field(Id, 1024) andalso is_binary(Content) andalso
         (is_float(Score) orelse is_integer(Score)) andalso
         is_atom(ScoreType) andalso is_integer(Timestamp) of
        true ->
            {ok, #{<<"id">> => Id,
                   <<"content">> => public_memory_text(Content),
                   <<"score">> => Score,
                   <<"score_type">> => atom_binary(ScoreType),
                   <<"timestamp">> => Timestamp,
                   <<"provenance">> =>
                       public_provenance(maps:get(provenance, Hit, #{}))}};
        false -> error
    end.

public_memory_text(Content) ->
    case valid_utf8(Content) andalso not sensitive_memory_text(Content) of
        true ->
            Redacted = safe_text(adk_secret_redactor:redact(Content)),
            truncate_utf8(Redacted, 4096);
        false -> adk_secret_redactor:marker()
    end.

sensitive_memory_text(Text) ->
    Patterns = [
        <<"(?i)(api[_ -]?key|password|passwd|access[_ -]?token|refresh[_ -]?token|authorization|bearer)\\s*[:=]\\s*\\S+">>,
        <<"AIza[0-9A-Za-z_-]{20,}">>,
        <<"sk-[0-9A-Za-z_-]{16,}">>
    ],
    lists:any(
      fun(Pattern) ->
          re:run(Text, Pattern, [unicode]) =/= nomatch
      end, Patterns).

truncate_utf8(Binary, Maximum) when byte_size(Binary) =< Maximum -> Binary;
truncate_utf8(Binary, Maximum) ->
    truncate_utf8_part(binary:part(Binary, 0, Maximum), 4).

truncate_utf8_part(_Part, 0) -> <<>>;
truncate_utf8_part(Part, Attempts) ->
    case valid_utf8(Part) of
        true -> Part;
        false when byte_size(Part) > 0 ->
            truncate_utf8_part(
              binary:part(Part, 0, byte_size(Part) - 1), Attempts - 1);
        false -> <<>>
    end.

public_provenance(Provenance) when is_map(Provenance) ->
    Public0 = maps:with([session_id, author, timestamp], Provenance),
    json_safe(adk_secret_redactor:redact(Public0));
public_provenance(_) -> #{}.

public_memory_capabilities(Capabilities) ->
    ScalarKeys = [contract_version, adapter, scope, durable, search,
                  idempotent_ingestion, incremental_events, delete],
    Public0 = maps:with(ScalarKeys, Capabilities),
    Limits = public_integer_map(maps:get(limits, Capabilities, #{})),
    Public0#{limits => Limits}.

public_integer_map(Map) when is_map(Map) ->
    maps:fold(
      fun(Key, Value, Acc)
            when is_atom(Key), is_integer(Value), Value >= 0 ->
              Acc#{Key => Value};
         (_Key, _Value, Acc) -> Acc
      end, #{}, Map);
public_integer_map(_) -> #{}.

valid_public_mime(Value)
  when is_binary(Value), byte_size(Value) > 2, byte_size(Value) =< 255 ->
    valid_utf8(Value) andalso binary:match(Value, <<"/">>) =/= nomatch;
valid_public_mime(_) -> false.

valid_public_digest(Value) when is_binary(Value), byte_size(Value) =:= 64 ->
    lists:all(
      fun(Char) ->
          (Char >= $0 andalso Char =< $9) orelse
          (Char >= $a andalso Char =< $f)
      end, binary_to_list(Value));
valid_public_digest(_) -> false.

bounded_proper_list(List, Limit) ->
    bounded_proper_list(List, Limit, 0).

bounded_proper_list([], _Limit, _Count) -> true;
bounded_proper_list(_Rest, Limit, Count) when Count >= Limit -> false;
bounded_proper_list([_ | Rest], Limit, Count) ->
    bounded_proper_list(Rest, Limit, Count + 1);
bounded_proper_list(_Improper, _Limit, _Count) -> false.

checked_memory_erase(Payload, App, User) when is_map(Payload) ->
    TargetJson = maps:get(<<"target">>, Payload, undefined),
    case memory_erase_target(TargetJson, Payload, User) of
        {ok, Target, Identifier, ExpectedKeys} ->
            Confirm = maps:get(<<"confirm">>, Payload, undefined),
            ExpectedConfirm = #{<<"app_name">> => App,
                                <<"user_id">> => User,
                                <<"target">> => TargetJson,
                                <<"identifier">> => Identifier},
            case lists:sort(maps:keys(Payload)) =:=
                 lists:sort(ExpectedKeys) andalso
                 Confirm =:= ExpectedConfirm of
                true -> {ok, Target, Identifier};
                false ->
                    {error, <<"Supply an exact app/user/target/identifier confirmation">>}
            end;
        {error, _} ->
            {error, <<"target must be entry, session, or user with its required identifier">>}
    end.

memory_erase_target(<<"entry">>, Payload, _User) ->
    erase_identifier(entry, maps:get(<<"id">>, Payload, undefined),
                     [<<"target">>, <<"id">>, <<"confirm">>]);
memory_erase_target(<<"session">>, Payload, _User) ->
    erase_identifier(session,
                     maps:get(<<"session_id">>, Payload, undefined),
                     [<<"target">>, <<"session_id">>, <<"confirm">>]);
memory_erase_target(<<"user">>, _Payload, User) ->
    {ok, user, User, [<<"target">>, <<"confirm">>]};
memory_erase_target(_, _Payload, _User) ->
    {error, invalid_target}.

erase_identifier(Target, Identifier, ExpectedKeys) ->
    case valid_field(Identifier, 1024) of
        true -> {ok, Target, Identifier, ExpectedKeys};
        false -> {error, invalid_identifier}
    end.

read_json_object(Req0, State) ->
    case is_json_request(Req0) of
        false ->
            {error, error_req(
                      415, <<"unsupported_media_type">>,
                      <<"Content-Type must be application/json">>,
                      #{}, Req0)};
        true ->
            Max = maps:get(max_body_bytes, State),
            case body_too_large(Req0, Max) of
                true ->
                    {error, error_req(
                              413, <<"payload_too_large">>,
                              <<"Request body exceeds the configured limit">>,
                              #{<<"connection">> => <<"close">>}, Req0)};
                false -> read_json_object_body(Req0, Max)
            end
    end.

read_json_object_body(Req0, Max) ->
    case read_body(Req0, <<>>, Max) of
        {error, payload_too_large, Req1} ->
            {error, error_req(
                      413, <<"payload_too_large">>,
                      <<"Request body exceeds the configured limit">>,
                      #{<<"connection">> => <<"close">>}, Req1)};
        {ok, Body, Req1} ->
            try jsx:decode(Body, [return_maps]) of
                Payload when is_map(Payload) -> {ok, Payload, Req1};
                _ ->
                    {error, error_req(
                              400, <<"invalid_json">>,
                              <<"Request body must be a JSON object">>,
                              #{}, Req1)}
            catch
                _:_ ->
                    {error, error_req(
                              400, <<"invalid_json">>,
                              <<"Request body must be a JSON object">>,
                              #{}, Req1)}
            end
    end.

session_scope_json(App, User, Session) ->
    #{<<"type">> => <<"session">>,
      <<"app_name">> => App,
      <<"user_id">> => User,
      <<"session_id">> => Session}.

user_scope_json(App, User) ->
    #{<<"type">> => <<"user">>,
      <<"app_name">> => App,
      <<"user_id">> => User}.

replay_gap_reply(Gap, Req, State) ->
    json_reply(
      409,
      #{<<"error">> =>
            #{<<"code">> => <<"run_event_replay_gap">>,
              <<"message">> =>
                  <<"Last-Event-ID is older than the retained replay window">>,
              <<"details">> => replay_gap_json(Gap)}},
      #{}, Req, State).

cursor_ahead_reply(Details, Req, State) ->
    json_reply(
      409,
      #{<<"error">> =>
            #{<<"code">> => <<"run_event_cursor_ahead">>,
              <<"message">> =>
                  <<"Last-Event-ID is newer than this run">>,
              <<"details">> =>
                  #{<<"after_sequence">> =>
                        maps:get(after_sequence, Details),
                    <<"latest_sequence">> =>
                        maps:get(latest_sequence, Details)}}},
      #{}, Req, State).

replay_gap_json(Gap) ->
    #{<<"after_sequence">> => maps:get(after_sequence, Gap),
      <<"oldest_available_sequence">> =>
          nullable(maps:get(oldest_available_sequence, Gap)),
      <<"latest_sequence">> => maps:get(latest_sequence, Gap),
      <<"terminal">> => maps:get(terminal, Gap)}.

safe_stream_body(Body, Fin, Req) ->
    try cowboy_req:stream_body(Body, Fin, Req) of
        ok -> ok
    catch
        _:_ -> closed
    end.

handle_sessions(Req0, State) ->
    case validated_session_scope_bindings(Req0, State) of
        {error, Req1} -> {ok, Req1, State};
        {ok, App, User} ->
            case cowboy_req:method(Req0) of
                <<"GET">> -> list_sessions(App, User, Req0, State);
                <<"POST">> -> create_session(App, User, Req0, State);
                _ -> method_not_allowed(<<"GET, POST">>, Req0, State)
            end
    end.

list_sessions(App, User, Req, State) ->
    Service = maps:get(session_service, State),
    Result = try Service:list_sessions(App, User) of
        Reply -> Reply
    catch
        _:_ -> {error, service_unavailable}
    end,
    case Result of
        {ok, SessionMetas} when is_list(SessionMetas) ->
            case normalize_session_metas(SessionMetas, []) of
                {ok, Normalized0} ->
                    Normalized = lists:sort(
                                   fun session_meta_before/2,
                                   Normalized0),
                    Total = length(Normalized),
                    Limit = maps:get(max_session_results, State),
                    Page = lists:sublist(Normalized, Limit),
                    json_reply(
                      200,
                      #{<<"schema_version">> => 1,
                        <<"app_name">> => App,
                        <<"user_id">> => User,
                        <<"sessions">> => Page,
                        <<"total">> => Total,
                        <<"truncated">> => Total > Limit},
                      #{}, Req, State);
                error ->
                    service_unavailable(Req, State)
            end;
        _ ->
            service_unavailable(Req, State)
    end.

normalize_session_metas([], Acc) ->
    {ok, lists:reverse(Acc)};
normalize_session_metas([#{id := Id, timestamp := Timestamp} | Rest], Acc)
  when is_binary(Id), is_integer(Timestamp) ->
    normalize_session_metas(
      Rest,
      [#{<<"id">> => Id, <<"timestamp">> => Timestamp} | Acc]);
normalize_session_metas([#{<<"id">> := Id,
                           <<"timestamp">> := Timestamp} | Rest], Acc)
  when is_binary(Id), is_integer(Timestamp) ->
    normalize_session_metas(
      Rest,
      [#{<<"id">> => Id, <<"timestamp">> => Timestamp} | Acc]);
normalize_session_metas(_Metas, _Acc) ->
    error.

session_meta_before(Left, Right) ->
    LeftTimestamp = maps:get(<<"timestamp">>, Left),
    RightTimestamp = maps:get(<<"timestamp">>, Right),
    case LeftTimestamp =:= RightTimestamp of
        true -> maps:get(<<"id">>, Left) =< maps:get(<<"id">>, Right);
        false -> LeftTimestamp > RightTimestamp
    end.

create_session(App, User, Req0, State) ->
    case is_json_request(Req0) of
        false ->
            error_reply(415, <<"unsupported_media_type">>,
                        <<"Content-Type must be application/json">>,
                        #{}, Req0, State);
        true ->
            Max = maps:get(max_body_bytes, State),
            case body_too_large(Req0, Max) of
                true -> payload_too_large(Req0, State);
                false ->
                    case read_body(Req0, <<>>, Max) of
                        {ok, Body, Req1} ->
                            decode_create_session(App, User, Body, Req1,
                                                  State);
                        {error, payload_too_large, Req1} ->
                            payload_too_large(Req1, State)
                    end
            end
    end.

decode_create_session(App, User, Body, Req, State) ->
    Decoded = try jsx:decode(Body, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, invalid_json}
    end,
    case Decoded of
        {ok, #{<<"session_id">> := SessionId} = Payload}
          when map_size(Payload) =:= 1 ->
            case valid_field(SessionId, maps:get(max_field_bytes, State)) of
                true ->
                    create_checked_session(
                      App, User, SessionId, Req, State);
                false ->
                    error_reply(
                      400, <<"invalid_session_id">>,
                      <<"session_id must be a non-empty UTF-8 string within configured limits">>,
                      #{}, Req, State)
            end;
        {ok, _} ->
            error_reply(400, <<"invalid_session_request">>,
                        <<"Expected a JSON object containing only session_id">>,
                        #{}, Req, State);
        _ ->
            error_reply(400, <<"invalid_json">>,
                        <<"Request body must be a JSON object">>,
                        #{}, Req, State)
    end.

create_checked_session(App, User, SessionId, Req, State) ->
    Service = maps:get(session_service, State),
    Existing = safe_session_service_call(
                 Service, get_session, [App, User, SessionId]),
    case safe_session_service_call(
           Service, create_session,
           [App, User, #{session_id => SessionId}]) of
        {ok, SessionMap} when is_map(SessionMap) ->
            Status = case Existing of
                {error, not_found} -> 201;
                _ -> 200
            end,
            json_reply(Status, session_json(SessionMap), #{}, Req, State);
        _ ->
            service_unavailable(Req, State)
    end.

safe_session_service_call(Service, Function, Args) ->
    try apply(Service, Function, Args) of
        Reply -> Reply
    catch
        _:_ -> {error, service_unavailable}
    end.

handle_session(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            case validated_session_bindings(Req0, State) of
                {ok, App, User, Session} ->
                    get_session(App, User, Session, Req0, State);
                {error, Req1} -> {ok, Req1, State}
            end;
        <<"DELETE">> ->
            case validated_session_bindings(Req0, State) of
                {ok, App, User, Session} ->
                    delete_session(App, User, Session, Req0, State);
                {error, Req1} -> {ok, Req1, State}
            end;
        _ -> method_not_allowed(<<"GET, DELETE">>, Req0, State)
    end.

get_session(App, User, Session, Req, State) ->
    Service = maps:get(session_service, State),
    Result = try Service:get_session(App, User, Session) of
        Reply -> Reply
    catch
        _:_ -> {error, service_unavailable}
    end,
    case Result of
        {ok, SessionMap} when is_map(SessionMap) ->
            json_reply(200, session_json(SessionMap), #{}, Req, State);
        {error, not_found} ->
            not_found(<<"session_not_found">>, Req, State);
        _ ->
            service_unavailable(Req, State)
    end.

delete_session(App, User, Session, Req, State) ->
    Service = maps:get(session_service, State),
    case safe_session_service_call(
           Service, get_session, [App, User, Session]) of
        {error, not_found} ->
            not_found(<<"session_not_found">>, Req, State);
        {ok, _} ->
            case safe_session_service_call(
                   Service, delete_session, [App, User, Session]) of
                ok ->
                    json_reply(
                      200,
                      #{<<"session_id">> => Session,
                        <<"deleted">> => true},
                      #{}, Req, State);
                _ ->
                    service_unavailable(Req, State)
            end;
        _ ->
            service_unavailable(Req, State)
    end.

handle_session_state(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case validated_session_bindings(Req0, State) of
                {ok, App, User, Session} ->
                    read_state_delta(App, User, Session, Req0, State);
                {error, Req1} -> {ok, Req1, State}
            end;
        _ ->
            method_not_allowed(<<"POST">>, Req0, State)
    end.

read_state_delta(App, User, Session, Req0, State) ->
    case is_json_request(Req0) of
        false ->
            error_reply(415, <<"unsupported_media_type">>,
                        <<"Content-Type must be application/json">>,
                        #{}, Req0, State);
        true ->
            Max = maps:get(max_body_bytes, State),
            case body_too_large(Req0, Max) of
                true -> payload_too_large(Req0, State);
                false ->
                    case read_body(Req0, <<>>, Max) of
                        {ok, Body, Req1} ->
                            decode_state_delta(
                              App, User, Session, Body, Req1, State);
                        {error, payload_too_large, Req1} ->
                            payload_too_large(Req1, State)
                    end
            end
    end.

decode_state_delta(App, User, Session, Body, Req, State) ->
    Decoded = try jsx:decode(Body, [return_maps]) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, invalid_json}
    end,
    case Decoded of
        {ok, #{<<"state_delta">> := Delta} = Payload}
          when map_size(Payload) =:= 1, is_map(Delta),
               map_size(Delta) > 0 ->
            case contains_forbidden_state(Delta) of
                false -> apply_state_delta(
                           App, User, Session, Delta, Req, State);
                true ->
                    error_reply(
                      400, <<"forbidden_state_key">>,
                      <<"Credentials and internal continuation keys cannot be written through the developer API">>,
                      #{}, Req, State)
            end;
        {ok, _} ->
            error_reply(
              400, <<"invalid_state_request">>,
              <<"Expected a JSON object containing one non-empty state_delta object">>,
              #{}, Req, State);
        _ ->
            error_reply(400, <<"invalid_json">>,
                        <<"Request body must be a JSON object">>,
                        #{}, Req, State)
    end.

apply_state_delta(App, User, Session, Delta, Req, State) ->
    Service = maps:get(session_service, State),
    case safe_session_service_call(
           Service, get_session, [App, User, Session]) of
        {error, not_found} ->
            not_found(<<"session_not_found">>, Req, State);
        {ok, _} ->
            case safe_session_service_call(
                   Service, update_state, [App, User, Session, Delta]) of
                ok -> get_session(App, User, Session, Req, State);
                _ -> service_unavailable(Req, State)
            end;
        _ ->
            service_unavailable(Req, State)
    end.

contains_forbidden_state(Map) when is_map(Map) ->
    lists:any(
      fun({Key, Value}) ->
          forbidden_state_key(Key) orelse contains_forbidden_state(Value)
      end, maps:to_list(Map));
contains_forbidden_state(List) when is_list(List) ->
    lists:any(fun contains_forbidden_state/1, List);
contains_forbidden_state(Binary) when is_binary(Binary) ->
    adk_secret_redactor:redact(Binary) =/= Binary;
contains_forbidden_state(_Value) ->
    false.

forbidden_state_key(<<"__adk_runner_continuation:", _/binary>>) -> true;
forbidden_state_key(<<"temp:__adk_runner_pause">>) -> true;
forbidden_state_key(Key) when is_binary(Key) ->
    Sentinel = <<"__adk_public_state_value__">>,
    Redacted = adk_secret_redactor:redact(#{Key => Sentinel}),
    maps:get(Key, Redacted, Sentinel) =:= adk_secret_redactor:marker();
forbidden_state_key(_Key) -> true.

validated_session_scope_bindings(Req, State) ->
    Max = maps:get(max_field_bytes, State),
    App = cowboy_req:binding(app_name, Req),
    User = cowboy_req:binding(user_id, Req),
    case valid_field(App, Max) andalso valid_field(User, Max) of
        true -> {ok, App, User};
        false ->
            Req1 = error_req(
                     400, <<"invalid_path_parameter">>,
                     <<"Path parameters must be non-empty UTF-8 strings within configured limits">>,
                     #{}, Req),
            {error, Req1}
    end.

validated_session_bindings(Req, State) ->
    Max = maps:get(max_field_bytes, State),
    App = cowboy_req:binding(app_name, Req),
    User = cowboy_req:binding(user_id, Req),
    Session = cowboy_req:binding(session_id, Req),
    case valid_field(App, Max) andalso valid_field(User, Max) andalso
         valid_field(Session, Max) of
        true -> {ok, App, User, Session};
        false ->
            Req1 = error_req(400, <<"invalid_path_parameter">>,
                             <<"Path parameters must be non-empty UTF-8 strings within configured limits">>,
                             #{}, Req),
            {error, Req1}
    end.

validated_binding(Name, Req, _State) ->
    Value = cowboy_req:binding(Name, Req),
    case valid_field(Value, 128) of
        true -> {ok, Value};
        false ->
            Req1 = error_req(400, <<"invalid_run_id">>,
                             <<"Run ID is invalid">>, #{}, Req),
            {error, Req1}
    end.

last_event_id(Req) ->
    case cowboy_req:header(<<"last-event-id">>, Req) of
        undefined -> {ok, 0};
        <<>> -> {ok, 0};
        Value ->
            try binary_to_integer(Value) of
                Number when Number >= 0 -> {ok, Number};
                _ -> {error, invalid_last_event_id}
            catch
                _:_ -> {error, invalid_last_event_id}
            end
    end.

status_json(Status) ->
    #{<<"run_id">> => maps:get(run_id, Status),
      <<"state">> => atom_binary(maps:get(state, Status)),
      <<"outcome">> => nullable_outcome(maps:get(outcome, Status)),
      <<"started_at">> => nullable(maps:get(started_at, Status)),
      <<"finished_at">> => nullable(maps:get(finished_at, Status)),
      <<"event_count">> => maps:get(event_count, Status),
      <<"buffered_event_count">> => maps:get(buffered_event_count, Status),
      <<"subscriber_count">> => maps:get(subscriber_count, Status),
      <<"parent_run_id">> => nullable(maps:get(parent_run_id, Status,
                                                undefined)),
      <<"resumed_to">> => nullable(maps:get(resumed_to, Status,
                                             undefined))}.

nullable_outcome(undefined) -> null;
nullable_outcome(Outcome) -> outcome_json(Outcome).

outcome_json({completed, Text}) ->
    #{<<"type">> => <<"completed">>, <<"text">> => safe_text(Text)};
outcome_json({paused, Event}) ->
    #{<<"type">> => <<"paused">>, <<"event">> => event_json(Event)};
outcome_json({cancelled, Reason}) ->
    #{<<"type">> => <<"cancelled">>,
      <<"reason">> => public_reason(Reason)};
outcome_json({failed, Reason}) ->
    #{<<"type">> => <<"failed">>,
      <<"reason">> => public_failure_reason(Reason)};
outcome_json(_) ->
    #{<<"type">> => <<"failed">>, <<"reason">> => <<"unknown">>}.

event_json(Event) ->
    case adk_event:encode(Event) of
        {ok, Encoded} -> Encoded;
        {error, _} ->
            #{<<"schema_version">> => adk_event:codec_version(),
              <<"encoding_error">> => <<"event_not_json_safe">>}
    end.

session_json(Session) ->
    Events = [event_json(Event) || Event <- maps:get(events, Session, [])],
    #{<<"id">> => maps:get(id, Session, <<>>),
      <<"app_name">> => maps:get(app_name, Session, <<>>),
      <<"user_id">> => maps:get(user_id, Session, <<>>),
      <<"state">> => json_safe(
                         adk_secret_redactor:redact(
                           maps:get(state, Session, #{}))),
      <<"events">> => Events,
      <<"timestamp">> => nullable(maps:get(timestamp, Session, undefined))}.

json_safe(Value) when is_binary(Value); is_integer(Value); is_float(Value) ->
    Value;
json_safe(true) -> true;
json_safe(false) -> false;
json_safe(null) -> null;
json_safe(undefined) -> null;
json_safe(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
json_safe(Value) when is_list(Value) -> [json_safe(Item) || Item <- Value];
json_safe(Value) when is_map(Value) ->
    maps:fold(
      fun(Key, Item, Acc) ->
          Acc#{json_key(Key) => json_safe(Item)}
      end, #{}, Value);
json_safe(_Unsupported) -> <<"unsupported_erlang_term">>.

json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
json_key(Key) when is_integer(Key) -> integer_to_binary(Key);
json_key(_Key) -> <<"unsupported_key">>.

public_reason(Reason) when is_binary(Reason) -> safe_text(Reason);
public_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
public_reason({adk_failure, #{reason := Reason}}) when is_atom(Reason) ->
    %% Preserve the developer API's stable, JSON-safe cancellation reason
    %% without serializing the structural failure envelope or arbitrary terms.
    atom_to_binary(Reason, utf8);
public_reason(_) -> <<"cancelled">>.

public_failure_reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
public_failure_reason({Tag, _}) when is_atom(Tag) ->
    atom_to_binary(Tag, utf8);
public_failure_reason(_) -> <<"run_failed">>.

safe_text(Text) when is_binary(Text) -> Text;
safe_text(Text) when is_list(Text) ->
    case unicode:characters_to_binary(Text) of
        Binary when is_binary(Binary) -> Binary;
        _ -> <<>>
    end;
safe_text(_) -> <<>>.

nullable(undefined) -> null;
nullable(Value) -> Value.

atom_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

valid_field(Value, Max) when is_binary(Value), byte_size(Value) > 0,
                              byte_size(Value) =< Max ->
    valid_utf8(Value);
valid_field(_, _) -> false.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.

is_json_request(Req) ->
    case cowboy_req:header(<<"content-type">>, Req) of
        undefined -> false;
        Value ->
            [MediaType | _] = binary:split(lowercase_ascii(Value), <<";">>),
            trim_ascii(MediaType) =:= <<"application/json">>
    end.

body_too_large(Req, Max) ->
    case cowboy_req:body_length(Req) of
        Length when is_integer(Length) -> Length > Max;
        undefined -> false
    end.

read_body(Req, Acc, Max) ->
    Remaining = Max - byte_size(Acc),
    case cowboy_req:read_body(
           Req, #{length => Remaining + 1, period => 5000}) of
        {ok, Data, Req1} when byte_size(Data) =< Remaining ->
            {ok, <<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} when byte_size(Data) =< Remaining ->
            read_body(Req1, <<Acc/binary, Data/binary>>, Max);
        {ok, _Data, Req1} -> {error, payload_too_large, Req1};
        {more, _Data, Req1} -> {error, payload_too_large, Req1}
    end.

payload_too_large(Req, State) ->
    error_reply(413, <<"payload_too_large">>,
                <<"Request body exceeds the configured limit">>,
                #{<<"connection">> => <<"close">>}, Req, State).

not_found(Code, Req, State) ->
    error_reply(404, Code, <<"Resource not found">>, #{}, Req, State).

service_unavailable(Req, State) ->
    error_reply(503, <<"run_service_unavailable">>,
                <<"The run service is unavailable">>, #{}, Req, State).

diagnostic_unavailable(Req, State) ->
    error_reply(503, <<"diagnostic_service_unavailable">>,
                <<"The scoped diagnostic resource is unavailable">>,
                #{}, Req, State).

context_cache_unavailable(Req, State) ->
    error_reply(503, <<"context_cache_unavailable">>,
                <<"The private Runner context cache is unavailable">>,
                #{}, Req, State).

method_not_allowed(Allow, Req, State) ->
    error_reply(405, <<"method_not_allowed">>, <<"Method not allowed">>,
                #{<<"allow">> => Allow}, Req, State).

error_reply(Status, Code, Message, ExtraHeaders, Req, State) ->
    Req1 = error_req(Status, Code, Message, ExtraHeaders, Req),
    {ok, Req1, State}.

error_req(Status, Code, Message, ExtraHeaders, Req) ->
    Body = #{<<"error">> =>
                 #{<<"code">> => Code, <<"message">> => Message}},
    reply_req(Status, Body, ExtraHeaders, Req).

json_reply(Status, Body, ExtraHeaders, Req, State) ->
    Req1 = reply_req(Status, Body, ExtraHeaders, Req),
    {ok, Req1, State}.

reply_req(Status, Body, ExtraHeaders, Req) ->
    Headers = maps:merge(
                (security_headers())#{<<"content-type">> => ?JSON},
                ExtraHeaders),
    cowboy_req:reply(Status, Headers, jsx:encode(Body), Req).

security_headers() ->
    #{<<"cache-control">> => <<"no-store">>,
      <<"referrer-policy">> => <<"no-referrer">>,
      <<"x-content-type-options">> => <<"nosniff">>,
      <<"x-frame-options">> => <<"DENY">>}.

lowercase_ascii(Value) ->
    << <<(lower_ascii(Char))>> || <<Char>> <= Value >>.

lower_ascii(Char) when Char >= $A, Char =< $Z -> Char + 32;
lower_ascii(Char) -> Char.

trim_ascii(Value) ->
    list_to_binary(string:trim(binary_to_list(Value))).
