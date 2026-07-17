defmodule ErlangAdkUi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ErlangAdkUiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:erlang_adk_ui, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ErlangAdkUi.PubSub},
      {ErlangAdkUi.Auth.LoginFlowStore,
       Application.fetch_env!(:erlang_adk_ui, :login_flow_store)},
      {ErlangAdkUi.Auth.SessionStore, Application.fetch_env!(:erlang_adk_ui, :session_store)},
      gateway_child(),
      ErlangAdkUiWeb.Endpoint
    ]

    Supervisor.start_link(Enum.reject(children, &is_nil/1),
      strategy: :one_for_one,
      name: ErlangAdkUi.Supervisor
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    ErlangAdkUiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp gateway_child do
    if Application.fetch_env!(:erlang_adk_ui, :start_gateway) do
      ErlangAdkUi.Gateway
    end
  end
end
