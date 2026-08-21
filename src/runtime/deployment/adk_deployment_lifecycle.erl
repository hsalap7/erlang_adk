%% @doc Dependency-aware deployment health and bounded admission draining.
%%
%% Health output contains only component names and coarse states. It never
%% serializes service handles, configuration, credentials, principals, or
%% provider failures. Draining is atomic at the admission controller: queued
%% calls are failed before this module waits for already-granted owners.
-module(adk_deployment_lifecycle).

-export([liveness/0, readiness/0, status/0,
         begin_drain/0, begin_drain/1,
         liveness_code/0, readiness_code/0, drain_code/1]).

-define(DEFAULT_DRAIN_TIMEOUT_MS, 30000).
-define(MAX_DRAIN_TIMEOUT_MS, 600000).
-define(DRAIN_POLL_MS, 25).

-spec liveness() -> {ok, map()} | {error, not_live}.
liveness() ->
    case live_process(erlang_adk_sup) of
        true -> {ok, #{status => live}};
        false -> {error, not_live}
    end.

-spec readiness() -> {ok, map()} | {error, {not_ready, [atom()]}}.
readiness() ->
    Snapshot = status(),
    case maps:get(ready, Snapshot) of
        true -> {ok, Snapshot};
        false -> {error, {not_ready, maps:get(failed_dependencies, Snapshot)}}
    end.

-spec status() -> map().
status() ->
    Live = live_process(erlang_adk_sup),
    {AdmissionState, Active, Queued, Draining} = admission_snapshot(),
    Dependencies = dependency_statuses(),
    Failed = lists:sort(
               [Name || {Name, State} <- maps:to_list(Dependencies),
                        State =/= ready] ++
               case AdmissionState of ready -> []; _ -> [admission] end ++
               case Live of true -> []; false -> [supervisor] end),
    Ready = Live andalso AdmissionState =:= ready andalso
            not Draining andalso Failed =:= [],
    #{status => case Ready of true -> ready; false -> not_ready end,
      live => Live,
      ready => Ready,
      draining => Draining,
      active_admissions => Active,
      queued_admissions => Queued,
      dependencies => Dependencies,
      failed_dependencies => Failed}.

-spec begin_drain() -> {ok, map()} | {error, term()}.
begin_drain() -> begin_drain(?DEFAULT_DRAIN_TIMEOUT_MS).

-spec begin_drain(non_neg_integer()) -> {ok, map()} | {error, term()}.
begin_drain(Timeout) when is_integer(Timeout), Timeout >= 0,
                          Timeout =< ?MAX_DRAIN_TIMEOUT_MS ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case adk_admission_control:begin_drain() of
        {ok, _} -> await_admissions(Deadline);
        {error, _} = Error -> Error
    end;
begin_drain(_Timeout) -> {error, invalid_drain_timeout}.

%% Integer helpers are deliberately shell-friendly for relx `rpc'.
-spec liveness_code() -> 0 | 1.
liveness_code() ->
    case liveness() of {ok, _} -> 0; _ -> 1 end.

-spec readiness_code() -> 0 | 1.
readiness_code() ->
    case readiness() of {ok, _} -> 0; _ -> 1 end.

-spec drain_code(term()) -> 0 | 1.
drain_code(Timeout) ->
    case begin_drain(Timeout) of {ok, _} -> 0; _ -> 1 end.

await_admissions(Deadline) ->
    case adk_admission_control:status() of
        {ok, #{active := 0}} -> drain_observability(Deadline);
        {ok, #{active := Active}} ->
            case remaining(Deadline) of
                0 -> {error, {drain_timeout, Active}};
                Remaining ->
                    receive after erlang:min(?DRAIN_POLL_MS, Remaining) -> ok end,
                    await_admissions(Deadline)
            end;
        {error, _} = Error -> Error
    end.

drain_observability(Deadline) ->
    case whereis(adk_observability_bus) of
        undefined -> {ok, status()};
        Bus when is_pid(Bus) ->
            case remaining(Deadline) of
                0 -> {error, drain_timeout};
                Remaining ->
                    case adk_observability_bus:drain(Bus, Remaining) of
                        ok -> {ok, status()};
                        {error, _} = Error -> Error
                    end
            end
    end.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

admission_snapshot() ->
    case adk_admission_control:status() of
        {ok, Status} ->
            {ready, maps:get(active, Status, 0),
             maps:get(queue_length, Status, 0),
             maps:get(draining, Status, false)};
        _ -> {unavailable, 0, 0, false}
    end.

dependency_statuses() ->
    Checks0 = [
        {runtime_services, runtime_services_ready()},
        {evaluation, evaluation_ready()},
        {trace, trace_ready()},
        {developer_payloads, developer_payloads_ready()},
        {memory_outbox, memory_outbox_ready()},
        {mnesia, mnesia_ready()},
        {a2a, a2a_ready()},
        {http, http_ready()},
        {observability, observability_ready()}
    ],
    maps:from_list([{Name, State} || {Name, State} <- Checks0,
                                     State =/= disabled]).

runtime_services_ready() ->
    case application:get_env(erlang_adk, runtime_service_profile, disabled) of
        disabled -> disabled;
        ephemeral_local -> safe_runtime_status();
        durable_local -> safe_runtime_status();
        _ -> invalid
    end.

safe_runtime_status() ->
    case live_process(adk_runtime_service_bundle) of
        false -> unavailable;
        true ->
            try adk_runtime_service_bundle:status(
                  adk_runtime_service_bundle) of
                {ok, _} -> ready;
                _ -> unhealthy
            catch _:_ -> unhealthy
            end
    end.

evaluation_ready() ->
    case application:get_env(erlang_adk, evaluation_service_enabled, false) of
        false -> disabled;
        true ->
            Options = application:get_env(
                        erlang_adk, evaluation_service_options, #{}),
            named_state(option_name(Options, adk_eval_service));
        _ -> invalid
    end.

trace_ready() ->
    case application:get_env(erlang_adk, trace_store_enabled, false) of
        false -> disabled;
        true ->
            Options = application:get_env(erlang_adk, trace_store_options, #{}),
            Name = option_name(Options, adk_trace_store),
            case named_state(Name) of
                ready ->
                    try adk_trace_store:status(Name) of
                        {ok, _} -> ready;
                        _ -> unhealthy
                    catch _:_ -> unhealthy
                    end;
                State -> State
            end;
        _ -> invalid
    end.

developer_payloads_ready() ->
    case application:get_env(
           erlang_adk, dev_provider_payload_inspection, false) of
        false -> disabled;
        #{enabled := true} = Options ->
            Name = maps:get(name, Options, adk_dev_payload_store),
            case named_state(Name) of
                ready ->
                    try adk_dev_payload_store:status(Name) of
                        {ok, _} -> ready;
                        _ -> unhealthy
                    catch _:_ -> unhealthy
                    end;
                State -> State
            end;
        _ -> invalid
    end.

memory_outbox_ready() ->
    case {application:get_env(
            erlang_adk, runtime_service_profile, disabled),
          application:get_env(erlang_adk, memory_outbox_enabled, false)} of
        {durable_local, Enabled} when is_boolean(Enabled) ->
            durable_profile_outbox_ready();
        {_Profile, false} -> disabled;
        {_Profile, true} -> independent_memory_outbox_ready();
        {_Profile, _Invalid} -> invalid
    end.

independent_memory_outbox_ready() ->
    case named_state(adk_memory_outbox_sup) of
        ready ->
            try adk_memory_outbox_sup:health(adk_memory_outbox_sup) of
                {ok, #{status := ready}} -> ready;
                _ -> unhealthy
            catch _:_ -> unhealthy
            end;
        State -> State
    end.

durable_profile_outbox_ready() ->
    case live_process(adk_runtime_service_bundle) of
        false -> unavailable;
        true ->
            try adk_runtime_service_bundle:status(
                  adk_runtime_service_bundle) of
                {ok, #{memory_outbox := #{status := ready}}} -> ready;
                {ok, _} -> unhealthy;
                _ -> unhealthy
            catch _:_ -> unhealthy
            end
    end.

mnesia_ready() ->
    case mnesia_required() of
        false -> disabled;
        true ->
            try mnesia:system_info(is_running) of
                yes -> ready;
                _ -> unavailable
            catch _:_ -> unavailable
            end
    end.

mnesia_required() ->
    application:get_env(erlang_adk, runtime_service_profile, disabled)
        =:= durable_local orelse
    application:get_env(erlang_adk, memory_outbox_enabled, false) =:= true orelse
    (application:get_env(erlang_adk, evaluation_service_enabled, false) =:= true
     andalso application:get_env(erlang_adk, evaluation_store, ets) =:= mnesia).

a2a_ready() ->
    case application:get_env(erlang_adk, a2a_v1_enabled, false) of
        false -> disabled;
        true -> named_state(adk_a2a_v1_server);
        _ -> invalid
    end.

http_ready() ->
    Enabled = application:get_env(
                erlang_adk, http_health_enabled, false) =:= true orelse
              application:get_env(erlang_adk, a2a_enabled, false) =:= true orelse
              application:get_env(erlang_adk, a2a_v1_enabled, false) =:= true orelse
              application:get_env(erlang_adk, dev_enabled, false) =:= true,
    case Enabled of
        true -> named_state(erlang_adk_http);
        false -> disabled
    end.

observability_ready() ->
    Enabled = application:get_env(
                erlang_adk, observability_bus_enabled, false) =:= true orelse
              application:get_env(erlang_adk, trace_store_enabled, false) =:= true,
    case Enabled of
        true -> named_state(adk_observability_bus);
        false -> disabled
    end.

option_name(Options, Default) when is_map(Options) ->
    maps:get(name, Options, Default);
option_name(_Options, _Default) -> invalid.

named_state(Name) when is_atom(Name), Name =/= undefined ->
    case live_process(Name) of true -> ready; false -> unavailable end;
named_state(_) -> invalid.

live_process(Name) when is_atom(Name) ->
    case whereis(Name) of
        Pid when is_pid(Pid) -> is_process_alive(Pid);
        _ -> false
    end.
