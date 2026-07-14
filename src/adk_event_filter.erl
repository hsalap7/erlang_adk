%% @doc Deterministic include/exclude filters for canonical ADK event maps.
-module(adk_event_filter).

-export([normalize/1, apply/2, matches/2, content_type/1]).

-type normalized_filter() :: map().
-export_type([normalized_filter/0]).

-spec normalize(map()) -> {ok, normalized_filter()} | {error, term()}.
normalize(Opts) when is_map(Opts) ->
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
      end);
normalize(_) ->
    {error, {invalid_filter, expected_map}}.

-spec apply([map()], normalized_filter()) -> [map()].
apply(Events, Filter) ->
    [Event || Event <- Events, matches(Event, Filter)].

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
            Allowed = [<<"text">>, <<"tool_calls">>, <<"tool_response">>],
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
