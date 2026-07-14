%% @doc Versioned model-context selection, budgeting, and compression policy.
%%
%% Inputs are converted to canonical ADK event maps and stripped of
%% credential-bearing keys before filtering, measuring, compression, or cache
%% hashing. Compression is opt-in and runs in a monitored process with timeout,
%% heap, event-count, and serialized-output bounds.
-module(adk_context_policy).

-export([version/0, capabilities/0, build/2]).

-define(VERSION, 1).
-define(DEFAULT_BYTES_PER_TOKEN, 4).
-define(DEFAULT_COMPRESSOR_TIMEOUT, 5000).
-define(DEFAULT_COMPRESSOR_MAX_HEAP_WORDS, 2000000).
-define(DEFAULT_MAX_COMPRESSED_EVENTS, 1024).
-define(DEFAULT_MAX_COMPRESSOR_OUTPUT_BYTES, 4194304).

-spec version() -> pos_integer().
version() -> ?VERSION.

-spec capabilities() -> map().
capabilities() ->
    #{version => ?VERSION,
      event_codec_version => adk_event:codec_version(),
      filters => [authors, invocation_ids, content_types, timestamp_range,
                  partial, final],
      budgets => #{bytes => summed_canonical_event_json_bytes,
                   tokens => estimated_by_bytes},
      overflow => [error, truncate, compress],
      compression => #{isolated => true,
                       timeout_bounded => true,
                       heap_bounded => true,
                       output_bounded => true},
      secrets => removed_before_measurement,
      cache => #{algorithm => sha256,
                 encoding => deterministic_erlang_external_term}}.

%% @doc Build a secret-free context from a session map or event list.
%%
%% Important options:
%%   * `max_bytes' / `max_tokens' - positive integers or `infinity'
%%   * `overflow' - `error' (default), `truncate', or `compress'
%%   * `compressor' - Module or `{Module, CompressorOptions}'
%%   * include/exclude options accepted by `adk_event_filter'
-spec build(map() | [adk_event:event() | map()], map()) ->
    {ok, map()} | {error, term()}.
build(Input, Opts) when is_map(Opts) ->
    case input_events(Input) of
        {ok, RawEvents} ->
            case sanitize_events(RawEvents, []) of
                {ok, SafeEvents} ->
                    case adk_event_filter:normalize(Opts) of
                        {ok, Filter} ->
                            case normalize_policy(Opts, Filter) of
                                {ok, Policy} ->
                                    Filtered = adk_event_filter:apply(
                                                 SafeEvents, Filter),
                                    apply_budget(Filtered, Policy);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
build(_Input, _Opts) ->
    {error, {invalid_context_options, expected_map}}.

input_events(Events) when is_list(Events) ->
    {ok, Events};
input_events(Session) when is_map(Session) ->
    case maps:find(events, Session) of
        {ok, Events} when is_list(Events) -> {ok, Events};
        {ok, _} -> {error, {invalid_context, events_not_list}};
        error ->
            case maps:find(<<"events">>, Session) of
                {ok, Events} when is_list(Events) -> {ok, Events};
                {ok, _} -> {error, {invalid_context, events_not_list}};
                error -> {error, {invalid_context, missing_events}}
            end
    end;
input_events(_) ->
    {error, {invalid_context, expected_session_or_events}}.

sanitize_events([], Acc) ->
    {ok, lists:reverse(Acc)};
sanitize_events([Event | Rest], Acc) ->
    case adk_context_guard:sanitize_event(Event) of
        {ok, SafeEvent} -> sanitize_events(Rest, [SafeEvent | Acc]);
        {error, Reason} -> {error, {invalid_context_event, Reason}}
    end;
sanitize_events(_Improper, _Acc) ->
    {error, {invalid_context, improper_event_list}}.

normalize_policy(Opts, Filter) ->
    case limit(max_bytes, Opts, infinity) of
        {ok, MaxBytes} ->
            case limit(max_tokens, Opts, infinity) of
                {ok, MaxTokens} ->
                    case positive(bytes_per_token, Opts,
                                  ?DEFAULT_BYTES_PER_TOKEN) of
                        {ok, BytesPerToken} ->
                            normalize_runtime_policy(
                              Opts, Filter, MaxBytes, MaxTokens,
                              BytesPerToken);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

normalize_runtime_policy(Opts, Filter, MaxBytes, MaxTokens,
                         BytesPerToken) ->
    Overflow = maps:get(overflow, Opts, error),
    case lists:member(Overflow, [error, truncate, compress]) of
        false -> {error, {invalid_context_options, overflow}};
        true ->
            case positive(compressor_timeout, Opts,
                          ?DEFAULT_COMPRESSOR_TIMEOUT) of
                {ok, Timeout} ->
                    case positive(compressor_max_heap_words, Opts,
                                  ?DEFAULT_COMPRESSOR_MAX_HEAP_WORDS) of
                        {ok, MaxHeap} ->
                            case positive(max_compressed_events, Opts,
                                          ?DEFAULT_MAX_COMPRESSED_EVENTS) of
                                {ok, MaxEvents} ->
                                    case positive(
                                           max_compressor_output_bytes, Opts,
                                           ?DEFAULT_MAX_COMPRESSOR_OUTPUT_BYTES) of
                                        {ok, MaxOutputBytes} ->
                                            validate_compressor_policy(
                                              Opts, #{
                                                max_bytes => MaxBytes,
                                                max_tokens => MaxTokens,
                                                bytes_per_token => BytesPerToken,
                                                overflow => Overflow,
                                                filter => Filter,
                                                compressor_timeout => Timeout,
                                                compressor_max_heap_words => MaxHeap,
                                                max_compressed_events => MaxEvents,
                                                max_compressor_output_bytes =>
                                                    MaxOutputBytes
                                              });
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

validate_compressor_policy(Opts, Policy) ->
    Compressor = maps:get(compressor, Opts, undefined),
    case {maps:get(overflow, Policy), normalize_compressor(Compressor)} of
        {compress, {ok, undefined}} ->
            {error, {invalid_context_options, compressor_required}};
        {_Overflow, {ok, Normalized}} ->
            CacheIdentity = maps:get(compressor_cache_identity, Opts, default),
            case safe_cache_identity(CacheIdentity) of
                {ok, SafeIdentity} ->
                    {ok, Policy#{compressor => Normalized,
                                 compressor_cache_identity => SafeIdentity}};
                {error, _} = Error -> Error
            end;
        {_Overflow, {error, _} = Error} -> Error
    end.

normalize_compressor(undefined) -> {ok, undefined};
normalize_compressor(Module) when is_atom(Module) ->
    {ok, {Module, #{}}};
normalize_compressor({Module, CompressorOpts})
  when is_atom(Module), is_map(CompressorOpts) ->
    {ok, {Module, CompressorOpts}};
normalize_compressor(_) ->
    {error, {invalid_context_options, compressor}}.

safe_cache_identity(default) -> {ok, default};
safe_cache_identity(Identity) ->
    case adk_context_guard:sanitize_value(Identity) of
        {ok, Safe} -> {ok, Safe};
        {error, _} ->
            {error, {invalid_context_options, compressor_cache_identity}}
    end.

limit(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        infinity -> {ok, infinity};
        Value when is_integer(Value), Value > 0 -> {ok, Value};
        _ -> {error, {invalid_context_options, Key}}
    end.

positive(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value > 0 -> {ok, Value};
        _ -> {error, {invalid_context_options, Key}}
    end.

apply_budget(Events, Policy) ->
    {Bytes, Tokens} = measure(Events, Policy),
    case within_budget(Bytes, Tokens, Policy) of
        true -> build_result(Events, Events, false, Bytes, Tokens, Policy);
        false -> handle_overflow(Events, Bytes, Tokens, Policy)
    end.

handle_overflow(_Events, Bytes, Tokens, #{overflow := error} = Policy) ->
    {error, budget_error(Bytes, Tokens, Policy)};
handle_overflow(Events, _Bytes, _Tokens,
                #{overflow := truncate} = Policy) ->
    Truncated = newest_suffix(Events, Policy),
    {Bytes, Tokens} = measure(Truncated, Policy),
    build_result(Events, Truncated, false, Bytes, Tokens, Policy);
handle_overflow(Events, _Bytes, _Tokens,
                #{overflow := compress} = Policy) ->
    case run_compressor(Events, Policy) of
        {ok, Compressed} ->
            {Bytes, Tokens} = measure(Compressed, Policy),
            case within_budget(Bytes, Tokens, Policy) of
                true ->
                    build_result(Events, Compressed, true,
                                 Bytes, Tokens, Policy);
                false ->
                    {error, {compressed_context_exceeds_budget,
                             budget_error(Bytes, Tokens, Policy)}}
            end;
        {error, _} = Error -> Error
    end.

newest_suffix(Events, Policy) ->
    newest_suffix(lists:reverse(Events), [], Policy).

newest_suffix([], Acc, _Policy) -> Acc;
newest_suffix([Event | Rest], Acc, Policy) ->
    Candidate = [Event | Acc],
    {Bytes, Tokens} = measure(Candidate, Policy),
    case within_budget(Bytes, Tokens, Policy) of
        true -> newest_suffix(Rest, Candidate, Policy);
        false -> Acc
    end.

run_compressor(Events, Policy) ->
    {Module, CompressorOpts} = maps:get(compressor, Policy),
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, compress, 2) of
                true -> spawn_compressor(Module, CompressorOpts,
                                         Events, Policy);
                false -> {error, {invalid_compressor, missing_callback}}
            end;
        _ -> {error, {invalid_compressor, unavailable}}
    end.

spawn_compressor(Module, CompressorOpts, Events, Policy) ->
    Parent = self(),
    ReplyRef = make_ref(),
    Request = #{version => ?VERSION,
                max_bytes => maps:get(max_bytes, Policy),
                max_tokens => maps:get(max_tokens, Policy),
                bytes_per_token => maps:get(bytes_per_token, Policy),
                options => CompressorOpts},
    Worker = fun() ->
        Outcome = try Module:compress(Events, Request) of
            Result -> Result
        catch
            Class:_Reason -> {adk_compressor_crashed, Class}
        end,
        Parent ! {ReplyRef, Outcome}
    end,
    SpawnOpts = [monitor,
                 {max_heap_size,
                  #{size => maps:get(compressor_max_heap_words, Policy),
                    kill => true,
                    error_logger => false}}],
    {Pid, MonitorRef} = spawn_opt(Worker, SpawnOpts),
    receive_compressor(Pid, MonitorRef, ReplyRef, Policy).

receive_compressor(Pid, MonitorRef, ReplyRef, Policy) ->
    Timeout = maps:get(compressor_timeout, Policy),
    receive
        {ReplyRef, {adk_compressor_crashed, Class}} ->
            erlang:demonitor(MonitorRef, [flush]),
            {error, {compressor_crashed, Class}};
        {ReplyRef, Result} ->
            erlang:demonitor(MonitorRef, [flush]),
            validate_compressor_result(Result, Policy);
        {'DOWN', MonitorRef, process, Pid, _Reason} ->
            {error, {compressor_crashed, exit}}
    after Timeout ->
        exit(Pid, kill),
        receive
            {'DOWN', MonitorRef, process, Pid, _} -> ok
        after 1000 ->
            erlang:demonitor(MonitorRef, [flush])
        end,
        flush_reply(ReplyRef),
        {error, compressor_timeout}
    end.

flush_reply(ReplyRef) ->
    receive {ReplyRef, _} -> ok after 0 -> ok end.

validate_compressor_result({ok, Events}, Policy) when is_list(Events) ->
    case length_bounded(Events, maps:get(max_compressed_events, Policy)) of
        false -> {error, compressor_output_too_many_events};
        true ->
            case sanitize_events(Events, []) of
                {ok, SafeEvents} ->
                    {Bytes, _Tokens} = measure(SafeEvents, Policy),
                    case Bytes =< maps:get(max_compressor_output_bytes, Policy) of
                        true -> {ok, SafeEvents};
                        false -> {error, compressor_output_too_large}
                    end;
                {error, _} -> {error, invalid_compressor_output}
            end
    end;
validate_compressor_result({ok, _}, _Policy) ->
    {error, invalid_compressor_output};
validate_compressor_result({error, Reason}, _Policy) ->
    {error, {compressor_error, reason_tag(Reason)}};
validate_compressor_result(_, _Policy) ->
    {error, invalid_compressor_output}.

length_bounded(List, Max) ->
    length_bounded(List, Max, 0).

length_bounded([], _Max, _Count) -> true;
length_bounded(_Rest, Max, Count) when Count >= Max -> false;
length_bounded([_ | Rest], Max, Count) ->
    length_bounded(Rest, Max, Count + 1);
length_bounded(_Improper, _Max, _Count) -> false.

reason_tag(Reason) when is_atom(Reason) -> Reason;
reason_tag(Reason) when is_tuple(Reason), tuple_size(Reason) > 0,
                              is_atom(element(1, Reason)) ->
    element(1, Reason);
reason_tag(_) -> unspecified.

measure(Events, Policy) ->
    Bytes = lists:sum([byte_size(jsx:encode(Event)) || Event <- Events]),
    BytesPerToken = maps:get(bytes_per_token, Policy),
    Tokens = case Bytes of
        0 -> 0;
        _ -> (Bytes + BytesPerToken - 1) div BytesPerToken
    end,
    {Bytes, Tokens}.

within_budget(Bytes, Tokens, Policy) ->
    within(Bytes, maps:get(max_bytes, Policy)) andalso
    within(Tokens, maps:get(max_tokens, Policy)).

within(_Value, infinity) -> true;
within(Value, Maximum) -> Value =< Maximum.

budget_error(Bytes, Tokens, Policy) ->
    {context_budget_exceeded,
     #{bytes => Bytes,
       estimated_tokens => Tokens,
       max_bytes => maps:get(max_bytes, Policy),
       max_tokens => maps:get(max_tokens, Policy)}}.

build_result(Original, Final, Compressed, Bytes, Tokens, Policy) ->
    PolicyMetadata = policy_metadata(Policy),
    CacheKey = hex(crypto:hash(
                     sha256,
                     term_to_binary(
                       {?VERSION, Final, PolicyMetadata}, [deterministic]))),
    {ok, #{version => ?VERSION,
           events => Final,
           bytes => Bytes,
           estimated_tokens => Tokens,
           input_events => length(Original),
           output_events => length(Final),
           dropped_events => erlang:max(0, length(Original) - length(Final)),
           compressed => Compressed,
           policy => PolicyMetadata,
           cache => #{key => CacheKey,
                      algorithm => <<"sha256">>,
                      encoding =>
                          <<"deterministic-erlang-external-term">>,
                      context_version => ?VERSION,
                      event_codec_version => adk_event:codec_version()}}}.

policy_metadata(Policy) ->
    CompressorIdentity = compressor_identity(Policy),
    #{max_bytes => maps:get(max_bytes, Policy),
      max_tokens => maps:get(max_tokens, Policy),
      bytes_per_token => maps:get(bytes_per_token, Policy),
      overflow => maps:get(overflow, Policy),
      filter => maps:get(filter, Policy),
      compressor => CompressorIdentity}.

compressor_identity(#{compressor := undefined}) -> <<"none">>;
compressor_identity(#{compressor := {Module, _},
                      compressor_cache_identity := Explicit}) ->
    _ = code:ensure_loaded(Module),
    CodeIdentity = try
        hex(Module:module_info(md5))
    catch
        _:_ -> <<"unavailable">>
    end,
    #{module => atom_to_binary(Module, utf8),
      code_identity => CodeIdentity,
      configuration => Explicit}.

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>>
       || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
