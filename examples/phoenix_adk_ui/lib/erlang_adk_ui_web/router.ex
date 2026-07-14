defmodule ErlangAdkUiWeb.Router do
  use ErlangAdkUiWeb, :router

  @security_headers %{
    "content-security-policy" =>
      "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; img-src 'self' data:; connect-src 'self'; script-src 'self'; style-src 'self'",
    "cross-origin-opener-policy" => "same-origin",
    "referrer-policy" => "no-referrer",
    "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=()",
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
  end

  pipeline :authenticated do
    plug ErlangAdkUiWeb.Plugs.RequireAuthentication
  end

  scope "/", ErlangAdkUiWeb do
    pipe_through :browser

    get "/health", HealthController, :show
    get "/auth/login", AuthController, :login
    get "/auth/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :logout
  end

  scope "/", ErlangAdkUiWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated, on_mount: [{ErlangAdkUiWeb.AuthHooks, :required}] do
      live "/", AgentLive, :index
      live "/agent", AgentLive, :index
    end
  end
end
