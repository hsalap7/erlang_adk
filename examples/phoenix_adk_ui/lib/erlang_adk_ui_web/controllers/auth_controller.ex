defmodule ErlangAdkUiWeb.AuthController do
  use ErlangAdkUiWeb, :controller

  alias ErlangAdkUi.Auth.{LoginFlowStore, ProviderCall, SessionStore}

  def login(conn, _params) do
    provider = Application.fetch_env!(:erlang_adk_ui, :auth_provider)
    _ = LoginFlowStore.discard(get_session(conn, "oidc_flow_handle"))
    _ = SessionStore.revoke(get_session(conn, "auth_session_id"))

    with {:ok, redirect_uri, flow} <- ProviderCall.authorization_request(provider),
         {:ok, flow_handle} <- LoginFlowStore.issue(flow) do
      conn
      |> configure_session(renew: true)
      |> clear_session()
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
    provider = Application.fetch_env!(:erlang_adk_ui, :auth_provider)
    flow_handle = get_session(conn, "oidc_flow_handle")
    conn = delete_session(conn, "oidc_flow_handle")

    with {:ok, flow} <- LoginFlowStore.consume(flow_handle),
         {:ok, identity} <- ProviderCall.complete(provider, params, flow),
         {:ok, handle} <- SessionStore.issue(identity) do
      conn
      |> configure_session(renew: true)
      |> clear_session()
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
end
