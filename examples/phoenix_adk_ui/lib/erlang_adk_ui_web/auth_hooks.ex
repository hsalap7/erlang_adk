defmodule ErlangAdkUiWeb.AuthHooks do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias ErlangAdkUi.Auth.SessionStore

  def on_mount(:required, _params, session, socket) do
    handle = session["auth_session_id"]
    gateway = Application.fetch_env!(:erlang_adk_ui, :gateway_server)

    with {:ok, context} <- SessionStore.fetch_context(handle),
         {:ok, agents} <- :adk_web_gateway.list_agents(gateway, context.identity) do
      {:cont,
       socket
       |> assign(:auth_session_id, handle)
       |> assign(:agents, agents)}
    else
      _error -> {:halt, redirect(socket, to: "/auth/login")}
    end
  end
end
