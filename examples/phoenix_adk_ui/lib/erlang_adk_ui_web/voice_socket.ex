defmodule ErlangAdkUiWeb.VoiceSocket do
  @moduledoc """
  Authenticated, binary-only browser transport for one server-owned Live voice bridge.

  The socket never accepts a principal, provider, model, API key, module, or transport
  option from the browser. The opaque bridge reference remains in process state, and
  every media frame re-fetches the server-side web session before the gateway is called.
  """

  @behaviour WebSock

  alias ErlangAdkUi.Auth.SessionStore
  alias ErlangAdkUi.LiveGateway

  @max_audio_payload_bytes 64_000
  @audio_frame_header_bytes 15
  @max_client_frame_bytes @max_audio_payload_bytes + @audio_frame_header_bytes
  @max_output_frame_bytes 262_144
  @idle_timeout_ms 60_000
  @auth_revalidation_ms 15_000
  @credit %{messages: 8, bytes: 262_144}

  @doc false
  def connection_options do
    [
      compress: false,
      max_frame_size: 65_536,
      timeout: @idle_timeout_ms,
      fullsweep_after: 10,
      max_heap_size: %{
        size: 200_000,
        kill: true,
        error_logger: false,
        include_shared_binaries: true
      },
      validate_utf8: true
    ]
  end

  @impl true
  def init(%{
        auth_session_id: auth_session_id,
        identity: initial_identity,
        session_id: session_id
      }) do
    with {:ok, identity} <- current_identity(auth_session_id, initial_identity),
         {:ok, %{voice_ref: voice_ref, bridge: bridge}}
         when is_pid(bridge) <-
           LiveGateway.open_voice(identity, session_id, self(), voice_options()) do
      monitor = Process.monitor(bridge)
      auth_timer = schedule_auth_revalidation()

      {:ok,
       %{
         auth_timer: auth_timer,
         auth_session_id: auth_session_id,
         bridge: bridge,
         identity: identity,
         monitor: monitor,
         voice_ref: voice_ref
       }}
    else
      error -> init_error(error)
    end
  end

  @impl true
  def handle_in({frame, opcode: :binary}, state)
      when is_binary(frame) and byte_size(frame) <= @max_client_frame_bytes do
    with {:ok, identity} <- current_identity(state.auth_session_id, state.identity),
         :ok <- LiveGateway.voice_frame(identity, state.voice_ref, frame) do
      {:ok, state}
    else
      error -> frame_error(error, state)
    end
  end

  def handle_in({frame, opcode: :binary}, state) when is_binary(frame),
    do: {:stop, :frame_too_large, {1009, "frame too large"}, state}

  def handle_in({_frame, opcode: :text}, state),
    do: {:stop, :unsupported_data, {1003, "binary frames required"}, state}

  def handle_in(_frame, state),
    do: {:stop, :unsupported_data, {1003, "binary frames required"}, state}

  @impl true
  def handle_control({_payload, opcode: opcode}, state) when opcode in [:ping, :pong] do
    case current_identity(state.auth_session_id, state.identity) do
      {:ok, _identity} -> {:ok, state}
      {:error, _reason} -> authentication_expired(state)
    end
  end

  @impl true
  def handle_info(
        {:adk_live_voice_frame, bridge, frame},
        %{bridge: bridge} = state
      )
      when is_binary(frame) and byte_size(frame) <= @max_output_frame_bytes do
    case current_identity(state.auth_session_id, state.identity) do
      {:ok, _identity} -> {:push, {:binary, frame}, state}
      {:error, _reason} -> authentication_expired(state)
    end
  end

  def handle_info(
        {:adk_live_voice_frame, bridge, frame},
        %{bridge: bridge} = state
      )
      when is_binary(frame),
      do: {:stop, :frame_too_large, {1009, "frame too large"}, state}

  def handle_info({:adk_live_voice_dropped, bridge, _reason}, %{bridge: bridge} = state),
    do: {:stop, :voice_dropped, {1011, "voice stream closed"}, state}

  def handle_info({:adk_live_voice_bridge_dropped, bridge, _reason}, %{bridge: bridge} = state),
    do: {:stop, :voice_dropped, {1011, "voice stream closed"}, state}

  def handle_info(:voice_auth_revalidate, state) do
    case current_identity(state.auth_session_id, state.identity) do
      {:ok, _identity} -> {:ok, %{state | auth_timer: schedule_auth_revalidation()}}
      {:error, _reason} -> authentication_expired(state)
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, bridge, reason},
        %{monitor: monitor, bridge: bridge} = state
      ) do
    case reason do
      :normal -> {:stop, :normal, {1000, "voice stream closed"}, state}
      :shutdown -> {:stop, :normal, {1000, "voice stream closed"}, state}
      {:shutdown, :live_voice_reconnect_required} -> reconnect_required(state)
      {:shutdown, :live_voice_outcome_unknown} -> outcome_unknown(state)
      _other -> {:stop, :voice_bridge_down, {1011, "voice stream closed"}, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{identity: identity, voice_ref: voice_ref} = state) do
    if is_reference(state[:auth_timer]), do: Process.cancel_timer(state.auth_timer)
    if is_reference(state[:monitor]), do: Process.demonitor(state.monitor, [:flush])
    _ = LiveGateway.close_voice(identity, voice_ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp current_identity(auth_session_id, expected_identity) do
    with {:ok, %{identity: identity}} <- SessionStore.fetch_context(auth_session_id),
         true <- identity == expected_identity do
      {:ok, identity}
    else
      _error -> {:error, :unauthenticated}
    end
  end

  defp voice_options do
    %{
      credit: @credit,
      max_audio_frame_bytes: @max_audio_payload_bytes
    }
  end

  defp schedule_auth_revalidation,
    do: Process.send_after(self(), :voice_auth_revalidate, @auth_revalidation_ms)

  defp init_error({:error, :automatic_activity_detection_required}),
    do:
      {:stop, :automatic_activity_detection_required,
       {1008, "automatic activity detection required"}, %{}}

  defp init_error({:error, reason}) when reason in [:unauthenticated, :forbidden],
    do: {:stop, :unauthenticated, {1008, "authentication expired"}, %{}}

  defp init_error({:error, :live_voice_reconnect_required}),
    do: {:stop, :live_voice_reconnect_required, {1012, "live session reconnecting"}, %{}}

  defp init_error({:error, :voice_session_not_active}),
    do: {:stop, :voice_session_not_active, {1013, "voice session not active"}, %{}}

  defp init_error({:error, :voice_input_format_unavailable}),
    do: {:stop, :voice_input_format_unavailable, {1013, "voice input format unavailable"}, %{}}

  defp init_error({:error, :live_voice_bridge_already_attached}),
    do: {:stop, :voice_busy, {1013, "voice session already in use"}, %{}}

  defp init_error(_error),
    do: {:stop, :voice_unavailable, {1011, "voice unavailable"}, %{}}

  defp frame_error({:error, reason}, state) when reason in [:unauthenticated, :forbidden],
    do: authentication_expired(state)

  defp frame_error({:error, :ingress_backpressure}, state), do: overloaded(state)
  defp frame_error({:error, :live_voice_reconnect_required}, state), do: reconnect_required(state)
  defp frame_error({:error, :live_voice_outcome_unknown}, state), do: outcome_unknown(state)

  defp frame_error({:error, reason}, state)
       when reason in [:live_voice_audio_frame_too_large, :live_voice_frame_too_large],
       do: {:stop, :frame_too_large, {1009, "frame too large"}, state}

  defp frame_error({:error, {:out_of_order_live_voice_audio, _expected}}, state),
    do: protocol_error(state)

  defp frame_error({:error, {:invalid_live_voice_audio, _reason}}, state),
    do: protocol_error(state)

  defp frame_error({:error, {:unexpected_live_voice_input_sample_rate, _expected}}, state),
    do: protocol_error(state)

  defp frame_error({:error, reason}, state)
       when reason in [
              :invalid_live_voice_frame,
              :invalid_live_voice_audio,
              :invalid_live_voice_frame_limit,
              :unknown_live_voice_event_sequence
            ],
       do: protocol_error(state)

  defp frame_error(_error, state),
    do: {:stop, :voice_unavailable, {1011, "voice unavailable"}, state}

  defp authentication_expired(state),
    do: {:stop, :unauthenticated, {1008, "authentication expired"}, state}

  defp overloaded(state),
    do: {:stop, :ingress_backpressure, {1013, "voice input overloaded"}, state}

  defp protocol_error(state),
    do: {:stop, :voice_protocol_error, {1002, "invalid voice protocol frame"}, state}

  defp outcome_unknown(state),
    do: {:stop, :live_voice_outcome_unknown, {1011, "voice outcome unknown"}, state}

  defp reconnect_required(state),
    do: {:stop, :live_voice_reconnect_required, {1012, "live session reconnecting"}, state}
end
