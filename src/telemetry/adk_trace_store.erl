%% @doc Supervised bounded retention for metadata-only traces and workflow
%% lifecycle events.
%%
%% Every retained event belongs to an exact principal digest and to all
%% applicable combinations of run, trace, workflow, and invocation identity.
%% The raw principal is never retained. Cursors are store-global and strictly
%% increasing; each identity stream remembers capacity/retention eviction long
%% enough to return an explicit replay gap instead of silently presenting a
%% partial history.
-module(adk_trace_store).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1,
         append_observability/2, append_observability/3,
         append_lifecycle/2, append_lifecycle/3,
         lifecycle_receiver/1, lifecycle_receiver/2,
         is_lifecycle_receiver/1, deliver_lifecycle/2,
         deliver_lifecycle/3,
         query/3, query/4,
         status/0, status/1,
         principal_status/1, principal_status/2,
         prune/0, prune/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(SERVER, ?MODULE).
-define(CALL_TIMEOUT_MS, 5000).
-define(DEFAULT_MAX_EVENTS, 4096).
-define(DEFAULT_MAX_BYTES, 16777216).
-define(DEFAULT_MAX_EVENT_BYTES, 262144).
-define(DEFAULT_MAX_PRINCIPALS, 1024).
-define(DEFAULT_MAX_EVENTS_PER_PRINCIPAL, 1024).
-define(DEFAULT_MAX_BYTES_PER_PRINCIPAL, 4194304).
-define(DEFAULT_RETENTION_MS, 300000).
-define(DEFAULT_MAX_QUERY_EVENTS, 256).
-define(DEFAULT_MAX_QUERY_BYTES, 1048576).
-define(MAX_ID_BYTES, 512).
-define(MAX_PRINCIPAL_BYTES, 256).
-define(MAX_IDENTITY_STREAMS_PER_EVENT, 16).
-define(MAX_LIFECYCLE_DELIVERY_BYTES, 65536).
-define(DEFAULT_MAX_LIFECYCLE_PENDING, 1024).
-define(DEFAULT_MAX_PRUNE_BATCH, 1024).
-define(LIFECYCLE_RECEIVER_TAG, '$adk_trace_store_lifecycle_receiver').

-opaque lifecycle_receiver() ::
    {?LIFECYCLE_RECEIVER_TAG, 2, gen_server:server_ref(), reference(),
     atomics:atomics_ref(), pos_integer()}.
-export_type([lifecycle_receiver/0]).

-record(state, {
    config = #{} :: map(),
    entries = #{} :: map(),
    order = undefined :: term(),
    streams = #{} :: map(),
    stream_expiry = undefined :: term(),
    principals = #{} :: map(),
    lifecycle_receivers = #{} :: map(),
    receiver_scopes = #{} :: map(),
    receiver_expiry = undefined :: term(),
    lifecycle_owner_monitors = #{} :: map(),
    lifecycle_admission :: atomics:atomics_ref(),
    next_cursor = 1 :: pos_integer(),
    event_count = 0 :: non_neg_integer(),
    encoded_bytes = 0 :: non_neg_integer(),
    counters = #{} :: map(),
    timer = undefined :: reference() | undefined
}).

-spec start_link() -> gen_server:start_ret().
start_link() -> start_link(#{}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Options) when is_map(Options) ->
    case maps:get(name, Options, ?SERVER) of
        undefined -> gen_server:start_link(?MODULE, Options, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Options, []);
        _ -> {error, invalid_trace_store_name}
    end;
start_link(_Options) -> {error, invalid_trace_store_options}.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Options) ->
    #{id => maps:get(name, Options, ?SERVER),
      start => {?MODULE, start_link, [Options]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

append_observability(Principal, Event) ->
    append_observability(?SERVER, Principal, Event).
append_observability(Server, Principal, Event) ->
    safe_call(Server, {append, observability, Principal, Event}).

append_lifecycle(Principal, Event) ->
    append_lifecycle(?SERVER, Principal, Event).
append_lifecycle(Server, Principal, Event) ->
    safe_call(Server, {append, workflow_lifecycle, Principal, Event}).

%% @doc Build the only non-process workflow lifecycle receiver accepted by
%% the workflow runtime. The store binds the authenticated principal digest to
%% an unguessable, retention-bounded capability. The returned descriptor has
%% no principal field, and workflow events cannot select or replace it.
-spec lifecycle_receiver(binary()) ->
    {ok, lifecycle_receiver()} | {error, term()}.
lifecycle_receiver(Principal) ->
    lifecycle_receiver(?SERVER, Principal).

-spec lifecycle_receiver(gen_server:server_ref(), binary()) ->
    {ok, lifecycle_receiver()} | {error, term()}.
lifecycle_receiver(Server, Principal) ->
    case valid_lifecycle_store_server(Server) andalso
         valid_principal(Principal) of
        true ->
            case safe_call(Server, {register_lifecycle_receiver, Principal}) of
                {ok, {Capability, Admission, MaxPending}}
                  when is_reference(Capability),
                       is_integer(MaxPending),
                       MaxPending > 0 ->
                    case valid_lifecycle_admission(Admission) of
                        true ->
                            {ok, {?LIFECYCLE_RECEIVER_TAG, 2, Server,
                                  Capability, Admission, MaxPending}};
                        false ->
                            {error, invalid_trace_lifecycle_receiver}
                    end;
                {error, _Reason} = Error -> Error;
                _Other -> {error, invalid_trace_lifecycle_receiver}
            end;
        false ->
            {error, invalid_trace_lifecycle_receiver}
    end.

%% @doc Validate the bounded descriptor shape. Authority is not inferred from
%% this structural check: the receiving store verifies the unguessable
%% capability against its private registry before accepting an event.
-spec is_lifecycle_receiver(term()) -> boolean().
is_lifecycle_receiver(
  {?LIFECYCLE_RECEIVER_TAG, 2, Server, Capability, Admission, MaxPending}) ->
    valid_lifecycle_store_server(Server) andalso is_reference(Capability)
    andalso valid_lifecycle_admission(Admission)
    andalso is_integer(MaxPending)
    andalso MaxPending > 0 andalso MaxPending =< 4096;
is_lifecycle_receiver(_Receiver) -> false.

%% @doc Non-blocking best-effort workflow adapter. Retention is diagnostic and
%% must never turn a completed workflow into a failure. Oversized messages and
%% unavailable or back-pressured stores are silently dropped; the store also
%% rejects unknown capabilities without inspecting any caller principal.
-spec deliver_lifecycle(lifecycle_receiver(), map()) -> ok.
deliver_lifecycle(Receiver, Event) ->
    deliver_lifecycle(Receiver, undefined, Event).

%% @doc Deliver an event while binding the capability lifetime to a local
%% workflow owner. Active owners keep the capability valid even when a
%% workflow is quiet for longer than the configured receiver TTL.
-spec deliver_lifecycle(lifecycle_receiver(), pid() | undefined, map()) -> ok.
deliver_lifecycle(
  {?LIFECYCLE_RECEIVER_TAG, 2, Server, Capability, Admission,
   MaxPending} = Receiver, Owner, Event)
  when is_map(Event), (is_pid(Owner) orelse Owner =:= undefined) ->
    case is_lifecycle_receiver(Receiver) of
        true ->
            case valid_lifecycle_owner(Owner) andalso
                 bounded_input(Event, ?MAX_LIFECYCLE_DELIVERY_BYTES) of
                true ->
                    case acquire_lifecycle_admission(Admission, MaxPending) of
                        true ->
                            case best_effort_send(
                                   Server,
                                   {append_lifecycle_capability, Capability,
                                    Admission, Owner, Event}) of
                                sent -> ok;
                                dropped ->
                                    record_lifecycle_drop(Admission),
                                    release_lifecycle_admission(Admission)
                            end;
                        false -> ok
                    end;
                false ->
                    record_lifecycle_drop(Admission)
            end;
        false -> ok
    end;
deliver_lifecycle(_Receiver, _Owner, _Event) -> ok.

query(Principal, Selector, Options) ->
    query(?SERVER, Principal, Selector, Options).
query(Server, Principal, Selector, Options) ->
    safe_call(Server, {query, Principal, Selector, Options}).

status() -> status(?SERVER).
status(Server) -> safe_call(Server, status).

principal_status(Principal) -> principal_status(?SERVER, Principal).
principal_status(Server, Principal) ->
    safe_call(Server, {principal_status, Principal}).

prune() -> prune(?SERVER).
prune(Server) -> safe_call(Server, prune).

init(Options) ->
    process_flag(message_queue_data, off_heap),
    case normalize_options(Options) of
        {ok, Config} ->
            %% Slot 1 is the bounded pending count. Slot 2 is a monotonic
            %% best-effort drop counter visible through status/1.
            Admission = atomics:new(2, [{signed, true}]),
            Timer = schedule_prune(Config),
            {ok, #state{config = Config, order = gb_sets:new(),
                        stream_expiry = gb_sets:new(),
                        receiver_expiry = gb_sets:new(),
                        lifecycle_admission = Admission,
                        counters = new_counters(), timer = Timer}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({append, Kind, Principal, Event0}, _From, State0) ->
    Now = monotonic_ms(),
    case prepare_append(Kind, Principal, Event0, State0) of
        {ok, Scope, Projection} ->
            case append_projection(Scope, Projection, Now, State0) of
                {ok, Cursor, State2} -> {reply, {ok, Cursor}, State2};
                {error, Reason, State2} ->
                    {reply, {error, Reason}, reject(Reason, State2)}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, reject(Reason, State0)}
    end;
handle_call({register_lifecycle_receiver, Principal}, _From, State0) ->
    Now = monotonic_ms(),
    case principal_scope(Principal) of
        {ok, Scope} ->
            case register_lifecycle_receiver(Scope, Now, State0) of
                {ok, Capability, State2} ->
                    Admission = State2#state.lifecycle_admission,
                    MaxPending = maps:get(
                                   max_lifecycle_pending,
                                   State2#state.config),
                    {reply,
                     {ok, {Capability, Admission, MaxPending}}, State2};
                {error, Reason, State2} ->
                    {reply, {error, Reason}, reject(Reason, State2)}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, reject(Reason, State0)}
    end;
handle_call({query, Principal, Selector0, Options0}, _From, State0) ->
    Config = State0#state.config,
    case {principal_scope(Principal), normalize_selector(Selector0),
          normalize_query_options(Options0, Config)} of
        {{ok, Scope}, {ok, Selector}, {ok, QueryOptions}} ->
            {reply, query_stream(Scope, Selector, QueryOptions, State0),
             State0};
        {{error, Reason}, _, _} -> {reply, {error, Reason}, State0};
        {_, {error, Reason}, _} -> {reply, {error, Reason}, State0};
        {_, _, {error, Reason}} -> {reply, {error, Reason}, State0}
    end;
handle_call(status, _From, State) ->
    {reply, {ok, public_status(State)}, State};
handle_call({principal_status, Principal}, _From, State0) ->
    case principal_scope(Principal) of
        {ok, Scope} ->
            {reply, {ok, public_principal_status(Scope, State0)}, State0};
        {error, Reason} -> {reply, {error, Reason}, State0}
    end;
handle_call(prune, _From, State0) ->
    BeforeEvents = State0#state.event_count,
    BeforeStreams = map_size(State0#state.streams),
    BeforeReceivers = map_size(State0#state.lifecycle_receivers),
    {State1, More} = prune_state(monotonic_ms(), State0),
    State2 = maybe_schedule_immediate_prune(More, State1),
    {reply,
     {ok, #{<<"events_removed">> =>
                BeforeEvents - State2#state.event_count,
            <<"streams_removed">> =>
                erlang:max(0, BeforeStreams - map_size(State2#state.streams)),
            <<"lifecycle_receivers_removed">> =>
                erlang:max(
                  0, BeforeReceivers -
                         map_size(State2#state.lifecycle_receivers)),
            <<"more_pending">> => More,
            <<"status">> => public_status(State2)}},
     State2};
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_trace_store_request}, State}.

handle_cast({append_lifecycle_capability, Capability, Admission, Event0},
            State0)
  when is_reference(Capability), is_map(Event0) ->
    handle_lifecycle_cast(
      Capability, Admission, undefined, Event0, State0);
handle_cast({append_lifecycle_capability, Capability, Admission, Owner,
             Event0}, State0)
  when is_reference(Capability), is_map(Event0),
       (is_pid(Owner) orelse Owner =:= undefined) ->
    handle_lifecycle_cast(Capability, Admission, Owner, Event0, State0);
handle_cast(_Message, State) -> {noreply, State}.

handle_lifecycle_cast(Capability, Admission, Owner, Event0, State0) ->
    OwnedAdmission = State0#state.lifecycle_admission,
    case Admission =:= OwnedAdmission of
        true ->
            release_lifecycle_admission(OwnedAdmission),
            handle_lifecycle_capability(Capability, Owner, Event0, State0);
        false ->
            {noreply,
             State0#state{
               counters = bump(lifecycle_capability_rejected,
                               State0#state.counters)}}
    end.

handle_lifecycle_capability(Capability, Owner, Event0, State0) ->
    Now = monotonic_ms(),
    case maps:get(Capability, State0#state.lifecycle_receivers, undefined) of
        #{scope := Scope} ->
            State1 = bind_lifecycle_owner(Capability, Owner, State0),
            State2 = touch_lifecycle_receiver(Capability, Scope, Now, State1),
            case prepare_append_scope(
                   workflow_lifecycle, Scope, Event0, State2) of
                {ok, Projection} ->
                    case append_projection(Scope, Projection, Now, State2) of
                        {ok, _Cursor, State3} -> {noreply, State3};
                        {error, Reason, State3} ->
                            {noreply, reject(Reason, State3)}
                    end;
                {error, Reason} -> {noreply, reject(Reason, State2)}
            end;
        undefined ->
            {noreply,
             State0#state{
               counters = bump(lifecycle_capability_rejected,
                               State0#state.counters)}}
    end.

handle_info(prune_tick, State0) ->
    {State1, More} = prune_state(
                       monotonic_ms(), State0#state{timer = undefined}),
    {noreply, schedule_next_prune(More, State1)};
handle_info({'DOWN', Ref, process, _Owner, _Reason}, State0) ->
    {noreply, remove_lifecycle_owner(Ref, State0)};
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, #state{timer = Timer,
                          lifecycle_owner_monitors = Monitors}) ->
    cancel_timer(Timer),
    lists:foreach(
      fun(Ref) -> erlang:demonitor(Ref, [flush]) end,
      maps:keys(Monitors)),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% Never include retained events, principal digests, selectors, or identity
%% values in supervisor status/crash formatting.
format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, State) when is_record(State, state) ->
              public_status(State);
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> Value
      end, Status);
format_status(Status) -> Status.

prepare_append(Kind, Principal, Event0, State) ->
    case principal_scope(Principal) of
        {ok, Scope} ->
            case prepare_append_scope(Kind, Scope, Event0, State) of
                {ok, Projection} -> {ok, Scope, Projection};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

prepare_append_scope(Kind, _Scope, Event0, State) ->
    MaxInput = maps:get(max_event_bytes, State#state.config) * 4,
    case bounded_input(Event0, MaxInput) of
        false -> {error, trace_event_input_too_large};
        true ->
            Policy = maps:get(content_policy, State#state.config),
            case Kind of
                observability -> adk_trace_event:observability(Event0, Policy);
                workflow_lifecycle ->
                    adk_trace_event:workflow_lifecycle(Event0, Policy);
                _ -> {error, invalid_trace_event_kind}
            end
    end.

register_lifecycle_receiver(Scope, Now, State0) ->
    Ttl = maps:get(lifecycle_receiver_ttl_ms, State0#state.config),
    case maps:get(Scope, State0#state.receiver_scopes, undefined) of
        Existing when is_reference(Existing) ->
            State1 = touch_lifecycle_receiver(Existing, Scope, Now, State0),
            {ok, Existing, State1};
        undefined ->
            Limit = maps:get(max_lifecycle_receivers, State0#state.config),
            case map_size(State0#state.lifecycle_receivers) >= Limit of
                true ->
                    {error, trace_lifecycle_receiver_capacity_reached,
                     State0};
                false ->
                    Capability = make_ref(),
                    Admission = State0#state.lifecycle_admission,
                    ExpiresAt = Now + Ttl,
                    Entry = #{scope => Scope,
                              admission => Admission,
                              expires_at => ExpiresAt,
                              owners => #{}},
                    {ok, Capability,
                     State0#state{
                       lifecycle_receivers =
                           (State0#state.lifecycle_receivers)#{
                             Capability => Entry},
                       receiver_scopes =
                           (State0#state.receiver_scopes)#{
                             Scope => Capability},
                       receiver_expiry =
                           gb_sets:add(
                             {ExpiresAt, Capability},
                             State0#state.receiver_expiry)}}
            end
    end.

touch_lifecycle_receiver(Capability, Scope, Now, State0) ->
    Ttl = maps:get(lifecycle_receiver_ttl_ms, State0#state.config),
    Existing = maps:get(Capability, State0#state.lifecycle_receivers),
    OldExpiry = maps:get(expires_at, Existing),
    ExpiresAt = Now + Ttl,
    Entry = Existing#{scope => Scope, expires_at => ExpiresAt},
    State0#state{
      lifecycle_receivers =
          (State0#state.lifecycle_receivers)#{Capability => Entry},
      receiver_expiry =
          gb_sets:add(
            {ExpiresAt, Capability},
            gb_sets:delete_any(
              {OldExpiry, Capability}, State0#state.receiver_expiry))}.

bind_lifecycle_owner(_Capability, undefined, State) -> State;
bind_lifecycle_owner(Capability, Owner, State0) ->
    Entry0 = maps:get(Capability, State0#state.lifecycle_receivers),
    Owners0 = maps:get(owners, Entry0, #{}),
    case maps:is_key(Owner, Owners0) of
        true -> State0;
        false ->
            Monitor = erlang:monitor(process, Owner),
            Entry = Entry0#{owners => Owners0#{Owner => Monitor}},
            State0#state{
              lifecycle_receivers =
                  (State0#state.lifecycle_receivers)#{Capability => Entry},
              lifecycle_owner_monitors =
                  (State0#state.lifecycle_owner_monitors)#{Monitor =>
                      {Capability, Owner}}}
    end.

remove_lifecycle_owner(Ref, State0) ->
    case maps:take(Ref, State0#state.lifecycle_owner_monitors) of
        {{Capability, Owner}, RemainingMonitors} ->
            Receivers = case maps:get(
                               Capability, State0#state.lifecycle_receivers,
                               undefined) of
                #{owners := Owners0} = Entry ->
                    (State0#state.lifecycle_receivers)#{
                      Capability => Entry#{owners => maps:remove(
                                                       Owner, Owners0)}};
                _ -> State0#state.lifecycle_receivers
            end,
            State0#state{lifecycle_receivers = Receivers,
                         lifecycle_owner_monitors = RemainingMonitors};
        error -> State0
    end.

append_projection(Scope, Projection, Now, State0) ->
    Config = State0#state.config,
    NewPrincipal = not maps:is_key(Scope, State0#state.principals),
    case NewPrincipal andalso
         map_size(State0#state.principals) >= maps:get(max_principals, Config) of
        true -> {error, trace_principal_capacity_reached, State0};
        false ->
            Cursor = State0#state.next_cursor,
            Public = public_event(Cursor, Projection),
            case encoded_size(Public) of
                {ok, Bytes} ->
                    case event_fits(Bytes, Config) of
                        false -> {error, trace_event_too_large, State0};
                        true ->
                            State1 = ensure_principal_capacity(
                                       Scope, Bytes, Now, State0),
                            State2 = ensure_global_capacity(Bytes, Now, State1),
                            {ok, Cursor,
                             insert_entry(Scope, Public, Bytes, Projection,
                                          Now, State2)}
                    end;
                error -> {error, invalid_trace_event_encoding, State0}
            end
    end.

public_event(Cursor, #{kind := Kind, timestamp_ms := Timestamp,
                       identity := Identity, event := Event,
                       content_pruned := Pruned}) ->
    Base = #{<<"cursor">> => Cursor,
             <<"kind">> => kind_binary(Kind),
             <<"timestamp_ms">> => Timestamp,
             <<"identity">> => Identity,
             <<"event">> => Event},
    case Pruned of
        true -> Base#{<<"content_pruned">> => true};
        false -> Base
    end.

kind_binary(observability) -> <<"observability">>;
kind_binary(workflow_lifecycle) -> <<"workflow_lifecycle">>.

event_fits(Bytes, Config) ->
    Bytes =< maps:get(max_event_bytes, Config) andalso
    Bytes =< maps:get(max_bytes_per_principal, Config) andalso
    Bytes =< maps:get(max_bytes, Config).

ensure_principal_capacity(Scope, Bytes, Now, State) ->
    Stats = maps:get(Scope, State#state.principals,
                     #{events => 0, bytes => 0}),
    TooMany = maps:get(events, Stats) + 1 >
                  maps:get(max_events_per_principal, State#state.config),
    TooLarge = maps:get(bytes, Stats) + Bytes >
                   maps:get(max_bytes_per_principal, State#state.config),
    case TooMany orelse TooLarge of
        false -> State;
        true ->
            case oldest_stream_cursor({Scope, []}, State) of
                undefined -> State;
                Cursor ->
                    ensure_principal_capacity(
                      Scope, Bytes, Now,
                      evict_cursor(Cursor, capacity, Now, State))
            end
    end.

ensure_global_capacity(Bytes, Now, State) ->
    TooMany = State#state.event_count + 1 >
                  maps:get(max_events, State#state.config),
    TooLarge = State#state.encoded_bytes + Bytes >
                   maps:get(max_bytes, State#state.config),
    case TooMany orelse TooLarge of
        false -> State;
        true ->
            case oldest_global_cursor(State) of
                undefined -> State;
                Cursor ->
                    ensure_global_capacity(
                      Bytes, Now, evict_cursor(Cursor, capacity, Now, State))
            end
    end.

insert_entry(Scope, Public, Bytes, Projection, Now, State0) ->
    Cursor = maps:get(<<"cursor">>, Public),
    Identity = maps:get(identity, Projection),
    StreamKeys = stream_keys(Scope, Identity),
    ExpiresAt = Now + maps:get(retention_ms, State0#state.config),
    Entry = #{cursor => Cursor, scope => Scope, bytes => Bytes,
              expires_at => ExpiresAt, public => Public,
              streams => StreamKeys},
    Stats0 = maps:get(Scope, State0#state.principals,
                      #{events => 0, bytes => 0}),
    Stats = #{events => maps:get(events, Stats0) + 1,
              bytes => maps:get(bytes, Stats0) + Bytes},
    {Streams, StreamExpiry} = lists:foldl(
      fun(Key, Acc) -> add_stream_cursor(Key, Cursor, Now, Acc) end,
      {State0#state.streams, State0#state.stream_expiry}, StreamKeys),
    State1 = State0#state{
               entries = (State0#state.entries)#{Cursor => Entry},
               order = gb_sets:add(Cursor, State0#state.order),
               streams = Streams,
               stream_expiry = StreamExpiry,
               principals = (State0#state.principals)#{Scope => Stats},
               next_cursor = Cursor + 1,
               event_count = State0#state.event_count + 1,
               encoded_bytes = State0#state.encoded_bytes + Bytes,
               counters = bump(accepted, State0#state.counters)},
    enforce_stream_limit(Now, State1).

add_stream_cursor(Key, Cursor, Now, {Streams, Expiry0}) ->
    Meta0 = maps:get(Key, Streams,
                     #{cursors => gb_sets:new(), latest_cursor => 0,
                       evicted_through => 0, updated_at => Now,
                       tombstone_expires_at => undefined}),
    OldExpiry = maps:get(tombstone_expires_at, Meta0, undefined),
    Expiry = remove_expiry(OldExpiry, Key, Expiry0),
    Meta = Meta0#{cursors => gb_sets:add(Cursor, maps:get(cursors, Meta0)),
                  latest_cursor => Cursor, updated_at => Now,
                  tombstone_expires_at => undefined},
    {Streams#{Key => Meta}, Expiry}.

evict_cursor(Cursor, Reason, Now, State0) ->
    case maps:take(Cursor, State0#state.entries) of
        error -> State0;
        {Entry, Entries} ->
            Scope = maps:get(scope, Entry),
            Bytes = maps:get(bytes, Entry),
            Principals = decrement_principal(Scope, Bytes,
                                             State0#state.principals),
            {Streams, StreamExpiry} = lists:foldl(
              fun(Key, Acc) ->
                  remove_stream_cursor(
                    Key, Cursor, Now, State0#state.config, Acc)
              end, {State0#state.streams, State0#state.stream_expiry},
              maps:get(streams, Entry)),
            CounterKey = case Reason of
                retention -> retention_evictions;
                capacity -> capacity_evictions
            end,
            State0#state{
              entries = Entries,
              order = gb_sets:delete_any(Cursor, State0#state.order),
              streams = Streams,
              stream_expiry = StreamExpiry,
              principals = Principals,
              event_count = State0#state.event_count - 1,
              encoded_bytes = State0#state.encoded_bytes - Bytes,
              counters = bump(CounterKey, State0#state.counters)}
    end.

decrement_principal(Scope, Bytes, Principals) ->
    case maps:get(Scope, Principals, undefined) of
        #{events := 1} -> maps:remove(Scope, Principals);
        #{events := Events, bytes := Existing} = Stats ->
            Principals#{Scope => Stats#{events => Events - 1,
                                         bytes => Existing - Bytes}};
        _ -> Principals
    end.

remove_stream_cursor(Key, Cursor, Now, Config, {Streams, Expiry0}) ->
    case maps:get(Key, Streams, undefined) of
        undefined -> {Streams, Expiry0};
        Meta0 ->
            Set0 = maps:get(cursors, Meta0),
            Set = gb_sets:delete_any(Cursor, Set0),
            Empty = gb_sets:is_empty(Set),
            TombstoneExpiry = case Empty of
                true -> Now + maps:get(retention_ms, Config);
                false -> undefined
            end,
            OldExpiry = maps:get(tombstone_expires_at, Meta0, undefined),
            Expiry1 = remove_expiry(OldExpiry, Key, Expiry0),
            Expiry = add_expiry(TombstoneExpiry, Key, Expiry1),
            Meta = Meta0#{cursors => Set,
                          evicted_through => erlang:max(
                                               Cursor,
                                               maps:get(evicted_through,
                                                        Meta0)),
                          updated_at => Now,
                          tombstone_expires_at => TombstoneExpiry},
            {Streams#{Key => Meta}, Expiry}
    end.

remove_expiry(Expiry, Key, Index) when is_integer(Expiry) ->
    gb_sets:delete_any({Expiry, Key}, Index);
remove_expiry(_Expiry, _Key, Index) -> Index.

add_expiry(Expiry, Key, Index) when is_integer(Expiry) ->
    gb_sets:add({Expiry, Key}, Index);
add_expiry(_Expiry, _Key, Index) -> Index.

query_stream(Scope, Selector, Options, State) ->
    Key = {Scope, Selector},
    case maps:get(Key, State#state.streams, undefined) of
        undefined -> empty_query(Options);
        Meta -> query_meta(Meta, Options, State)
    end.

query_meta(Meta, Options, State) ->
    Explicit = maps:get(cursor_provided, Options),
    After = maps:get(after_cursor, Options),
    Evicted = maps:get(evicted_through, Meta),
    Latest = maps:get(latest_cursor, Meta),
    Cursors = maps:get(cursors, Meta),
    Oldest = oldest_cursor(Cursors),
    Gap = #{<<"after_cursor">> => After,
            <<"oldest_available_cursor">> => nullable(Oldest),
            <<"latest_cursor">> => Latest,
            <<"evicted_through">> => Evicted},
    case {Explicit andalso After < Evicted, Explicit andalso After > Latest} of
        {true, _} -> {error, {replay_gap, Gap}};
        {_, true} -> {error, {cursor_ahead, Gap}};
        _ ->
            Iterator = gb_sets:iterator_from(After + 1, Cursors),
            {Events, Next, Used, More} = query_events(
                                           Iterator,
                                           State#state.entries,
                                           maps:get(limit, Options),
                                           maps:get(max_bytes, Options),
                                           After, [], 0),
            {ok, #{<<"events">> => Events,
                   <<"next_cursor">> => Next,
                   <<"oldest_available_cursor">> => nullable(Oldest),
                   <<"latest_cursor">> => Latest,
                   <<"encoded_bytes">> => Used,
                   <<"truncated">> => More}}
    end.

query_events(Iterator, Entries, Limit, MaxBytes, Next, Acc, Used) ->
    case gb_sets:next(Iterator) of
        none -> {lists:reverse(Acc), Next, Used, false};
        {_Cursor, _Rest} when Limit =:= 0 ->
            {lists:reverse(Acc), Next, Used, true};
        {Cursor, Rest} ->
            case maps:get(Cursor, Entries, undefined) of
                #{public := Public, bytes := Bytes}
                  when Used + Bytes =< MaxBytes ->
                    query_events(Rest, Entries, Limit - 1, MaxBytes,
                                 Cursor, [Public | Acc], Used + Bytes);
                #{bytes := _Bytes} ->
                    {lists:reverse(Acc), Next, Used, true};
                undefined ->
                    query_events(Rest, Entries, Limit, MaxBytes,
                                 Next, Acc, Used)
            end
    end.

empty_query(Options) ->
    After = maps:get(after_cursor, Options),
    {ok, #{<<"events">> => [], <<"next_cursor">> => After,
           <<"oldest_available_cursor">> => null,
           <<"latest_cursor">> => 0,
           <<"encoded_bytes">> => 0,
           <<"truncated">> => false}}.

prune_state(Now, State0) ->
    Limit = maps:get(max_prune_batch, State0#state.config),
    {State1, MoreEntries} = prune_expired_entries(Now, Limit, State0),
    {State2, MoreStreams} = prune_expired_streams(Now, Limit, State1),
    {State3, MoreReceivers} =
        prune_expired_lifecycle_receivers(Now, Limit, State2),
    {State3, MoreEntries orelse MoreStreams orelse MoreReceivers}.

prune_expired_entries(Now, Remaining, State) ->
    case oldest_global_cursor(State) of
        undefined -> {State, false};
        Cursor ->
            Entry = maps:get(Cursor, State#state.entries),
            Expired = maps:get(expires_at, Entry) =< Now,
            case {Expired, Remaining} of
                {false, _} -> {State, false};
                {true, 0} -> {State, true};
                {true, _} ->
                    prune_expired_entries(
                      Now, Remaining - 1,
                      evict_cursor(Cursor, retention, Now, State))
            end
    end.

prune_expired_streams(Now, Remaining, State0) ->
    Index0 = State0#state.stream_expiry,
    case gb_sets:is_empty(Index0) of
        true -> {State0, false};
        false ->
            {Expiry, Key} = gb_sets:smallest(Index0),
            case {Expiry =< Now, Remaining} of
                {false, _} -> {State0, false};
                {true, 0} -> {State0, true};
                {true, _} ->
                    Index = gb_sets:delete_any({Expiry, Key}, Index0),
                    State1 = case maps:get(
                                      Key, State0#state.streams, undefined) of
                        #{cursors := Cursors,
                          tombstone_expires_at := Expiry} ->
                            case gb_sets:is_empty(Cursors) of
                                true ->
                                    State0#state{
                                      streams = maps:remove(
                                        Key, State0#state.streams),
                                      stream_expiry = Index,
                                      counters = bump(
                                        tombstones_pruned,
                                        State0#state.counters)};
                                false ->
                                    State0#state{stream_expiry = Index}
                            end;
                        _ -> State0#state{stream_expiry = Index}
                    end,
                    prune_expired_streams(
                      Now, Remaining - 1, State1)
            end
    end.

prune_expired_lifecycle_receivers(Now, Remaining, State0) ->
    Index0 = State0#state.receiver_expiry,
    case gb_sets:is_empty(Index0) of
        true -> {State0, false};
        false ->
            {Expiry, Capability} = gb_sets:smallest(Index0),
            case {Expiry =< Now, Remaining} of
                {false, _} -> {State0, false};
                {true, 0} -> {State0, true};
                {true, _} ->
                    Index = gb_sets:delete_any(
                              {Expiry, Capability}, Index0),
                    case maps:get(
                           Capability, State0#state.lifecycle_receivers,
                           undefined) of
                        #{scope := Scope, expires_at := Expiry,
                          owners := Owners}
                          when map_size(Owners) > 0 ->
                            %% A quiet workflow may legitimately run longer
                            %% than the receiver TTL. Its monitored ownership
                            %% keeps authority live without workflow-path
                            %% heartbeats or synchronous store calls.
                            State1 = touch_lifecycle_receiver(
                                       Capability, Scope, Now, State0),
                            prune_expired_lifecycle_receivers(
                              Now, Remaining - 1, State1);
                        #{scope := Scope, expires_at := Expiry} ->
                            State1 = remove_lifecycle_receiver(
                                       Capability, Scope, Index, State0),
                            prune_expired_lifecycle_receivers(
                              Now, Remaining - 1, State1);
                        _ ->
                            prune_expired_lifecycle_receivers(
                              Now, Remaining - 1,
                              State0#state{receiver_expiry = Index})
                    end
            end
    end.

remove_lifecycle_receiver(Capability, Scope, ExpiryIndex, State0) ->
    Entry = maps:get(Capability, State0#state.lifecycle_receivers),
    MonitorRefs = maps:values(maps:get(owners, Entry, #{})),
    lists:foreach(
      fun(Ref) -> erlang:demonitor(Ref, [flush]) end, MonitorRefs),
    State0#state{
      lifecycle_receivers = maps:remove(
                              Capability,
                              State0#state.lifecycle_receivers),
      receiver_scopes = maps:remove(Scope, State0#state.receiver_scopes),
      receiver_expiry = ExpiryIndex,
      lifecycle_owner_monitors = maps:without(
                                   MonitorRefs,
                                   State0#state.lifecycle_owner_monitors),
      counters = bump(lifecycle_receivers_pruned,
                      State0#state.counters)}.

enforce_stream_limit(_Now, State = #state{streams = Streams,
                                          config = Config})
  when map_size(Streams) =< map_get(max_streams, Config) -> State;
enforce_stream_limit(Now, State0) ->
    case gb_sets:is_empty(State0#state.stream_expiry) of
        true -> State0;
        false ->
            {Expiry, Key} = gb_sets:smallest(State0#state.stream_expiry),
            Index = gb_sets:delete_any(
                      {Expiry, Key}, State0#state.stream_expiry),
            State1 = State0#state{
                       streams = maps:remove(Key, State0#state.streams),
                       stream_expiry = Index,
                       counters = bump(tombstones_pruned,
                                       State0#state.counters)},
            enforce_stream_limit(Now, State1)
    end.

stream_keys(Scope, Identity) ->
    Pairs = lists:sort(maps:to_list(Identity)),
    [{Scope, Selector} || Selector <- subsets(Pairs)].

subsets([]) -> [[]];
subsets([Pair | Rest]) ->
    Tail = subsets(Rest),
    Tail ++ [[Pair | Existing] || Existing <- Tail].

oldest_global_cursor(#state{order = Order}) ->
    case gb_sets:is_empty(Order) of
        true -> undefined;
        false -> gb_sets:smallest(Order)
    end.

oldest_stream_cursor(Key, State) ->
    case maps:get(Key, State#state.streams, undefined) of
        undefined -> undefined;
        Meta -> oldest_cursor(maps:get(cursors, Meta))
    end.

oldest_cursor(Cursors) ->
    case gb_sets:is_empty(Cursors) of
        true -> undefined;
        false -> gb_sets:smallest(Cursors)
    end.

normalize_selector(all) -> {ok, []};
normalize_selector(Selector) when is_map(Selector), map_size(Selector) =< 4 ->
    normalize_selector_pairs(maps:to_list(Selector), #{}, []);
normalize_selector(_Selector) -> {error, invalid_trace_selector}.

normalize_selector_pairs([], _Seen, Acc) -> {ok, lists:sort(Acc)};
normalize_selector_pairs([{Key0, Value} | Rest], Seen, Acc) ->
    case selector_key(Key0) of
        {ok, Key} ->
            case maps:is_key(Key, Seen) orelse not valid_id(Value) of
                true -> {error, invalid_trace_selector};
                false -> normalize_selector_pairs(
                           Rest, Seen#{Key => true}, [{Key, Value} | Acc])
            end;
        error -> {error, invalid_trace_selector}
    end.

selector_key(run_id) -> {ok, <<"run_id">>};
selector_key(trace_id) -> {ok, <<"trace_id">>};
selector_key(workflow_id) -> {ok, <<"workflow_id">>};
selector_key(invocation_id) -> {ok, <<"invocation_id">>};
selector_key(<<"run_id">>) -> {ok, <<"run_id">>};
selector_key(<<"trace_id">>) -> {ok, <<"trace_id">>};
selector_key(<<"workflow_id">>) -> {ok, <<"workflow_id">>};
selector_key(<<"invocation_id">>) -> {ok, <<"invocation_id">>};
selector_key(_) -> error.

normalize_query_options(Options, Config) when is_map(Options) ->
    Allowed = [after_cursor, limit, max_bytes],
    case maps:keys(maps:without(Allowed, Options)) of
        [] ->
            Explicit = maps:is_key(after_cursor, Options),
            After = maps:get(after_cursor, Options, 0),
            Limit = maps:get(limit, Options,
                             maps:get(max_query_events, Config)),
            MaxBytes = maps:get(max_bytes, Options,
                                maps:get(max_query_bytes, Config)),
            case is_integer(After) andalso After >= 0 andalso
                 is_integer(Limit) andalso Limit > 0 andalso
                 Limit =< maps:get(max_query_events, Config) andalso
                 is_integer(MaxBytes) andalso
                 MaxBytes >= maps:get(max_event_bytes, Config) andalso
                 MaxBytes =< maps:get(max_query_bytes, Config) of
                true -> {ok, #{after_cursor => After, limit => Limit,
                               max_bytes => MaxBytes,
                               cursor_provided => Explicit}};
                false -> {error, invalid_trace_query_options}
            end;
        _ -> {error, invalid_trace_query_options}
    end;
normalize_query_options(_Options, _Config) ->
    {error, invalid_trace_query_options}.

normalize_options(Options) when is_map(Options) ->
    Allowed = [name, max_events, max_bytes, max_event_bytes,
               max_principals, max_events_per_principal,
               max_bytes_per_principal, retention_ms, prune_interval_ms,
               max_query_events, max_query_bytes, content_policy,
               lifecycle_receiver_ttl_ms, max_lifecycle_pending,
               max_prune_batch],
    case maps:keys(maps:without(Allowed, Options)) of
        [] -> normalize_known_options(Options);
        Unknown -> {error, {invalid_trace_store_options,
                            {unknown_keys, lists:sort(Unknown)}}}
    end;
normalize_options(_Options) -> {error, invalid_trace_store_options}.

normalize_known_options(Options) ->
    MaxEvents = maps:get(max_events, Options, ?DEFAULT_MAX_EVENTS),
    MaxBytes = maps:get(max_bytes, Options, ?DEFAULT_MAX_BYTES),
    MaxEventBytes = maps:get(max_event_bytes, Options,
                             ?DEFAULT_MAX_EVENT_BYTES),
    MaxPrincipals = maps:get(max_principals, Options,
                             ?DEFAULT_MAX_PRINCIPALS),
    MaxEventsPerPrincipal = maps:get(
                              max_events_per_principal, Options,
                              erlang:min(?DEFAULT_MAX_EVENTS_PER_PRINCIPAL,
                                         MaxEvents)),
    MaxBytesPerPrincipal = maps:get(
                             max_bytes_per_principal, Options,
                             erlang:min(?DEFAULT_MAX_BYTES_PER_PRINCIPAL,
                                        MaxBytes)),
    Retention = maps:get(retention_ms, Options, ?DEFAULT_RETENTION_MS),
    PruneInterval = maps:get(prune_interval_ms, Options,
                             erlang:min(1000, Retention)),
    MaxQueryEvents = maps:get(max_query_events, Options,
                              erlang:min(?DEFAULT_MAX_QUERY_EVENTS,
                                         MaxEvents)),
    MaxQueryBytes = maps:get(max_query_bytes, Options,
                             erlang:min(?DEFAULT_MAX_QUERY_BYTES, MaxBytes)),
    ContentPolicy = maps:get(content_policy, Options, reject),
    ReceiverTtl = maps:get(lifecycle_receiver_ttl_ms, Options, 86400000),
    MaxLifecyclePending = maps:get(
                            max_lifecycle_pending, Options,
                            ?DEFAULT_MAX_LIFECYCLE_PENDING),
    MaxPruneBatch = maps:get(max_prune_batch, Options,
                             ?DEFAULT_MAX_PRUNE_BATCH),
    Name = maps:get(name, Options, ?SERVER),
    Values = [MaxEvents, MaxBytes, MaxEventBytes, MaxPrincipals,
              MaxEventsPerPrincipal, MaxBytesPerPrincipal, Retention,
              PruneInterval, MaxQueryEvents, MaxQueryBytes, ReceiverTtl,
              MaxLifecyclePending, MaxPruneBatch],
    Valid = lists:all(fun positive_integer/1, Values) andalso
            (Name =:= undefined orelse is_atom(Name)) andalso
            MaxEvents =< 1000000 andalso MaxBytes =< 1073741824 andalso
            MaxEventBytes =< 16777216 andalso MaxEventBytes =< MaxBytes andalso
            MaxPrincipals =< 100000 andalso
            MaxEventsPerPrincipal =< MaxEvents andalso
            MaxBytesPerPrincipal =< MaxBytes andalso
            MaxEventBytes =< MaxBytesPerPrincipal andalso
            Retention =< 86400000 andalso PruneInterval =< Retention andalso
            ReceiverTtl >= Retention andalso
            ReceiverTtl =< 604800000 andalso
            MaxLifecyclePending =< 4096 andalso MaxPruneBatch =< 10000 andalso
            MaxQueryEvents =< MaxEvents andalso
            MaxEventBytes =< MaxQueryBytes andalso
            MaxQueryBytes =< MaxBytes andalso
            (ContentPolicy =:= reject orelse ContentPolicy =:= prune),
    case Valid of
        true ->
            {ok, #{name => Name, max_events => MaxEvents,
                   max_bytes => MaxBytes, max_event_bytes => MaxEventBytes,
                   max_principals => MaxPrincipals,
                   max_events_per_principal => MaxEventsPerPrincipal,
                   max_bytes_per_principal => MaxBytesPerPrincipal,
                   retention_ms => Retention,
                   prune_interval_ms => PruneInterval,
                   max_query_events => MaxQueryEvents,
                   max_query_bytes => MaxQueryBytes,
                   content_policy => ContentPolicy,
                   lifecycle_receiver_ttl_ms => ReceiverTtl,
                   max_lifecycle_pending => MaxLifecyclePending,
                   max_prune_batch => MaxPruneBatch,
                   max_lifecycle_receivers => MaxPrincipals,
                   max_lifecycle_delivery_bytes =>
                       ?MAX_LIFECYCLE_DELIVERY_BYTES,
                   max_streams => MaxEvents *
                                      ?MAX_IDENTITY_STREAMS_PER_EVENT +
                                      MaxPrincipals}};
        false -> {error, invalid_trace_store_options}
    end.

public_status(State) ->
    Admission = State#state.lifecycle_admission,
    Counters = (State#state.counters)#{
                 lifecycle_delivery_dropped => atomics:get(Admission, 2)},
    #{<<"events">> => State#state.event_count,
      <<"encoded_bytes">> => State#state.encoded_bytes,
      <<"principals">> => map_size(State#state.principals),
      <<"lifecycle_receivers">> =>
          map_size(State#state.lifecycle_receivers),
      <<"lifecycle_active_owners">> =>
          map_size(State#state.lifecycle_owner_monitors),
      <<"lifecycle_pending">> => atomics:get(Admission, 1),
      <<"streams">> => map_size(State#state.streams),
      <<"oldest_cursor">> => nullable(oldest_global_cursor(State)),
      <<"latest_cursor">> => State#state.next_cursor - 1,
      <<"limits">> => public_limits(State#state.config),
      <<"counters">> => public_counters(Counters)}.

public_principal_status(Scope, State) ->
    Stats = maps:get(Scope, State#state.principals,
                     #{events => 0, bytes => 0}),
    Meta = maps:get({Scope, []}, State#state.streams, undefined),
    #{<<"events">> => maps:get(events, Stats),
      <<"encoded_bytes">> => maps:get(bytes, Stats),
      <<"oldest_cursor">> => case Meta of
          undefined -> null;
          _ -> nullable(oldest_cursor(maps:get(cursors, Meta)))
      end,
      <<"latest_cursor">> => case Meta of
          undefined -> 0;
          _ -> maps:get(latest_cursor, Meta)
      end}.

public_limits(Config) ->
    maps:from_list(
      [{atom_to_binary(Key, utf8), maps:get(Key, Config)}
       || Key <- [max_events, max_bytes, max_event_bytes, max_principals,
                  max_events_per_principal, max_bytes_per_principal,
                  retention_ms, max_query_events, max_query_bytes,
                  max_lifecycle_receivers,
                  max_lifecycle_delivery_bytes,
                  lifecycle_receiver_ttl_ms, max_lifecycle_pending,
                  max_prune_batch]]).

public_counters(Counters) ->
    maps:from_list(
      [{atom_to_binary(Key, utf8), Value}
       || {Key, Value} <- maps:to_list(Counters)]).

new_counters() ->
    #{accepted => 0, rejected => 0, content_rejected => 0,
      oversized_rejected => 0, capacity_evictions => 0,
      retention_evictions => 0, tombstones_pruned => 0,
      lifecycle_capability_rejected => 0,
      lifecycle_receivers_pruned => 0}.

reject(Reason, State) ->
    Key = case Reason of
        trace_content_rejected -> content_rejected;
        trace_event_input_too_large -> oversized_rejected;
        trace_event_too_large -> oversized_rejected;
        _ -> rejected
    end,
    State#state{counters = bump(Key, State#state.counters)}.

bump(Key, Counters) ->
    Counters#{Key => maps:get(Key, Counters, 0) + 1}.

principal_scope(Principal) when is_binary(Principal),
                                byte_size(Principal) > 0,
                                byte_size(Principal) =< ?MAX_PRINCIPAL_BYTES ->
    case unicode:characters_to_binary(Principal, utf8, utf8) of
        Principal -> {ok, crypto:hash(sha256, Principal)};
        _ -> {error, invalid_trace_principal}
    end;
principal_scope(_Principal) -> {error, invalid_trace_principal}.

valid_principal(Principal) ->
    case principal_scope(Principal) of
        {ok, _Scope} -> true;
        {error, _Reason} -> false
    end.

valid_lifecycle_store_server(Server) when is_pid(Server) ->
    node(Server) =:= node();
valid_lifecycle_store_server(Server) when is_atom(Server) ->
    Server =/= undefined;
valid_lifecycle_store_server(_Server) -> false.

valid_lifecycle_admission(Admission) ->
    %% There is no public predicate for an atomics handle.  Keep the dynamic
    %% type boundary here so malformed, structurally forged descriptors are
    %% rejected without teaching Dialyzer that an ordinary reference is an
    %% atomics opaque value.
    Atomics = atomics,
    Info = info,
    try erlang:apply(Atomics, Info, [Admission]) of
        #{size := Size} when Size >= 2 -> true;
        _ -> false
    catch
        error:badarg -> false
    end.

valid_lifecycle_owner(undefined) -> true;
valid_lifecycle_owner(Owner) when is_pid(Owner) -> node(Owner) =:= node().

valid_id(Value) when is_binary(Value), byte_size(Value) > 0,
                     byte_size(Value) =< ?MAX_ID_BYTES ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end;
valid_id(_Value) -> false.

bounded_input(Event, MaxBytes) ->
    Limits = #{max_depth => 32,
               max_nodes => 10000,
               max_binary_bytes => MaxBytes,
               max_total_binary_bytes => MaxBytes,
               max_list_length => 1024,
               max_map_size => 1024,
               max_external_bytes => MaxBytes},
    adk_eval_limits:check(Event, Limits) =:= ok.

encoded_size(Value) ->
    try jsx:encode(Value) of
        Encoded -> {ok, byte_size(Encoded)}
    catch _:_ -> error
    end.

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

nullable(undefined) -> null;
nullable(Value) -> Value.

monotonic_ms() -> erlang:monotonic_time(millisecond).

schedule_prune(Config) ->
    erlang:send_after(maps:get(prune_interval_ms, Config), self(), prune_tick).

schedule_next_prune(true, State) ->
    State#state{timer = erlang:send_after(0, self(), prune_tick)};
schedule_next_prune(false, State) ->
    State#state{timer = schedule_prune(State#state.config)}.

maybe_schedule_immediate_prune(false, State) -> State;
maybe_schedule_immediate_prune(true, State = #state{timer = Timer}) ->
    cancel_timer(Timer),
    State#state{timer = erlang:send_after(0, self(), prune_tick)}.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

safe_call(Server, Request) ->
    try gen_server:call(Server, Request, ?CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, trace_store_timeout};
        exit:{noproc, _} -> {error, trace_store_unavailable};
        exit:{normal, _} -> {error, trace_store_unavailable};
        exit:{shutdown, _} -> {error, trace_store_unavailable};
        exit:_ -> {error, trace_store_unavailable}
    end.

best_effort_send(Server, Request) ->
    try erlang:send(Server, {'$gen_cast', Request}, [nosuspend, noconnect]) of
        nosuspend -> dropped;
        noconnect -> dropped;
        _Result -> sent
    catch
        _:_ -> dropped
    end.

acquire_lifecycle_admission(Admission, MaxPending) ->
    Current = atomics:get(Admission, 1),
    case Current >= MaxPending of
        true ->
            record_lifecycle_drop(Admission),
            false;
        false ->
            case atomics:compare_exchange(
                   Admission, 1, Current, Current + 1) of
                ok -> true;
                _Actual ->
                    acquire_lifecycle_admission(Admission, MaxPending)
            end
    end.

record_lifecycle_drop(Admission) ->
    _ = atomics:add_get(Admission, 2, 1),
    ok.

release_lifecycle_admission(Admission) ->
    Current = atomics:get(Admission, 1),
    case Current =< 0 of
        true -> ok;
        false ->
            case atomics:compare_exchange(
                   Admission, 1, Current, Current - 1) of
                ok -> ok;
                _Actual -> release_lifecycle_admission(Admission)
            end
    end.
