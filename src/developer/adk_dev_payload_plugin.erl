%% @doc Observe-only model payload capture for the local Developer UI.
%%
%% This plugin is installed only by the explicitly enabled loopback developer
%% runtime.  The plugin pipeline already isolates it by time and heap.  It
%% additionally redacts secret-bearing fields, normalizes to JSON, and applies
%% a byte bound before handing data to the retention store.
-module(adk_dev_payload_plugin).
-behaviour(adk_plugin).

-export([before_model/3, after_model/3, on_model_error/3]).

-define(DEFAULT_MAX_EVENT_BYTES, 65536).
-define(DEFAULT_CALL_TIMEOUT, 500).

before_model(Context, Value, Config) ->
    capture(<<"request">>, Context, Value, Config),
    observe.

after_model(Context, Value, Config) ->
    capture(<<"response">>, Context, Value, Config),
    observe.

on_model_error(Context, Value, Config) ->
    capture(<<"error">>, Context, Value, Config),
    observe.

capture(Phase, Context0, Value0, Config) ->
    try
        Store = maps:get(store, Config),
        MaxBytes = maps:get(max_event_bytes, Config,
                            ?DEFAULT_MAX_EVENT_BYTES),
        Timeout = maps:get(call_timeout_ms, Config, ?DEFAULT_CALL_TIMEOUT),
        Context = project_context(Context0),
        Redacted = adk_secret_redactor:redact(Value0),
        case {adk_json:normalize(Context), adk_json:normalize(Redacted)} of
            {{ok, SafeContext}, {ok, SafeValue}} ->
                Json = jsx:encode(#{<<"schema_version">> => 1,
                                    <<"context">> => SafeContext,
                                    <<"payload">> => SafeValue}),
                case byte_size(Json) =< MaxBytes of
                    true ->
                        _ = adk_dev_payload_store:append_json(
                              Store, Phase, Json, Timeout),
                        ok;
                    false -> ok
                end;
            _ -> ok
        end
    catch
        _:_ -> ok
    end.

project_context(Context) when is_map(Context) ->
    maps:with([run_id, invocation_id, session, app_name, user_id,
               agent, model, phase], Context);
project_context(_) -> #{}.
