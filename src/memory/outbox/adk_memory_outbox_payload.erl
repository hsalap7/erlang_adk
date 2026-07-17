%% @doc Checked persistence boundary for memory-outbox payloads.
%%
%% Events are converted to the canonical event codec, sensitive fields and
%% common credential-shaped text are redacted, and only bounded JSON-safe maps
%% are returned.  Stable job and batch IDs are derived from event IDs rather
%% than runtime Erlang terms.
-module(adk_memory_outbox_payload).

-export([prepare/2, safe_reason/1]).

-define(BATCH_LIMIT, 500).

prepare(Request, Limits) when is_map(Request), is_map(Limits) ->
    Allowed = [scope, session_id, adapter, events, max_attempts],
    case lists:sort(maps:keys(maps:without(Allowed, Request))) of
        [] -> prepare_fields(Request, Limits);
        Unknown -> {error, {invalid_memory_outbox_request,
                            {unknown_keys, Unknown}}}
    end;
prepare(_Request, _Limits) ->
    {error, {invalid_memory_outbox_request, expected_map}}.

safe_reason(Reason) ->
    Redacted = scrub(adk_secret_redactor:redact(Reason)),
    case adk_json:normalize(Redacted) of
        {ok, Json} -> bound_reason(Json);
        {error, _} -> #{<<"type">> => <<"opaque_failure">>}
    end.

prepare_fields(Request, Limits) ->
    Scope0 = maps:get(scope, Request, undefined),
    SessionId = maps:get(session_id, Request, undefined),
    Adapter0 = maps:get(adapter, Request, undefined),
    Events0 = maps:get(events, Request, undefined),
    MaxAttempts = maps:get(max_attempts, Request,
                           maps:get(default_max_attempts, Limits)),
    case {validate_scope(Scope0),
          bounded_binary(SessionId, 256),
          validate_adapter(Adapter0),
          validate_attempts(MaxAttempts, Limits)} of
        {{ok, Scope}, ok, {ok, Adapter}, ok} ->
            prepare_events(Scope, SessionId, Adapter, Events0,
                           MaxAttempts, Limits);
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, Reason}, _, _} ->
            {error, {invalid_memory_outbox_session_id, Reason}};
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end.

validate_scope({user, App, User}) ->
    case {bounded_binary(App, 256), bounded_binary(User, 256)} of
        {ok, ok} -> {ok, {user, App, User}};
        {{error, Reason}, _} ->
            {error, {invalid_memory_outbox_scope, app_name, Reason}};
        {_, {error, Reason}} ->
            {error, {invalid_memory_outbox_scope, user_id, Reason}}
    end;
validate_scope(_) ->
    {error, {invalid_memory_outbox_scope, expected_user_scope}}.

validate_adapter({Module, StableId}) when is_atom(Module) ->
    case bounded_binary(StableId, 256) of
        ok -> {ok, {Module, StableId}};
        {error, Reason} ->
            {error, {invalid_memory_outbox_adapter_id, Reason}}
    end;
validate_adapter(_) ->
    {error, {invalid_memory_outbox_adapter,
             expected_module_stable_id_tuple}}.

validate_attempts(Value, Limits) ->
    Max = maps:get(max_attempts, Limits),
    case is_integer(Value) andalso Value > 0 andalso Value =< Max of
        true -> ok;
        false -> {error, {invalid_memory_outbox_max_attempts,
                          Value, {allowed_range, 1, Max}}}
    end.

prepare_events(_Scope, _SessionId, _Adapter, undefined, _Attempts, _Limits) ->
    {error, {invalid_memory_outbox_events, expected_list}};
prepare_events(Scope, SessionId, Adapter, Events0, MaxAttempts, Limits) ->
    MaxEvents = maps:get(max_events_per_job, Limits),
    case bounded_list(Events0, MaxEvents) of
        {ok, 0} -> {error, empty_memory_outbox_events};
        {ok, _} ->
            case sanitize_events(Events0, Limits, #{}, [], 0) of
                {ok, Events, EventIds, InputDuplicates} ->
                    build_prepared(Scope, SessionId, Adapter, Events,
                                   EventIds, InputDuplicates, MaxAttempts,
                                   Limits);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

sanitize_events([], _Limits, _Seen, Acc, Duplicates) ->
    Events = lists:reverse(Acc),
    {ok, Events, [maps:get(<<"id">>, Event) || Event <- Events],
     Duplicates};
sanitize_events([Event0 | Rest], Limits, Seen, Acc, Duplicates) ->
    case canonical_event(Event0, maps:get(max_event_bytes, Limits)) of
        {ok, Event, EventId, Digest} ->
            case maps:find(EventId, Seen) of
                error ->
                    sanitize_events(Rest, Limits, Seen#{EventId => Digest},
                                    [Event | Acc], Duplicates);
                {ok, Digest} ->
                    sanitize_events(Rest, Limits, Seen, Acc, Duplicates + 1);
                {ok, _Different} ->
                    {error, {memory_outbox_event_id_conflict, EventId}}
            end;
        {error, _} = Error -> Error
    end.

canonical_event(Event0, MaxBytes) ->
    case encode_canonical(Event0) of
        {ok, Encoded0} ->
            Encoded = Encoded0#{
                <<"content">> => scrub(adk_secret_redactor:redact(
                                          maps:get(<<"content">>, Encoded0))),
                <<"actions">> => scrub(adk_secret_redactor:redact(
                                          maps:get(<<"actions">>, Encoded0)))
            },
            Bytes = byte_size(jsx:encode(Encoded)),
            case Bytes =< MaxBytes of
                false ->
                    {error, {memory_outbox_event_size_limit_exceeded,
                             Bytes, MaxBytes}};
                true ->
                    case adk_event:decode(Encoded) of
                        {ok, _} ->
                            Id = maps:get(<<"id">>, Encoded),
                            case bounded_binary(Id, 256) of
                                ok -> {ok, Encoded, Id, digest(Encoded)};
                                {error, Reason} ->
                                    {error, {invalid_memory_outbox_event_id,
                                             Reason}}
                            end;
                        {error, Reason} ->
                            {error, {invalid_sanitized_memory_outbox_event,
                                     Reason}}
                    end
            end;
        {error, Reason} ->
            {error, {invalid_memory_outbox_event, Reason}}
    end.

encode_canonical(Map) when is_map(Map) ->
    case adk_event:decode(Map) of
        {ok, Event} -> adk_event:encode(Event);
        {error, _} = Error -> Error
    end;
encode_canonical(Event) ->
    adk_event:encode(Event).

build_prepared(Scope, SessionId, Adapter, Events, EventIds,
               InputDuplicates, MaxAttempts, Limits) ->
    Batches = build_batches(Events, Scope, SessionId, Adapter, 1, []),
    StorageBytes = byte_size(term_to_binary(Batches, [compressed,
                                                       deterministic])),
    MaxJobBytes = maps:get(max_job_bytes, Limits),
    case StorageBytes =< MaxJobBytes of
        false -> {error, {memory_outbox_job_size_limit_exceeded,
                          StorageBytes, MaxJobBytes}};
        true ->
            Identity = {Adapter, Scope, SessionId, EventIds},
            {ok, #{job_id => <<"memout-", (short_hash(Identity))/binary>>,
                   scope => Scope,
                   session_id => SessionId,
                   adapter => Adapter,
                   batches => Batches,
                   event_count => length(Events),
                   input_duplicates => InputDuplicates,
                   payload_digest => digest(Events),
                   storage_bytes => StorageBytes,
                   max_attempts => MaxAttempts}}
    end.

build_batches([], _Scope, _SessionId, _Adapter, _Index, Acc) ->
    lists:reverse(Acc);
build_batches(Events, Scope, SessionId, Adapter, Index, Acc) ->
    {BatchEvents, Rest} = take(Events, ?BATCH_LIMIT, []),
    EventIds = [maps:get(<<"id">>, Event) || Event <- BatchEvents],
    BatchIdentity = {Adapter, Scope, SessionId, EventIds},
    Batch = #{index => Index,
              batch_id => <<"membatch-", (short_hash(BatchIdentity))/binary>>,
              event_ids => EventIds,
              events => BatchEvents},
    build_batches(Rest, Scope, SessionId, Adapter, Index + 1,
                  [Batch | Acc]).

take(Rest, 0, Acc) -> {lists:reverse(Acc), Rest};
take([], _Remaining, Acc) -> {lists:reverse(Acc), []};
take([Value | Rest], Remaining, Acc) ->
    take(Rest, Remaining - 1, [Value | Acc]).

bounded_list(List, Max) -> bounded_list(List, Max, 0).
bounded_list([], _Max, Count) -> {ok, Count};
bounded_list([_ | _], Max, Count) when Count >= Max ->
    {error, {memory_outbox_event_count_limit_exceeded, Max}};
bounded_list([_ | Rest], Max, Count) ->
    bounded_list(Rest, Max, Count + 1);
bounded_list(_, _Max, _Count) ->
    {error, {invalid_memory_outbox_events, expected_list}}.

bounded_binary(Value, Max) when is_binary(Value) ->
    Size = byte_size(Value),
    case Size > 0 andalso Size =< Max andalso valid_utf8(Value) andalso
         binary:match(Value, <<0>>) =:= nomatch of
        true -> ok;
        false when Size =:= 0 -> {error, empty};
        false when Size > Max -> {error, {size_limit_exceeded, Size, Max}};
        false -> {error, invalid_utf8_or_nul}
    end;
bounded_binary(_, _) -> {error, expected_binary}.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

scrub(Map) when is_map(Map) ->
    maps:from_list([{Key, scrub(Value)} || {Key, Value} <- maps:to_list(Map)]);
scrub(List) when is_list(List) -> [scrub(Value) || Value <- List];
scrub(Binary) when is_binary(Binary) -> scrub_binary(Binary);
scrub(Value) -> Value.

scrub_binary(Binary) ->
    Patterns = [
        <<"(?i)(api[_ -]?key|password|passwd|access[_ -]?token|refresh[_ -]?token|authorization|bearer)\\s*[:=]\\s*\\S+">>,
        <<"AIza[0-9A-Za-z_-]{20,}">>,
        <<"sk-[0-9A-Za-z_-]{16,}">>
    ],
    lists:foldl(fun scrub_pattern/2, Binary, Patterns).

scrub_pattern(Pattern, Value) ->
    try re:replace(Value, Pattern, <<"[REDACTED]">>,
                   [global, unicode, {return, binary}]) of
        Scrubbed -> Scrubbed
    catch
        _:_ -> Value
    end.

bound_reason(Json) ->
    Encoded = jsx:encode(Json),
    case byte_size(Encoded) =< 4096 of
        true -> Json;
        false -> #{<<"type">> => <<"failure_detail_truncated">>,
                   <<"digest">> => hex(crypto:hash(sha256, Encoded))}
    end.

digest(Term) -> hex(crypto:hash(sha256,
                                term_to_binary(Term, [deterministic]))).

short_hash(Term) ->
    <<Prefix:20/binary, _/binary>> = crypto:hash(
                                      sha256,
                                      term_to_binary(Term, [deterministic])),
    hex(Prefix).

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
       || <<Byte>> <= Binary >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.
