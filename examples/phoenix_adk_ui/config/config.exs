import Config

config :erlang_adk_ui,
  auth_provider: ErlangAdkUi.Auth.Oidc,
  local_dev_mode: false,
  gateway_provider: ErlangAdkUi.AgentCatalog.Gemini,
  gateway_server: ErlangAdkUi.Gateway,
  start_gateway: true,
  live_gateway: ErlangAdkUi.LiveGateway.Local,
  live_credit: %{messages: 8, bytes: 262_144},
  evaluation_reports: %{},
  auth_provider_call: [timeout_ms: 15_000, max_heap_words: 1_000_000],
  login_flow_store: [ttl_ms: :timer.minutes(10), max_entries: 1_000],
  session_store: [ttl_ms: :timer.hours(8), max_entries: 10_000],
  ui_limits: [
    max_message_bytes: 16_384,
    max_events: 100,
    max_event_bytes: 262_144,
    max_output_bytes: 32_768,
    max_live_text_bytes: 16_384,
    max_live_events: 100,
    max_live_event_bytes: 262_144,
    max_observability_bytes: 262_144,
    max_evaluation_bytes: 1_048_576
  ]

config :erlang_adk_ui, ErlangAdkUiWeb.Endpoint,
  url: [host: "127.0.0.1"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ErlangAdkUiWeb.ErrorHTML, json: ErlangAdkUiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ErlangAdkUi.PubSub,
  live_view: [signing_salt: "adk-live-v06"]

config :phoenix_live_view, root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.25.4",
  erlang_adk_ui: [
    args:
      ~w(js/app.js js/live_voice_worklet.js css/app.css --bundle --target=es2022 --outbase=. --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
