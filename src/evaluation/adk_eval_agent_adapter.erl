%% @doc Production adapter for evaluating an Erlang ADK agent specification.
%%
%% Every case/sample receives a fresh agent, Runner session, and guardian
%% process.  The guardian owns resource cleanup and monitors the bounded
%% evaluation worker, so a case timeout or max-heap kill cannot orphan the
%% supervised agent or its active Runner stream.
-module(adk_eval_agent_adapter).
-behaviour(adk_eval_adapter).

-include("adk_event.hrl").

-export([init_case/4, run_turn/5, terminate_case/3]).

-define(DEFAULT_INIT_TIMEOUT_MS, 5000).
-define(DEFAULT_STOP_TIMEOUT_MS, 5000).
-define(DEFAULT_RUN_TIMEOUT_MS, 120000).

-spec init_case(map(), map(), map(), map()) ->
    {ok, map(), non_neg_integer()} | {error, term()}.
init_case(Target, _Case, Context, Config)
  when is_map(Target), is_map(Context), is_map(Config) ->
    Owner = self(),
    ReadyRef = make_ref(),
    {Guard, Monitor} = spawn_opt(
                         fun() ->
                             guardian_init(
                               Owner, ReadyRef, Target, Context, Config)
                         end,
                         [monitor, {message_queue_data, off_heap}]),
    Timeout = positive_option(
                Config, init_timeout_ms, ?DEFAULT_INIT_TIMEOUT_MS),
    receive
        {adk_eval_agent_ready, ReadyRef, Guard, {ok, CaseTarget}} ->
            erlang:demonitor(Monitor, [flush]),
            {ok, CaseTarget, 0};
        {adk_eval_agent_ready, ReadyRef, Guard, {error, Reason}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, Reason};
        {'DOWN', Monitor, process, Guard, _Reason} ->
            {error, agent_guard_start_failed}
    after Timeout ->
        %% The guardian already monitors this worker.  Returning lets the
        %% sample finish; its subsequent DOWN signal makes the guardian clean
        %% up even if agent startup completed just after this timeout.
        erlang:demonitor(Monitor, [flush]),
        {error, agent_guard_start_timeout}
    end;
init_case(_, _, _, _) ->
    {error, invalid_agent_eval_target}.

-spec run_turn(map(), map(), term(), map(), map()) ->
    {ok, adk_eval_adapter:turn_result()} | {error, term()}.
run_turn(#{guard := Guard}, Turn, State, _Context, _Config)
  when is_pid(Guard), is_map(Turn) ->
    case maps:find(<<"input">>, Turn) of
        error -> {error, missing_eval_turn_input};
        {ok, Input} -> guarded_run_turn(Guard, Input, next_state(State))
    end;
run_turn(_, _, _, _, _) ->
    {error, invalid_agent_eval_case_target}.

-spec terminate_case(map(), term(), map()) -> ok | {error, term()}.
terminate_case(#{guard := Guard}, _State, Config)
  when is_pid(Guard), is_map(Config) ->
    Alias = erlang:alias([reply]),
    Monitor = erlang:monitor(process, Guard),
    Guard ! {adk_eval_agent_stop, self(), Alias},
    Timeout = positive_option(
                Config, stop_timeout_ms, ?DEFAULT_STOP_TIMEOUT_MS),
    receive
        {adk_eval_agent_stopped, Alias} ->
            _ = erlang:unalias(Alias),
            erlang:demonitor(Monitor, [flush]),
            ok;
        {'DOWN', Monitor, process, Guard, normal} ->
            _ = erlang:unalias(Alias),
            ok;
        {'DOWN', Monitor, process, Guard, _Reason} ->
            _ = erlang:unalias(Alias),
            {error, agent_guard_stopped_unexpectedly}
    after Timeout ->
        _ = erlang:unalias(Alias),
        erlang:demonitor(Monitor, [flush]),
        %% Do not kill the cleanup owner.  This sample worker will now exit,
        %% and the guard's owner monitor gives cleanup another safe trigger.
        {error, agent_guard_stop_timeout}
    end;
terminate_case(_, _, _) ->
    {error, invalid_agent_eval_case_target}.

guarded_run_turn(Guard, Input, NextState) ->
    %% A turn carries zero or more event messages followed by one terminal
    %% message. A reply alias auto-deactivates after the first event, so this
    %% must be an explicitly unaliased multi-message alias.
    Alias = erlang:alias(),
    Monitor = erlang:monitor(process, Guard),
    Guard ! {adk_eval_agent_run, self(), Alias, Input},
    collect_turn(Guard, Monitor, Alias, NextState, [], undefined).

collect_turn(Guard, Monitor, Alias, State, Events, FinalOutput) ->
    receive
        {adk_eval_agent_event, Alias, Event} ->
            Output = final_output(Event, FinalOutput),
            collect_turn(Guard, Monitor, Alias, State,
                         [Event | Events], Output);
        {adk_eval_agent_terminal, Alias, ok} ->
            finish_turn_alias(Monitor, Alias),
            Output = case FinalOutput of
                undefined -> <<>>;
                Value -> Value
            end,
            {ok, #{output => Output,
                   events => lists:reverse(Events),
                   state => State,
                   metadata => #{}}};
        {adk_eval_agent_terminal, Alias, {error, Reason}} ->
            finish_turn_alias(Monitor, Alias),
            {error, Reason};
        {'DOWN', Monitor, process, Guard, _Reason} ->
            _ = erlang:unalias(Alias),
            {error, agent_guard_down}
    end.

finish_turn_alias(Monitor, Alias) ->
    _ = erlang:unalias(Alias),
    erlang:demonitor(Monitor, [flush]),
    ok.

final_output(#adk_event{is_final = true, content = Content}, _Previous) ->
    Content;
final_output(_Event, Previous) -> Previous.

next_state(State) when is_integer(State), State >= 0 -> State + 1;
next_state(_) -> 1.

guardian_init(Owner, ReadyRef, Target, Context, Config) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    case start_resources(Target, Context, Config, Owner, OwnerMonitor) of
        {ok, Resources} ->
            Owner ! {adk_eval_agent_ready, ReadyRef, self(),
                     {ok, #{guard => self()}}},
            Outcome = try guardian_idle(Resources) of
                Value -> Value
            catch
                _:_ -> guard_failed
            end,
            cleanup_resources(Resources),
            case Outcome of
                {stopped, ReplyAlias} ->
                    ReplyAlias ! {adk_eval_agent_stopped, ReplyAlias};
                _ -> ok
            end;
        {error, Reason} ->
            Owner ! {adk_eval_agent_ready, ReadyRef, self(),
                     {error, Reason}},
            erlang:demonitor(OwnerMonitor, [flush])
    end.

start_resources(Target, Context, Config, Owner, OwnerMonitor) ->
    case target_fields(Target) of
        {error, _} = Error -> Error;
        {ok, BaseName, AgentConfig, Tools, RunnerOptions0} ->
            Name = unique_name(BaseName),
            case erlang_adk:spawn_agent(Name, AgentConfig, Tools) of
                {ok, AgentPid} ->
                    RunTimeout = positive_option(
                                   Config, run_timeout_ms,
                                   ?DEFAULT_RUN_TIMEOUT_MS),
                    RunnerOptions = RunnerOptions0#{
                        run_timeout => RunTimeout
                    },
                    App = <<"adk-eval">>,
                    User = <<"local-evaluator">>,
                    Session = unique_session(Context),
                    Runner = adk_runner:new(
                               AgentPid, App, erlang_adk_session,
                               RunnerOptions),
                    Resources = #{owner => Owner,
                                  owner_monitor => OwnerMonitor,
                                  agent_pid => AgentPid,
                                  agent_name => Name,
                                  runner => Runner,
                                  app => App, user => User,
                                  session => Session,
                                  run_timeout_ms => RunTimeout},
                    case owner_is_down(OwnerMonitor) of
                        true ->
                            cleanup_resources(Resources),
                            {error, eval_worker_down};
                        false -> {ok, Resources}
                    end;
                {error, _Reason} ->
                    {error, agent_start_failed}
            end
    end.

target_fields(#{name := Name, config := AgentConfig,
                tools := Tools} = Target)
  when is_binary(Name), byte_size(Name) > 0,
       is_map(AgentConfig), is_list(Tools) ->
    RunnerOptions = maps:get(runner_options, Target, #{}),
    case is_map(RunnerOptions) of
        true -> {ok, Name, AgentConfig, Tools, RunnerOptions};
        false -> {error, invalid_agent_runner_options}
    end;
target_fields(_) ->
    {error, invalid_agent_eval_target}.

owner_is_down(OwnerMonitor) ->
    receive
        {'DOWN', OwnerMonitor, process, _Owner, _Reason} -> true
    after 0 ->
        false
    end.

guardian_idle(Resources) ->
    OwnerMonitor = maps:get(owner_monitor, Resources),
    receive
        {'DOWN', OwnerMonitor, process, _Owner, _Reason} ->
            owner_down;
        {adk_eval_agent_stop, Owner, ReplyAlias} ->
            case owner_matches(Resources, Owner) of
                true -> {stopped, ReplyAlias};
                false -> guardian_idle(Resources)
            end;
        {adk_eval_agent_run, Owner, ReplyAlias, Input} ->
            case owner_matches(Resources, Owner) of
                true -> start_guarded_turn(
                          Resources, ReplyAlias, Input);
                false -> guardian_idle(Resources)
            end;
        _Other ->
            guardian_idle(Resources)
    end.

owner_matches(Resources, Owner) when is_pid(Owner) ->
    maps:get(owner, Resources) =:= Owner;
owner_matches(_Resources, _Owner) -> false.

start_guarded_turn(Resources, ReplyAlias, Input) ->
    Runner = maps:get(runner, Resources),
    User = maps:get(user, Resources),
    Session = maps:get(session, Resources),
    try adk_runner:run_async(Runner, User, Session, Input) of
        {ok, StreamPid} when is_pid(StreamPid) ->
            put('$adk_eval_agent_stream', StreamPid),
            StreamMonitor = erlang:monitor(process, StreamPid),
            guardian_active(Resources, ReplyAlias, StreamPid,
                            StreamMonitor)
    catch
        _:_ ->
            ReplyAlias ! {adk_eval_agent_terminal, ReplyAlias,
                          {error, runner_start_failed}},
            guardian_idle(Resources)
    end.

guardian_active(Resources, ReplyAlias, StreamPid, StreamMonitor) ->
    OwnerMonitor = maps:get(owner_monitor, Resources),
    Timeout = maps:get(run_timeout_ms, Resources) + 1000,
    receive
        {adk_event, StreamPid, Event} ->
            ReplyAlias ! {adk_eval_agent_event, ReplyAlias, Event},
            guardian_active(Resources, ReplyAlias, StreamPid,
                            StreamMonitor);
        {adk_done, StreamPid} ->
            clear_stream(StreamMonitor),
            ReplyAlias ! {adk_eval_agent_terminal, ReplyAlias, ok},
            guardian_idle(Resources);
        {adk_paused, StreamPid, _PauseEvent} ->
            clear_stream(StreamMonitor),
            ReplyAlias ! {adk_eval_agent_terminal, ReplyAlias,
                          {error, evaluation_paused}},
            guardian_idle(Resources);
        {adk_error, StreamPid, _Reason} ->
            clear_stream(StreamMonitor),
            ReplyAlias ! {adk_eval_agent_terminal, ReplyAlias,
                          {error, runner_failed}},
            guardian_idle(Resources);
        {'DOWN', OwnerMonitor, process, _Owner, _Reason} ->
            stop_stream(StreamPid, StreamMonitor),
            owner_down;
        {'DOWN', StreamMonitor, process, StreamPid, _Reason} ->
            erase('$adk_eval_agent_stream'),
            ReplyAlias ! {adk_eval_agent_terminal, ReplyAlias,
                          {error, runner_stream_down}},
            guardian_idle(Resources);
        {adk_eval_agent_stop, Owner, StopAlias} ->
            case owner_matches(Resources, Owner) of
                true ->
                    stop_stream(StreamPid, StreamMonitor),
                    {stopped, StopAlias};
                false ->
                    guardian_active(Resources, ReplyAlias, StreamPid,
                                    StreamMonitor)
            end;
        _Other ->
            guardian_active(Resources, ReplyAlias, StreamPid,
                            StreamMonitor)
    after Timeout ->
        stop_stream(StreamPid, StreamMonitor),
        ReplyAlias ! {adk_eval_agent_terminal, ReplyAlias,
                      {error, runner_timeout}},
        guardian_idle(Resources)
    end.

clear_stream(StreamMonitor) ->
    erase('$adk_eval_agent_stream'),
    erlang:demonitor(StreamMonitor, [flush]),
    ok.

stop_stream(StreamPid, StreamMonitor) ->
    erase('$adk_eval_agent_stream'),
    exit(StreamPid, kill),
    erlang:demonitor(StreamMonitor, [flush]),
    ok.

cleanup_resources(Resources) ->
    case get('$adk_eval_agent_stream') of
        StreamPid when is_pid(StreamPid) -> exit(StreamPid, kill);
        _ -> ok
    end,
    erase('$adk_eval_agent_stream'),
    safe_stop_agent(maps:get(agent_pid, Resources),
                    maps:get(agent_name, Resources)),
    _ = catch erlang_adk_session:delete_session(
                maps:get(app, Resources), maps:get(user, Resources),
                maps:get(session, Resources)),
    erlang:demonitor(maps:get(owner_monitor, Resources), [flush]),
    ok.

safe_stop_agent(AgentPid, Name) ->
    _ = catch erlang_adk:stop_agent(AgentPid),
    stop_registered_agent(Name, 3).

stop_registered_agent(_Name, 0) -> ok;
stop_registered_agent(Name, Remaining) ->
    case catch adk_agent_registry:lookup(Name) of
        {ok, Pid} when is_pid(Pid) ->
            _ = catch erlang_adk:stop_agent(Pid),
            stop_registered_agent(Name, Remaining - 1);
        _ -> ok
    end.

unique_name(BaseName) ->
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<BaseName/binary, "_eval_", Suffix/binary>>.

unique_session(Context) ->
    SampleId = maps:get(<<"sample_id">>, Context, <<"sample">>),
    Suffix = integer_to_binary(
               erlang:unique_integer([positive, monotonic])),
    <<SampleId/binary, "-", Suffix/binary>>.

positive_option(Config, Key, Default) ->
    case maps:get(Key, Config, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.
