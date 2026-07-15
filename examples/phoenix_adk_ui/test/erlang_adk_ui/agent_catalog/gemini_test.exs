defmodule ErlangAdkUi.AgentCatalog.GeminiTest do
  use ExUnit.Case, async: false

  alias ErlangAdkUi.AgentCatalog.Gemini

  @agent_name <<"PhoenixAssistantV06">>

  setup do
    previous_issuer = Application.get_env(:erlang_adk_ui, :trusted_auth_issuer)

    Application.put_env(
      :erlang_adk_ui,
      :trusted_auth_issuer,
      "https://identity.example.com"
    )

    on_exit(fn ->
      case :adk_agent_registry.lookup(@agent_name) do
        {:ok, agent} -> :erlang_adk.stop_agent(agent)
        {:error, :not_found} -> :ok
      end

      case previous_issuer do
        nil -> Application.delete_env(:erlang_adk_ui, :trusted_auth_issuer)
        value -> Application.put_env(:erlang_adk_ui, :trusted_auth_issuer, value)
      end
    end)

    :ok
  end

  test "default production catalog starts the Erlang gateway" do
    assert {:ok, options} = Gemini.gateway_options()
    assert {:ok, gateway} = :adk_web_gateway.start_link(options)
    assert :ok = GenServer.stop(gateway)
  end
end
