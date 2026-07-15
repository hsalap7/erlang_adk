%% @doc Optional exporter behaviour for structured Erlang ADK envelopes.
%%
%% Exporters receive only JSON-safe, secret-pruned data. OpenTelemetry, a log
%% backend, or an in-house collector can implement this behaviour without the
%% core application depending on any of those libraries.
-module(adk_observability_exporter).

-type envelope() :: map().
-type result() :: ok | {error, term()}.
-export_type([envelope/0, result/0]).

-callback export(Envelope :: envelope(), Config :: map()) -> result().
