%% @doc Deterministic include/exclude filters for canonical ADK event maps.
%%
%% Complete tool exchanges are selection atoms.  A filter either retains the
%% call and all of its contiguous responses, or drops the whole exchange.  It
%% never re-adds an event that an exclusion rule removed.  This is important at
%% the model boundary: a lone function call or function response is not a valid
%% provider history.
-module(adk_event_filter).

-export([normalize/1, apply/2, matches/2, content_type/1,
         exchange_units/1, complete_exchange_groups/1]).

-type normalized_filter() :: map().
-export_type([normalized_filter/0]).

-spec normalize(map()) -> {ok, normalized_filter()} | {error, term()}.
normalize(Opts) when is_map(Opts) ->
    case unknown_options(Opts) of
        [] -> normalize_known_options(Opts);
        Unknown -> {error, {invalid_filter,
                            {unknown_keys, lists:sort(Unknown)}}}
    end;
normalize(_) ->
    {error, {invalid_filter, expected_map}}.

-spec apply([map()], normalized_filter()) -> [map()].
apply(Events, Filter) ->
    lists:append(
      [Unit || Unit <- exchange_units(Events), unit_matches(Unit, Filter)]).

%% @doc Partition chronological events into atomic context-selection units.
%% Only complete, contiguous call/response exchanges are combined.  An
%% already-incomplete history is left unchanged rather than silently deleting
%% data; the policy can still diagnose compressor-created partial exchanges by
%% comparing complete source groups.
-spec exchange_units([map()]) -> [[map()]].
exchange_units(Events) ->
    exchange_units(Events, []).

%% @doc Return the multi-event exchanges present in a canonical history.
-spec complete_exchange_groups([map()]) -> [[map()]].
complete_exchange_groups(Events) ->
    [Unit || Unit <- exchange_units(Events), length(Unit) > 1].

-spec matches(map(), normalized_filter()) -> boolean().
matches(Event, Filter) ->
    Author = maps:get(<<"author">>, Event),
    InvocationId = maps:get(<<"invocation_id">>, Event),
    Timestamp = maps:get(<<"timestamp">>, Event),
    Partial = maps:get(<<"partial">>, Event),
    Final = maps:get(<<"is_final">>, Event),
    Type = content_type(Event),
    included(Author, maps:get(include_authors, Filter)) andalso
    not excluded(Author, maps:get(exclude_authors, Filter)) andalso
    included(InvocationId, maps:get(include_invocation_ids, Filter)) andalso
    not excluded(InvocationId,
                 maps:get(exclude_invocation_ids, Filter)) andalso
    included(Type, maps:get(include_content_types, Filter)) andalso
    not excluded(Type, maps:get(exclude_content_types, Filter)) andalso
    lower_bound(Timestamp, maps:get(from_timestamp, Filter)) andalso
    upper_bound(Timestamp, maps:get(to_timestamp, Filter)) andalso
    boolean_match(Partial, maps:get(partial, Filter)) andalso
    boolean_match(Final, maps:get(final, Filter)).

-spec content_type(map()) -> binary().
content_type(Event) ->
    Content = maps:get(<<"content">>, Event),
    maps:get(<<"type">>, Content).

normalize_known_options(Opts) ->
    with_binary_set(include_authors, Opts, all,
      fun(IncludeAuthors) ->
        with_binary_set(exclude_authors, Opts, [],
          fun(ExcludeAuthors) ->
            with_binary_set(include_invocation_ids, Opts, all,
              fun(IncludeInvocations) ->
                with_binary_set(exclude_invocation_ids, Opts, [],
                  fun(ExcludeInvocations) ->
                    with_content_types(Opts,
                      fun(IncludeTypes, ExcludeTypes) ->
                        with_time_range(Opts,
                          fun(From, To) ->
                            with_boolean_filter(partial, Opts,
                              fun(Partial) ->
                                with_boolean_filter(final, Opts,
                                  fun(Final) ->
                                    {ok, #{
                                        include_authors => IncludeAuthors,
                                        exclude_authors => ExcludeAuthors,
                                        include_invocation_ids => IncludeInvocations,
                                        exclude_invocation_ids => ExcludeInvocations,
                                        include_content_types => IncludeTypes,
                                        exclude_content_types => ExcludeTypes,
                                        from_timestamp => From,
                                        to_timestamp => To,
                                        partial => Partial,
                                        final => Final
                                    }}
                                  end)
                              end)
                          end)
                      end)
                  end)
              end)
          end)
      end).

unknown_options(Opts) ->
    maps:keys(maps:without(known_container_options(), Opts)).

%% `normalize/1' is intentionally usable on the containing option maps passed
%% by the two public consumers.  Known non-filter keys are ignored; every
%% unknown key is rejected.  The context policy performs an additional,
%% narrower validation so session-query keys are not accepted there.
known_container_options() ->
    filter_options() ++
    [event_limit, event_cursor, cursor_secret,
     max_bytes, max_tokens, max_request_bytes, max_request_tokens,
     bytes_per_token, overflow,
     compressor, compressor_timeout, compressor_max_heap_words,
     max_input_events, max_compressed_events,
     max_compressor_output_bytes, compressor_cache_identity].

filter_options() ->
    [include_authors, exclude_authors,
     include_invocation_ids, exclude_invocation_ids,
     include_content_types, exclude_content_types,
     from_timestamp, to_timestamp, partial, final].

unit_matches(Unit, Filter) ->
    lists:all(fun(Event) -> matches(Event, Filter) end, Unit).

exchange_units([], Acc) ->
    lists:reverse(Acc);
exchange_units([Event | Rest], Acc) ->
    Calls = event_calls(Event),
    Responses = event_responses(Event),
    case initial_pending(Calls, Responses) of
        {ok, []} ->
            exchange_units(Rest, [[Event] | Acc]);
        {ok, Pending} ->
            case collect_exchange(Rest, Pending, [Event]) of
                {ok, Unit, Remaining} ->
                    exchange_units(Remaining, [Unit | Acc]);
                incomplete ->
                    exchange_units(Rest, [[Event] | Acc])
            end;
        not_a_call ->
            exchange_units(Rest, [[Event] | Acc])
    end.

initial_pending([], _Responses) ->
    not_a_call;
initial_pending(Calls, Responses) ->
    consume_responses(Calls, Responses).

collect_exchange([], _Pending, _Acc) ->
    incomplete;
collect_exchange([Event | Rest], Pending, Acc) ->
    case {event_calls(Event), event_responses(Event)} of
        {[], [_ | _] = Responses} ->
            case consume_responses(Pending, Responses) of
                {ok, []} -> {ok, lists:reverse([Event | Acc]), Rest};
                {ok, Remaining} ->
                    collect_exchange(Rest, Remaining, [Event | Acc]);
                no_match -> incomplete
            end;
        _ ->
            incomplete
    end.

consume_responses(Pending, []) ->
    {ok, Pending};
consume_responses(Pending, [Response | Rest]) ->
    case take_matching_call(Response, Pending) of
        {ok, Remaining} -> consume_responses(Remaining, Rest);
        no_match -> no_match
    end.

take_matching_call({ResponseId, ResponseName}, Pending) ->
    Predicate = case ResponseId of
        Id when is_binary(Id) ->
            fun({CallId, _Name}) -> CallId =:= Id end;
        undefined ->
            fun({_CallId, Name}) -> Name =:= ResponseName end
    end,
    take_first(Predicate, Pending, []).

take_first(_Predicate, [], _Acc) ->
    no_match;
take_first(Predicate, [Item | Rest], Acc) ->
    case Predicate(Item) of
        true -> {ok, lists:reverse(Acc, Rest)};
        false -> take_first(Predicate, Rest, [Item | Acc])
    end.

event_calls(Event) ->
    Content = maps:get(<<"content">>, Event, #{}),
    case maps:get(<<"type">>, Content, undefined) of
        <<"tool_calls">> ->
            [call_descriptor(Call) ||
                Call <- maps:get(<<"calls">>, Content, [])];
        <<"model_content">> ->
            [part_descriptor(Part) || Part <- model_parts(Content),
                                      maps:get(<<"type">>, Part, undefined)
                                          =:= <<"function_call">>];
        _ -> []
    end.

event_responses(Event) ->
    Content = maps:get(<<"content">>, Event, #{}),
    case maps:get(<<"type">>, Content, undefined) of
        <<"tool_response">> -> [response_descriptor(Content)];
        <<"model_content">> ->
            [part_descriptor(Part) || Part <- model_parts(Content),
                                      maps:get(<<"type">>, Part, undefined)
                                          =:= <<"function_response">>];
        _ -> []
    end.

model_parts(#{<<"value">> := #{<<"parts">> := Parts}})
  when is_list(Parts) -> Parts;
model_parts(_) -> [].

call_descriptor(Call) ->
    {binary_or_undefined(maps:get(<<"call_id">>, Call, undefined)),
     maps:get(<<"name">>, Call)}.

response_descriptor(Response) ->
    {binary_or_undefined(maps:get(<<"call_id">>, Response, undefined)),
     maps:get(<<"name">>, Response)}.

part_descriptor(Part) ->
    {binary_or_undefined(maps:get(<<"id">>, Part, undefined)),
     maps:get(<<"name">>, Part)}.

binary_or_undefined(Value) when is_binary(Value) -> Value;
binary_or_undefined(_) -> undefined.

with_binary_set(Key, Opts, Default, Next) ->
    case maps:get(Key, Opts, Default) of
        all -> Next(all);
        Values when is_list(Values) ->
            case lists:all(fun is_binary/1, Values) of
                true -> Next(lists:usort(Values));
                false -> {error, {invalid_filter, Key}}
            end;
        _ -> {error, {invalid_filter, Key}}
    end.

with_content_types(Opts, Next) ->
    case normalize_content_types(include_content_types, Opts, all) of
        {ok, Include} ->
            case normalize_content_types(exclude_content_types, Opts, []) of
                {ok, Exclude} -> Next(Include, Exclude);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

normalize_content_types(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        all -> {ok, all};
        Values when is_list(Values) ->
            Allowed = [<<"text">>, <<"model_content">>,
                       <<"tool_calls">>, <<"tool_response">>],
            case lists:all(fun(Value) -> lists:member(Value, Allowed) end,
                           Values) of
                true -> {ok, lists:usort(Values)};
                false -> {error, {invalid_filter, Key}}
            end;
        _ -> {error, {invalid_filter, Key}}
    end.

with_time_range(Opts, Next) ->
    case timestamp_bound(from_timestamp, Opts) of
        {ok, From} ->
            case timestamp_bound(to_timestamp, Opts) of
                {ok, To} ->
                    case valid_range(From, To) of
                        true -> Next(From, To);
                        false -> {error, {invalid_filter, timestamp_range}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

timestamp_bound(Key, Opts) ->
    case maps:get(Key, Opts, unbounded) of
        unbounded -> {ok, unbounded};
        Value when is_integer(Value) -> {ok, Value};
        _ -> {error, {invalid_filter, Key}}
    end.

valid_range(unbounded, _To) -> true;
valid_range(_From, unbounded) -> true;
valid_range(From, To) -> From =< To.

with_boolean_filter(Key, Opts, Next) ->
    case maps:get(Key, Opts, any) of
        any -> Next(any);
        true -> Next(true);
        false -> Next(false);
        _ -> {error, {invalid_filter, Key}}
    end.

included(_Value, all) -> true;
included(Value, Values) -> lists:member(Value, Values).

excluded(_Value, all) -> true;
excluded(Value, Values) -> lists:member(Value, Values).

lower_bound(_Timestamp, unbounded) -> true;
lower_bound(Timestamp, From) -> Timestamp >= From.

upper_bound(_Timestamp, unbounded) -> true;
upper_bound(Timestamp, To) -> Timestamp =< To.

boolean_match(_Value, any) -> true;
boolean_match(Value, Expected) -> Value =:= Expected.
