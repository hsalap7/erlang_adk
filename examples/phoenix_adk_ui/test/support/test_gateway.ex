defmodule ErlangAdkUi.TestGatewayFixture do
  @app_name "erlang_adk_ui_test"

  def start(options \\ []) do
    mode = Keyword.get(options, :mode, :complete)
    owner = Keyword.get(options, :owner, self())
    agent = spawn(fn -> agent_loop(mode, owner) end)

    runner =
      :adk_runner.new(agent, @app_name, :erlang_adk_session, %{
        run_timeout: 2_000
      })

    gateway_options = %{
      name: ErlangAdkUi.TestGateway,
      agents: %{
        "assistant" => %{
          runner: runner,
          label: "Assistant",
          description: "Deterministic LiveView fixture",
          run_options: %{retention_ms: 2_000}
        }
      },
      policy: %{
        trusted_issuers: [ErlangAdkUi.TestAuthProvider.issuer()],
        required_scopes: %{
          list_agents: ["adk.agents.read"],
          start_run: ["adk.run.start"],
          observe_run: ["adk.run.read"],
          control_run: ["adk.run.control"],
          resume_run: ["adk.run.control"]
        }
      }
    }

    {:ok, gateway} = :adk_web_gateway.start_link(gateway_options)
    {:ok, %{gateway: gateway, agent: agent}}
  end

  def stop(%{gateway: gateway, agent: agent}) do
    if Process.alive?(gateway), do: GenServer.stop(gateway)
    send(agent, :stop)
    :ok
  end

  def app_name, do: @app_name

  defp agent_loop(mode, owner) do
    receive do
      {:"$gen_call", from, :get_runtime} ->
        tools = if mode in [:pause, :paused], do: [:adk_long_running_tool], else: []
        GenServer.reply(from, {:ok, "phoenix-test-agent", %{}, tools, %{}})
        agent_loop(mode, owner)

      {:"$gen_call", from, {:run_with_events, history, invocation_id}} ->
        run_agent_turn(mode, owner, from, history, invocation_id)

      :stop ->
        :ok

      _other ->
        agent_loop(mode, owner)
    end
  end

  defp run_agent_turn(:complete, owner, from, _history, invocation_id) do
    event =
      :adk_event.new("phoenix-test-agent", "Gateway response", %{
        invocation_id: invocation_id,
        is_final: true
      })

    GenServer.reply(from, {:ok, event})
    agent_loop(:complete, owner)
  end

  defp run_agent_turn(:block, owner, from, _history, invocation_id) do
    send(owner, {:agent_blocked, self()})

    receive do
      :release ->
        event =
          :adk_event.new("phoenix-test-agent", "Released response", %{
            invocation_id: invocation_id,
            is_final: true
          })

        GenServer.reply(from, {:ok, event})
        agent_loop(:block, owner)

      :stop ->
        GenServer.reply(from, {:error, :stopped})
        :ok
    end
  end

  defp run_agent_turn(:pause, owner, from, _history, invocation_id) do
    calls = [
      {"request_human_approval", %{"action_summary" => "Publish release"}, :undefined,
       "approval-call"}
    ]

    event =
      :adk_event.new("phoenix-test-agent", {:tool_calls, calls}, %{
        invocation_id: invocation_id
      })

    GenServer.reply(from, {:tool_calls, event, calls})
    agent_loop(:paused, owner)
  end

  defp run_agent_turn(:paused, owner, from, history, invocation_id) do
    encoded_history =
      Enum.map(history, fn event ->
        {:ok, encoded} = :adk_event.encode(event)
        encoded
      end)

    send(owner, {:resumed_history, encoded_history})

    event =
      :adk_event.new("phoenix-test-agent", "Decision applied", %{
        invocation_id: invocation_id,
        is_final: true
      })

    GenServer.reply(from, {:ok, event})
    agent_loop(:complete, owner)
  end
end
