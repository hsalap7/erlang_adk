%% @doc Monitored global/per-agent admission controller.
%%
%% Permits are owned by Erlang processes. Owner death, explicit release, or
%% cancellation returns capacity exactly once. When capacity is unavailable a
%% request either fails immediately (`reject`) or enters a bounded queue. The
%% queue selects the oldest request that is currently eligible, preserving FIFO
%% order per agent while avoiding head-of-line blocking across independent
%% agents.
-module(adk_admission_control).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         acquire/2, acquire/3,
         submit/2, submit/3,
         await/2,
         cancel/1, cancel/2,
         release/1, release/2,
         status/0, status/1,
         deadline_after/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_GLOBAL_LIMIT, 1024).
-define(DEFAULT_AGENT_LIMIT, 64).
-define(DEFAULT_MAX_QUEUE, 1024).
-define(DEFAULT_QUEUE_TIMEOUT, 30000).

-type request_ref() :: binary().
-type permit_ref() :: binary().
-export_type([request_ref/0, permit_ref/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(application:get_env(erlang_adk, admission_control, #{})).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    case maps:get(name, Options, ?SERVER) of
        undefined -> gen_server:start_link(?MODULE, Options, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Options, [])
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) ->
    #{id => maps:get(name, Options, ?SERVER),
      start => {?MODULE, start_link, [Options]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec acquire(binary(), map()) -> {ok, permit_ref()} | {error, term()}.
acquire(AgentId, Options) -> acquire(?SERVER, AgentId, Options).

-spec acquire(gen_server:server_ref(), binary(), map()) ->
    {ok, permit_ref()} | {error, term()}.
acquire(Server, AgentId, Options) ->
    case submit(Server, AgentId, Options) of
        {ok, _RequestRef, {granted, Permit}} -> {ok, Permit};
        {ok, RequestRef, {queued, Deadline}} ->
            await_deadline(Server, RequestRef, Deadline);
        {error, _} = Error -> Error
    end.

-spec submit(binary(), map()) ->
    {ok, request_ref(), {granted, permit_ref()} | {queued, integer() | infinity}}
    | {error, term()}.
submit(AgentId, Options) -> submit(?SERVER, AgentId, Options).

-spec submit(gen_server:server_ref(), binary(), map()) ->
    {ok, request_ref(), {granted, permit_ref()} | {queued, integer() | infinity}}
    | {error, term()}.
submit(Server, AgentId, Options) when is_map(Options) ->
    try gen_server:call(Server, {submit, AgentId, Options}, infinity) of
        Result -> Result
    catch
        exit:{noproc, _} -> {error, admission_controller_not_started};
        exit:Reason -> {error, {admission_controller_failed, Reason}}
    end;
submit(_Server, _AgentId, _Options) -> {error, invalid_admission_options}.

-spec await(request_ref(), timeout()) ->
    {ok, permit_ref()} | {error, term()}.
await(RequestRef, infinity) when is_binary(RequestRef) ->
    receive
        {adk_admission, RequestRef, {granted, Permit}} -> {ok, Permit};
        {adk_admission, RequestRef, {error, Reason}} -> {error, Reason}
    end;
await(RequestRef, Timeout)
  when is_binary(RequestRef), is_integer(Timeout), Timeout >= 0 ->
    receive
        {adk_admission, RequestRef, {granted, Permit}} -> {ok, Permit};
        {adk_admission, RequestRef, {error, Reason}} -> {error, Reason}
    after Timeout -> {error, await_timeout}
    end;
await(_RequestRef, _Timeout) -> {error, invalid_await}.

-spec cancel(request_ref()) -> ok | {error, term()}.
cancel(RequestRef) -> cancel(?SERVER, RequestRef).

-spec cancel(gen_server:server_ref(), request_ref()) -> ok | {error, term()}.
cancel(Server, RequestRef) when is_binary(RequestRef) ->
    safe_call(Server, {cancel, RequestRef});
cancel(_Server, _RequestRef) -> {error, invalid_request_ref}.

-spec release(permit_ref()) -> ok | {error, term()}.
release(Permit) -> release(?SERVER, Permit).

-spec release(gen_server:server_ref(), permit_ref()) -> ok | {error, term()}.
release(Server, Permit) when is_binary(Permit) ->
    safe_call(Server, {release, Permit});
release(_Server, _Permit) -> {error, invalid_permit}.

-spec status() -> {ok, map()} | {error, term()}.
status() -> status(?SERVER).

-spec status(gen_server:server_ref()) -> {ok, map()} | {error, term()}.
status(Server) ->
    case safe_call(Server, status) of
        Status when is_map(Status) -> {ok, Status};
        {error, _} = Error -> Error
    end.

-spec deadline_after(non_neg_integer() | infinity) -> integer() | infinity.
deadline_after(infinity) -> infinity;
deadline_after(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout.

init(Options) ->
    case normalize_config(Options) of
        {ok, Config} ->
            {ok, #{config => Config,
                   active => #{},
                   request_to_permit => #{},
                   active_by_agent => #{},
                   queue => [],
                   queued => #{},
                   monitor_refs => #{}}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({submit, AgentId, Options}, From, State0) ->
    Requester = element(1, From),
    case normalize_request(AgentId, Options, Requester,
                           maps:get(config, State0)) of
        {ok, Request} ->
            State1 = purge_expired(State0),
            case capacity_available(AgentId, State1) of
                true ->
                    RequestRef = maps:get(request_ref, Request),
                    {Permit, State2} = grant(Request, false, State1),
                    emit(granted, Request, 0, State2),
                    {reply, {ok, RequestRef, {granted, Permit}}, State2};
                false ->
                    enqueue_or_reject(Request, State1)
            end;
        {error, Reason} -> {reply, {error, Reason}, State0}
    end;
handle_call({cancel, RequestRef}, _From, State0) ->
    case maps:find(RequestRef, maps:get(queued, State0)) of
        {ok, Request} ->
            State1 = remove_queued(RequestRef, State0),
            notify(Request, {error, cancelled}),
            emit(cancelled, Request, elapsed(Request), State1),
            {reply, ok, dispatch(State1)};
        error ->
            case maps:find(RequestRef,
                           maps:get(request_to_permit, State0)) of
                {ok, Permit} ->
                    {Request, State1} = revoke_permit(Permit, State0),
                    emit(cancelled, Request, elapsed(Request), State1),
                    {reply, ok, dispatch(State1)};
                error -> {reply, {error, not_found}, State0}
            end
    end;
handle_call({release, Permit}, _From, State0) ->
    case maps:is_key(Permit, maps:get(active, State0)) of
        true ->
            {Request, State1} = revoke_permit(Permit, State0),
            emit(released, Request, elapsed(Request), State1),
            {reply, ok, dispatch(State1)};
        false -> {reply, {error, not_found}, State0}
    end;
handle_call(status, _From, State0) ->
    State1 = purge_expired(State0),
    {reply, status_map(State1), State1};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({adk_admission_deadline, RequestRef}, State0) ->
    case maps:find(RequestRef, maps:get(queued, State0)) of
        {ok, Request} ->
            State1 = remove_queued(RequestRef, State0),
            notify(Request, {error, queue_deadline_exceeded}),
            emit(expired, Request, elapsed(Request), State1),
            {noreply, dispatch(State1)};
        error -> {noreply, State0}
    end;
handle_info({'DOWN', Monitor, process, _Pid, Reason}, State0) ->
    case maps:find(Monitor, maps:get(monitor_refs, State0)) of
        {ok, {queued, RequestRef, Role}} ->
            case maps:find(RequestRef, maps:get(queued, State0)) of
                {ok, Request} ->
                    State1 = remove_queued(RequestRef, State0),
                    case Role of
                        owner -> notify(Request, {error, owner_down});
                        requester -> ok;
                        both -> ok
                    end,
                    emit(owner_or_requester_down(Role, Reason), Request,
                         elapsed(Request), State1),
                    {noreply, dispatch(State1)};
                error -> {noreply, remove_monitor(Monitor, State0)}
            end;
        {ok, {active, Permit}} ->
            case maps:is_key(Permit, maps:get(active, State0)) of
                true ->
                    {Request, State1} = revoke_permit(Permit, State0),
                    emit(owner_down, Request, elapsed(Request), State1),
                    {noreply, dispatch(State1)};
                false -> {noreply, remove_monitor(Monitor, State0)}
            end;
        error -> {noreply, State0}
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
      fun(_Ref, Request) ->
          notify(Request, {error, admission_controller_stopped})
      end, maps:get(queued, State, #{})),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% request handling

enqueue_or_reject(Request, State) ->
    Config = maps:get(config, State),
    case maps:get(overflow, Request) of
        reject ->
            emit(rejected, Request, 0, State),
            {reply, {error, concurrency_limit_reached}, State};
        queue ->
            case {length(maps:get(queue, State)) < maps:get(max_queue, Config),
                  deadline_remaining(maps:get(deadline, Request))} of
                {false, _} ->
                    emit(queue_full, Request, 0, State),
                    {reply, {error, admission_queue_full}, State};
                {true, expired} ->
                    emit(expired, Request, 0, State),
                    {reply, {error, queue_deadline_exceeded}, State};
                {true, Remaining} ->
                    {QueuedRequest, State1} = monitor_queued(Request, State),
                    Timer = start_deadline_timer(
                              maps:get(request_ref, Request), Remaining),
                    QueuedRequest1 = QueuedRequest#{timer => Timer},
                    RequestRef = maps:get(request_ref, Request),
                    Queue = maps:get(queue, State1),
                    Queued = maps:get(queued, State1),
                    State2 = State1#{queue => Queue ++ [RequestRef],
                                     queued => Queued#{RequestRef =>
                                                          QueuedRequest1}},
                    emit(queued, QueuedRequest1, 0, State2),
                    {reply, {ok, RequestRef,
                             {queued, maps:get(deadline, Request)}}, State2}
            end
    end.

dispatch(State0) ->
    State1 = purge_expired(State0),
    case active_count(State1) < global_limit(State1) of
        false -> State1;
        true ->
            case take_oldest_eligible(State1) of
                none -> State1;
                {Request, State2} ->
                    {_Permit, State3} = grant(Request, true, State2),
                    emit(granted, Request, elapsed(Request), State3),
                    dispatch(State3)
            end
    end.

take_oldest_eligible(State) ->
    take_oldest_eligible(maps:get(queue, State), [], State).

take_oldest_eligible([], _Prefix, _State) -> none;
take_oldest_eligible([RequestRef | Rest], Prefix, State0) ->
    Request = maps:get(RequestRef, maps:get(queued, State0)),
    case capacity_available(maps:get(agent_id, Request), State0) of
        true ->
            State1 = remove_queued(RequestRef, State0),
            %% remove_queued/2 uses the original queue. Restore the exact
            %% eligible-selection order after skipping ineligible entries.
            Remaining = Prefix ++ Rest,
            {Request, State1#{queue => Remaining}};
        false ->
            take_oldest_eligible(Rest, Prefix ++ [RequestRef], State0)
    end.

grant(Request0, Notify, State0) ->
    Request = cleanup_request_wait(Request0, State0),
    State1 = cleanup_request_monitors(Request0, State0),
    Permit = unique_ref(<<"permit-">>),
    Owner = maps:get(owner, Request),
    OwnerMonitor = erlang:monitor(process, Owner),
    AgentId = maps:get(agent_id, Request),
    Granted = Request#{permit => Permit,
                       owner_monitor => OwnerMonitor,
                       granted_at => erlang:monotonic_time(millisecond)},
    Active = maps:get(active, State1),
    ByAgent = maps:get(active_by_agent, State1),
    Count = maps:get(AgentId, ByAgent, 0),
    RequestMap = maps:get(request_to_permit, State1),
    MonitorRefs = maps:get(monitor_refs, State1),
    State2 = State1#{active => Active#{Permit => Granted},
                     active_by_agent => ByAgent#{AgentId => Count + 1},
                     request_to_permit =>
                         RequestMap#{maps:get(request_ref, Request) => Permit},
                     monitor_refs =>
                         MonitorRefs#{OwnerMonitor => {active, Permit}}},
    case Notify of
        true -> notify(Request, {granted, Permit});
        false -> ok
    end,
    {Permit, State2}.

revoke_permit(Permit, State0) ->
    {Request, Active1} = maps:take(Permit, maps:get(active, State0)),
    AgentId = maps:get(agent_id, Request),
    OwnerMonitor = maps:get(owner_monitor, Request),
    _ = erlang:demonitor(OwnerMonitor, [flush]),
    MonitorRefs = maps:remove(OwnerMonitor, maps:get(monitor_refs, State0)),
    ByAgent0 = maps:get(active_by_agent, State0),
    Count = maps:get(AgentId, ByAgent0),
    ByAgent1 = case Count of
        1 -> maps:remove(AgentId, ByAgent0);
        _ -> ByAgent0#{AgentId => Count - 1}
    end,
    RequestMap = maps:remove(maps:get(request_ref, Request),
                             maps:get(request_to_permit, State0)),
    {Request, State0#{active => Active1,
                      active_by_agent => ByAgent1,
                      request_to_permit => RequestMap,
                      monitor_refs => MonitorRefs}}.

monitor_queued(Request, State0) ->
    Requester = maps:get(requester, Request),
    Owner = maps:get(owner, Request),
    RequestRef = maps:get(request_ref, Request),
    case Requester =:= Owner of
        true ->
            Ref = erlang:monitor(process, Owner),
            MonitorRefs = maps:get(monitor_refs, State0),
            {Request#{monitors => [{Ref, both}]},
             State0#{monitor_refs =>
                         MonitorRefs#{Ref => {queued, RequestRef, both}}}};
        false ->
            RequesterRef = erlang:monitor(process, Requester),
            OwnerRef = erlang:monitor(process, Owner),
            MonitorRefs = maps:get(monitor_refs, State0),
            {Request#{monitors => [{RequesterRef, requester},
                                   {OwnerRef, owner}]},
             State0#{monitor_refs =>
                         MonitorRefs#{RequesterRef =>
                                          {queued, RequestRef, requester},
                                      OwnerRef =>
                                          {queued, RequestRef, owner}}}}
    end.

remove_queued(RequestRef, State0) ->
    case maps:take(RequestRef, maps:get(queued, State0)) of
        {Request, Queued1} ->
            cleanup_request_wait(Request, State0),
            State1 = cleanup_request_monitors(Request, State0),
            Queue1 = lists:delete(RequestRef, maps:get(queue, State1)),
            State1#{queue => Queue1, queued => Queued1};
        error -> State0
    end.

cleanup_request_wait(Request, _State) ->
    case maps:get(timer, Request, undefined) of
        Timer when is_reference(Timer) ->
            _ = erlang:cancel_timer(Timer),
            ok;
        _ -> ok
    end,
    maps:remove(timer, Request).

cleanup_request_monitors(Request, State0) ->
    lists:foldl(
      fun({Ref, _Role}, StateAcc) ->
          _ = erlang:demonitor(Ref, [flush]),
          remove_monitor(Ref, StateAcc)
      end, State0, maps:get(monitors, Request, [])).

remove_monitor(Ref, State) ->
    State#{monitor_refs => maps:remove(Ref, maps:get(monitor_refs, State))}.

purge_expired(State0) ->
    Now = erlang:monotonic_time(millisecond),
    Expired = [Ref || Ref <- maps:get(queue, State0),
                      deadline_expired(
                        maps:get(deadline,
                                 maps:get(Ref, maps:get(queued, State0))), Now)],
    lists:foldl(
      fun(Ref, StateAcc) ->
          case maps:find(Ref, maps:get(queued, StateAcc)) of
              {ok, Request} ->
                  StateNext = remove_queued(Ref, StateAcc),
                  notify(Request, {error, queue_deadline_exceeded}),
                  emit(expired, Request, elapsed(Request), StateNext),
                  StateNext;
              error -> StateAcc
          end
      end, State0, Expired).

%% config and validation

normalize_config(Options) when is_map(Options) ->
    Global = maps:get(global_limit, Options, ?DEFAULT_GLOBAL_LIMIT),
    DefaultAgent = maps:get(default_agent_limit, Options,
                            ?DEFAULT_AGENT_LIMIT),
    AgentLimits = maps:get(agent_limits, Options, #{}),
    Overflow = maps:get(overflow, Options, reject),
    MaxQueue = maps:get(max_queue, Options, ?DEFAULT_MAX_QUEUE),
    QueueTimeout = maps:get(default_queue_timeout, Options,
                            ?DEFAULT_QUEUE_TIMEOUT),
    case positive_integer(Global) andalso positive_integer(DefaultAgent)
         andalso valid_agent_limits(AgentLimits)
         andalso valid_overflow(Overflow)
         andalso is_integer(MaxQueue) andalso MaxQueue >= 0
         andalso valid_timeout(QueueTimeout) of
        true ->
            {ok, #{global_limit => Global,
                   default_agent_limit => DefaultAgent,
                   agent_limits => AgentLimits,
                   overflow => Overflow,
                   max_queue => MaxQueue,
                   default_queue_timeout => QueueTimeout}};
        false -> {error, invalid_admission_control_config}
    end;
normalize_config(_) -> {error, invalid_admission_control_config}.

normalize_request(AgentId, Options, Requester, Config) ->
    Owner = maps:get(owner, Options, Requester),
    Overflow = maps:get(overflow, Options, maps:get(overflow, Config)),
    DeadlineResult = request_deadline(Options, Config),
    case {valid_agent_id(AgentId), is_pid(Owner),
          valid_overflow(Overflow), DeadlineResult} of
        {true, true, true, {ok, Deadline}} ->
            {ok, #{request_ref => unique_ref(<<"request-">>),
                   agent_id => AgentId,
                   requester => Requester,
                   owner => Owner,
                   overflow => Overflow,
                   deadline => Deadline,
                   enqueued_at => erlang:monotonic_time(millisecond),
                   monitors => [], timer => undefined}};
        _ -> {error, invalid_admission_options}
    end.

request_deadline(Options, Config) ->
    case maps:find(deadline, Options) of
        {ok, Value} ->
            case valid_deadline(Value) of
                true -> {ok, Value};
                false -> error
            end;
        error ->
            Timeout = maps:get(queue_timeout, Options,
                               maps:get(default_queue_timeout, Config)),
            case valid_timeout(Timeout) of
                true -> {ok, deadline_after(Timeout)};
                false -> error
            end
    end.

valid_agent_limits(Limits) when is_map(Limits) ->
    lists:all(fun({Agent, Limit}) ->
                      valid_agent_id(Agent) andalso positive_integer(Limit)
              end, maps:to_list(Limits));
valid_agent_limits(_) -> false.

valid_agent_id(Value) when is_binary(Value), byte_size(Value) > 0,
                           byte_size(Value) =< 256 ->
    try unicode:characters_to_binary(Value, utf8, utf8) =:= Value
    catch _:_ -> false
    end;
valid_agent_id(_) -> false.

valid_overflow(reject) -> true;
valid_overflow(queue) -> true;
valid_overflow(_) -> false.

valid_timeout(infinity) -> true;
valid_timeout(Value) -> is_integer(Value) andalso Value >= 0.

valid_deadline(infinity) -> true;
valid_deadline(Value) -> is_integer(Value).

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

%% status, telemetry, and scalar helpers

capacity_available(AgentId, State) ->
    active_count(State) < global_limit(State) andalso
    maps:get(AgentId, maps:get(active_by_agent, State), 0)
        < agent_limit(AgentId, State).

active_count(State) -> map_size(maps:get(active, State)).
global_limit(State) -> maps:get(global_limit, maps:get(config, State)).

agent_limit(AgentId, State) ->
    Config = maps:get(config, State),
    maps:get(AgentId, maps:get(agent_limits, Config),
             maps:get(default_agent_limit, Config)).

status_map(State) ->
    Config = maps:get(config, State),
    AgentIds = lists:usort(
                 maps:keys(maps:get(active_by_agent, State)) ++
                 [maps:get(agent_id, Request)
                  || {_Ref, Request} <- maps:to_list(maps:get(queued, State))]),
    PerAgent = maps:from_list(
                 [{AgentId,
                   #{active => maps:get(AgentId,
                                        maps:get(active_by_agent, State), 0),
                     queued => length(
                                 [ok || {_Ref, Request} <-
                                            maps:to_list(maps:get(queued, State)),
                                        maps:get(agent_id, Request) =:= AgentId]),
                     limit => agent_limit(AgentId, State)}}
                  || AgentId <- AgentIds]),
    #{global_limit => maps:get(global_limit, Config),
      active => active_count(State),
      available => erlang:max(0, maps:get(global_limit, Config) -
                                  active_count(State)),
      queue_length => length(maps:get(queue, State)),
      max_queue => maps:get(max_queue, Config),
      overflow => maps:get(overflow, Config),
      per_agent => PerAgent}.

notify(Request, Result) ->
    maps:get(requester, Request) !
        {adk_admission, maps:get(request_ref, Request), Result},
    ok.

emit(Outcome, Request, WaitMs, State) ->
    Measurements = #{wait_ms => erlang:max(0, WaitMs),
                     active => active_count(State),
                     queued => length(maps:get(queue, State))},
    Metadata = #{outcome => Outcome,
                 agent_id => maps:get(agent_id, Request)},
    _ = case lists:keymember(telemetry, 1,
                             application:which_applications()) of
        true ->
            try telemetry:execute([erlang_adk, admission, decision],
                                  Measurements, Metadata)
            catch _:_ -> ok
            end;
        false -> ok
    end,
    ok.

elapsed(Request) ->
    erlang:max(0, erlang:monotonic_time(millisecond) -
                      maps:get(enqueued_at, Request)).

deadline_remaining(infinity) -> infinity;
deadline_remaining(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> expired;
        Remaining -> Remaining
    end.

deadline_expired(infinity, _Now) -> false;
deadline_expired(Deadline, Now) -> Deadline =< Now.

start_deadline_timer(_RequestRef, infinity) -> undefined;
start_deadline_timer(RequestRef, Remaining) ->
    erlang:send_after(Remaining, self(),
                      {adk_admission_deadline, RequestRef}).

await_deadline(_Server, RequestRef, infinity) ->
    await(RequestRef, infinity);
await_deadline(Server, RequestRef, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    case await(RequestRef, Remaining + 1) of
        {error, await_timeout} ->
            _ = cancel(Server, RequestRef),
            flush_request(RequestRef),
            {error, queue_deadline_exceeded};
        Result -> Result
    end.

flush_request(RequestRef) ->
    receive {adk_admission, RequestRef, _} -> ok after 0 -> ok end.

owner_or_requester_down(owner, _Reason) -> owner_down;
owner_or_requester_down(requester, _Reason) -> requester_down;
owner_or_requester_down(both, _Reason) -> owner_down.

safe_call(Server, Request) ->
    try gen_server:call(Server, Request, 5000) of
        Result -> Result
    catch
        exit:{noproc, _} -> {error, admission_controller_not_started};
        exit:Reason -> {error, {admission_controller_failed, Reason}}
    end.

unique_ref(Prefix) ->
    Random = crypto:strong_rand_bytes(18),
    Encoded0 = base64:encode(Random),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    Encoded = binary:replace(Encoded2, <<"=">>, <<>>, [global]),
    <<Prefix/binary, Encoded/binary>>.
