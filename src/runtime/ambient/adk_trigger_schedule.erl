%% @doc Fixed-delay periodic adapter for the ambient runtime.
%%
%% The adapter owns exactly one timer. Every tick is submitted through the
%% bounded ambient queue and receives an idempotency key based on the schedule
%% identity and wall-clock interval slot. Slow or full runtimes therefore do
%% not create overlapping timer processes or an internal delivery backlog.
-module(adk_trigger_schedule).
-behaviour(gen_server).
-behaviour(adk_trigger_source).

-export([start/4, start/5,
         start_link/1, child_spec/1,
         status/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_CALL_TIMEOUT, 5000).

-spec start(binary(), binary(), pos_integer(), map()) ->
    {ok, pid()} | {error, term()}.
start(Trigger, ScheduleId, IntervalMs, EventTemplate) ->
    start(Trigger, ScheduleId, IntervalMs, EventTemplate, #{}).

-spec start(binary(), binary(), pos_integer(), map(), map()) ->
    {ok, pid()} | {error, term()}.
start(Trigger, ScheduleId, IntervalMs, EventTemplate, Options)
  when is_map(Options) ->
    SourceOptions = Options#{trigger => Trigger,
                             schedule_id => ScheduleId,
                             interval_ms => IntervalMs,
                             event_template => EventTemplate},
    adk_trigger_sup:start_source(?MODULE, SourceOptions);
start(_Trigger, _ScheduleId, _IntervalMs, _Template, _Options) ->
    {error, invalid_schedule_options}.

-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) ->
    #{id => ?MODULE,
      start => {?MODULE, start_link, [Options]},
      restart => transient,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec status(pid()) -> {ok, map()} | {error, term()}.
status(Pid) when is_pid(Pid) ->
    safe_call(Pid, status);
status(_Pid) ->
    {error, invalid_trigger_source}.

-spec stop(pid()) -> ok | {error, term()}.
stop(Pid) when is_pid(Pid) ->
    case adk_trigger_sup:stop_source(Pid) of
        {error, not_found} ->
            try gen_server:stop(Pid, normal, ?DEFAULT_CALL_TIMEOUT) of
                ok -> ok
            catch
                exit:{noproc, _} -> {error, not_found};
                exit:Reason -> {error, {trigger_source_stop_failed, Reason}}
            end;
        Result -> Result
    end;
stop(_Pid) ->
    {error, invalid_trigger_source}.

init(Options) ->
    case normalize_options(Options) of
        {ok, State0} ->
            Delay = maps:get(initial_delay_ms, State0),
            Timer = erlang:start_timer(Delay, self(), schedule_tick),
            {ok, State0#{timer => Timer,
                         started_at => erlang:system_time(millisecond),
                         submitted => 0,
                         duplicates => 0,
                         rejected => 0,
                         last_event_ref => undefined,
                         last_error => undefined,
                         last_tick_at => undefined}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(status, _From, State) ->
    {reply, {ok, public_status(State)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({timeout, Timer, schedule_tick}, State = #{timer := Timer}) ->
    State1 = submit_tick(State#{timer => undefined}),
    Next = erlang:start_timer(maps:get(interval_ms, State1), self(),
                              schedule_tick),
    {noreply, State1#{timer => Next}};
handle_info({timeout, _Timer, schedule_tick}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case maps:get(timer, State, undefined) of
        undefined -> ok;
        Timer -> _ = erlang:cancel_timer(Timer), ok
    end.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

normalize_options(Options) when is_map(Options) ->
    Known = [trigger, schedule_id, interval_ms, event_template,
             initial_delay_ms],
    Trigger = maps:get(trigger, Options, undefined),
    ScheduleId = maps:get(schedule_id, Options, undefined),
    Interval = maps:get(interval_ms, Options, undefined),
    Template = maps:get(event_template, Options, undefined),
    Initial = maps:get(initial_delay_ms, Options, Interval),
    case map_size(maps:without(Known, Options)) =:= 0 andalso
         valid_id(Trigger) andalso valid_id(ScheduleId) andalso
         is_integer(Interval) andalso Interval > 0 andalso
         Interval =< 86400000 andalso
         is_integer(Initial) andalso Initial >= 0 andalso
         Initial =< 86400000 andalso is_map(Template) andalso
         maps:is_key(payload, Template) of
        true ->
            case maps:get(idempotency_key, Template, ScheduleId) of
                Base when is_binary(Base), byte_size(Base) > 0,
                          byte_size(Base) =< 384 ->
                    {ok, #{trigger => Trigger,
                           schedule_id => ScheduleId,
                           interval_ms => Interval,
                           initial_delay_ms => Initial,
                           event_template => Template,
                           idempotency_base => Base}};
                _ ->
                    {error, invalid_schedule_idempotency_key}
            end;
        false ->
            {error, invalid_schedule_options}
    end;
normalize_options(_) ->
    {error, invalid_schedule_options}.

submit_tick(State) ->
    Interval = maps:get(interval_ms, State),
    ScheduledAt = erlang:system_time(millisecond),
    Slot = ScheduledAt div Interval,
    Base = maps:get(idempotency_base, State),
    Key = <<Base/binary, ":", (integer_to_binary(Slot))/binary>>,
    Template0 = maps:get(event_template, State),
    ExistingMetadata = maps:get(metadata, Template0, #{}),
    ScheduleMetadata = #{schedule_id => maps:get(schedule_id, State),
                         scheduled_at => ScheduledAt,
                         slot => Slot},
    Event = Template0#{idempotency_key => Key,
                       metadata => maps:merge(ExistingMetadata,
                                              ScheduleMetadata)},
    case adk_ambient:submit(maps:get(trigger, State), Event) of
        {ok, Ref} ->
            State#{submitted => maps:get(submitted, State) + 1,
                   last_event_ref => Ref,
                   last_error => undefined,
                   last_tick_at => ScheduledAt};
        {ok, Ref, duplicate} ->
            State#{duplicates => maps:get(duplicates, State) + 1,
                   last_event_ref => Ref,
                   last_error => undefined,
                   last_tick_at => ScheduledAt};
        {error, Reason} ->
            State#{rejected => maps:get(rejected, State) + 1,
                   last_error => Reason,
                   last_tick_at => ScheduledAt}
    end.

public_status(State) ->
    #{type => schedule,
      trigger => maps:get(trigger, State),
      schedule_id => maps:get(schedule_id, State),
      interval_ms => maps:get(interval_ms, State),
      started_at => maps:get(started_at, State),
      submitted => maps:get(submitted, State),
      duplicates => maps:get(duplicates, State),
      rejected => maps:get(rejected, State),
      last_event_ref => maps:get(last_event_ref, State),
      last_error => maps:get(last_error, State),
      last_tick_at => maps:get(last_tick_at, State)}.

safe_call(Pid, Request) ->
    try gen_server:call(Pid, Request, ?DEFAULT_CALL_TIMEOUT) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> {error, not_found};
        exit:{timeout, _} -> {error, trigger_source_timeout};
        exit:Reason -> {error, {trigger_source_failed, Reason}}
    end.

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                     byte_size(Value) =< 256 -> true;
valid_id(_) -> false.
