%% @doc Shared validation, canonicalization and deterministic lexical ranking
%% for version-2 memory adapters.  Storage adapters receive only bounded,
%% JSON-safe values from this module.
-module(adk_memory_contract).

-include("adk_event.hrl").

-export([contract_version/0, default_limits/0, compile_config/1,
         capabilities/2, validate_scope/1, prepare_entry/4,
         prepare_search/4, hit/2, metadata_matches/2,
         prepare_events/5, prepare_legacy_session/3,
         entry_storage_bytes/1, id_for/2]).

-define(VERSION, 2).
-define(ENTRY_SCHEMA, 1).
-define(MAX_CONTENT_CEILING, 1048576).
-define(MAX_METADATA_CEILING, 262144).
-define(MAX_QUERY_CEILING, 65536).
-define(MAX_RESULTS_CEILING, 1000).
-define(MAX_ENTRIES_CEILING, 10000000).
-define(MAX_TOTAL_BYTES_CEILING, 10737418240).
-define(MAX_EVENTS_CEILING, 10000).

contract_version() -> ?VERSION.

default_limits() ->
    #{max_content_bytes => 65536,
      max_metadata_bytes => 16384,
      max_metadata_depth => 8,
      max_metadata_nodes => 512,
      max_query_bytes => 4096,
      max_results => 50,
      max_result_bytes => 262144,
      max_entries => 100000,
      max_total_bytes => 268435456,
      max_events_per_request => 1000,
      call_timeout => 5000}.

compile_config(Config) when is_map(Config) ->
    Defaults = default_limits(),
    Allowed = maps:keys(Defaults),
    Unknown = lists:sort(maps:keys(maps:without(Allowed, Config))),
    case Unknown of
        [] -> validate_limits(maps:merge(Defaults, Config));
        _ -> {error, {invalid_memory_config, {unknown_keys, Unknown}}}
    end;
compile_config(Other) ->
    {error, {invalid_memory_config, {expected_map, term_type(Other)}}}.

validate_limits(Limits) ->
    Checks = [{max_content_bytes, ?MAX_CONTENT_CEILING},
              {max_metadata_bytes, ?MAX_METADATA_CEILING},
              {max_metadata_depth, 32},
              {max_metadata_nodes, 100000},
              {max_query_bytes, ?MAX_QUERY_CEILING},
              {max_results, ?MAX_RESULTS_CEILING},
              {max_result_bytes, ?MAX_CONTENT_CEILING},
              {max_entries, ?MAX_ENTRIES_CEILING},
              {max_total_bytes, ?MAX_TOTAL_BYTES_CEILING},
              {max_events_per_request, ?MAX_EVENTS_CEILING},
              {call_timeout, 60000}],
    case first_invalid_limit(Checks, Limits) of
        none ->
            case maps:get(max_result_bytes, Limits) >=
                 maps:get(max_content_bytes, Limits) of
                true -> {ok, Limits};
                false -> {error, {invalid_memory_config,
                                  max_result_bytes_below_content_limit}}
            end;
        Error -> {error, {invalid_memory_config, Error}}
    end.

first_invalid_limit([], _Limits) -> none;
first_invalid_limit([{Key, Ceiling} | Rest], Limits) ->
    Value = maps:get(Key, Limits),
    case is_integer(Value) andalso Value > 0 andalso Value =< Ceiling of
        true -> first_invalid_limit(Rest, Limits);
        false -> {Key, Value, {allowed_range, 1, Ceiling}}
    end.

capabilities(Adapter, Limits) ->
    #{contract_version => ?VERSION,
      adapter => Adapter,
      scope => app_user,
      durable => Adapter =:= mnesia,
      search => lexical_overlap,
      idempotent_ingestion => true,
      incremental_events => true,
      delete => [entry, session, user],
      limits => Limits}.

validate_scope({user, App, User}) ->
    case {bounded_text(App, 256, false), bounded_text(User, 256, false)} of
        {ok, ok} -> {ok, {user, App, User}};
        {{error, Reason}, _} -> {error, {invalid_memory_scope, app_name, Reason}};
        {_, {error, Reason}} -> {error, {invalid_memory_scope, user_id, Reason}}
    end;
validate_scope(Other) ->
    {error, {invalid_memory_scope, {expected_user_scope, term_type(Other)}}}.

prepare_entry(Scope0, Input, Opts, Limits) when is_map(Input), is_map(Opts) ->
    case validate_scope(Scope0) of
        {ok, Scope} -> prepare_entry_scope(Scope, Input, Opts, Limits);
        {error, _} = Error -> Error
    end;
prepare_entry(_Scope, Input, _Opts, _Limits) when not is_map(Input) ->
    {error, {invalid_memory_entry, expected_map}};
prepare_entry(_Scope, _Input, _Opts, _Limits) ->
    {error, {invalid_memory_options, expected_map}}.

prepare_entry_scope(Scope, Input, Opts, Limits) ->
    UnknownInput = maps:keys(maps:without(
                              [content, metadata, provenance], Input)),
    UnknownOpts = maps:keys(maps:without([idempotency_key], Opts)),
    case {UnknownInput, UnknownOpts} of
        {[], []} ->
            Content = maps:get(content, Input, undefined),
            Metadata0 = maps:get(metadata, Input, #{}),
            Provenance0 = maps:get(provenance, Input, #{}),
            Idempotency = maps:get(idempotency_key, Opts, undefined),
            case validate_entry_fields(Content, Metadata0, Provenance0,
                                       Idempotency, Limits) of
                {ok, Metadata, Provenance} ->
                    Digest = hex(crypto:hash(sha256, Content)),
                    Id = case Idempotency of
                        undefined -> random_id();
                        _ -> id_for(Scope, Idempotency)
                    end,
                    Timestamp = maps:get(timestamp, Provenance,
                                         erlang:system_time(millisecond)),
                    Entry0 = #{schema_version => ?ENTRY_SCHEMA,
                               id => Id, scope => Scope, content => Content,
                               metadata => Metadata,
                               provenance => Provenance,
                               digest => Digest, timestamp => Timestamp},
                    Entry = case Idempotency of
                        undefined -> Entry0;
                        _ -> Entry0#{idempotency_key => Idempotency}
                    end,
                    {ok, Entry#{storage_bytes => entry_storage_bytes(Entry)}};
                {error, _} = Error -> Error
            end;
        {[_ | _], _} ->
            {error, {invalid_memory_entry,
                     {unknown_keys, lists:sort(UnknownInput)}}};
        {_, [_ | _]} ->
            {error, {invalid_memory_options,
                     {unknown_keys, lists:sort(UnknownOpts)}}}
    end.

validate_entry_fields(Content, Metadata0, Provenance0, Idempotency, Limits) ->
    MaxContent = maps:get(max_content_bytes, Limits),
    case bounded_text(Content, MaxContent, false) of
        ok ->
            case sensitive_text(Content) of
                true -> {error, sensitive_memory_content};
                false -> validate_metadata_and_provenance(
                           Metadata0, Provenance0, Idempotency, Limits)
            end;
        {error, Reason} -> {error, {invalid_memory_content, Reason}}
    end.

validate_metadata_and_provenance(Metadata0, Provenance0, Idempotency, Limits) ->
    case normalize_metadata(Metadata0, Limits) of
        {ok, Metadata} ->
            case normalize_provenance(Provenance0) of
                {ok, Provenance} ->
                    case Idempotency of
                        undefined -> {ok, Metadata, Provenance};
                        Key -> case bounded_text(Key, 512, false) of
                            ok -> {ok, Metadata, Provenance};
                            {error, Reason} ->
                                {error, {invalid_idempotency_key, Reason}}
                        end
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

normalize_metadata(Metadata, Limits) when is_map(Metadata) ->
    Redacted = adk_secret_redactor:redact(Metadata),
    case adk_json:normalize(Redacted) of
        {ok, Normalized} when is_map(Normalized) ->
            case json_stats(Normalized, 0,
                            maps:get(max_metadata_depth, Limits),
                            maps:get(max_metadata_nodes, Limits)) of
                {ok, _Nodes} ->
                    Bytes = byte_size(jsx:encode(Normalized)),
                    Max = maps:get(max_metadata_bytes, Limits),
                    case Bytes =< Max of
                        true -> {ok, Normalized};
                        false -> {error, {metadata_size_limit_exceeded,
                                          Bytes, Max}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, {invalid_memory_metadata, Reason}};
        _ -> {error, {invalid_memory_metadata, expected_map}}
    end;
normalize_metadata(_, _) -> {error, {invalid_memory_metadata, expected_map}}.

normalize_provenance(Provenance) when is_map(Provenance) ->
    Allowed = [session_id, event_ids, author, timestamp],
    case lists:sort(maps:keys(maps:without(Allowed, Provenance))) of
        [] -> normalize_provenance_fields(Provenance);
        Unknown -> {error, {invalid_memory_provenance,
                            {unknown_keys, Unknown}}}
    end;
normalize_provenance(_) ->
    {error, {invalid_memory_provenance, expected_map}}.

normalize_provenance_fields(Provenance) ->
    Checks = [{session_id, 256}, {author, 256}],
    case validate_optional_texts(Checks, Provenance) of
        ok ->
            EventIds = maps:get(event_ids, Provenance, []),
            Timestamp = maps:get(timestamp, Provenance, undefined),
            ValidTimestamp = Timestamp =:= undefined orelse
                             (is_integer(Timestamp) andalso Timestamp >= 0),
            case {bounded_text_list(EventIds, 256, 1000), ValidTimestamp} of
                {ok, true} -> {ok, Provenance#{event_ids => EventIds}};
                {{error, Reason}, _} ->
                    {error, {invalid_memory_provenance, event_ids, Reason}};
                {_, false} ->
                    {error, {invalid_memory_provenance, timestamp}}
            end;
        {error, _} = Error -> Error
    end.

validate_optional_texts([], _Map) -> ok;
validate_optional_texts([{Key, Max} | Rest], Map) ->
    case maps:find(Key, Map) of
        error -> validate_optional_texts(Rest, Map);
        {ok, Value} -> case bounded_text(Value, Max, false) of
            ok -> validate_optional_texts(Rest, Map);
            {error, Reason} ->
                {error, {invalid_memory_provenance, Key, Reason}}
        end
    end.

prepare_search(Scope0, Query, Opts, Limits) when is_map(Opts) ->
    case validate_scope(Scope0) of
        {ok, Scope} ->
            Unknown = maps:keys(maps:without([filter, limit], Opts)),
            Filter0 = maps:get(filter, Opts, #{}),
            Limit = maps:get(limit, Opts, maps:get(max_results, Limits)),
            case Unknown of
                [] -> validate_search_fields(Scope, Query, Filter0, Limit, Limits);
                _ -> {error, {invalid_memory_options,
                              {unknown_keys, lists:sort(Unknown)}}}
            end;
        {error, _} = Error -> Error
    end;
prepare_search(_Scope, _Query, _Opts, _Limits) ->
    {error, {invalid_memory_options, expected_map}}.

validate_search_fields(Scope, Query, Filter0, Limit, Limits) ->
    case bounded_text(Query, maps:get(max_query_bytes, Limits), false) of
        ok ->
            case is_integer(Limit) andalso Limit > 0 andalso
                 Limit =< maps:get(max_results, Limits) of
                true ->
                    case normalize_metadata(Filter0, Limits) of
                        {ok, Filter} ->
                            Tokens = search_tokens(Query),
                            case Tokens of
                                [] -> {error, empty_memory_query};
                                _ -> {ok, Scope, Tokens, Filter, Limit}
                            end;
                        {error, _} = Error -> Error
                    end;
                false -> {error, {invalid_memory_limit, Limit}}
            end;
        {error, Reason} -> {error, {invalid_memory_query, Reason}}
    end.

hit(Entry, QueryTokens) ->
    Score = lexical_score(QueryTokens,
                          search_tokens(maps:get(content, Entry))),
    (maps:without([storage_bytes, idempotency_key], Entry))#{
      score => Score, score_type => lexical_overlap}.

metadata_matches(_Metadata, Filter) when map_size(Filter) =:= 0 -> true;
metadata_matches(Metadata, Filter) ->
    maps:fold(fun(Key, Value, Match) ->
                      Match andalso maps:get(Key, Metadata, '$missing') =:= Value
              end, true, Filter).

prepare_events(Scope, SessionId, Events, Opts, Limits) ->
    MaxEvents = maps:get(max_events_per_request, Limits),
    case {validate_scope(Scope), bounded_text(SessionId, 256, false),
          bounded_list(Events, MaxEvents), is_map(Opts)} of
        {{ok, CanonScope}, ok, {ok, _}, true} ->
            case maps:keys(Opts) of
                [] -> prepare_events_list(CanonScope, SessionId, Events,
                                          Limits, [], 0);
                Unknown -> {error, {invalid_memory_options,
                                    {unknown_keys, lists:sort(Unknown)}}}
            end;
        {{error, _} = Error, _, _, _} -> Error;
        {_, {error, Reason}, _, _} ->
            {error, {invalid_memory_session_id, Reason}};
        {_, _, {error, Reason}, _} -> {error, Reason};
        _ -> {error, {invalid_memory_options, expected_map}}
    end.

prepare_events_list(_Scope, _SessionId, [], _Limits, Acc, Skipped) ->
    {ok, lists:reverse(Acc), Skipped};
prepare_events_list(Scope, SessionId, [Event | Rest], Limits, Acc, Skipped) ->
    case event_input(Event, SessionId) of
        skip -> prepare_events_list(Scope, SessionId, Rest, Limits,
                                    Acc, Skipped + 1);
        {ok, Input, Idem} ->
            case prepare_entry(Scope, Input, #{idempotency_key => Idem}, Limits) of
                {ok, Entry} -> prepare_events_list(Scope, SessionId, Rest,
                                                   Limits, [Entry | Acc], Skipped);
                {error, sensitive_memory_content} ->
                    prepare_events_list(Scope, SessionId, Rest, Limits,
                                        Acc, Skipped + 1);
                {error, _} = Error -> Error
            end
    end.

event_input(Event, SessionId) when is_record(Event, adk_event) ->
    case adk_event:encode(Event) of
        {ok, Map} -> event_input_map(Map, SessionId);
        {error, _} -> skip
    end;
event_input(Map, SessionId) when is_map(Map) ->
    case adk_event:decode(Map) of
        {ok, Event} -> event_input(Event, SessionId);
        {error, _} -> skip
    end;
event_input(_, _) -> skip.

event_input_map(#{<<"id">> := EventId, <<"author">> := Author,
                  <<"timestamp">> := Timestamp, <<"partial">> := false,
                  <<"content">> := Content}, SessionId) ->
    case lists:member(Author, [<<"runner">>, <<"tool">>, <<"system">>]) of
        true -> skip;
        false -> case event_text(Content) of
            <<>> -> skip;
            Text ->
                Input = #{content => Text, metadata => #{},
                          provenance => #{session_id => SessionId,
                                          event_ids => [EventId],
                                          author => Author,
                                          timestamp => Timestamp}},
                {ok, Input, <<"event:", EventId/binary>>}
        end
    end;
event_input_map(_, _) -> skip.

event_text(#{<<"type">> := <<"text">>, <<"text">> := Text}) -> Text;
event_text(#{<<"type">> := <<"model_content">>, <<"value">> := Value}) ->
    Texts = [maps:get(<<"text">>, Part) || Part <- adk_content:parts(Value),
             maps:get(<<"type">>, Part, undefined) =:= <<"text">>],
    iolist_to_binary(lists:join(<<"\n">>, Texts));
event_text(_) -> <<>>.

prepare_legacy_session(SessionId, Events, Limits) ->
    Scope = legacy_scope(),
    case prepare_events(Scope, SessionId, Events, #{}, Limits) of
        {ok, Entries, _Skipped} ->
            Content = iolist_to_binary(lists:join(
                         <<"\n">>, [maps:get(content, E) || E <- Entries])),
            case Content of
                <<>> -> {ok, none};
                _ -> prepare_entry(
                       Scope,
                       #{content => Content,
                         metadata => #{<<"session_id">> => SessionId},
                         provenance => #{session_id => SessionId,
                                         event_ids => lists:append(
                                           [maps:get(event_ids,
                                             maps:get(provenance, E), [])
                                            || E <- Entries])}},
                       #{idempotency_key => <<"legacy-session:",
                                             SessionId/binary>>}, Limits)
            end;
        {error, _} = Error -> Error
    end.

entry_storage_bytes(Entry) ->
    byte_size(maps:get(content, Entry)) +
    byte_size(jsx:encode(maps:get(metadata, Entry))) +
    byte_size(jsx:encode(json_safe_provenance(maps:get(provenance, Entry)))) +
    256.

json_safe_provenance(Provenance) ->
    maps:from_list([{atom_to_binary(K, utf8), V}
                    || {K, V} <- maps:to_list(Provenance)]).

id_for({user, App, User}, Idempotency) ->
    Digest = crypto:hash(sha256,
                         <<App/binary, 0, User/binary, 0,
                           Idempotency/binary>>),
    <<Prefix:16/binary, _/binary>> = Digest,
    <<"mem-", (hex(Prefix))/binary>>.

random_id() ->
    <<"mem-", (hex(crypto:strong_rand_bytes(16)))/binary>>.

legacy_scope() -> {user, <<"legacy">>, <<"legacy">>}.

search_tokens(Text) ->
    Lower = string:lowercase(Text),
    lists:usort(re:split(Lower, <<"[^\\p{L}\\p{N}_]+">>,
                          [unicode, {return, binary}, trim])).

lexical_score([], _) -> 0.0;
lexical_score(QueryTokens, ContentTokens) ->
    Matches = length([Token || Token <- QueryTokens,
                               lists:member(Token, ContentTokens)]),
    Matches / length(QueryTokens).

bounded_text(Value, Max, AllowEmpty) when is_binary(Value) ->
    Size = byte_size(Value),
    case valid_utf8(Value) andalso binary:match(Value, <<0>>) =:= nomatch andalso
         (AllowEmpty orelse Size > 0) andalso Size =< Max of
        true -> ok;
        false when Size > Max -> {error, {size_limit_exceeded, Size, Max}};
        false when Size =:= 0 -> {error, empty};
        false -> {error, invalid_utf8_or_nul}
    end;
bounded_text(_, _, _) -> {error, expected_binary}.

bounded_text_list(List, MaxText, MaxItems) ->
    case bounded_list(List, MaxItems) of
        {ok, _} -> bounded_text_list_values(List, MaxText);
        {error, _} = Error -> Error
    end.

bounded_text_list_values([], _) -> ok;
bounded_text_list_values([Value | Rest], Max) ->
    case bounded_text(Value, Max, false) of
        ok -> bounded_text_list_values(Rest, Max);
        {error, _} = Error -> Error
    end.

bounded_list(List, Max) -> bounded_list(List, Max, 0).
bounded_list([], _Max, Count) -> {ok, Count};
bounded_list([_ | _], Max, Count) when Count >= Max ->
    {error, {memory_count_limit_exceeded, Max}};
bounded_list([_ | Rest], Max, Count) -> bounded_list(Rest, Max, Count + 1);
bounded_list(_, _Max, _Count) -> {error, invalid_list}.

json_stats(_Value, Depth, MaxDepth, _MaxNodes) when Depth > MaxDepth ->
    {error, {metadata_depth_limit_exceeded, MaxDepth}};
json_stats(Value, Depth, MaxDepth, MaxNodes) when is_map(Value) ->
    json_stats_values(maps:values(Value), Depth + 1, MaxDepth, MaxNodes, 1);
json_stats(Value, Depth, MaxDepth, MaxNodes) when is_list(Value) ->
    json_stats_values(Value, Depth + 1, MaxDepth, MaxNodes, 1);
json_stats(_Value, _Depth, _MaxDepth, _MaxNodes) -> {ok, 1}.

json_stats_values([], _Depth, _MaxDepth, MaxNodes, Count)
  when Count =< MaxNodes -> {ok, Count};
json_stats_values([], _Depth, _MaxDepth, MaxNodes, _Count) ->
    {error, {metadata_node_limit_exceeded, MaxNodes}};
json_stats_values([Value | Rest], Depth, MaxDepth, MaxNodes, Count) ->
    case json_stats(Value, Depth, MaxDepth, MaxNodes - Count) of
        {ok, ChildCount} when Count + ChildCount =< MaxNodes ->
            json_stats_values(Rest, Depth, MaxDepth, MaxNodes,
                              Count + ChildCount);
        {ok, _} -> {error, {metadata_node_limit_exceeded, MaxNodes}};
        {error, _} = Error -> Error
    end.

sensitive_text(Text) ->
    Patterns = [<<"(?i)(api[_ -]?key|password|passwd|access[_ -]?token|refresh[_ -]?token|authorization|bearer)\\s*[:=]\\s*\\S+">>,
                <<"AIza[0-9A-Za-z_-]{20,}">>,
                <<"sk-[0-9A-Za-z_-]{16,}">>],
    lists:any(fun(Pattern) -> re:run(Text, Pattern, [unicode]) =/= nomatch end,
              Patterns).

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
       || <<Byte>> <= Binary >>.
hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

term_type(V) when is_map(V) -> map;
term_type(V) when is_tuple(V) -> tuple;
term_type(V) when is_binary(V) -> binary;
term_type(V) when is_list(V) -> list;
term_type(V) when is_pid(V) -> pid;
term_type(_) -> other.
