defmodule ErlangAdkUiWeb.Plugs.RequireAuthentication do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  alias ErlangAdkUi.Auth.SessionStore

  def init(options), do: options

  def call(conn, _options) do
    handle = get_session(conn, "auth_session_id")

    case SessionStore.fetch(handle) do
      {:ok, identity} ->
        assign(conn, :current_identity, identity)

      {:error, :unauthenticated} ->
        conn
        |> configure_session(drop: true)
        |> redirect(to: "/auth/login")
        |> halt()
    end
  end
end
