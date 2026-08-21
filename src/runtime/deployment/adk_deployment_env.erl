%% @doc Strict deployment-owned environment bridge for the OTLP bus exporter.
%%
%% The bridge is intentionally narrow: endpoint and header values are accepted
%% only from the orchestrator environment, validated before application state
%% changes, and never included in an error. Agent JSON cannot reach this path.
-module(adk_deployment_env).

-export([configure/0]).

-define(EXPORTER_ID, <<"erlang-adk-deployment-otlp">>).
-define(MAX_ENDPOINT_BYTES, 2048).
-define(MAX_HEADER_ENV_BYTES, 32768).
-define(MAX_HEADERS, 32).
-define(OTLP_HTTP_TIMEOUT_MS, 3000).
-define(EXPORTER_TIMEOUT_MS, 4000).
-define(DEFAULT_BUS_BATCH_TIMEOUT_MS, 5000).
-define(DEFAULT_OTHER_EXPORTER_TIMEOUT_MS, 1000).
-define(BUS_TIMEOUT_GUARD_MS, 250).
-define(MAX_BUS_BATCH_TIMEOUT_MS, 300000).

-spec configure() -> ok | {error, term()}.
configure() ->
    case endpoint() of
        disabled -> ok;
        {ok, Endpoint} -> configure_otlp(Endpoint);
        error -> invalid(endpoint)
    end.

endpoint() ->
    case os:getenv("ERLANG_ADK_OTLP_ENDPOINT") of
        false -> disabled;
        "" -> error;
        Value -> bounded_utf8(Value, ?MAX_ENDPOINT_BYTES)
    end.

configure_otlp(Endpoint) ->
    case headers() of
        {ok, Headers} -> install_exporter(Endpoint, Headers);
        error -> invalid(headers)
    end.

headers() ->
    case os:getenv("OTEL_EXPORTER_OTLP_HEADERS") of
        false -> {ok, #{}};
        "" -> {ok, #{}};
        Value ->
            case bounded_utf8(Value, ?MAX_HEADER_ENV_BYTES) of
                {ok, Binary} -> parse_headers(Binary);
                error -> error
            end
    end.

parse_headers(Binary) ->
    Parts = binary:split(Binary, <<",">>, [global]),
    case length(Parts) =< ?MAX_HEADERS of
        true -> parse_header_parts(Parts, #{});
        false -> error
    end.

parse_header_parts([], Headers) -> {ok, Headers};
parse_header_parts([Part | Rest], Headers0) ->
    case {binary:match(Part, <<";">>),
          binary:split(trim_ows(Part), <<"=">>)} of
        {nomatch, [Name, EncodedValue]} ->
            case percent_decode(trim_ows(EncodedValue)) of
                {ok, Value} when byte_size(Name) > 0 ->
                    TrimmedName = trim_ows(Name),
                    LowerName = ascii_lower(TrimmedName),
                    case byte_size(TrimmedName) > 0 andalso
                         valid_utf8(Value) andalso
                         not maps:is_key(LowerName, Headers0) of
                        false ->
                            error;
                        true ->
                            parse_header_parts(
                              Rest, Headers0#{LowerName => Value})
                    end;
                error -> error
            end;
        _ -> error
    end.

install_exporter(Endpoint, Headers) ->
    Config = #{endpoint => Endpoint, headers => Headers,
               timeout_ms => ?OTLP_HTTP_TIMEOUT_MS},
    Descriptor = #{id => ?EXPORTER_ID,
                   module => adk_otlp_http_json_exporter,
                   config => Config,
                   timeout_ms => ?EXPORTER_TIMEOUT_MS,
                   max_heap_words => 200000,
                   failure_policy => open},
    BusEnabled = application:get_env(
                   erlang_adk, observability_bus_enabled, false),
    BusOptions = application:get_env(
                   erlang_adk, observability_bus_options, #{}),
    case {adk_otlp_http_json_exporter:validate_config(Config),
          is_boolean(BusEnabled), install_descriptor(BusOptions, Descriptor)} of
        {{ok, _}, true, {ok, EffectiveOptions}} ->
            ok = application:set_env(
                   erlang_adk, observability_bus_options, EffectiveOptions),
            application:set_env(erlang_adk, observability_bus_enabled, true);
        {{error, _}, _, _} -> invalid(exporter);
        {_, false, _} -> invalid(bus_enabled);
        {_, _, {error, Reason}} -> invalid(Reason)
    end.

install_descriptor(Options, Descriptor) when is_map(Options) ->
    case maps:get(exporters, Options, []) of
        Exporters when is_list(Exporters) ->
            Matches = [Existing || Existing <- Exporters,
                                   is_map(Existing),
                                   maps:get(id, Existing, undefined) =:=
                                       ?EXPORTER_ID],
            case Matches of
                [] -> checked_runtime_options(
                        Options#{exporters => Exporters ++ [Descriptor],
                                 batch_size => 1});
                [Descriptor] ->
                    checked_runtime_options(Options#{batch_size => 1});
                _ -> {error, exporter_id_conflict}
            end;
        _ -> {error, invalid_exporters}
    end;
install_descriptor(_, _) -> {error, invalid_bus_options}.

checked_runtime_options(Options) ->
    case adk_trace_runtime:configure_bus_options(Options) of
        {ok, EffectiveOptions} -> checked_options(EffectiveOptions);
        {error, _} -> {error, invalid_trace_runtime_options}
    end.

checked_options(Options) ->
    Exporters = maps:get(exporters, Options),
    case adk_observability:validate_exporters(Exporters) of
        ok ->
            Required = lists:sum(
                         [maps:get(timeout_ms, Exporter,
                                   ?DEFAULT_OTHER_EXPORTER_TIMEOUT_MS)
                          || Exporter <- Exporters]) +
                       ?BUS_TIMEOUT_GUARD_MS,
            checked_batch_timeout(Options, Required);
        {error, _} -> {error, invalid_exporter_descriptor}
    end.

checked_batch_timeout(Options, Required)
  when Required < ?MAX_BUS_BATCH_TIMEOUT_MS ->
    case maps:find(batch_timeout_ms, Options) of
        error ->
            Timeout = erlang:max(?DEFAULT_BUS_BATCH_TIMEOUT_MS,
                                 Required + 1),
            {ok, Options#{batch_timeout_ms => Timeout}};
        {ok, Timeout} when is_integer(Timeout),
                           Timeout > Required,
                           Timeout =< ?MAX_BUS_BATCH_TIMEOUT_MS ->
            {ok, Options};
        {ok, _} -> {error, incompatible_bus_timeout}
    end;
checked_batch_timeout(_Options, _Required) ->
    {error, incompatible_bus_timeout}.

bounded_utf8(Value, Limit) when is_list(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Binary when is_binary(Binary), byte_size(Binary) > 0,
                    byte_size(Binary) =< Limit -> {ok, Binary};
        _ -> error
    catch _:_ -> error
    end.

ascii_lower(Binary) ->
    << <<(lower_char(Char))>> || <<Char>> <= Binary >>.

trim_ows(Binary) ->
    trim_ows_right(trim_ows_left(Binary)).

trim_ows_left(<<Char, Rest/binary>>) when Char =:= $\s; Char =:= $\t ->
    trim_ows_left(Rest);
trim_ows_left(Binary) -> Binary.

trim_ows_right(<<>>) -> <<>>;
trim_ows_right(Binary) ->
    case binary:last(Binary) of
        Char when Char =:= $\s; Char =:= $\t ->
            trim_ows_right(
              binary:part(Binary, 0, byte_size(Binary) - 1));
        _ -> Binary
    end.

percent_decode(Binary) ->
    percent_decode(Binary, []).

percent_decode(<<>>, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
percent_decode(<<$%, High, Low, Rest/binary>>, Acc) ->
    case {hex_value(High), hex_value(Low)} of
        {{ok, HighValue}, {ok, LowValue}} ->
            percent_decode(Rest, [(HighValue bsl 4) bor LowValue | Acc]);
        _ -> error
    end;
percent_decode(<<$%, _/binary>>, _Acc) -> error;
percent_decode(<<Byte, Rest/binary>>, Acc) ->
    percent_decode(Rest, [Byte | Acc]).

valid_utf8(Binary) ->
    case unicode:characters_to_binary(Binary, utf8, utf8) of
        Binary -> true;
        _ -> false
    end.

hex_value(Char) when Char >= $0, Char =< $9 -> {ok, Char - $0};
hex_value(Char) when Char >= $a, Char =< $f -> {ok, Char - $a + 10};
hex_value(Char) when Char >= $A, Char =< $F -> {ok, Char - $A + 10};
hex_value(_) -> error.

lower_char(Char) when Char >= $A, Char =< $Z -> Char + 32;
lower_char(Char) -> Char.

invalid(Reason) ->
    {error, {invalid_deployment_observability_config, Reason}}.
