%% @doc Versioned query, pagination, and non-destructive branching for sessions.
%%
%% The current session-service behaviour exposes whole snapshots. This layer
%% adds stable ordering, HMAC-authenticated snapshot cursors, event filters,
%% and plan/apply branching without requiring a backend rewrite. A rewind is
%% materialized as a new session; the source is never edited or deleted.
-module(adk_session_query).

-export([
    version/0,
    capabilities/0,
    new_cursor_secret/0,
    list/4,
    get/5,
    plan_branch/5,
    plan_rewind/6,
    apply_plan/3,
    branch/5,
    rewind/6
]).

-define(VERSION, 1).
-define(DEFAULT_LIST_LIMIT, 50).
-define(DEFAULT_EVENT_LIMIT, 100).
-define(MAX_PAGE_LIMIT, 500).
-define(CURSOR_MAC_BYTES, 32).
-define(CURSOR_PAYLOAD_BYTES, 105).

-spec version() -> pos_integer().
version() -> ?VERSION.

-spec capabilities() -> map().
capabilities() ->
    #{version => ?VERSION,
      session_pagination => #{stable_order => timestamp_desc_id_asc,
                              snapshot_bound => true,
                              cursor_authentication => hmac_sha256},
      event_pagination => #{snapshot_bound => true,
                            cursor_authentication => hmac_sha256},
      event_filters => [authors, invocation_ids, content_types,
                        timestamp_range, partial, final],
      branch => #{source_mutation => never,
                  stale_plan_detection => true,
                  head_state => current_session_local,
                  rewind_state => event_deltas_only,
                  transient_state_replay => blocked,
                  shared_state_replay => blocked_by_default},
      secret_fields => removed,
      event_codec_version => adk_event:codec_version()}.

-spec new_cursor_secret() -> binary().
new_cursor_secret() ->
    crypto:strong_rand_bytes(32).

%% @doc List one deterministic page. `cursor_secret' (at least 32 bytes) is
%% mandatory; cursors are bound to app, user, page size, order, and the complete
%% list snapshot.
-spec list(module(), binary(), binary(), map()) ->
    {ok, map()} | {error, term()}.
list(Service, AppName, UserId, Opts)
  when is_atom(Service), is_binary(AppName), is_binary(UserId), is_map(Opts) ->
    case query_options(limit, cursor, ?DEFAULT_LIST_LIMIT, Opts) of
        {ok, Limit, Cursor, Secret} ->
            case service_call(Service, list_sessions, [AppName, UserId]) of
                {ok, RawSessions} when is_list(RawSessions) ->
                    case normalize_session_metas(RawSessions, []) of
                        {ok, Metas0} ->
                            case unique_session_ids(Metas0) of
                                true ->
                                    Metas = sort_session_metas(Metas0),
                                    Snapshot = hash_term(Metas),
                                    Scope = hash_term(
                                              {session_list, AppName, UserId}),
                                    Query = hash_term(
                                              {Limit,
                                               timestamp_desc_id_asc}),
                                    page_response(
                                      Metas, Limit, Cursor, Secret,
                                      Snapshot, Scope, Query,
                                      fun(Page, Next) ->
                                          #{version => ?VERSION,
                                            sessions => Page,
                                            next_cursor => Next,
                                            total => length(Metas),
                                            snapshot => hex(Snapshot),
                                            order => timestamp_desc_id_asc}
                                      end);
                                false ->
                                    {error, duplicate_session_id}
                            end;
                        {error, _} = Error -> Error
                    end;
                {ok, _} -> {error, invalid_session_list};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
list(_Service, _AppName, _UserId, _Opts) ->
    {error, invalid_session_query}.

%% @doc Get one session with a stable, filtered page of canonical JSON-safe
%% events. State and event maps have all credential-bearing keys removed.
-spec get(module(), binary(), binary(), binary(), map()) ->
    {ok, map()} | {error, term()}.
get(Service, AppName, UserId, SessionId, Opts)
  when is_atom(Service), is_binary(AppName), is_binary(UserId),
       is_binary(SessionId), is_map(Opts) ->
    case query_options(event_limit, event_cursor,
                       ?DEFAULT_EVENT_LIMIT, Opts) of
        {ok, Limit, Cursor, Secret} ->
            case adk_event_filter:normalize(Opts) of
                {ok, Filter} ->
                    get_filtered_session(
                      Service, AppName, UserId, SessionId, Opts,
                      Limit, Cursor, Secret, Filter);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
get(_Service, _AppName, _UserId, _SessionId, _Opts) ->
    {error, invalid_session_query}.

get_filtered_session(Service, AppName, UserId, SessionId, _Opts,
                     Limit, Cursor, Secret, Filter) ->
    case service_call(Service, get_session,
                      [AppName, UserId, SessionId]) of
        {ok, Session} when is_map(Session) ->
            Snapshot = hash_term({AppName, UserId, SessionId, Session}),
            case safe_session_values(Session) of
                {ok, State, Timestamp, RawEvents} ->
                    case sanitize_events(RawEvents, []) of
                        {ok, Events0} ->
                            Events = adk_event_filter:apply(Events0, Filter),
                            Scope = hash_term(
                                      {session_events, AppName, UserId,
                                       SessionId}),
                            Query = hash_term({Limit, Filter}),
                            page_response(
                              Events, Limit, Cursor, Secret,
                              Snapshot, Scope, Query,
                              fun(Page, Next) ->
                                  #{version => ?VERSION,
                                    id => SessionId,
                                    app_name => AppName,
                                    user_id => UserId,
                                    state => State,
                                    timestamp => Timestamp,
                                    events => Page,
                                    event_page => #{next_cursor => Next,
                                                    total => length(Events)},
                                    snapshot => hex(Snapshot),
                                    filter => Filter}
                              end);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {ok, _} -> {error, invalid_session};
        {error, _} = Error -> Error
    end.

%% @doc Plan a branch at the current head without creating it.
-spec plan_branch(module(), binary(), binary(), binary(), map()) ->
    {ok, map()} | {error, term()}.
plan_branch(Service, AppName, UserId, SessionId, Opts) ->
    plan_rewind(Service, AppName, UserId, SessionId, all, Opts).

%% @doc Plan a new session retaining a chronological prefix of source events.
%% Selectors are `all', `{index, Count}', `{event_id, Id}', or
%% `{timestamp, Milliseconds}'. Event-id and timestamp selectors are inclusive.
-spec plan_rewind(module(), binary(), binary(), binary(), term(), map()) ->
    {ok, map()} | {error, term()}.
plan_rewind(Service, AppName, UserId, SessionId, Selector, Opts)
  when is_atom(Service), is_binary(AppName), is_binary(UserId),
       is_binary(SessionId), is_map(Opts) ->
    case maps:get(destructive, Opts, false) of
        true -> {error, destructive_rewind_unsupported};
        false ->
            case normalize_selector(Selector) of
                {ok, NormalizedSelector} ->
                    make_plan(Service, AppName, UserId, SessionId,
                              NormalizedSelector);
                {error, _} = Error -> Error
            end;
        _ -> {error, {invalid_branch_options, destructive}}
    end;
plan_rewind(_Service, _AppName, _UserId, _SessionId, _Selector, _Opts) ->
    {error, invalid_branch_query}.

make_plan(Service, AppName, UserId, SessionId, Selector) ->
    case service_call(Service, get_session,
                      [AppName, UserId, SessionId]) of
        {ok, Session} when is_map(Session) ->
            Snapshot = hash_term({AppName, UserId, SessionId, Session}),
            case session_events(Session) of
                {ok, RawEvents} ->
                    case sanitize_events(RawEvents, []) of
                        {ok, Events} ->
                            case plan_state(Session, Selector) of
                                {ok, InitialState, StateStrategy} ->
                                    case select_events(Events, Selector) of
                                        {ok, Retained} ->
                                            EventDigest = hash_term(Retained),
                                            PlanCore = #{
                                                version => ?VERSION,
                                                operation => branch,
                                                source => #{
                                                    app_name => AppName,
                                                    user_id => UserId,
                                                    session_id => SessionId,
                                                    snapshot => hex(Snapshot)},
                                                selector => Selector,
                                                events => Retained,
                                                events_digest => hex(EventDigest),
                                                retained_events =>
                                                    length(Retained),
                                                excluded_events =>
                                                    length(Events) -
                                                        length(Retained),
                                                initial_state => InitialState,
                                                state_strategy => StateStrategy,
                                                destructive => false
                                            },
                                            {ok, PlanCore#{
                                                plan_digest =>
                                                    hex(hash_term(PlanCore))
                                            }};
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {ok, _} -> {error, invalid_session};
        {error, _} = Error -> Error
    end.

%% @doc Apply a previously generated plan to a new target session. The source
%% snapshot and plan contents are revalidated. Scoped app/user deltas are
%% rejected unless `allow_shared_state_replay => true' is explicit.
-spec apply_plan(module(), map(), map()) -> {ok, map()} | {error, term()}.
apply_plan(Service, Plan, Opts)
  when is_atom(Service), is_map(Plan), is_map(Opts) ->
    case maps:get(destructive, Opts, false) of
        true -> {error, destructive_rewind_unsupported};
        false -> validate_and_apply_plan(Service, Plan, Opts);
        _ -> {error, {invalid_branch_options, destructive}}
    end;
apply_plan(_Service, _Plan, _Opts) ->
    {error, invalid_branch_plan}.

validate_and_apply_plan(Service, Plan, Opts) ->
    case parse_plan(Plan) of
        {ok, AppName, UserId, SessionId, SnapshotHex,
         Selector, PlanEvents, PlanState, StateStrategy} ->
            case service_call(Service, get_session,
                              [AppName, UserId, SessionId]) of
                {ok, Session} when is_map(Session) ->
                    CurrentSnapshot = hex(hash_term(
                                            {AppName, UserId,
                                             SessionId, Session})),
                    case secure_equal(CurrentSnapshot, SnapshotHex) of
                        false -> {error, stale_branch_plan};
                        true ->
                            revalidate_and_materialize(
                              Service, Plan, Opts, Session,
                              AppName, UserId, SessionId,
                              Selector, PlanEvents, PlanState,
                              StateStrategy)
                    end;
                {ok, _} -> {error, invalid_session};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

revalidate_and_materialize(Service, Plan, Opts, Session,
                           AppName, UserId, SessionId,
                           Selector, PlanEvents, PlanState,
                           StateStrategy) ->
    case session_events(Session) of
        {ok, RawEvents} ->
            case sanitize_events(RawEvents, []) of
                {ok, AllEvents} ->
                    case plan_state(Session, Selector) of
                        {ok, ExpectedState, StateStrategy} ->
                            case select_events(AllEvents, Selector) of
                                {ok, ExpectedEvents} ->
                                    case valid_plan_contents(
                                           Plan, ExpectedEvents, PlanEvents,
                                           ExpectedState, PlanState) of
                                        true ->
                                            materialize_plan(
                                              Service, AppName, UserId,
                                              SessionId, ExpectedEvents,
                                              ExpectedState, StateStrategy,
                                              Opts);
                                        false ->
                                            {error, invalid_branch_plan}
                                    end;
                                {error, _} -> {error, invalid_branch_plan}
                            end;
                        {ok, _ExpectedState, _DifferentStrategy} ->
                            {error, invalid_branch_plan};
                        {error, _} -> {error, invalid_branch_plan}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

valid_plan_contents(Plan, ExpectedEvents, PlanEvents,
                    ExpectedState, PlanState) ->
    ExpectedEvents =:= PlanEvents andalso
    ExpectedState =:= PlanState andalso
    maps:get(events_digest, Plan, undefined) =:=
        hex(hash_term(ExpectedEvents)) andalso
    valid_plan_digest(Plan).

valid_plan_digest(Plan) ->
    case maps:take(plan_digest, Plan) of
        {Digest, Core} when is_binary(Digest) ->
            secure_equal(Digest, hex(hash_term(Core)));
        _ -> false
    end.

materialize_plan(Service, AppName, UserId, SourceId, Events,
                 InitialState, StateStrategy, Opts) ->
    case transient_state_keys(Events) of
        [] ->
            materialize_without_transient_state(
              Service, AppName, UserId, SourceId, Events,
              InitialState, StateStrategy, Opts);
        Keys ->
            {error, {transient_state_replay_blocked, Keys}}
    end.

materialize_without_transient_state(Service, AppName, UserId, SourceId,
                                    Events, InitialState, StateStrategy,
                                    Opts) ->
    case shared_state_keys(Events) of
        [] ->
            create_branch(Service, AppName, UserId, SourceId,
                          Events, InitialState, StateStrategy, Opts);
        Keys ->
            case maps:get(allow_shared_state_replay, Opts, false) of
                true ->
                    create_branch(Service, AppName, UserId, SourceId,
                                  Events, InitialState, StateStrategy, Opts);
                false -> {error, {shared_state_replay_blocked, Keys}};
                _ -> {error, {invalid_branch_options,
                              allow_shared_state_replay}}
            end
    end.

create_branch(Service, AppName, UserId, SourceId, Events,
              InitialState, StateStrategy, Opts) ->
    case target_session_id(Opts) of
        {ok, SourceId} -> {error, source_and_target_must_differ};
        {ok, TargetId} ->
            Lock = {{?MODULE, branch_target, AppName, UserId, TargetId}, self()},
            global:trans(
              Lock,
              fun() ->
                  create_branch_locked(Service, AppName, UserId, SourceId,
                                       TargetId, Events, InitialState,
                                       StateStrategy)
              end,
              [node()], infinity);
        {error, _} = Error -> Error
    end.

create_branch_locked(Service, AppName, UserId, SourceId, TargetId, Events,
                     InitialState, StateStrategy) ->
    case service_call(Service, get_session,
                      [AppName, UserId, TargetId]) of
        {error, not_found} ->
            case service_call(Service, create_session,
                              [AppName, UserId,
                               #{session_id => TargetId,
                                 state => InitialState}]) of
                {ok, Created} when is_map(Created) ->
                    case session_events(Created) of
                        {ok, []} ->
                            copy_events(Service, AppName, UserId, TargetId,
                                        Events, SourceId, StateStrategy);
                        {ok, _} -> {error, target_session_exists};
                        {error, _} = Error -> Error
                    end;
                {ok, _} -> {error, invalid_created_session};
                {error, _} = Error -> Error
            end;
        {ok, _} -> {error, target_session_exists};
        {error, _} = Error -> Error
    end.

copy_events(Service, AppName, UserId, TargetId, Events, SourceId,
            StateStrategy) ->
    case decode_events(Events, []) of
        {ok, Records} ->
            case add_events(Service, AppName, UserId, TargetId, Records) of
                ok ->
                    {ok, #{version => ?VERSION,
                           source_session_id => SourceId,
                           session_id => TargetId,
                           events_copied => length(Events),
                           state_strategy => StateStrategy,
                           destructive => false}};
                {error, Reason} ->
                    _ = service_call(Service, delete_session,
                                     [AppName, UserId, TargetId]),
                    {error, {branch_materialization_failed, Reason}}
            end;
        {error, _} = Error ->
            _ = service_call(Service, delete_session,
                             [AppName, UserId, TargetId]),
            Error
    end.

%% @doc Materialize a full-head branch.
-spec branch(module(), binary(), binary(), binary(), map()) ->
    {ok, map()} | {error, term()}.
branch(Service, AppName, UserId, SessionId, Opts) ->
    case plan_branch(Service, AppName, UserId, SessionId, Opts) of
        {ok, Plan} -> apply_plan(Service, Plan, Opts);
        {error, _} = Error -> Error
    end.

%% @doc Materialize an historical prefix as a new session. This is always
%% non-destructive; `destructive => true' is rejected.
-spec rewind(module(), binary(), binary(), binary(), term(), map()) ->
    {ok, map()} | {error, term()}.
rewind(Service, AppName, UserId, SessionId, Selector, Opts) ->
    case plan_rewind(Service, AppName, UserId, SessionId,
                     Selector, Opts) of
        {ok, Plan} -> apply_plan(Service, Plan, Opts);
        {error, _} = Error -> Error
    end.

query_options(LimitKey, CursorKey, DefaultLimit, Opts) ->
    case page_limit(LimitKey, Opts, DefaultLimit) of
        {ok, Limit} ->
            case cursor_value(CursorKey, Opts) of
                {ok, Cursor} ->
                    case cursor_secret(Opts) of
                        {ok, Secret} -> {ok, Limit, Cursor, Secret};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

page_limit(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value > 0,
                   Value =< ?MAX_PAGE_LIMIT -> {ok, Value};
        _ -> {error, {invalid_pagination, Key}}
    end.

cursor_value(Key, Opts) ->
    case maps:get(Key, Opts, null) of
        null -> {ok, null};
        undefined -> {ok, null};
        Cursor when is_binary(Cursor), byte_size(Cursor) > 0 -> {ok, Cursor};
        _ -> {error, {invalid_pagination, Key}}
    end.

cursor_secret(Opts) ->
    case maps:get(cursor_secret, Opts, undefined) of
        Secret when is_binary(Secret), byte_size(Secret) >= 32 -> {ok, Secret};
        _ -> {error, {invalid_pagination, cursor_secret}}
    end.

page_response(Items, Limit, Cursor, Secret,
              Snapshot, Scope, Query, Build) ->
    case cursor_offset(Cursor, Secret, Snapshot, Scope, Query) of
        {ok, Offset} when Offset =< length(Items) ->
            Remaining = lists:nthtail(Offset, Items),
            Page = lists:sublist(Remaining, Limit),
            NextOffset = Offset + length(Page),
            Next = case NextOffset < length(Items) of
                true -> encode_cursor(NextOffset, Snapshot,
                                      Scope, Query, Secret);
                false -> null
            end,
            {ok, Build(Page, Next)};
        {ok, _Offset} -> {error, invalid_cursor};
        {error, _} = Error -> Error
    end.

cursor_offset(null, _Secret, _Snapshot, _Scope, _Query) -> {ok, 0};
cursor_offset(Cursor, Secret, Snapshot, Scope, Query) ->
    case decode_cursor(Cursor) of
        {ok, Offset, CursorSnapshot, CursorScope, CursorQuery, Payload, Mac} ->
            ExpectedMac = crypto:mac(hmac, sha256, Secret, Payload),
            case secure_equal(Mac, ExpectedMac) andalso
                 secure_equal(CursorScope, Scope) andalso
                 secure_equal(CursorQuery, Query) of
                false -> {error, invalid_cursor};
                true ->
                    case secure_equal(CursorSnapshot, Snapshot) of
                        true -> {ok, Offset};
                        false -> {error, stale_cursor}
                    end
            end;
        error -> {error, invalid_cursor}
    end.

encode_cursor(Offset, Snapshot, Scope, Query, Secret) ->
    Payload = <<?VERSION:8, Offset:64/unsigned-big,
                Snapshot:32/binary, Scope:32/binary, Query:32/binary>>,
    Mac = crypto:mac(hmac, sha256, Secret, Payload),
    base64url_encode(<<Payload/binary, Mac/binary>>).

decode_cursor(Cursor) ->
    case base64url_decode(Cursor) of
        {ok, <<Payload:?CURSOR_PAYLOAD_BYTES/binary,
               Mac:?CURSOR_MAC_BYTES/binary>>} ->
            case Payload of
                <<?VERSION:8, Offset:64/unsigned-big,
                  Snapshot:32/binary, Scope:32/binary, Query:32/binary>> ->
                    {ok, Offset, Snapshot, Scope, Query, Payload, Mac};
                _ -> error
            end;
        _ -> error
    end.

base64url_encode(Binary) ->
    Encoded0 = base64:encode(Binary),
    Encoded1 = binary:replace(Encoded0, <<"+">>, <<"-">>, [global]),
    Encoded2 = binary:replace(Encoded1, <<"/">>, <<"_">>, [global]),
    binary:replace(Encoded2, <<"=">>, <<>>, [global]).

base64url_decode(Binary) when is_binary(Binary) ->
    Standard0 = binary:replace(Binary, <<"-">>, <<"+">>, [global]),
    Standard1 = binary:replace(Standard0, <<"_">>, <<"/">>, [global]),
    Padding = case byte_size(Standard1) rem 4 of
        0 -> <<>>;
        2 -> <<"==">>;
        3 -> <<"=">>;
        _ -> invalid
    end,
    case Padding of
        invalid -> error;
        _ ->
            try base64:decode(<<Standard1/binary, Padding/binary>>) of
                Decoded ->
                    %% Reject alternate encodings whose unused base64 bits do
                    %% not alter the decoded signed payload. This keeps cursor
                    %% tokens canonical as well as MAC-authenticated.
                    case secure_equal(base64url_encode(Decoded), Binary) of
                        true -> {ok, Decoded};
                        false -> error
                    end
            catch
                _:_ -> error
            end
    end.

normalize_session_metas([], Acc) -> {ok, lists:reverse(Acc)};
normalize_session_metas([Meta | Rest], Acc) when is_map(Meta) ->
    case {map_field(id, Meta), map_field(timestamp, Meta)} of
        {{ok, Id}, {ok, Timestamp}}
          when is_binary(Id), is_integer(Timestamp) ->
            normalize_session_metas(
              Rest, [#{id => Id, timestamp => Timestamp} | Acc]);
        _ -> {error, invalid_session_metadata}
    end;
normalize_session_metas(_, _Acc) -> {error, invalid_session_metadata}.

unique_session_ids(Metas) ->
    Ids = [maps:get(id, Meta) || Meta <- Metas],
    length(Ids) =:= length(lists:usort(Ids)).

sort_session_metas(Metas) ->
    lists:sort(
      fun(A, B) ->
          TA = maps:get(timestamp, A),
          TB = maps:get(timestamp, B),
          case TA =:= TB of
              true -> maps:get(id, A) < maps:get(id, B);
              false -> TA > TB
          end
      end, Metas).

safe_session_values(Session) ->
    case {map_field(state, Session), map_field(timestamp, Session),
          session_events(Session)} of
        {{ok, State0}, {ok, Timestamp}, {ok, Events}}
          when is_map(State0), is_integer(Timestamp) ->
            case adk_context_guard:sanitize_value(State0) of
                {ok, State} when is_map(State) ->
                    {ok, State, Timestamp, Events};
                {ok, _} -> {error, invalid_session_state};
                {error, Reason} ->
                    {error, {invalid_session_state, Reason}}
            end;
        _ -> {error, invalid_session}
    end.

session_events(Session) ->
    case map_field(events, Session) of
        {ok, Events} when is_list(Events) -> {ok, Events};
        _ -> {error, invalid_session_events}
    end.

map_field(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> {ok, Value};
        error -> maps:find(atom_to_binary(Key, utf8), Map)
    end.

sanitize_events([], Acc) -> {ok, lists:reverse(Acc)};
sanitize_events([Event | Rest], Acc) ->
    case adk_context_guard:sanitize_event(Event) of
        {ok, Encoded} -> sanitize_events(Rest, [Encoded | Acc]);
        {error, Reason} -> {error, {invalid_session_event, Reason}}
    end;
sanitize_events(_, _Acc) -> {error, invalid_session_events}.

normalize_selector(all) -> {ok, #{kind => all}};
normalize_selector({index, Count})
  when is_integer(Count), Count >= 0 ->
    {ok, #{kind => index, value => Count}};
normalize_selector({event_id, EventId}) when is_binary(EventId) ->
    {ok, #{kind => event_id, value => EventId}};
normalize_selector({timestamp, Timestamp}) when is_integer(Timestamp) ->
    {ok, #{kind => timestamp, value => Timestamp}};
normalize_selector(_) -> {error, invalid_rewind_selector}.

select_events(Events, #{kind := all}) -> {ok, Events};
select_events(Events, #{kind := index, value := Count}) ->
    case Count =< length(Events) of
        true -> {ok, lists:sublist(Events, Count)};
        false -> {error, rewind_index_out_of_range}
    end;
select_events(Events, #{kind := event_id, value := EventId}) ->
    select_through_event(Events, EventId, []);
select_events(Events, #{kind := timestamp, value := Timestamp}) ->
    {ok, lists:takewhile(
           fun(Event) -> maps:get(<<"timestamp">>, Event) =< Timestamp end,
           Events)};
select_events(_Events, _Selector) -> {error, invalid_rewind_selector}.

select_through_event([], _EventId, _Acc) ->
    {error, rewind_event_not_found};
select_through_event([Event | Rest], EventId, Acc) ->
    Acc1 = [Event | Acc],
    case maps:get(<<"id">>, Event) =:= EventId of
        true -> {ok, lists:reverse(Acc1)};
        false -> select_through_event(Rest, EventId, Acc1)
    end.

parse_plan(#{version := ?VERSION, operation := branch,
             source := #{app_name := AppName, user_id := UserId,
                         session_id := SessionId, snapshot := Snapshot},
             selector := Selector, events := Events,
             initial_state := InitialState,
             state_strategy := StateStrategy,
             destructive := false})
  when is_binary(AppName), is_binary(UserId), is_binary(SessionId),
       is_binary(Snapshot), is_map(Selector), is_list(Events),
       is_map(InitialState) ->
    case lists:member(StateStrategy,
                      [current_session_local, event_deltas_only]) of
        true ->
            {ok, AppName, UserId, SessionId, Snapshot, Selector, Events,
             InitialState, StateStrategy};
        false -> {error, invalid_branch_plan}
    end;
parse_plan(_) -> {error, invalid_branch_plan}.

plan_state(Session, #{kind := all}) ->
    case map_field(state, Session) of
        {ok, State0} when is_map(State0) ->
            case adk_context_guard:sanitize_value(State0) of
                {ok, SafeState} when is_map(SafeState) ->
                    {ok, branchable_state(SafeState),
                     current_session_local};
                _ -> {error, invalid_session_state}
            end;
        _ -> {error, invalid_session_state}
    end;
plan_state(_Session, _HistoricalSelector) ->
    %% The current backend does not journal pre-event initial state. Replaying
    %% retained event deltas is therefore the only honest historical state
    %% reconstruction available without mutating the source.
    {ok, #{}, event_deltas_only}.

branchable_state(State) ->
    maps:filter(
      fun(Key, _Value) -> branchable_state_key(Key) end,
      State).

branchable_state_key(<<"app:", _/binary>>) -> false;
branchable_state_key(<<"user:", _/binary>>) -> false;
branchable_state_key(<<"temp:", _/binary>>) -> false;
branchable_state_key(<<"__adk_", _/binary>>) -> false;
branchable_state_key(_) -> true.

shared_state_keys(Events) ->
    lists:usort(lists:flatmap(fun event_shared_state_keys/1, Events)).

transient_state_keys(Events) ->
    lists:usort(lists:flatmap(fun event_transient_state_keys/1, Events)).

event_shared_state_keys(Event) ->
    Actions = maps:get(<<"actions">>, Event, #{}),
    Delta = maps:get(<<"state_delta">>, Actions, #{}),
    case is_map(Delta) of
        true ->
            [Key || {Key, _} <- maps:to_list(Delta),
                    shared_state_key(Key)];
        false -> []
    end.

event_transient_state_keys(Event) ->
    Actions = maps:get(<<"actions">>, Event, #{}),
    Delta = maps:get(<<"state_delta">>, Actions, #{}),
    case is_map(Delta) of
        true ->
            [Key || {Key, _} <- maps:to_list(Delta),
                    transient_state_key(Key)];
        false -> []
    end.

shared_state_key(<<"app:", _/binary>>) -> true;
shared_state_key(<<"user:", _/binary>>) -> true;
shared_state_key(_) -> false.

transient_state_key(<<"temp:", _/binary>>) -> true;
transient_state_key(<<"__adk_", _/binary>>) -> true;
transient_state_key(_) -> false.

target_session_id(Opts) ->
    case maps:get(target_session_id, Opts, undefined) of
        undefined -> {ok, generate_session_id()};
        Id when is_binary(Id), byte_size(Id) > 0 -> {ok, Id};
        _ -> {error, {invalid_branch_options, target_session_id}}
    end.

generate_session_id() ->
    Random = base64url_encode(crypto:strong_rand_bytes(18)),
    <<"branch-", Random/binary>>.

decode_events([], Acc) -> {ok, lists:reverse(Acc)};
decode_events([Event | Rest], Acc) ->
    case adk_event:decode(Event) of
        {ok, Record} -> decode_events(Rest, [Record | Acc]);
        {error, _} -> {error, invalid_branch_event}
    end.

add_events(_Service, _AppName, _UserId, _TargetId, []) -> ok;
add_events(Service, AppName, UserId, TargetId, [Event | Rest]) ->
    case service_call(Service, add_event,
                      [AppName, UserId, TargetId, Event]) of
        ok -> add_events(Service, AppName, UserId, TargetId, Rest);
        {error, _} = Error -> Error
    end.

service_call(Service, Function, Args) ->
    try erlang:apply(Service, Function, Args) of
        {ok, _} = Ok -> Ok;
        {error, _} = Error -> Error;
        ok -> ok;
        _ -> {error, {invalid_session_service_result, Function}}
    catch
        Class:_Reason ->
            {error, {session_service_failed, Function, Class}}
    end.

hash_term(Term) ->
    crypto:hash(sha256, term_to_binary(Term, [deterministic])).

secure_equal(A, B) when is_binary(A), is_binary(B),
                        byte_size(A) =:= byte_size(B) ->
    secure_equal(A, B, 0) =:= 0;
secure_equal(_, _) -> false.

secure_equal(<<>>, <<>>, Acc) -> Acc;
secure_equal(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    secure_equal(RestA, RestB, Acc bor (A bxor B)).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>
       || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
