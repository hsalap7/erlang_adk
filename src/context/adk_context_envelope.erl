%% @doc Canonical safety and complete provider-envelope accounting.
%%
%% This module does not call a provider. It measures the complete sanitized
%% request inputs visible at the provider boundary: effective instructions and
%% generation options, chronological model messages, tool declarations, and a
%% conservative framing allowance. Provider credentials and runtime handles
%% are deliberately excluded.
-module(adk_context_envelope).

-include("adk_event.hrl").

-export([sanitize_history/1, measure/3, check/4]).

-define(VERSION, 1).
-define(DEFAULT_BYTES_PER_TOKEN, 4).
-define(FRAMING_BYTES, 128).
-define(PER_MESSAGE_FRAMING_BYTES, 32).

-spec sanitize_history([map()]) -> {ok, [map()]} | {error, term()}.
sanitize_history(History) when is_list(History) ->
    sanitize_history(History, []);
sanitize_history(_) -> {error, invalid_model_history}.

sanitize_history([], Acc) -> {ok, lists:reverse(Acc)};
sanitize_history([#{role := Role, content := Content} = Message | Rest], Acc) ->
    case role_binary(Role) of
        {ok, Author} ->
            Event = adk_event:new(Author, Content),
            case adk_context_guard:sanitize_event(Event) of
                {ok, SafeMap} ->
                    case adk_event:decode(SafeMap) of
                        {ok, SafeEvent} ->
                            SafeMessage = Message#{content =>
                              SafeEvent#adk_event.content},
                            sanitize_history(Rest, [SafeMessage | Acc]);
                        {error, Reason} ->
                            {error, {invalid_model_history, Reason}}
                    end;
                {error, Reason} ->
                    {error, {invalid_model_history, Reason}}
            end;
        {error, _} = Error -> Error
    end;
sanitize_history([_ | _], _Acc) -> {error, invalid_model_history}.

-spec measure(map(), [map()], [map()]) -> {ok, map()} | {error, term()}.
measure(Config, History, Tools)
  when is_map(Config), is_list(History), is_list(Tools) ->
    case {canonical_config(Config), canonical_history(History),
          adk_context_guard:sanitize_value(Tools)} of
        {{ok, SafeConfig}, {ok, SafeHistory}, {ok, SafeTools}}
          when is_list(SafeTools) ->
            Envelope = #{<<"version">> => ?VERSION,
                         <<"config">> => SafeConfig,
                         <<"history">> => SafeHistory,
                         <<"tools">> => SafeTools},
            Encoded = jsx:encode(Envelope),
            Framing = ?FRAMING_BYTES +
                      ?PER_MESSAGE_FRAMING_BYTES * length(History),
            Bytes = byte_size(Encoded) + Framing,
            {ok, #{version => ?VERSION,
                   bytes => Bytes,
                   encoded_bytes => byte_size(Encoded),
                   framing_bytes => Framing,
                   fingerprint => hex(crypto:hash(sha256,
                                                   term_to_binary(Envelope,
                                                                  [deterministic]))),
                   fingerprint_algorithm => sha256}};
        {{error, Reason}, _, _} -> {error, Reason};
        {_, {error, Reason}, _} -> {error, Reason};
        {_, _, {error, Reason}} -> {error, Reason};
        _ -> {error, invalid_model_envelope}
    end;
measure(_, _, _) -> {error, invalid_model_envelope}.

-spec check(map(), [map()], [map()], disabled | map()) ->
    {ok, map()} | {error, term()}.
check(Config, History, Tools, Policy) ->
    case normalize_policy(Policy) of
        {ok, Normalized} ->
            case measure(Config, History, Tools) of
                {ok, Metadata0} ->
                    Bytes = maps:get(bytes, Metadata0),
                    Tokens = (Bytes + maps:get(bytes_per_token, Normalized) - 1)
                             div maps:get(bytes_per_token, Normalized),
                    Metadata = Metadata0#{estimated_tokens => Tokens},
                    case within(Bytes, Tokens, Normalized) of
                        true -> {ok, Metadata};
                        false ->
                            {error,
                             {request_context_budget_exceeded,
                              #{bytes => Bytes,
                                estimated_tokens => Tokens,
                                max_bytes => maps:get(max_bytes, Normalized),
                                max_tokens => maps:get(max_tokens,
                                                       Normalized)}}}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

normalize_policy(disabled) ->
    {ok, #{max_bytes => infinity, max_tokens => infinity,
           bytes_per_token => ?DEFAULT_BYTES_PER_TOKEN}};
normalize_policy(Policy) when is_map(Policy) ->
    MaxBytes = maps:get(max_request_bytes, Policy, infinity),
    MaxTokens = maps:get(max_request_tokens, Policy, infinity),
    BytesPerToken = maps:get(bytes_per_token, Policy,
                             ?DEFAULT_BYTES_PER_TOKEN),
    case valid_limit(MaxBytes) andalso valid_limit(MaxTokens) andalso
         is_integer(BytesPerToken) andalso BytesPerToken > 0 of
        true -> {ok, #{max_bytes => MaxBytes, max_tokens => MaxTokens,
                       bytes_per_token => BytesPerToken}};
        false -> {error, invalid_request_context_budget}
    end;
normalize_policy(_) -> {error, invalid_request_context_budget}.

within(Bytes, Tokens, Policy) ->
    within_one(Bytes, maps:get(max_bytes, Policy)) andalso
    within_one(Tokens, maps:get(max_tokens, Policy)).

within_one(_Value, infinity) -> true;
within_one(Value, Limit) -> Value =< Limit.

valid_limit(infinity) -> true;
valid_limit(Value) -> is_integer(Value) andalso Value > 0.

canonical_config(Config) ->
    %% These values affect the provider request. Transport/auth/callback/test
    %% fields are omitted even if a custom provider stores them in Config.
    Keys = [instructions, model, temperature, top_p, top_k, max_tokens,
            stop_sequences, response_mime_type, response_schema,
            safety_settings, builtin_tools, generation_config,
            thinking_config],
    adk_context_guard:sanitize_value(maps:with(Keys, Config)).

canonical_history(History) ->
    canonical_history(History, []).

canonical_history([], Acc) -> {ok, lists:reverse(Acc)};
canonical_history([#{role := Role, content := Content} | Rest], Acc) ->
    case role_binary(Role) of
        {ok, RoleBin} ->
            Event = adk_event:new(RoleBin, Content),
            case adk_context_guard:sanitize_event(Event) of
                {ok, SafeEvent} ->
                    Canon = #{<<"role">> => RoleBin,
                              <<"content">> => maps:get(<<"content">>,
                                                       SafeEvent)},
                    canonical_history(Rest, [Canon | Acc]);
                {error, Reason} ->
                    {error, {invalid_model_history, Reason}}
            end;
        {error, _} = Error -> Error
    end;
canonical_history([_ | _], _Acc) -> {error, invalid_model_history}.

role_binary(user) -> {ok, <<"user">>};
role_binary(agent) -> {ok, <<"agent">>};
role_binary(tool) -> {ok, <<"tool">>};
role_binary(system) -> {ok, <<"system">>};
role_binary(Role) when is_binary(Role) -> {ok, Role};
role_binary(_) -> {error, invalid_model_role}.

hex(Binary) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte])
                      || <<Byte>> <= Binary]).
