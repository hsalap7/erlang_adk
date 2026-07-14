%% @doc HTTP boundary for the opt-in local ADK developer platform.
%%
%% The handler is deliberately provider-neutral.  Agents are resolved through
%% the stable binary-name registry, while execution and replay are delegated to
%% adk_run.  The bearer credential is never accepted from the URI.
-module(adk_dev_handler).
-behaviour(cowboy_handler).

-export([init/2]).

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
