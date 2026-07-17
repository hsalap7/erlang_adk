defmodule ErlangAdkUiWeb.Router do
  use ErlangAdkUiWeb, :router

  @security_headers %{
    "cross-origin-opener-policy" => "same-origin",
    "referrer-policy" => "no-referrer",
    "permissions-policy" => "camera=(), microphone=(self), geolocation=(), payment=()",
    "x-content-type-options" => "nosniff",
    "x-frame-options" => "DENY",
    "x-permitted-cross-domain-policies" => "none"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ErlangAdkUiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @security_headers
    plug :put_content_security_policy
  end

  pipeline :authenticated do
    plug ErlangAdkUiWeb.Plugs.RequireAuthentication
  end

  scope "/", ErlangAdkUiWeb do
    pipe_through :browser

    get "/favicon.ico", FaviconController, :show
    get "/health", HealthController, :show
    get "/auth/login", AuthController, :login
    post "/auth/local", AuthController, :local_login
    get "/auth/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :logout
  end

  scope "/", ErlangAdkUiWeb do
    pipe_through [:browser, :authenticated]

    get "/live/voice/:session_id", VoiceSocketController, :upgrade

    live_session :authenticated, on_mount: [{ErlangAdkUiWeb.AuthHooks, :required}] do
      live "/", AgentLive, :index
      live "/agent", AgentLive, :index
      live "/live", LiveSessionLive, :index
    end
  end

  defp put_content_security_policy(conn, _opts) do
    policy =
      "default-src 'self'; base-uri 'self'; form-action 'self'; " <>
        "frame-ancestors 'none'; object-src 'none'; img-src 'self' data:; " <>
        "connect-src 'self' #{websocket_origin(conn)}; " <>
        "script-src 'self'; style-src 'self'"

    Plug.Conn.put_resp_header(conn, "content-security-policy", policy)
  end

  defp websocket_origin(conn) do
    {scheme, default_port} =
      case conn.scheme do
        :https -> {"wss", 443}
        :http -> {"ws", 80}
      end

    URI.to_string(%URI{
      scheme: scheme,
      host: conn.host,
      port: if(conn.port == default_port, do: nil, else: conn.port)
    })
  end
end
