defmodule ErlangAdkUiWeb do
  @moduledoc false

  def static_paths, do: ~w(assets robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      import Phoenix.HTML
      alias ErlangAdkUiWeb.Layouts
      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0]
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ErlangAdkUiWeb.Endpoint,
        router: ErlangAdkUiWeb.Router,
        statics: ErlangAdkUiWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
