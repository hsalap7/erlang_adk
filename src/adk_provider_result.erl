%% @doc Checked envelope for provider-specific result metadata.
%%
%% Providers must keep the legacy result terms when they have no metadata.
%% When metadata is present, `{provider_result, Envelope}' is the reserved LLM
%% result tag. The envelope is internal Erlang data; `provider_metadata/1'
%% returns the bounded JSON-safe projection suitable for `adk_event.actions'.
-module(adk_provider_result).

-export([new/4, decode/1, provider_metadata/1, max_metadata_bytes/0]).

-define(SCHEMA_VERSION, 1).
-define(MAX_METADATA_BYTES, 262144).

-type outcome() :: {ok, term()} | {tool_calls, list()} | streamed.
-type envelope() :: #{version := pos_integer(),
                      provider := binary(),
                      type := binary(),
                      outcome := outcome(),
                      metadata := map()}.
-type result() :: {provider_result, envelope()}.

-export_type([outcome/0, envelope/0, result/0]).

-spec max_metadata_bytes() -> pos_integer().
max_metadata_bytes() ->
    ?MAX_METADATA_BYTES.

-spec new(binary(), binary(), outcome(), map()) ->
    {ok, result()} | {error, term()}.
new(Provider, Type, Outcome, Metadata) ->
    Envelope = #{version => ?SCHEMA_VERSION,
                 provider => Provider,
                 type => Type,
                 outcome => Outcome,
                 metadata => Metadata},
    case validate_envelope(Envelope) of
        {ok, _Action} -> {ok, {provider_result, Envelope}};
        {error, _} = Error -> Error
    end.

%% @doc Decode and revalidate an untrusted provider-result tuple. This check is
%% intentionally repeated at the agent boundary because callbacks and custom
%% providers can manufacture result terms without using `new/4'.
-spec decode(term()) ->
    {ok, outcome(), map()} | {error, term()} | not_provider_result.
decode({provider_result, Envelope}) ->
    case validate_envelope(Envelope) of
        {ok, Action} ->
            {ok, maps:get(outcome, Envelope), Action};
        {error, Reason} ->
            {error, {invalid_provider_result, Reason}}
    end;
decode(_) ->
    not_provider_result.

-spec provider_metadata(result()) -> {ok, map()} | {error, term()}.
provider_metadata(Result) ->
    case decode(Result) of
        {ok, _Outcome, Action} -> {ok, Action};
        {error, _} = Error -> Error;
        not_provider_result -> {error, not_provider_result}
    end.

validate_envelope(Envelope) when is_map(Envelope) ->
    ExpectedKeys = [metadata, outcome, provider, type, version],
    case lists:sort(maps:keys(Envelope)) of
        ExpectedKeys ->
            validate_envelope_fields(Envelope);
        _ ->
            {error, invalid_envelope_keys}
    end;
validate_envelope(_) ->
    {error, envelope_must_be_map}.

validate_envelope_fields(#{version := ?SCHEMA_VERSION,
                           provider := Provider,
                           type := Type,
                           outcome := Outcome,
                           metadata := Metadata}) ->
    case {valid_discriminator(Provider), valid_discriminator(Type),
          valid_outcome(Outcome), validate_metadata(Metadata)} of
        {true, true, true, {ok, CanonicalMetadata}} ->
            {ok, #{<<"schema_version">> => ?SCHEMA_VERSION,
                   <<"provider">> => Provider,
                   <<"type">> => Type,
                   <<"metadata">> => CanonicalMetadata}};
        {false, _, _, _} -> {error, invalid_provider};
        {_, false, _, _} -> {error, invalid_type};
        {_, _, false, _} -> {error, invalid_outcome};
        {_, _, _, {error, _} = Error} -> Error
    end;
validate_envelope_fields(#{version := Version}) ->
    {error, {unsupported_schema_version, Version}}.

valid_discriminator(Value) when is_binary(Value) ->
    byte_size(Value) > 0 andalso byte_size(Value) =< 128 andalso
        valid_utf8(Value);
valid_discriminator(_) -> false.

valid_outcome({ok, _Output}) -> true;
valid_outcome({tool_calls, Calls}) -> is_list(Calls);
valid_outcome(streamed) -> true;
valid_outcome(_) -> false.

validate_metadata(Metadata) when is_map(Metadata) ->
    %% adk_json can normalize convenient Erlang terms. Provider metadata is a
    %% stricter boundary: normalization must be an identity operation, so atom
    %% keys, tuples, charlists, undefined, pids, and other non-JSON terms fail.
    case adk_json:normalize(Metadata) of
        {ok, Metadata} ->
            encoded_metadata_size(Metadata);
        {ok, _Coerced} ->
            {error, metadata_must_be_json};
        {error, Reason} ->
            {error, {invalid_metadata_json, Reason}}
    end;
validate_metadata(_) ->
    {error, metadata_must_be_map}.

encoded_metadata_size(Metadata) ->
    try jsx:encode(Metadata) of
        Encoded when byte_size(Encoded) =< ?MAX_METADATA_BYTES ->
            {ok, Metadata};
        Encoded ->
            {error, {metadata_too_large, byte_size(Encoded),
                     ?MAX_METADATA_BYTES}}
    catch
        error:Reason -> {error, {invalid_metadata_json, Reason}}
    end.

valid_utf8(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    end.
