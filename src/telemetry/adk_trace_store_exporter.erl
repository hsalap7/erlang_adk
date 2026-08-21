%% @doc Observability exporter adapter for the bounded developer trace store.
%%
%% Configuration is intentionally closed: callers must bind one authenticated
%% principal and one trace-store server when constructing the exporter
%% descriptor. Neither envelope data nor the principal is reflected in error
%% values.
-module(adk_trace_store_exporter).
-behaviour(adk_observability_exporter).

-export([export/2, validate_config/1]).

-define(MAX_PRINCIPAL_BYTES, 256).

-spec validate_config(map()) -> {ok, map()} | {error, term()}.
validate_config(#{principal := Principal, server := Server} = Config)
  when map_size(Config) =:= 2 ->
    case valid_principal(Principal) andalso valid_server(Server) of
        true -> {ok, Config};
        false -> {error, invalid_trace_store_exporter_config}
    end;
validate_config(_Config) ->
    {error, invalid_trace_store_exporter_config}.

-spec export(map(), map()) -> ok | {error, term()}.
export(Envelope0, Config0) when is_map(Envelope0), is_map(Config0) ->
    case validate_config(Config0) of
        {ok, #{principal := Principal, server := Server}} ->
            case adk_observability:encode(Envelope0) of
                {ok, Envelope} ->
                    export_canonical(Server, Principal, Envelope);
                {error, _Reason} ->
                    {error, invalid_trace_store_exporter_envelope}
            end;
        {error, _Reason} = Error -> Error
    end;
export(_Envelope, _Config) ->
    {error, invalid_trace_store_exporter_arguments}.

export_canonical(Server, Principal, Envelope) ->
    case adk_trace_store:append_observability(Server, Principal, Envelope) of
        {ok, _Cursor} -> ok;
        {error, Reason} -> {error, safe_store_reason(Reason)};
        _Unexpected -> {error, trace_store_invalid_result}
    end.

%% Trace-store failures are structural. Keep the exporter boundary defensive
%% so future internal errors cannot accidentally echo input or identity data.
safe_store_reason(trace_store_timeout) -> trace_store_timeout;
safe_store_reason(trace_store_unavailable) -> trace_store_unavailable;
safe_store_reason(trace_content_rejected) -> trace_content_rejected;
safe_store_reason(trace_event_input_too_large) -> trace_event_input_too_large;
safe_store_reason(trace_event_too_large) -> trace_event_too_large;
safe_store_reason(trace_principal_capacity_reached) ->
    trace_principal_capacity_reached;
safe_store_reason(invalid_trace_event_encoding) ->
    invalid_trace_event_encoding;
safe_store_reason(invalid_trace_observability_event) ->
    invalid_trace_observability_event;
safe_store_reason({invalid_trace_observability_event, _Reason}) ->
    invalid_trace_observability_event;
safe_store_reason(trace_identity_required) -> trace_identity_required;
safe_store_reason(_Reason) -> trace_store_rejected.

valid_principal(Principal)
  when is_binary(Principal), byte_size(Principal) > 0,
       byte_size(Principal) =< ?MAX_PRINCIPAL_BYTES ->
    case unicode:characters_to_binary(Principal, utf8, utf8) of
        Principal -> true;
        _ -> false
    end;
valid_principal(_Principal) -> false.

valid_server(Server) when is_pid(Server) -> true;
valid_server(Server) when is_atom(Server) -> Server =/= undefined;
valid_server({Name, Node}) when is_atom(Name), is_atom(Node) -> true;
valid_server(_Server) -> false.
