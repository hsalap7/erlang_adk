%% @doc Application-level wiring for the optional local trace store.
%%
%% Enabling the store also installs one bounded observability-bus exporter and
%% supplies metadata-only asynchronous observability options to standard
%% Runner construction. Workflow facade calls receive a store-minted
%% lifecycle capability. All of those paths are derived from the same strict
%% application configuration so merely starting a store can never create the
%% misleading appearance that traces are being retained.
-module(adk_trace_runtime).

-export([config/0, bus_enabled/1, configure_bus_options/1,
         runner_options/0, workflow_options/1]).

-define(EXPORTER_ID, <<"erlang-adk-trace-store">>).
-define(DEFAULT_PRINCIPAL, <<"local-runtime">>).
-define(MAX_PRINCIPAL_BYTES, 256).

-spec config() -> {ok, disabled | map()} | {error, term()}.
config() ->
    case application:get_env(erlang_adk, trace_store_enabled, false) of
        false -> {ok, disabled};
        true -> enabled_config();
        Invalid ->
            {error, {invalid_application_env,
                     trace_store_enabled, Invalid}}
    end.

-spec bus_enabled(boolean()) -> {ok, boolean()} | {error, term()}.
bus_enabled(Explicit) when is_boolean(Explicit) ->
    case config() of
        {ok, disabled} -> {ok, Explicit};
        {ok, _Config} -> {ok, true};
        {error, _} = Error -> Error
    end;
bus_enabled(Invalid) ->
    {error, {invalid_application_env,
             observability_bus_enabled, Invalid}}.

-spec configure_bus_options(map()) -> {ok, map()} | {error, term()}.
configure_bus_options(Options) when is_map(Options) ->
    case config() of
        {ok, disabled} -> {ok, Options};
        {ok, Config} -> install_exporter(Options, exporter(Config));
        {error, _} = Error -> Error
    end;
configure_bus_options(Invalid) ->
    {error, {invalid_application_env,
             observability_bus_options, Invalid}}.

-spec runner_options() -> {ok, map()} | {error, term()}.
runner_options() ->
    case config() of
        {ok, disabled} -> configured_bus_runner_options();
        {ok, #{bus := Bus}} ->
            {ok, #{observability =>
                       #{delivery => async,
                         bus => Bus,
                         failure_policy => open,
                         capture_content => false,
                         attributes => #{}}}};
        {error, _} = Error -> Error
    end.

configured_bus_runner_options() ->
    Enabled = application:get_env(
                erlang_adk, observability_bus_enabled, false),
    Options = application:get_env(
                erlang_adk, observability_bus_options, #{}),
    case {Enabled, named_options(Options, adk_observability_bus)} of
        {false, {ok, _}} -> {ok, #{}};
        {true, {ok, Bus}} ->
            {ok, #{observability =>
                       #{delivery => async,
                         bus => Bus,
                         failure_policy => open,
                         capture_content => false,
                         attributes => #{}}}};
        {Invalid, _} when not is_boolean(Invalid) ->
            {error, {invalid_application_env,
                     observability_bus_enabled, Invalid}};
        {_, {error, _} = Error} -> Error
    end.

-spec workflow_options(map()) -> {ok, map()} | {error, term()}.
workflow_options(Options) when is_map(Options) ->
    case maps:is_key(lifecycle_receiver, Options) of
        true -> {ok, Options};
        false -> configured_workflow_options(Options)
    end;
workflow_options(_Options) -> {error, invalid_workflow_options}.

configured_workflow_options(Options) ->
    case config() of
        {ok, disabled} -> {ok, Options};
        {ok, #{store := Store, principal := Principal}} ->
            case adk_trace_store:lifecycle_receiver(Store, Principal) of
                {ok, Receiver} ->
                    {ok, Options#{lifecycle_receiver => Receiver}};
                {error, Reason} ->
                    {error, {workflow_trace_unavailable, safe_reason(Reason)}}
            end;
        {error, _} = Error -> Error
    end.

enabled_config() ->
    StoreOptions = application:get_env(
                     erlang_adk, trace_store_options, #{}),
    BusOptions = application:get_env(
                   erlang_adk, observability_bus_options, #{}),
    Principal = application:get_env(
                  erlang_adk, trace_store_principal,
                  ?DEFAULT_PRINCIPAL),
    case {named_options(StoreOptions, adk_trace_store),
          named_options(BusOptions, adk_observability_bus),
          valid_principal(Principal)} of
        {{ok, Store}, {ok, Bus}, true} ->
            {ok, #{store => Store, bus => Bus,
                   principal => Principal}};
        {{error, _} = Error, _, _} -> Error;
        {_, {error, _} = Error, _} -> Error;
        {_, _, false} ->
            %% Do not reflect an identity value through startup diagnostics.
            {error, {invalid_application_env, trace_store_principal}}
    end.

named_options(Options, Default) when is_map(Options) ->
    case maps:get(name, Options, Default) of
        Name when is_atom(Name), Name =/= undefined -> {ok, Name};
        _ -> {error, {invalid_application_env,
                      options_key(Default), Options}}
    end;
named_options(Options, Default) ->
    {error, {invalid_application_env, options_key(Default), Options}}.

options_key(adk_trace_store) -> trace_store_options;
options_key(adk_observability_bus) -> observability_bus_options.

install_exporter(Options, Descriptor) ->
    case maps:get(exporters, Options, []) of
        Exporters when is_list(Exporters) ->
            case [Existing || Existing <- Exporters,
                              is_map(Existing),
                              maps:get(id, Existing, undefined) =:=
                                  ?EXPORTER_ID] of
                [] -> {ok, Options#{exporters => Exporters ++ [Descriptor]}};
                [Descriptor] -> {ok, Options};
                _ ->
                    {error, {invalid_application_env,
                             observability_bus_options,
                             trace_exporter_id_conflict}}
            end;
        Invalid ->
            {error, {invalid_application_env,
                     observability_bus_options,
                     {invalid_exporters, Invalid}}}
    end.

exporter(#{store := Store, principal := Principal}) ->
    #{id => ?EXPORTER_ID,
      module => adk_trace_store_exporter,
      config => #{principal => Principal, server => Store},
      timeout_ms => 1000,
      max_heap_words => 100000,
      failure_policy => open}.

valid_principal(Principal)
  when is_binary(Principal), byte_size(Principal) > 0,
       byte_size(Principal) =< ?MAX_PRINCIPAL_BYTES ->
    unicode:characters_to_binary(Principal, utf8, utf8) =:= Principal;
valid_principal(_Principal) -> false.

safe_reason(trace_store_timeout) -> trace_store_timeout;
safe_reason(trace_store_unavailable) -> trace_store_unavailable;
safe_reason(trace_lifecycle_receiver_capacity_reached) ->
    trace_lifecycle_receiver_capacity_reached;
safe_reason(_Reason) -> trace_store_rejected.
