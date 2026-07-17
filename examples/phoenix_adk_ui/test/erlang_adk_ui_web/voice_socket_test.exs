defmodule ErlangAdkUiWeb.VoiceSocketTest do
  use ErlangAdkUiWeb.ConnCase, async: false

  alias ErlangAdkUi.Auth.SessionStore
  alias ErlangAdkUiWeb.VoiceSocket

  setup do
    Application.put_env(:erlang_adk_ui, :test_live_gateway_pid, self())

    on_exit(fn ->
      Application.delete_env(:erlang_adk_ui, :test_live_gateway_pid)
      Application.delete_env(:erlang_adk_ui, :test_live_voice_mode)
      Application.delete_env(:erlang_adk_ui, :test_live_voice_state)
      Application.delete_env(:erlang_adk_ui, :test_live_voice_error)
      Application.delete_env(:erlang_adk_ui, :test_live_voice_input_sample_rate)
    end)

    :ok
  end

  test "the voice endpoint requires an authenticated web session", %{conn: conn} do
    conn = conn |> websocket_headers("http://www.example.com") |> get("/live/voice/live-alice")

    assert redirected_to(conn) == "/auth/login"
    refute_receive {:live_gateway, {:open_voice, _identity, _session_id, _owner, _options}}
  end

  test "the browser policy allows only same-origin microphone capture", %{conn: conn} do
    conn = get(conn, "/health")

    assert get_resp_header(conn, "permissions-policy") == [
             "camera=(), microphone=(self), geolocation=(), payment=()"
           ]
  end

  test "the voice endpoint rejects absent and cross-origin upgrades", %{conn: conn} do
    {conn, _handle, _context} = authenticated(conn)

    absent =
      conn
      |> websocket_headers(nil)
      |> get("/live/voice/live-alice")

    assert absent.status == 403

    cross_origin =
      conn
      |> websocket_headers("https://attacker.example")
      |> get("/live/voice/live-alice")

    assert cross_origin.status == 403
    refute_receive {:live_gateway, {:open_voice, _identity, _session_id, _owner, _options}}
  end

  test "a same-origin upgrade carries only the server session context and bounded options", %{
    conn: conn
  } do
    {conn, handle, context} = authenticated(conn)

    upgraded =
      conn
      |> websocket_headers("http://www.example.com")
      |> get("/live/voice/live-alice?principal=forged")

    assert upgraded.state == :upgraded
    {Plug.Adapters.Test.Conn, %{ref: adapter_ref}} = upgraded.adapter

    assert_receive {^adapter_ref, :upgrade,
                    {:websocket,
                     {VoiceSocket,
                      %{
                        auth_session_id: ^handle,
                        identity: identity,
                        session_id: "live-alice"
                      }, options}}}

    assert identity == context.identity
    assert options[:compress] == false
    assert options[:max_frame_size] == 65_536
    assert options[:timeout] == 60_000
    assert options[:max_heap_size].size == 200_000
  end

  test "binary frames re-fetch authorization and reach the gateway unchanged" do
    {initial, handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    frame = <<1, 2, 3, 4, 5>>
    assert {:ok, ^socket} = VoiceSocket.handle_in({frame, opcode: :binary}, socket)

    assert_receive {:live_gateway, {:voice_frame, identity, voice_ref, ^frame}}

    assert identity == context.identity
    assert voice_ref == socket.voice_ref
    assert {:ok, _context} = SessionStore.fetch_context(handle)

    VoiceSocket.terminate(:normal, socket)
    assert_receive {:live_gateway, {:close_voice, ^identity, ^voice_ref}}
  end

  test "text and oversized frames are rejected before the gateway" do
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    assert {:stop, :unsupported_data, {1003, "binary frames required"}, ^socket} =
             VoiceSocket.handle_in({"not audio", opcode: :text}, socket)

    oversized = :binary.copy(<<0>>, 64_016)

    assert {:stop, :frame_too_large, {1009, "frame too large"}, ^socket} =
             VoiceSocket.handle_in({oversized, opcode: :binary}, socket)

    refute_receive {:live_gateway, {:voice_frame, _identity, _voice_ref, _frame}}
    VoiceSocket.terminate(:normal, socket)
  end

  test "the trusted 24 kHz input config is the first unacknowledged binary frame" do
    Application.put_env(:erlang_adk_ui, :test_live_voice_input_sample_rate, 24_000)
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)

    assert_voice_open(context.identity, socket)
    VoiceSocket.terminate(:normal, socket)
  end

  test "the exact 64,000-byte PCM v1 boundary is accepted and one byte more is rejected" do
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    pcm = :binary.copy(<<0, 0>>, 32_000)
    boundary = <<1, 1, 1::64-big, 16_000::32-big, 1, pcm::binary>>
    assert byte_size(boundary) == 64_015

    assert {:ok, ^socket} = VoiceSocket.handle_in({boundary, opcode: :binary}, socket)

    assert_receive {:live_gateway, {:voice_frame, _identity, voice_ref, ^boundary}}

    assert voice_ref == socket.voice_ref

    over_boundary = <<boundary::binary, 0>>

    assert {:stop, :frame_too_large, {1009, "frame too large"}, ^socket} =
             VoiceSocket.handle_in({over_boundary, opcode: :binary}, socket)

    refute_receive {:live_gateway, {:voice_frame, _identity, _voice_ref, ^over_boundary}}
    VoiceSocket.terminate(:normal, socket)
  end

  test "session revocation closes the socket before another voice frame is admitted" do
    {initial, handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)
    :ok = SessionStore.revoke(handle)

    assert {:stop, :unauthenticated, {1008, "authentication expired"}, ^socket} =
             VoiceSocket.handle_in({<<1, 2>>, opcode: :binary}, socket)

    refute_receive {:live_gateway, {:voice_frame, _identity, _voice_ref, _frame}}
    VoiceSocket.terminate(:normal, socket)
    assert_receive {:live_gateway, {:close_voice, identity, _voice_ref}}
    assert identity == context.identity
  end

  test "session revocation is enforced on control traffic and the periodic auth check" do
    {initial, handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    assert {:ok, ^socket} = VoiceSocket.handle_control({<<>>, opcode: :ping}, socket)
    :ok = SessionStore.revoke(handle)

    assert {:stop, :unauthenticated, {1008, "authentication expired"}, ^socket} =
             VoiceSocket.handle_control({<<>>, opcode: :pong}, socket)

    assert {:stop, :unauthenticated, {1008, "authentication expired"}, ^socket} =
             VoiceSocket.handle_info(:voice_auth_revalidate, socket)

    bridge_monitor = Process.monitor(socket.bridge)
    VoiceSocket.terminate(:normal, socket)
    assert_receive {:live_gateway, {:close_voice, identity, voice_ref}}
    assert identity == context.identity
    assert voice_ref == socket.voice_ref
    assert_receive {:DOWN, ^bridge_monitor, :process, _bridge, :normal}
  end

  test "manual activity detection is rejected with a stable browser-voice error" do
    Application.put_env(:erlang_adk_ui, :test_live_voice_mode, :manual)
    {initial, _handle, context} = voice_state()

    assert {:stop, :automatic_activity_detection_required,
            {1008, "automatic activity detection required"}, %{}} = VoiceSocket.init(initial)

    assert_receive {:live_gateway,
                    {:open_voice, identity, "live-alice", owner,
                     %{credit: %{messages: 8, bytes: 262_144}, max_audio_frame_bytes: 64_000}}}

    assert identity == context.identity
    assert owner == self()
    refute_receive {:live_gateway, {:voice_opened, _session_id, _voice_ref, _bridge}}
  end

  test "a non-active Live session is rejected with a stable retryable error" do
    Application.put_env(:erlang_adk_ui, :test_live_voice_state, :reconnecting)
    {initial, _handle, context} = voice_state()

    assert {:stop, :voice_session_not_active, {1013, "voice session not active"}, %{}} =
             VoiceSocket.init(initial)

    assert_receive {:live_gateway,
                    {:open_voice, identity, "live-alice", owner,
                     %{credit: %{messages: 8, bytes: 262_144}, max_audio_frame_bytes: 64_000}}}

    assert identity == context.identity
    assert owner == self()
    refute_receive {:live_gateway, {:voice_opened, _session_id, _voice_ref, _bridge}}
  end

  test "an exclusive voice lease conflict is a retryable capacity error" do
    Application.put_env(
      :erlang_adk_ui,
      :test_live_voice_error,
      :live_voice_bridge_already_attached
    )

    {initial, _handle, context} = voice_state()

    assert {:stop, :voice_busy, {1013, "voice session already in use"}, %{}} =
             VoiceSocket.init(initial)

    assert_receive {:live_gateway, {:open_voice, identity, "live-alice", owner, _options}}
    assert identity == context.identity
    assert owner == self()
  end

  test "client framing, ordering and acknowledgement errors use protocol close code 1002" do
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    for reason <- [
          :invalid_live_voice_frame,
          :invalid_live_voice_audio,
          :invalid_live_voice_frame_limit,
          :unknown_live_voice_event_sequence,
          {:out_of_order_live_voice_audio, 2},
          {:unexpected_live_voice_input_sample_rate, 24_000},
          {:invalid_live_voice_audio, :invalid_audio_size}
        ] do
      failing = %{socket | voice_ref: {:force_error, reason}}

      assert {:stop, :voice_protocol_error, {1002, "invalid voice protocol frame"}, ^failing} =
               VoiceSocket.handle_in({<<1, 2>>, opcode: :binary}, failing)
    end

    VoiceSocket.terminate(:normal, socket)
  end

  test "only the matching bridge can push binary output and termination cleans it up" do
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    assert {:ok, ^socket} =
             VoiceSocket.handle_info(
               {:adk_live_voice_frame, spawn(fn -> :ok end), <<9>>},
               socket
             )

    output = :binary.copy(<<5>>, 70_000)

    assert {:push, {:binary, ^output}, ^socket} =
             VoiceSocket.handle_info(
               {:adk_live_voice_frame, socket.bridge, output},
               socket
             )

    oversized_output = :binary.copy(<<6>>, 262_145)

    assert {:stop, :frame_too_large, {1009, "frame too large"}, ^socket} =
             VoiceSocket.handle_info(
               {:adk_live_voice_frame, socket.bridge, oversized_output},
               socket
             )

    bridge_monitor = Process.monitor(socket.bridge)
    VoiceSocket.terminate(:normal, socket)

    assert_receive {:live_gateway, {:close_voice, identity, voice_ref}}

    assert identity == context.identity
    assert voice_ref == socket.voice_ref
    assert_receive {:DOWN, ^bridge_monitor, :process, _bridge, :normal}
  end

  test "a dropped or exited bridge closes safely" do
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    assert {:stop, :voice_dropped, {1011, "voice stream closed"}, ^socket} =
             VoiceSocket.handle_info(
               {:adk_live_voice_dropped, socket.bridge, :subscriber_backpressure},
               socket
             )

    Process.exit(socket.bridge, :kill)

    assert_receive {:DOWN, monitor, :process, bridge, :killed}
    assert monitor == socket.monitor
    assert bridge == socket.bridge

    assert {:stop, :voice_bridge_down, {1011, "voice stream closed"}, ^socket} =
             VoiceSocket.handle_info({:DOWN, monitor, :process, bridge, :killed}, socket)

    VoiceSocket.terminate(:normal, socket)
  end

  test "a reconnect-required bridge result uses the retryable service-restart close" do
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)

    reconnecting = %{socket | voice_ref: {:force_error, :live_voice_reconnect_required}}

    assert {:stop, :live_voice_reconnect_required, {1012, "live session reconnecting"},
            ^reconnecting} =
             VoiceSocket.handle_in({<<1, 2>>, opcode: :binary}, reconnecting)

    assert {:stop, :live_voice_reconnect_required, {1012, "live session reconnecting"}, ^socket} =
             VoiceSocket.handle_info(
               {:DOWN, socket.monitor, :process, socket.bridge,
                {:shutdown, :live_voice_reconnect_required}},
               socket
             )

    VoiceSocket.terminate(:normal, socket)
  end

  test "an ambiguous core outcome closes explicitly to prevent client retries" do
    {initial, _handle, context} = voice_state()
    {:ok, socket} = VoiceSocket.init(initial)
    assert_voice_open(context.identity, socket)
    ambiguous = %{socket | voice_ref: {:force_error, :live_voice_outcome_unknown}}

    assert {:stop, :live_voice_outcome_unknown, {1011, "voice outcome unknown"}, ^ambiguous} =
             VoiceSocket.handle_in({<<1, 2>>, opcode: :binary}, ambiguous)

    assert {:stop, :live_voice_outcome_unknown, {1011, "voice outcome unknown"}, ^socket} =
             VoiceSocket.handle_info(
               {:DOWN, socket.monitor, :process, socket.bridge,
                {:shutdown, :live_voice_outcome_unknown}},
               socket
             )

    VoiceSocket.terminate(:normal, socket)
  end

  defp authenticated(conn, subject \\ "alice") do
    {:ok, handle} = SessionStore.issue(ErlangAdkUi.TestAuthProvider.identity(subject))
    {:ok, context} = SessionStore.fetch_context(handle)
    {init_test_session(conn, %{"auth_session_id" => handle}), handle, context}
  end

  defp voice_state(subject \\ "alice") do
    {:ok, handle} = SessionStore.issue(ErlangAdkUi.TestAuthProvider.identity(subject))
    {:ok, context} = SessionStore.fetch_context(handle)

    {
      %{
        auth_session_id: handle,
        identity: context.identity,
        session_id: "live-#{subject}"
      },
      handle,
      context
    }
  end

  defp assert_voice_open(identity, socket) do
    assert_receive {:live_gateway,
                    {:open_voice, opened_identity, "live-alice", owner,
                     %{
                       credit: %{messages: 8, bytes: 262_144},
                       max_audio_frame_bytes: 64_000
                     }}}

    assert opened_identity == identity
    assert owner == self()

    assert_receive {:live_gateway, {:voice_opened, "live-alice", voice_ref, bridge}}

    assert voice_ref == socket.voice_ref
    assert bridge == socket.bridge

    input_sample_rate =
      Application.get_env(:erlang_adk_ui, :test_live_voice_input_sample_rate, 16_000)

    assert_receive {:adk_live_voice_frame, ^bridge,
                    <<1, 128, ^input_sample_rate::unsigned-big-integer-size(32), 1, 1>> =
                      config_frame}

    assert {:push, {:binary, ^config_frame}, ^socket} =
             VoiceSocket.handle_info({:adk_live_voice_frame, bridge, config_frame}, socket)
  end

  defp websocket_headers(conn, origin) do
    conn =
      %{
        conn
        | host: "www.example.com",
          req_headers: [{"host", "www.example.com"} | conn.req_headers]
      }
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", Base.encode64(:binary.copy(<<7>>, 16)))
      |> put_req_header("sec-websocket-version", "13")

    if is_binary(origin), do: put_req_header(conn, "origin", origin), else: conn
  end
end
