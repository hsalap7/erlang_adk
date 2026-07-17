defmodule ErlangAdkUiWeb.AgentLiveTest do
  use ErlangAdkUiWeb.ConnCase, async: false

  alias ErlangAdkUi.Auth.SessionStore
  alias ErlangAdkUi.TestGatewayFixture

  setup context do
    :ok = :erlang_adk_session.init()
    {:ok, fixture} = TestGatewayFixture.start(mode: Map.get(context, :agent_mode, :complete))
    on_exit(fn -> TestGatewayFixture.stop(fixture) end)
    {:ok, fixture: fixture}
  end

  test "unauthenticated requests never mount the LiveView", %{conn: conn} do
    conn = get(conn, ~p"/agent")
    assert redirected_to(conn) == ~p"/auth/login"
  end

  test "a run uses only server-derived principal and session identifiers", %{conn: conn} do
    {conn, handle, context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")

    render_submit(view, "start", %{
      "agent" => "assistant",
      "message" => "hello",
      "user_id" => "browser-forged-user",
      "session_id" => "browser-forged-session"
    })

    assert eventually(fn -> render(view) =~ "Gateway response" end)

    assert {:ok, _session} =
             :erlang_adk_session.get_session(
               TestGatewayFixture.app_name(),
               context.identity.principal,
               context.agent_session_id
             )

    assert {:error, :not_found} =
             :erlang_adk_session.get_session(
               TestGatewayFixture.app_name(),
               "browser-forged-user",
               "browser-forged-session"
             )

    :ok = SessionStore.revoke(handle)
  end

  test "start reauthorizes against the server-side session", %{conn: conn} do
    {conn, handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")
    :ok = SessionStore.revoke(handle)

    view
    |> form("#prompt-form", %{"agent" => "assistant", "message" => "hello"})
    |> render_submit()

    assert_redirect(view, ~p"/auth/login")
  end

  @tag agent_mode: :block
  test "cancel reauthorizes against the server-side session", %{conn: conn, fixture: fixture} do
    {conn, handle, context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> form("#prompt-form", %{"agent" => "assistant", "message" => "block"})
    |> render_submit()

    assert has_element?(view, "button[phx-click=cancel]")
    assert_receive {:agent_blocked, agent}, 1_000
    %{ui: %{run_id: run_id}} = wait_for_run(handle)
    wait_for_stream_cursor(handle, context.identity, run_id)
    :ok = SessionStore.revoke(handle)
    view |> element("button[phx-click=cancel]") |> render_click()
    assert_redirect(view, ~p"/auth/login")
    assert agent == fixture.agent
    send(agent, :release)
    assert {:completed, "Released response"} = :adk_run.await(run_id, 1_000)
  end

  @tag agent_mode: :block
  test "an authorized cancel reaches a terminal state", %{conn: conn} do
    {conn, _handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")
    start(view, "block")

    assert has_element?(view, "button[phx-click=cancel]")
    view |> element("button[phx-click=cancel]") |> render_click()
    assert eventually(fn -> render(view) =~ "Run cancelled." end)
  end

  @tag agent_mode: :block
  test "a second mount reconnects with the server cursor and completes through credit and ack", %{
    conn: conn,
    fixture: fixture
  } do
    {conn, handle, _context} = authenticated(conn)
    {:ok, first_view, _html} = live(conn, ~p"/agent")
    start(first_view, "block")
    assert_receive {:agent_blocked, agent}, 1_000
    assert agent == fixture.agent
    %{ui: %{run_id: run_id, cursor: cursor}} = wait_for_run(handle)

    {:ok, reconnected_view, html} = live(conn, ~p"/agent")
    assert html =~ run_id
    assert cursor >= 0
    assert has_element?(reconnected_view, "button[phx-click=cancel]")

    send(agent, :release)
    assert eventually(fn -> render(reconnected_view) =~ "Released response" end)
  end

  @tag agent_mode: :block
  test "a stolen reconnect run id is hidden from another principal", %{
    conn: conn,
    fixture: fixture
  } do
    {alice_conn, alice_handle, _context} = authenticated(conn, "alice")
    {:ok, alice_view, _html} = live(alice_conn, ~p"/agent")
    start(alice_view, "block")
    assert_receive {:agent_blocked, agent}, 1_000
    %{ui: %{run_id: run_id}} = wait_for_run(alice_handle)

    {bob_conn, bob_handle, _context} = authenticated(build_conn(), "bob")
    :ok = SessionStore.save_run(bob_handle, run_id, 0)
    {:ok, _bob_view, html} = live(bob_conn, ~p"/agent")

    refute html =~ run_id
    assert html =~ "The previous run is no longer available."
    assert {:ok, %{ui: %{run_id: nil}}} = SessionStore.fetch_context(bob_handle)
    assert agent == fixture.agent
    send(agent, :release)
    assert {:completed, "Released response"} = :adk_run.await(run_id, 1_000)
  end

  @tag agent_mode: :block
  test "a replay gap stops the stream and clears reconnect state", %{conn: conn, fixture: fixture} do
    {conn, handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")
    start(view, "block")
    assert_receive {:agent_blocked, agent}, 1_000
    %{ui: %{run_id: run_id}} = wait_for_run(handle)

    send(view.pid, {:adk_run_replay_gap, run_id, %{after_sequence: 0}})

    assert eventually(fn -> render(view) =~ "retained event window was exceeded" end)
    assert {:ok, %{ui: %{run_id: nil, cursor: 0}}} = SessionStore.fetch_context(handle)
    assert agent == fixture.agent
    send(agent, :release)
    assert {:completed, "Released response"} = :adk_run.await(run_id, 1_000)
  end

  @tag agent_mode: :pause
  test "human decisions reauthorize and ignore forged principal fields", %{conn: conn} do
    {conn, handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> form("#prompt-form", %{"agent" => "assistant", "message" => "pause"})
    |> render_submit()

    assert eventually(fn -> has_element?(view, "#approval-panel") end)
    :ok = SessionStore.revoke(handle)

    view
    |> element("button[phx-click=decide][phx-value-decision=approve]")
    |> render_click(%{"principal" => "browser-forged-user"})

    assert_redirect(view, ~p"/auth/login")
  end

  @tag agent_mode: :pause
  test "human approval uses a typed boolean and the server principal", %{conn: conn} do
    {conn, _handle, context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")
    start(view, "pause")
    assert eventually(fn -> has_element?(view, "#approval-panel") end)

    render_click(view, "decide", %{
      "decision" => "approve",
      "principal" => "browser-forged-user"
    })

    assert_receive {:resumed_history, history}, 1_000
    assert deep_pair?(history, "approved", true)
    assert deep_pair?(history, "approver", context.identity.principal)
    refute deep_pair?(history, "approver", "browser-forged-user")
    assert eventually(fn -> render(view) =~ "Decision applied" end)
  end

  @tag agent_mode: :pause
  test "human rejection remains boolean false", %{conn: conn} do
    {conn, _handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")
    start(view, "pause")
    assert eventually(fn -> has_element?(view, "#approval-panel") end)

    view
    |> element("button[phx-click=decide][phx-value-decision=reject]")
    |> render_click()

    assert_receive {:resumed_history, history}, 1_000
    assert deep_pair?(history, "approved", false)
    assert eventually(fn -> render(view) =~ "Decision applied" end)
  end

  @tag agent_mode: :block
  test "a revoked session cannot receive terminal output", %{conn: conn, fixture: fixture} do
    {conn, handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> form("#prompt-form", %{"agent" => "assistant", "message" => "block"})
    |> render_submit()

    assert has_element?(view, "button[phx-click=cancel]")
    assert_receive {:agent_blocked, agent}, 1_000
    assert agent == fixture.agent
    :ok = SessionStore.revoke(handle)
    send(agent, :release)

    assert_redirect(view, ~p"/auth/login")
  end

  defp authenticated(conn, subject \\ "alice") do
    {:ok, handle} = SessionStore.issue(ErlangAdkUi.TestAuthProvider.identity(subject))
    {:ok, context} = SessionStore.fetch_context(handle)
    {init_test_session(conn, %{"auth_session_id" => handle}), handle, context}
  end

  defp start(view, message) do
    view
    |> form("#prompt-form", %{"agent" => "assistant", "message" => message})
    |> render_submit()
  end

  defp wait_for_run(handle) do
    assert eventually(fn ->
             case SessionStore.fetch_context(handle) do
               {:ok, %{ui: %{run_id: run_id}}} when is_binary(run_id) -> true
               _other -> false
             end
           end)

    {:ok, context} = SessionStore.fetch_context(handle)
    context
  end

  defp wait_for_stream_cursor(handle, identity, run_id) do
    assert eventually(fn ->
             case :adk_web_gateway.status(ErlangAdkUi.TestGateway, identity, run_id) do
               {:ok, %{event_count: count}} when is_integer(count) and count > 0 -> true
               _other -> false
             end
           end)

    probe =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    try do
      assert {:ok, %{latest_sequence: latest}} =
               :adk_web_gateway.subscribe_credit(
                 ErlangAdkUi.TestGateway,
                 identity,
                 run_id,
                 probe,
                 0
               )

      assert latest > 0

      assert eventually(fn ->
               match?(
                 {:ok, %{ui: %{run_id: ^run_id, cursor: ^latest}}},
                 SessionStore.fetch_context(handle)
               )
             end)
    after
      _ = :adk_web_gateway.unsubscribe(ErlangAdkUi.TestGateway, identity, run_id, probe)
      send(probe, :stop)
    end
  end

  defp deep_pair?(value, key, expected) when is_map(value) do
    Map.get(value, key) == expected or
      Enum.any?(value, fn {_map_key, item} -> deep_pair?(item, key, expected) end)
  end

  defp deep_pair?(value, key, expected) when is_list(value),
    do: Enum.any?(value, &deep_pair?(&1, key, expected))

  defp deep_pair?(_value, _key, _expected), do: false

  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(fun, deadline)
      else
        false
      end
    end
  end
end
