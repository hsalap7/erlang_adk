import Config

config :erlang_adk_ui,
  auth_provider: ErlangAdkUi.TestAuthProvider,
  gateway_server: ErlangAdkUi.TestGateway,
  start_gateway: false,
  live_gateway: ErlangAdkUi.TestLiveGateway,
  auth_provider_call: [timeout_ms: 100, max_heap_words: 200_000],
  login_flow_store: [ttl_ms: 60_000, max_entries: 100],
  session_store: [ttl_ms: :timer.minutes(5), max_entries: 100]

config :erlang_adk_ui, ErlangAdkUiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "SPMlCJ74VIZCHGNAmygpzaxiSohxVc0YT48QEId7uT1D6dHDTZvcf4I4IarD3LgE",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true
