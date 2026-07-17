%% @doc Read-only resolver for operator-configured model provider profiles.
%%
%% Profiles are loaded from the `erlang_adk' application environment under
%% `provider_profiles'. Only bounded binary IDs are accepted. In particular,
%% this module never converts user-provided binaries to module atoms.
-module(adk_provider_registry).

-export([profiles/0, lookup/1, resolve/1, resolve/2,
         resolve_config/1, resolve_live/2, resolve_live_config/2]).

-define(MAX_PROFILES, 128).
-define(MAX_PROFILES_BYTES, 4194304).

-spec profiles() -> {ok, map()} | {error, term()}.
profiles() ->
    normalize_profiles(application:get_env(
                         erlang_adk, provider_profiles, #{})).

-spec lookup(term()) -> {ok, map()} | {error, term()}.
lookup(ProfileId) when is_binary(ProfileId) ->
    case profiles() of
        {ok, Profiles} ->
            case maps:find(ProfileId, Profiles) of
                {ok, Profile} -> {ok, Profile};
                error -> {error, unknown_provider_profile}
            end;
        {error, _} = Error -> Error
    end;
lookup(_ProfileId) ->
    {error, invalid_provider_profile_id}.

-spec resolve(term()) -> {ok, map()} | {error, term()}.
resolve(ProfileId) ->
    lookup(ProfileId).

-spec resolve(term(), term()) -> {ok, map()} | {error, term()}.
resolve(ProfileId, ModelAlias) ->
    case lookup(ProfileId) of
        {ok, Profile} ->
            adk_provider_profile:request_config(Profile, ModelAlias);
        {error, _} = Error -> Error
    end.

%% @doc Resolve an operator-owned Live adapter, endpoint, concrete model and
%% transport. The public profile identifier and model alias remain binaries;
%% only modules which were already present in the trusted profile are called.
%% Fixed transports must agree with the profile endpoint and be selected by
%% the adapter itself through `transport/0'.
-spec resolve_live(term(), term()) -> {ok, map()} | {error, term()}.
resolve_live(ProfileId, ModelAlias) ->
    case lookup(ProfileId) of
        {ok, Profile} ->
            case adk_provider_profile:live_config(Profile, ModelAlias) of
                {ok, Resolved} -> resolve_live_transport(Resolved);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

%% @doc Resolve the profile portion of a public Live session configuration.
%% `model' is an operator-defined alias. All other entries are provider
%% options; authority-bearing values are rejected before they can be merged
%% with the concrete model identifier from the profile.
-spec resolve_live_config(term(), term()) ->
    {ok, map()} | {error, term()}.
resolve_live_config(ProfileId, #{model := ModelAlias} = ProviderConfig)
  when is_binary(ProfileId), is_binary(ModelAlias) ->
    case prohibited_overrides(ProviderConfig) of
        [] ->
            case resolve_live(ProfileId, ModelAlias) of
                {ok, Resolved} ->
                    Options = maps:remove(model, ProviderConfig),
                    {ok, Resolved#{options => Options}};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, provider_profile_override_not_allowed}
    end;
resolve_live_config(ProfileId, ProviderConfig)
  when is_binary(ProfileId), is_map(ProviderConfig) ->
    case maps:is_key(model, ProviderConfig) of
        false -> {error, missing_provider_model_alias};
        true -> {error, invalid_provider_model_alias}
    end;
resolve_live_config(_ProfileId, _ProviderConfig) ->
    {error, invalid_provider_config}.

%% @doc Resolve a new binary profile configuration, or explicitly identify an
%% existing atom-module configuration as legacy. Caller-supplied authority
%% fields are rejected for profile configurations rather than merged over the
%% operator-owned profile.
-spec resolve_config(term()) -> {ok, map()} | {error, term()}.
resolve_config(#{provider := Provider} = Config) when is_atom(Provider) ->
    {ok, #{kind => legacy, adapter => Provider, config => Config}};
resolve_config(#{provider := ProfileId, model := ModelAlias} = Config)
  when is_binary(ProfileId), is_binary(ModelAlias) ->
    case resolve(ProfileId, ModelAlias) of
        {ok, #{adapter := Adapter} = Resolved} ->
            CallerOptions = maps:without([provider, model], Config),
            case validate_request_caller_options(Adapter, CallerOptions) of
                ok ->
                    LockedOptions = maps:get(
                                      request_options, Resolved, #{}),
                    %% Locked operator policy wins even if a future adapter
                    %% allowlist accidentally overlaps with it.
                    Options = maps:merge(CallerOptions, LockedOptions),
                    {ok, Resolved#{options => Options}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
resolve_config(#{provider := ProfileId}) when is_binary(ProfileId) ->
    {error, missing_provider_model_alias};
resolve_config(#{}) ->
    {error, missing_llm_provider};
resolve_config(_Config) ->
    {error, invalid_provider_config}.

normalize_profiles(Profiles)
  when is_map(Profiles), map_size(Profiles) =< ?MAX_PROFILES ->
    case bounded_term(Profiles, ?MAX_PROFILES_BYTES) of
        true -> normalize_profile_pairs(maps:to_list(Profiles), #{});
        false -> {error, invalid_provider_profiles}
    end;
normalize_profiles(_Profiles) ->
    {error, invalid_provider_profiles}.

normalize_profile_pairs([], Acc) -> {ok, Acc};
normalize_profile_pairs([{ProfileId, Profile} | Rest], Acc) ->
    case adk_provider_profile:normalize(ProfileId, Profile) of
        {ok, Normalized} ->
            normalize_profile_pairs(
              Rest, maps:put(ProfileId, Normalized, Acc));
        {error, Reason} ->
            {error, {invalid_provider_profile, safe_profile_id(ProfileId),
                     Reason}}
    end.

resolve_live_transport(#{adapter := Adapter,
                         endpoint := Endpoint} = Resolved) ->
    case live_endpoint_allowed(Adapter, Endpoint) of
        false -> {error, provider_profile_live_endpoint_not_supported};
        true ->
            case adapter_transport(Adapter) of
                {ok, Transport} ->
                    {ok, Resolved#{transport => Transport}};
                {error, _} = Error -> Error
            end
    end.

%% The bundled Live transports have fixed TLS origins. A profile must name
%% the matching preset; custom/local endpoints remain unsupported until a
%% transport exposes and validates a structured endpoint contract.
live_endpoint_allowed(adk_live_openai, openai) -> true;
live_endpoint_allowed(adk_live_gemini, gemini) -> true;
live_endpoint_allowed(_Adapter, _Endpoint) -> false.

adapter_transport(Adapter) when is_atom(Adapter) ->
    case erlang:function_exported(Adapter, transport, 0) of
        false -> {error, provider_live_transport_unavailable};
        true ->
            try Adapter:transport() of
                Transport when is_atom(Transport), Transport =/= undefined ->
                    {ok, Transport};
                _ -> {error, invalid_provider_live_transport}
            catch
                _:_ -> {error, provider_live_transport_unavailable}
            end
    end.

validate_request_caller_options(Adapter, Options) ->
    case request_caller_allowlist(Adapter) of
        {ok, Allowed} ->
            case maps:keys(Options) -- Allowed of
                [] -> ok;
                [_ | _] ->
                    {error, provider_profile_override_not_allowed}
            end;
        {error, _} ->
            {error, provider_profile_override_not_allowed}
    end.

request_caller_allowlist(adk_llm_openai) ->
    {ok, openai_request_options() ++ agent_runtime_options()};
request_caller_allowlist(adk_llm_anthropic) ->
    {ok, anthropic_request_options() ++ agent_runtime_options()};
request_caller_allowlist(adk_llm_compatible) ->
    {ok, compatible_request_options() ++ agent_runtime_options()};
request_caller_allowlist(adk_llm_gemini) ->
    {ok, gemini_request_options() ++ agent_runtime_options()};
request_caller_allowlist(Adapter) ->
    custom_request_caller_allowlist(Adapter).

openai_request_options() ->
    [temperature, top_p, max_tokens, max_output_tokens,
     parallel_tool_calls, response_mime_type, response_schema,
     response_schema_name, content_limits, max_stream_events,
     request_timeout, max_response_bytes].

anthropic_request_options() ->
    [max_tokens, temperature, top_p, top_k, stop_sequences, tool_choice,
     content_limits, request_timeout, max_response_bytes].

compatible_request_options() ->
    [temperature, top_p, max_tokens, max_completion_tokens,
     stop_sequences, parallel_tool_calls, tool_choice, response_format,
     response_mime_type, response_schema, response_schema_name,
     stream_include_usage, content_limits, max_stream_events,
     request_timeout, max_response_bytes].

gemini_request_options() ->
    [temperature, top_p, top_k, max_tokens, max_output_tokens,
     candidate_count, seed, presence_penalty, frequency_penalty,
     stop_sequences, response_mime_type, response_schema,
     thinking_config, safety_settings, builtin_tools, content_limits,
     request_timeout, context_cache].

agent_runtime_options() ->
    [instructions, global_instruction, input_schema, output_schema,
     generation_config, history_policy, include_history, include_contents,
     output_key, required_capabilities, instruction_timeout_ms,
     artifact_timeout_ms, max_instruction_bytes,
     session_id, session_store, sub_agents, callbacks, callback_config,
     callback_pid, max_tool_rounds, app_name, user_id, artifact_svc,
     artifact_service, agent_turn_timeout, max_concurrent_invocations,
     '$adk_invocation_context_api',
     '$adk_inherited_global_instruction'].

custom_request_caller_allowlist(Adapter) when is_atom(Adapter) ->
    case erlang:function_exported(
           Adapter, profile_request_option_allowlist, 0) of
        false -> {ok, []};
        true ->
            try Adapter:profile_request_option_allowlist() of
                Allowed when is_list(Allowed), length(Allowed) =< 128 ->
                    case valid_custom_request_allowlist(Allowed) of
                        true -> {ok, Allowed};
                        false -> {error, invalid_provider_option_allowlist}
                    end;
                _ -> {error, invalid_provider_option_allowlist}
            catch
                _:_ -> {error, invalid_provider_option_allowlist}
            end
    end.

valid_custom_request_allowlist(Allowed) ->
    length(Allowed) =:= length(lists:usort(Allowed)) andalso
    lists:all(
      fun(Key) ->
          is_atom(Key) andalso
          not request_authority_key(Key) andalso
          not adk_context_guard:sensitive_key(Key)
      end, Allowed).

request_authority_key(Key) ->
    lists:member(
      Key,
      [provider, model, request_adapter, live_adapter, provider_module,
       endpoint, base_url, url, headers, credential, credential_source,
       provider_profile, profile, model_id, request_options,
       api_key, auth_scheme, organization, project, store,
       anthropic_version, http_transport, transport,
       allow_private_hosts, cacertfile, tls_opts, ssl_options,
       input_audio_sample_rate, input_audio_sample_rate_hz]).

prohibited_overrides(Config) ->
    Explicit = [request_adapter, live_adapter, provider_module, endpoint,
                base_url, url, headers, credential, credential_source,
                provider_profile, profile, model_id,
                input_audio_sample_rate, input_audio_sample_rate_hz,
                http_transport, transport, allow_private_hosts],
    [Key || Key <- maps:keys(Config),
            lists:member(Key, Explicit) orelse
            adk_context_guard:sensitive_key(Key)].

safe_profile_id(ProfileId) when is_binary(ProfileId),
                                byte_size(ProfileId) > 0,
                                byte_size(ProfileId) =< 128 -> ProfileId;
safe_profile_id(_ProfileId) -> invalid_id.

bounded_term(Term, Maximum) ->
    try erlang:external_size(Term) =< Maximum
    catch _:_ -> false
    end.
