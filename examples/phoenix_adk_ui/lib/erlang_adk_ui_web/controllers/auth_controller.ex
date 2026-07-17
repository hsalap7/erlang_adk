defmodule ErlangAdkUiWeb.AuthController do
  use ErlangAdkUiWeb, :controller

  alias ErlangAdkUi.Auth.{LocalDev, LoginFlowStore, ProviderCall, SessionStore}

  def login(conn, _params) do
    _ = LoginFlowStore.discard(get_session(conn, "oidc_flow_handle"))
    _ = SessionStore.revoke(get_session(conn, "auth_session_id"))

    conn = renew_browser_session(conn)

    if local_dev_mode?() do
      render(conn, :local_login)
    else
      oidc_login(conn)
    end
  end

  def local_login(conn, _params) do
    if local_dev_mode?() do
      _ = LoginFlowStore.discard(get_session(conn, "oidc_flow_handle"))
      _ = SessionStore.revoke(get_session(conn, "auth_session_id"))

      with {:ok, identity} <- LocalDev.identity(),
           {:ok, handle} <- SessionStore.issue(identity) do
        conn
        |> renew_browser_session()
        |> put_session("auth_session_id", handle)
        |> redirect(to: "/agent")
      else
        _error ->
          conn
          |> configure_session(drop: true)
          |> send_resp(:service_unavailable, "local login unavailable")
      end
    else
      send_resp(conn, :not_found, "not found")
    end
  end

  defp oidc_login(conn) do
    provider = Application.fetch_env!(:erlang_adk_ui, :auth_provider)

    with {:ok, redirect_uri, flow} <- ProviderCall.authorization_request(provider),
         {:ok, flow_handle} <- LoginFlowStore.issue(flow) do
      conn
      |> put_session("oidc_flow_handle", flow_handle)
      |> redirect(external: redirect_uri)
    else
      {:error, reason} when reason in [:login_flow_capacity, :login_flow_unavailable] ->
        conn
        |> configure_session(drop: true)
        |> send_resp(:service_unavailable, "login service unavailable")

      _error ->
        conn
        |> configure_session(drop: true)
        |> send_resp(:service_unavailable, "identity provider unavailable")
    end
  end

  def callback(conn, params) do
    if local_dev_mode?() do
      send_resp(conn, :not_found, "not found")
    else
      oidc_callback(conn, params)
    end
  end

  defp oidc_callback(conn, params) do
    provider = Application.fetch_env!(:erlang_adk_ui, :auth_provider)
    flow_handle = get_session(conn, "oidc_flow_handle")
    conn = delete_session(conn, "oidc_flow_handle")

    with {:ok, flow} <- LoginFlowStore.consume(flow_handle),
         {:ok, identity} <- ProviderCall.complete(provider, params, flow),
         {:ok, handle} <- SessionStore.issue(identity) do
      conn
      |> renew_browser_session()
      |> put_session("auth_session_id", handle)
      |> redirect(to: "/agent")
    else
      {:error, :provider_unavailable} ->
        send_resp(conn, :service_unavailable, "identity provider unavailable")

      {:error, :login_flow_unavailable} ->
        send_resp(conn, :service_unavailable, "login service unavailable")

      {:error, reason}
      when reason in [
             :session_capacity,
             :session_unavailable,
             :session_handle_collision,
             :invalid_handle_generator
           ] ->
        send_resp(conn, :service_unavailable, "session service unavailable")

      _error ->
        send_resp(conn, :unauthorized, "authentication failed")
    end
  end

  def logout(conn, _params) do
    _ = SessionStore.revoke(get_session(conn, "auth_session_id"))
    _ = LoginFlowStore.discard(get_session(conn, "oidc_flow_handle"))

    conn
    |> configure_session(drop: true)
    |> clear_session()
    |> redirect(to: "/auth/login")
  end

  defp local_dev_mode? do
    Application.get_env(:erlang_adk_ui, :local_dev_mode, false) and
      Application.get_env(:erlang_adk_ui, :auth_provider) == LocalDev
  end

  # The CSRF plug loads the current token before the controller runs. Rotating
  # it before clearing the session ensures the response cookie and any form
  # rendered in this request receive the same new state, even after revisiting
  # the login page with an existing session cookie.
  defp renew_browser_session(conn) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
