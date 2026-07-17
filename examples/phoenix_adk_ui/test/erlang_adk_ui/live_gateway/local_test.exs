defmodule ErlangAdkUi.LiveGateway.LocalTest do
  use ExUnit.Case, async: false

  alias ErlangAdkUi.LiveGateway.Local

  test "each operations surface requires its explicit server-side scope" do
    identity = %{principal: "principal", scopes: []}

    assert {:error, :forbidden} = Local.discover(identity)
    assert {:error, :forbidden} = Local.send_text(identity, "session", "hello")
    assert {:error, :forbidden} = Local.open_voice(identity, "session", self(), %{})
    assert {:error, :forbidden} = Local.voice_frame(identity, make_ref(), <<1, 2>>)
    assert {:error, :forbidden} = Local.close_voice(identity, make_ref())
    assert {:error, :forbidden} = Local.observability_snapshot(identity)
    assert {:error, :forbidden} = Local.list_evaluations(identity)
  end

  test "evaluation catalog accepts only a bounded server-configured map" do
    original = Application.fetch_env!(:erlang_adk_ui, :evaluation_reports)
    identity = %{principal: "principal", scopes: ["adk.evaluation.read"]}

    on_exit(fn -> Application.put_env(:erlang_adk_ui, :evaluation_reports, original) end)

    Application.put_env(:erlang_adk_ui, :evaluation_reports, [])
    assert {:error, :invalid_evaluation_catalog} = Local.list_evaluations(identity)

    Application.put_env(:erlang_adk_ui, :evaluation_reports, %{})
    assert {:ok, []} = Local.list_evaluations(identity)
  end

  test "public session identifiers cannot be reused as post-attach handles" do
    identity = %{
      principal: "principal",
      scopes: ["adk.live.read", "adk.live.control"]
    }

    assert {:error, :not_found} = Local.send_text(identity, "public-session-id", "hello")
    assert {:error, :not_found} = Local.ack(identity, "public-session-id", self(), 1)
    assert {:error, :not_found} = Local.detach(identity, "public-session-id", self())
  end

  test "voice bridge options are exact and opaque refs remain owner bound" do
    identity = %{
      principal: "principal",
      scopes: ["adk.live.read", "adk.live.control"]
    }

    assert {:error, :invalid_request} =
             Local.open_voice(identity, "session", self(), %{browser_selected: true})

    bridge = spawn(fn -> Process.sleep(:infinity) end)
    voice_ref = {Local, :voice, bridge, self(), identity.principal, make_ref()}

    assert {:error, :not_found} =
             Task.async(fn -> Local.voice_frame(identity, voice_ref, <<1, 2>>) end)
             |> Task.await()

    assert {:error, :not_found} =
             Task.async(fn -> Local.close_voice(identity, voice_ref) end)
             |> Task.await()

    Process.exit(bridge, :kill)
  end

  test "each voice frame and close requires both Live scopes" do
    control_only = %{principal: "principal", scopes: ["adk.live.control"]}
    read_only = %{principal: "principal", scopes: ["adk.live.read"]}

    assert {:error, :forbidden} = Local.voice_frame(control_only, make_ref(), <<1, 2>>)
    assert {:error, :forbidden} = Local.close_voice(control_only, make_ref())
    assert {:error, :forbidden} = Local.voice_frame(read_only, make_ref(), <<1, 2>>)
    assert {:error, :forbidden} = Local.close_voice(read_only, make_ref())
  end

  test "browser voice requires an active automatic-VAD session and exposes bounded status" do
    {session_id, session, transport} = start_live_session(true)
    identity = live_identity()

    on_exit(fn ->
      _ = :erlang_adk.close_live_session(session, identity.principal, :test_complete)
    end)

    assert {:error, :voice_session_not_active} =
             Local.open_voice(identity, session_id, self(), voice_options())

    :ok = ErlangAdkUi.TestLiveTransport.inject(transport, %{"setupComplete" => %{}})
    assert eventually(fn -> active_session?(identity, session_id, "automatic") end)

    assert {:ok, %{voice_ref: voice_ref, bridge: bridge}} =
             Local.open_voice(identity, session_id, self(), voice_options())

    assert is_pid(bridge)
    assert :ok = Local.close_voice(identity, voice_ref)
  end

  test "manual-VAD sessions remain discoverable but browser voice fails with a stable error" do
    {session_id, session, transport} = start_live_session(false)
    identity = live_identity()

    on_exit(fn ->
      _ = :erlang_adk.close_live_session(session, identity.principal, :test_complete)
    end)

    :ok = ErlangAdkUi.TestLiveTransport.inject(transport, %{"setupComplete" => %{}})
    assert eventually(fn -> active_session?(identity, session_id, "manual") end)

    assert {:error, :automatic_activity_detection_required} =
             Local.open_voice(identity, session_id, self(), voice_options())
  end

  defp start_live_session(automatic_activity_detection) do
    session_id = "phoenix-voice-#{System.unique_integer([:positive, :monotonic])}"
    identity = live_identity()

    config = %{
      provider: :adk_live_gemini,
      provider_config: %{
        automatic_activity_detection: automatic_activity_detection,
        model: "gemini-3.1-flash-live-preview",
        response_modalities: [:audio]
      },
      transport: ErlangAdkUi.TestLiveTransport,
      transport_opts: %{test_pid: self()}
    }

    assert {:ok, session} =
             :erlang_adk.start_live_session(session_id, identity.principal, config)

    assert_receive {:test_live_transport, :opened, transport}
    assert_receive {:test_live_transport, :sent, ^transport, setup_frame}
    assert is_binary(setup_frame)
    {session_id, session, transport}
  end

  defp live_identity do
    %{
      principal: "principal",
      scopes: ["adk.live.read", "adk.live.control"]
    }
  end

  defp voice_options do
    %{
      credit: %{messages: 8, bytes: 262_144},
      max_audio_frame_bytes: 64_000
    }
  end

  defp active_session?(identity, session_id, expected_mode) do
    case Local.discover(identity) do
      {:ok, sessions} ->
        Enum.any?(sessions, fn status ->
          status.id == session_id and status.state == "active" and
            status.voice_mode == expected_mode
        end)

      _error ->
        false
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
