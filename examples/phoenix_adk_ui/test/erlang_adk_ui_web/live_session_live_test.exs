defmodule ErlangAdkUiWeb.LiveSessionLiveTest do
  use ErlangAdkUiWeb.ConnCase, async: false

  alias ErlangAdkUi.Auth.SessionStore
  alias ErlangAdkUi.TestGatewayFixture

  setup do
    :ok = :erlang_adk_session.init()
    {:ok, fixture} = TestGatewayFixture.start()
    Application.put_env(:erlang_adk_ui, :test_live_gateway_pid, self())

    on_exit(fn ->
      Application.delete_env(:erlang_adk_ui, :test_live_gateway_pid)
      TestGatewayFixture.stop(fixture)
    end)

    :ok
  end

  test "discovery is principal scoped and browser identity fields are ignored", %{conn: conn} do
    {conn, _handle, context} = authenticated(conn, "alice")
    {:ok, view, html} = live(conn, ~p"/live")

    assert_receive {:live_gateway, {:discover, discovered_identity}}, 1_000
    assert discovered_identity == context.identity
    assert html =~ "live-alice"
    refute html =~ "live-bob"
    assert html =~ "future events only"

    render_submit(view, "attach", %{
      "session_id" => "live-alice",
      "principal" => "browser-forged-principal",
      "module" => "Elixir.System"
    })

    assert_receive {:live_gateway,
                    {:attach, attached_identity, "live-alice", subscriber,
                     %{messages: 8, bytes: 262_144}}},
                   1_000

    assert attached_identity == context.identity
    assert subscriber == view.pid

    assert_receive {:live_gateway,
                    {:attached, "live-alice", {ErlangAdkUi.TestLiveGateway, "live-alice", token},
                     token}},
                   1_000

    assert has_element?(view, "#live-attachment")
  end

  test "realtime text reauthorizes and carries only the server identity", %{conn: conn} do
    {conn, _handle, context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/live")
    {attachment_ref, _event_token} = attach(view)

    render_submit(view, "live-text", %{
      "text" => "hello live",
      "principal" => "forged",
      "session_id" => "live-bob"
    })

    assert_receive {:live_gateway, {:send_text, identity, ^attachment_ref, "hello live"}},
                   1_000

    assert identity == context.identity

    render_submit(view, "live-text", %{"text" => "busy"})
    assert render(view) =~ "input window is full"
  end

  test "audio is projected to metadata, raw bytes never enter assigns, and credit is acked", %{
    conn: conn
  } do
    {conn, _handle, context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/live")
    {attachment_ref, event_token} = attach(view)

    raw = "RAW_AUDIO_SHOULD_NEVER_RENDER!"
    raw = if rem(byte_size(raw), 2) == 0, do: raw, else: raw <> "!"
    {:ok, media} = :adk_live_media.audio_pcm(raw, 24_000, 1)
    event = live_event(:audio, media, 1)
    send(view.pid, {:adk_live_event, event_token, "live-alice", 1, event})

    assert_receive {:live_gateway, {:ack, identity, ^attachment_ref, subscriber, 1}},
                   1_000

    assert identity == context.identity
    assert subscriber == view.pid

    html = render(view)
    assert html =~ "media_omitted"
    assert html =~ Integer.to_string(byte_size(raw))
    refute html =~ raw
    assert :binary.match(:erlang.term_to_binary(:sys.get_state(view.pid)), raw) == :nomatch

    transcription =
      live_event(:output_transcription, %{text: "Hello from Live", final: true}, 2)

    send(view.pid, {:adk_live_event, event_token, "live-alice", 2, transcription})

    assert_receive {:live_gateway, {:ack, ^identity, ^attachment_ref, ^subscriber, 2}},
                   1_000

    assert render(view) =~ "Hello from Live"
  end

  test "revocation prevents event ack and redirects before content is rendered", %{conn: conn} do
    {conn, handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/live")
    {_attachment_ref, event_token} = attach(view)
    :ok = SessionStore.revoke(handle)

    event = live_event(:output_transcription, %{text: "must stay hidden", final: true}, 1)
    send(view.pid, {:adk_live_event, event_token, "live-alice", 1, event})

    assert_redirect(view, ~p"/auth/login")
    refute_receive {:live_gateway, {:ack, _identity, _session, _subscriber, 1}}, 100
  end

  test "the rendered event window stays bounded while every accepted projection returns credit",
       %{
         conn: conn
       } do
    original = Application.fetch_env!(:erlang_adk_ui, :ui_limits)
    limits = Keyword.put(original, :max_live_events, 2)
    Application.put_env(:erlang_adk_ui, :ui_limits, limits)
    on_exit(fn -> Application.put_env(:erlang_adk_ui, :ui_limits, original) end)

    {conn, _handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/live")
    {attachment_ref, event_token} = attach(view)

    for sequence <- 1..3 do
      event =
        live_event(:output_transcription, %{text: "message #{sequence}", final: true}, sequence)

      send(view.pid, {:adk_live_event, event_token, "live-alice", sequence, event})

      assert_receive {:live_gateway, {:ack, _identity, ^attachment_ref, _subscriber, ^sequence}},
                     1_000
    end

    html = render(view)
    refute html =~ "message 1"
    assert html =~ "message 2"
    assert html =~ "message 3"
    assert html =~ "1 event(s) were omitted"
  end

  test "LiveView termination explicitly detaches the subscription", %{conn: conn} do
    {conn, _handle, context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/live")
    {attachment_ref, _event_token} = attach(view)
    Process.unlink(view.pid)
    GenServer.stop(view.pid, :normal)

    assert_receive {:live_gateway, {:detach, identity, ^attachment_ref, subscriber}},
                   1_000

    assert identity == context.identity
    assert subscriber == view.pid
  end

  test "observability and evaluation views are bounded server callbacks without paths or modules",
       %{
         conn: conn
       } do
    {conn, _handle, context} = authenticated(conn)
    {:ok, view, html} = live(conn, ~p"/live")

    assert_receive {:live_gateway, {:observability_snapshot, observed_identity}}, 1_000
    assert observed_identity == context.identity
    assert html =~ "request_count"
    assert html =~ "binary payload omitted"
    refute html =~ "RAW_OBSERVABILITY_PAYLOAD"
    refute html =~ "SUPER_SECRET_KEY"

    render_submit(view, "show-evaluation", %{
      "report_id" => "baseline",
      "path" => "/etc/passwd",
      "module" => "Elixir.System"
    })

    assert_receive {:live_gateway, {:evaluation_report, report_identity, "baseline"}}, 1_000
    assert report_identity == context.identity
    assert render(view) =~ "Evaluation baseline"

    render_submit(view, "compare-evaluations", %{
      "baseline_id" => "baseline",
      "current_id" => "current",
      "path" => "/tmp/forged.json"
    })

    assert_receive {:live_gateway,
                    {:compare_evaluations, comparison_identity, "baseline", "current"}},
                   1_000

    assert comparison_identity == context.identity
    assert render(view) =~ "Baseline comparison"
  end

  test "a session identifier not returned by discovery is never sent to the gateway", %{
    conn: conn
  } do
    {conn, _handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/live")
    flush_gateway_messages()

    render_submit(view, "attach", %{"session_id" => "live-bob"})

    assert render(view) =~ "could not be attached"
    refute_receive {:live_gateway, {:attach, _identity, "live-bob", _subscriber, _credit}}, 100
  end

  test "queued events from a detached generation cannot affect a same-id reattachment", %{
    conn: conn
  } do
    {conn, _handle, _context} = authenticated(conn)
    {:ok, view, _html} = live(conn, ~p"/live")
    {old_attachment, old_token} = attach(view)

    render_click(view, "detach")
    assert_receive {:live_gateway, {:detach, _identity, ^old_attachment, _subscriber}}, 1_000

    {new_attachment, new_token} = attach(view)
    refute old_token == new_token
    stale = live_event(:output_transcription, %{text: "stale generation", final: true}, 1)
    send(view.pid, {:adk_live_event, old_token, "live-alice", 1, stale})
    refute render(view) =~ "stale generation"
    refute_receive {:live_gateway, {:ack, _identity, ^new_attachment, _subscriber, 1}}, 100

    current = live_event(:output_transcription, %{text: "current generation", final: true}, 1)
    send(view.pid, {:adk_live_event, new_token, "live-alice", 1, current})
    assert_receive {:live_gateway, {:ack, _identity, ^new_attachment, _subscriber, 1}}, 1_000
    assert render(view) =~ "current generation"
  end

  defp authenticated(conn, subject \\ "alice") do
    {:ok, handle} = SessionStore.issue(ErlangAdkUi.TestAuthProvider.identity(subject))
    {:ok, context} = SessionStore.fetch_context(handle)
    {init_test_session(conn, %{"auth_session_id" => handle}), handle, context}
  end

  defp attach(view) do
    flush_gateway_messages()
    render_submit(view, "attach", %{"session_id" => "live-alice"})

    assert_receive {:live_gateway, {:attach, _identity, "live-alice", _subscriber, _credit}},
                   1_000

    assert_receive {:live_gateway, {:attached, "live-alice", attachment_ref, event_token}}, 1_000
    {attachment_ref, event_token}
  end

  defp live_event(kind, payload, sequence) do
    {:ok, base} = :adk_live_event.new(kind, payload)
    {:ok, event} = :adk_live_event.with_envelope(base, sequence, 0, 0)
    event
  end

  defp flush_gateway_messages do
    receive do
      {:live_gateway, _message} -> flush_gateway_messages()
    after
      0 -> :ok
    end
  end
end
