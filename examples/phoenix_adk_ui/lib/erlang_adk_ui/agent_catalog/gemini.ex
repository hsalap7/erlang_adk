defmodule ErlangAdkUi.AgentCatalog.Gemini do
  @moduledoc """
  Default immutable catalog for the companion UI.

  It uses Gemini 3.1 Flash-Lite and adopts only the fixed, server-configured
  agent name. Deployments with a larger catalog can provide another module
  implementing `gateway_options/0` through application configuration.
  """

  @agent_name <<"PhoenixAssistantV06">>
  @app_name <<"erlang_adk_ui">>

  def gateway_options do
    oidc = Application.fetch_env!(:erlang_adk_ui, :oidc)

    with {:ok, agent} <- ensure_agent() do
      runner =
        :adk_runner.new(agent, @app_name, :erlang_adk_session, %{
          run_timeout: 120_000,
          admission_control: %{overflow: :queue, queue_timeout: 10_000},
          runtime_policy: %{
            id: <<"phoenix-ui-default">>,
            agents: %{allow: [@agent_name]},
            tools: %{allow: :all, deny: [<<"shell">>]},
            max_argument_bytes: 32_768,
            max_content_bytes: 262_144
          }
        })

      {:ok,
       %{
         agents: %{
           <<"assistant">> => %{
             runner: runner,
             label: <<"Assistant">>,
             description: <<"Gemini 3.1 Flash-Lite assistant">>,
             run_options: %{retention_ms: 300_000}
           }
         },
         policy: %{
           trusted_issuers: [oidc[:issuer]],
           required_scopes: %{
             list_agents: [<<"adk.agents.read">>],
             start_run: [<<"adk.run.start">>],
             observe_run: [<<"adk.run.read">>],
             control_run: [<<"adk.run.control">>],
             resume_run: [<<"adk.run.control">>]
           }
         },
         max_message_bytes: 16_384,
         max_decision_bytes: 65_536
       }}
    end
  end

  defp ensure_agent do
    case :adk_agent_registry.lookup(@agent_name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        :erlang_adk.spawn_agent(
          @agent_name,
          %{
            provider: :adk_llm_gemini,
            model: <<"gemini-3.1-flash-lite">>,
            instructions:
              <<"Answer clearly and concisely. Never claim a tool action occurred unless a tool result confirms it.">>
          },
          []
        )
    end
  end
end
