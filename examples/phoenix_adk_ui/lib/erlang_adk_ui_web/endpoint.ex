defmodule ErlangAdkUiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :erlang_adk_ui

  @session_options [
    store: :cookie,
    key: "_erlang_adk_ui_session",
    signing_salt: "adk-sign-v06",
    encryption_salt: "adk-encrypt-v06",
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:erlang_adk_ui, :secure_cookies, false),
    max_age: 28_800
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Phoenix compiles the Endpoint :force_ssl option into the release. The
  # deployment may choose direct TLS or a trusted TLS proxy at runtime, so a
  # runtime-aware plug must make that choice without disabling compile-env
  # validation. It remains the first application plug so redirects and HSTS
  # cover static files, LiveView, and every router path.
  plug ErlangAdkUiWeb.Plugs.ProductionSSL

  plug Plug.Static,
    at: "/",
    from: :erlang_adk_ui,
    gzip: not code_reloading?,
    only: ErlangAdkUiWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/json", "application/x-www-form-urlencoded"],
    length: 1_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ErlangAdkUiWeb.Router
end
