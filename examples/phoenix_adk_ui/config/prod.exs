import Config

config :erlang_adk_ui, :secure_cookies, true

config :erlang_adk_ui, ErlangAdkUiWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
