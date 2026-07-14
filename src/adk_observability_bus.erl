%% @doc Supervised, bounded asynchronous observability export bus.
%%
%% Admission is bounded by event count and bytes.  Export workers are bounded
%% by count, time and heap, and their mailbox payloads are kept off heap. The
%% delivery guarantee is bounded best effort: uncertain failures are retried
%% after bounded exponential backoff and can duplicate an event, while queue
%% pressure or attempt exhaustion can still result in zero successful exports.
%% Exporters should use trace/span/event identity when they need deduplication.
-module(adk_observability_bus).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         enqueue/1, enqueue/2, stats/0, stats/1,
         drain/1, drain/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_MAX_QUEUE_EVENTS, 4096).
-define(DEFAULT_MAX_QUEUE_BYTES, 16777216).
-define(DEFAULT_MAX_EVENT_BYTES, 262144).
-define(DEFAULT_BATCH_SIZE, 32).
-define(DEFAULT_MAX_INFLIGHT, 2).
-define(DEFAULT_MAX_ATTEMPTS, 3).
-define(DEFAULT_FLUSH_INTERVAL_MS, 100).
-define(DEFAULT_BATCH_TIMEOUT_MS, 5000).
-define(DEFAULT_WORKER_HEAP_WORDS, 500000).
-define(DEFAULT_RETRY_BASE_DELAY_MS, 100).
-define(DEFAULT_RETRY_MAX_DELAY_MS, 5000).
-define(DEFAULT_MAX_DRAIN_WAITERS, 128).
-define(CALL_GUARD_MS, 250).

-record(state, {
    queue = {[], []} :: term(),
    queue_events = 0 :: non_neg_integer(),
    queue_bytes = 0 :: non_neg_integer(),
    exporters = [] :: [map()],
    max_queue_events = ?DEFAULT_MAX_QUEUE_EVENTS :: pos_integer(),
    max_queue_bytes = ?DEFAULT_MAX_QUEUE_BYTES :: pos_integer(),
    max_event_bytes = ?DEFAULT_MAX_EVENT_BYTES :: pos_integer(),
    batch_size = ?DEFAULT_BATCH_SIZE :: pos_integer(),
    max_inflight = ?DEFAULT_MAX_INFLIGHT :: pos_integer(),
    max_attempts = ?DEFAULT_MAX_ATTEMPTS :: pos_integer(),
    flush_interval_ms = ?DEFAULT_FLUSH_INTERVAL_MS :: pos_integer(),
    batch_timeout_ms = ?DEFAULT_BATCH_TIMEOUT_MS :: pos_integer(),
    worker_heap_words = ?DEFAULT_WORKER_HEAP_WORDS :: pos_integer(),
    drop_policy = reject :: reject | drop_newest | drop_oldest,
    inflight = #{} :: map(),
    retry_wait = #{} :: map(),
    retry_events = 0 :: non_neg_integer(),
    retry_bytes = 0 :: non_neg_integer(),
    retry_base_delay_ms = ?DEFAULT_RETRY_BASE_DELAY_MS :: pos_integer(),
    retry_max_delay_ms = ?DEFAULT_RETRY_MAX_DELAY_MS :: pos_integer(),
    drainers = #{} :: map(),
    max_drain_waiters = ?DEFAULT_MAX_DRAIN_WAITERS :: pos_integer(),
    counters = #{} :: map(),
    tick = undefined :: reference() | undefined
}).

start_link() -> start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    Name = maps:get(name, Opts, ?SERVER),
    gen_server:start_link({local, Name}, ?MODULE, Opts, []).

child_spec(Opts) ->
    #{id => maps:get(name, Opts, ?SERVER),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 10000,
      type => worker,
      modules => [?MODULE]}.

enqueue(Envelope) -> enqueue(?SERVER, Envelope).
enqueue(Server, Envelope) ->
    gen_server:call(Server, {enqueue, Envelope}).

stats() -> stats(?SERVER).
stats(Server) -> gen_server:call(Server, stats).

drain(Timeout) -> drain(?SERVER, Timeout).
drain(Server, Timeout) when is_integer(Timeout), Timeout > 0 ->
    try gen_server:call(Server, {drain, Timeout},
                        Timeout + ?CALL_GUARD_MS) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, drain_timeout};
        exit:{noproc, _} -> {error, bus_unavailable};
        exit:_ -> {error, drain_failed}
    end;
drain(_Server, _Timeout) -> {error, invalid_drain_timeout}.

init(Opts) ->
    process_flag(message_queue_data, off_heap),
    case compile_options(Opts) of
        {ok, Config} ->
            Tick = erlang:send_after(maps:get(flush_interval_ms, Config),
                                     self(), flush_tick),
            {ok, #state{
                    exporters = maps:get(exporters, Config),
                    max_queue_events = maps:get(max_queue_events, Config),
                    max_queue_bytes = maps:get(max_queue_bytes, Config),
                    max_event_bytes = maps:get(max_event_bytes, Config),
                    batch_size = maps:get(batch_size, Config),
                    max_inflight = maps:get(max_inflight_batches, Config),
                    max_attempts = maps:get(max_attempts, Config),
                    flush_interval_ms = maps:get(flush_interval_ms, Config),
                    batch_timeout_ms = maps:get(batch_timeout_ms, Config),
                    worker_heap_words = maps:get(worker_max_heap_words,
                                                 Config),
                    retry_base_delay_ms = maps:get(retry_base_delay_ms,
                                                   Config),
                    retry_max_delay_ms = maps:get(retry_max_delay_ms,
                                                  Config),
                    max_drain_waiters = maps:get(max_drain_waiters, Config),
                    drop_policy = maps:get(drop_policy, Config),
                    counters = new_counters(), tick = Tick}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({enqueue, Envelope0}, _From, State0) ->
    case prepare_entry(Envelope0, State0#state.max_event_bytes) of
        {ok, Entry} ->
            {Reply, State1} = admit_entry(Entry, State0),
            self() ! dispatch,
            {reply, Reply, State1};
        {error, Reason} ->
            {reply, {error, Reason}, bump(rejected, State0)}
    end;
handle_call(stats, _From, State) ->
    {reply, public_stats(State), State};
handle_call({drain, Timeout}, From, State0)
  when is_integer(Timeout), Timeout > 0 ->
    case idle(State0) of
        true -> {reply, ok, State0};
        false ->
            case map_size(State0#state.drainers) <
                   State0#state.max_drain_waiters of
                false -> {reply, {error, drain_waiter_limit}, State0};
                true ->
                    self() ! dispatch,
                    Ref = make_ref(),
                    Caller = element(1, From),
                    Monitor = erlang:monitor(process, Caller),
                    Timer = erlang:send_after(
                              Timeout, self(), {drain_timeout, Ref}),
                    Drainer = #{from => From, caller => Caller,
                                monitor => Monitor, timer => Timer},
                    {noreply, State0#state{
                                drainers =
                                  (State0#state.drainers)#{Ref => Drainer}}}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(dispatch, State0) ->
    {noreply, maybe_finish_drainers(start_batches(State0))};
handle_info(flush_tick, State0) ->
    State1 = start_batches(State0),
    Tick = erlang:send_after(State1#state.flush_interval_ms,
                             self(), flush_tick),
    {noreply, maybe_finish_drainers(State1#state{tick = Tick})};
handle_info({adk_observability_batch, Ref, Pid, _CompletedAt, Results},
            State0) ->
    case maps:take(Ref, State0#state.inflight) of
        {#{pid := Pid, monitor := Monitor, timer := Timer,
           batch := Batch}, Inflight1} ->
            _ = erlang:cancel_timer(Timer),
            erlang:demonitor(Monitor, [flush]),
            State1 = State0#state{inflight = Inflight1},
            State2 = apply_batch_results(Batch, Results, State1),
            {noreply, maybe_finish_drainers(start_batches(State2))};
        error ->
            %% Late completion from a timed-out generation is ignored.
            {noreply, State0}
    end;
handle_info({batch_timeout, Ref}, State0) ->
    case maps:take(Ref, State0#state.inflight) of
        {#{pid := Pid, monitor := Monitor, batch := Batch}, Inflight1} ->
            exit(Pid, kill),
            erlang:demonitor(Monitor, [flush]),
            Failed = lists:duplicate(length(Batch), {error, timeout}),
            State1 = bump(worker_timeouts,
                          State0#state{inflight = Inflight1}),
            State2 = apply_batch_results(Batch, Failed, State1),
            {noreply, maybe_finish_drainers(start_batches(State2))};
        error -> {noreply, State0}
    end;
handle_info({retry_ready, Ref}, State0) ->
    case maps:take(Ref, State0#state.retry_wait) of
        {#{entry := Entry}, RetryWait1} ->
            Bytes = maps:get(bytes, Entry),
            State1 = State0#state{
                       retry_wait = RetryWait1,
                       retry_events = State0#state.retry_events - 1,
                       retry_bytes = State0#state.retry_bytes - Bytes,
                       queue = queue:in(Entry, State0#state.queue),
                       queue_events = State0#state.queue_events + 1,
                       queue_bytes = State0#state.queue_bytes + Bytes},
            {noreply, maybe_finish_drainers(start_batches(State1))};
        error -> {noreply, State0}
    end;
handle_info({drain_timeout, Ref}, State0) ->
    case maps:take(Ref, State0#state.drainers) of
        {Drainer, Drainers1} ->
            erlang:demonitor(maps:get(monitor, Drainer), [flush]),
            gen_server:reply(maps:get(from, Drainer),
                             {error, drain_timeout}),
            {noreply, State0#state{drainers = Drainers1}};
        error -> {noreply, State0}
    end;
handle_info({'DOWN', Monitor, process, Pid, _Reason}, State0) ->
    case take_inflight_by_monitor(Monitor, Pid, State0#state.inflight) of
        {ok, _Ref, #{batch := Batch, timer := Timer}, Inflight1} ->
            _ = erlang:cancel_timer(Timer),
            Failed = lists:duplicate(length(Batch), {error, worker_down}),
            State1 = bump(worker_down,
                          State0#state{inflight = Inflight1}),
            State2 = apply_batch_results(Batch, Failed, State1),
            {noreply, maybe_finish_drainers(start_batches(State2))};
        error -> {noreply, remove_drainer_by_monitor(Monitor, Pid, State0)}
    end;
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    case State#state.tick of
        undefined -> ok;
        Tick -> erlang:cancel_timer(Tick)
    end,
    maps:foreach(fun(_Ref, #{pid := Pid}) -> exit(Pid, shutdown) end,
                 State#state.inflight),
    maps:foreach(
      fun(_Ref, #{timer := Timer}) -> erlang:cancel_timer(Timer) end,
      State#state.retry_wait),
    maps:foreach(
      fun(_Ref, Drainer) ->
          erlang:cancel_timer(maps:get(timer, Drainer)),
          erlang:demonitor(maps:get(monitor, Drainer), [flush])
      end, State#state.drainers),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

compile_options(Opts) ->
    Defaults = #{exporters => [],
                 max_queue_events => ?DEFAULT_MAX_QUEUE_EVENTS,
                 max_queue_bytes => ?DEFAULT_MAX_QUEUE_BYTES,
                 max_event_bytes => ?DEFAULT_MAX_EVENT_BYTES,
                 batch_size => ?DEFAULT_BATCH_SIZE,
                 max_inflight_batches => ?DEFAULT_MAX_INFLIGHT,
                 max_attempts => ?DEFAULT_MAX_ATTEMPTS,
                 flush_interval_ms => ?DEFAULT_FLUSH_INTERVAL_MS,
                 batch_timeout_ms => ?DEFAULT_BATCH_TIMEOUT_MS,
                 worker_max_heap_words => ?DEFAULT_WORKER_HEAP_WORDS,
                 retry_base_delay_ms => ?DEFAULT_RETRY_BASE_DELAY_MS,
                 retry_max_delay_ms => ?DEFAULT_RETRY_MAX_DELAY_MS,
                 max_drain_waiters => ?DEFAULT_MAX_DRAIN_WAITERS,
                 drop_policy => reject},
    Allowed = [name | maps:keys(Defaults)],
    Unknown = maps:keys(maps:without(Allowed, Opts)),
    Config = maps:merge(Defaults, maps:without([name], Opts)),
    Numeric = [{max_queue_events, 1000000},
               {max_queue_bytes, 1073741824},
               {max_event_bytes, 16777216},
               {batch_size, 10000},
               {max_inflight_batches, 128},
               {max_attempts, 100},
               {flush_interval_ms, 60000},
               {batch_timeout_ms, 300000},
               {worker_max_heap_words, 10000000},
               {retry_base_delay_ms, 60000},
               {retry_max_delay_ms, 300000},
               {max_drain_waiters, 10000}],
    BadNumber = [Key || {Key, Max} <- Numeric,
                        not valid_limit(maps:get(Key, Config), Max)],
    Policy = maps:get(drop_policy, Config),
    case {Unknown, BadNumber,
          maps:get(max_event_bytes, Config) =<
            maps:get(max_queue_bytes, Config),
          maps:get(retry_base_delay_ms, Config) =<
            maps:get(retry_max_delay_ms, Config),
          lists:member(Policy, [reject, drop_newest, drop_oldest]),
          adk_observability:validate_exporters(maps:get(exporters, Config))} of
        {[], [], true, true, true, ok} -> {ok, Config};
        {[_ | _], _, _, _, _, _} ->
            {error, {invalid_observability_bus_options,
                     {unknown_keys, lists:sort(Unknown)}}};
        {_, [Bad | _], _, _, _, _} ->
            {error, {invalid_observability_bus_options, Bad}};
        {_, _, false, _, _, _} ->
            {error, {invalid_observability_bus_options,
                     max_event_bytes_above_queue}};
        {_, _, _, false, _, _} ->
            {error, {invalid_observability_bus_options,
                     retry_delay_range}};
        {_, _, _, _, false, _} ->
            {error, {invalid_observability_bus_options, drop_policy}};
        {_, _, _, _, _, {error, Reason}} ->
            {error, {invalid_observability_bus_options, Reason}}
    end.

prepare_entry(Envelope0, MaxBytes) ->
    case adk_observability:encode(Envelope0) of
        {ok, Envelope} ->
            try erlang:external_size(Envelope) of
                Bytes when Bytes =< MaxBytes ->
                    {ok, #{envelope => Envelope, bytes => Bytes,
                           attempt => 1}};
                Bytes -> {error, {observability_event_too_large,
                                  Bytes, MaxBytes}}
            catch _:_ -> {error, invalid_observability_event_size}
            end;
        {error, _} = Error -> Error
    end.

admit_entry(Entry, State) ->
    case fits(Entry, State) of
        true -> {{ok, accepted}, queue_entry(Entry, State)};
        false -> overflow_entry(Entry, State#state.drop_policy, State)
    end.

overflow_entry(_Entry, reject, State) ->
    {{error, queue_full}, bump(dropped_rejected, State)};
overflow_entry(_Entry, drop_newest, State) ->
    {{error, dropped_newest}, bump(dropped_newest, State)};
overflow_entry(Entry, drop_oldest, State0) ->
    case make_room(Entry, State0, 0) of
        {ok, State1, Dropped} ->
            State2 = bump_by(dropped_oldest, Dropped,
                             queue_entry(Entry, State1)),
            {{ok, #{accepted => true, dropped_oldest => Dropped}}, State2};
        error ->
            {{error, queue_full}, bump(dropped_rejected, State0)}
    end.

make_room(Entry, State, Dropped) ->
    case fits(Entry, State) of
        true -> {ok, State, Dropped};
        false ->
            case queue:out(State#state.queue) of
                {{value, Old}, Queue1} ->
                    State1 = State#state{
                               queue = Queue1,
                               queue_events = State#state.queue_events - 1,
                               queue_bytes = State#state.queue_bytes -
                                             maps:get(bytes, Old)},
                    make_room(Entry, State1, Dropped + 1);
                {empty, _} -> error
            end
    end.

fits(Entry, State) ->
    State#state.queue_events + State#state.retry_events + 1 =<
      State#state.max_queue_events andalso
    State#state.queue_bytes + State#state.retry_bytes +
      maps:get(bytes, Entry) =<
      State#state.max_queue_bytes.

queue_entry(Entry, State) ->
    bump(accepted,
         State#state{queue = queue:in(Entry, State#state.queue),
                     queue_events = State#state.queue_events + 1,
                     queue_bytes = State#state.queue_bytes +
                                   maps:get(bytes, Entry)}).

start_batches(State = #state{queue_events = 0}) -> State;
start_batches(State = #state{inflight = Inflight, max_inflight = Max})
  when map_size(Inflight) >= Max -> State;
start_batches(State0) ->
    {Batch, State1} = take_batch(State0#state.batch_size, State0, []),
    case Batch of
        [] -> State1;
        _ -> start_batches(start_worker(lists:reverse(Batch), State1))
    end.

take_batch(0, State, Acc) -> {Acc, State};
take_batch(_Remaining, State = #state{queue_events = 0}, Acc) ->
    {Acc, State};
take_batch(Remaining, State0, Acc) ->
    {{value, Entry}, Queue1} = queue:out(State0#state.queue),
    State1 = State0#state{
               queue = Queue1,
               queue_events = State0#state.queue_events - 1,
               queue_bytes = State0#state.queue_bytes - maps:get(bytes, Entry)},
    take_batch(Remaining - 1, State1, [Entry | Acc]).

start_worker(Batch, State0) ->
    Parent = self(),
    Ref = make_ref(),
    Exporters = State0#state.exporters,
    Worker = fun() ->
        process_flag(message_queue_data, off_heap),
        Results = [export_one(maps:get(envelope, Entry), Exporters)
                   || Entry <- Batch],
        Parent ! {adk_observability_batch, Ref, self(),
                  erlang:monotonic_time(millisecond), Results}
    end,
    Options = [monitor, {message_queue_data, off_heap},
               {max_heap_size,
                #{size => State0#state.worker_heap_words,
                  kill => true, error_logger => false,
                  include_shared_binaries => true}}],
    {Pid, Monitor} = spawn_opt(Worker, Options),
    Timer = erlang:send_after(State0#state.batch_timeout_ms, self(),
                              {batch_timeout, Ref}),
    Info = #{pid => Pid, monitor => Monitor, timer => Timer, batch => Batch},
    State0#state{inflight = (State0#state.inflight)#{Ref => Info}}.

export_one(Envelope, Exporters) ->
    case adk_observability:export(Envelope, Exporters) of
        {ok, Statuses} -> exporter_result(Statuses);
        {error, _Reason} -> {error, exporter_error};
        {error, _Reason, Statuses} -> exporter_result(Statuses)
    end.

exporter_result(Statuses) ->
    Errors = [Status || Status <- Statuses,
                        maps:get(<<"status">>, Status, <<"error">>)
                          =/= <<"ok">>],
    case Errors of
        [] -> ok;
        _ ->
            Retryable = lists:any(
                          fun(Status) ->
                              maps:get(<<"retryable">>, Status, true)
                          end, Errors),
            case Retryable of
                true -> {error, exporter_error};
                false -> {error, permanent_exporter_error}
            end
    end.

apply_batch_results(Batch, Results, State0)
  when length(Batch) =:= length(Results) ->
    lists:foldl(fun apply_result/2, State0, lists:zip(Batch, Results));
apply_batch_results(Batch, _Invalid, State0) ->
    Results = lists:duplicate(length(Batch), {error, invalid_worker_result}),
    lists:foldl(fun apply_result/2, bump(invalid_worker_results, State0),
                lists:zip(Batch, Results)).

apply_result({_Entry, ok}, State) -> bump(exported, State);
apply_result({_Entry, {error, permanent_exporter_error}}, State0) ->
    bump(permanent_failures,
         bump(export_failed, bump(failed_attempts, State0)));
apply_result({Entry, {error, _Reason}}, State0) ->
    State1 = bump(failed_attempts, State0),
    Attempt = maps:get(attempt, Entry),
    case Attempt < State1#state.max_attempts of
        true ->
            Retry = Entry#{attempt => Attempt + 1},
            case fits(Retry, State1) of
                true -> schedule_retry(Retry, Attempt, State1);
                false -> bump(retry_dropped, State1)
            end;
        false -> bump(export_failed, State1)
    end;
apply_result({_Entry, _Invalid}, State) ->
    bump(invalid_worker_results, State).

schedule_retry(Entry, FailedAttempt, State0) ->
    Ref = make_ref(),
    Delay = retry_delay(FailedAttempt, State0),
    Timer = erlang:send_after(Delay, self(), {retry_ready, Ref}),
    Bytes = maps:get(bytes, Entry),
    Info = #{entry => Entry, timer => Timer, delay_ms => Delay},
    bump(retried,
         State0#state{
           retry_wait = (State0#state.retry_wait)#{Ref => Info},
           retry_events = State0#state.retry_events + 1,
           retry_bytes = State0#state.retry_bytes + Bytes}).

retry_delay(FailedAttempt, State) ->
    Shift = erlang:min(20, erlang:max(0, FailedAttempt - 1)),
    Candidate = State#state.retry_base_delay_ms * (1 bsl Shift),
    erlang:min(State#state.retry_max_delay_ms, Candidate).

take_inflight_by_monitor(Monitor, Pid, Inflight) ->
    case [{Ref, Info} || {Ref, Info = #{monitor := M, pid := P}} <-
                           maps:to_list(Inflight),
                         M =:= Monitor, P =:= Pid] of
        [{Ref, Info}] -> {ok, Ref, Info, maps:remove(Ref, Inflight)};
        _ -> error
    end.

idle(State) ->
    State#state.queue_events =:= 0 andalso
    State#state.retry_events =:= 0 andalso
    map_size(State#state.inflight) =:= 0.

maybe_finish_drainers(State = #state{drainers = Drainers})
  when map_size(Drainers) =:= 0 -> State;
maybe_finish_drainers(State = #state{drainers = Drainers}) ->
    case idle(State) of
        true ->
            maps:foreach(
              fun(_Ref, Drainer) ->
                  _ = erlang:cancel_timer(maps:get(timer, Drainer)),
                  _ = erlang:demonitor(
                        maps:get(monitor, Drainer), [flush]),
                  gen_server:reply(maps:get(from, Drainer), ok)
              end, Drainers),
            State#state{drainers = #{}};
        false -> State
    end.

remove_drainer_by_monitor(Monitor, Pid, State0) ->
    Matches = [{Ref, Drainer}
               || {Ref, Drainer = #{monitor := M, caller := Caller}} <-
                    maps:to_list(State0#state.drainers),
                  M =:= Monitor, Caller =:= Pid],
    case Matches of
        [{Ref, Drainer}] ->
            _ = erlang:cancel_timer(maps:get(timer, Drainer)),
            State0#state{drainers = maps:remove(
                                      Ref, State0#state.drainers)};
        _ -> State0
    end.

public_stats(State) ->
    Counters = maps:from_list(
                 [{atom_to_binary(Key, utf8), Value}
                  || {Key, Value} <- maps:to_list(State#state.counters)]),
    #{<<"queue_events">> => State#state.queue_events,
      <<"queue_bytes">> => State#state.queue_bytes,
      <<"pending_retry_events">> => State#state.retry_events,
      <<"pending_retry_bytes">> => State#state.retry_bytes,
      <<"inflight_batches">> => map_size(State#state.inflight),
      <<"drain_waiters">> => map_size(State#state.drainers),
      <<"max_queue_events">> => State#state.max_queue_events,
      <<"max_queue_bytes">> => State#state.max_queue_bytes,
      <<"drop_policy">> => atom_to_binary(State#state.drop_policy, utf8),
      <<"delivery_guarantee">> => <<"bounded_best_effort">>,
      <<"counters">> => Counters}.

new_counters() ->
    #{accepted => 0, exported => 0, rejected => 0,
      dropped_rejected => 0, dropped_newest => 0, dropped_oldest => 0,
      failed_attempts => 0, retried => 0, retry_dropped => 0,
      export_failed => 0, permanent_failures => 0,
      worker_timeouts => 0, worker_down => 0,
      invalid_worker_results => 0}.

bump(Key, State) -> bump_by(Key, 1, State).
bump_by(Key, Amount, State) ->
    Counters = State#state.counters,
    State#state{counters = Counters#{Key => maps:get(Key, Counters, 0) +
                                           Amount}}.

valid_limit(Value, Max) ->
    is_integer(Value) andalso Value > 0 andalso Value =< Max.
