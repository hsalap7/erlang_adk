defmodule ErlangAdkUi.TestLiveGateway do
  @behaviour ErlangAdkUi.LiveGateway

  @impl true
  def discover(identity) do
    notify({:discover, identity})
    principal = Map.fetch!(identity, :principal)

    {:ok,
     [
       %{
         id: session_id(identity),
         state:
           :erlang_adk_ui
           |> Application.get_env(:test_live_voice_state, :active)
           |> Atom.to_string(),
         model: "gemini-3.1-flash-live-preview",
         voice_mode:
           :erlang_adk_ui
           |> Application.get_env(:test_live_voice_mode, :automatic)
           |> Atom.to_string(),
         input_sample_rate:
           Application.get_env(
             :erlang_adk_ui,
             :test_live_voice_input_sample_rate,
             16_000
           ),
         latest_sequence: 0,
         owner_digest: :crypto.hash(:sha256, principal)
       }
     ]}
  end

  @impl true
  def attach(identity, session_id, subscriber, credit) do
    notify({:attach, identity, session_id, subscriber, credit})

    if session_id == session_id(identity) do
      attachment_token = make_ref()
      attachment_ref = {__MODULE__, session_id, attachment_token}

      state =
        :erlang_adk_ui
        |> Application.get_env(:test_live_voice_state, :active)
        |> Atom.to_string()

      notify({:attached, session_id, attachment_ref, attachment_token})

      {:ok,
       %{
         latest_sequence: 0,
         state: state,
         turn_epoch: 0,
         generation_epoch: 0,
         replay: false,
         attachment_ref: attachment_ref,
         attachment_token: attachment_token
       }}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def detach(identity, attachment_ref, subscriber) do
    notify({:detach, identity, attachment_ref, subscriber})
    :ok
  end

  @impl true
  def send_text(identity, attachment_ref, text) do
    notify({:send_text, identity, attachment_ref, text})

    cond do
      not valid_attachment?(attachment_ref, session_id(identity)) -> {:error, :not_found}
      text == "busy" -> {:error, :ingress_backpressure}
      true -> {:ok, 1}
    end
  end

  @impl true
  def ack(identity, attachment_ref, subscriber, sequence) do
    notify({:ack, identity, attachment_ref, subscriber, sequence})
    :ok
  end

  @impl true
  def open_voice(identity, requested_session_id, owner, options) do
    notify({:open_voice, identity, requested_session_id, owner, options})

    state = Application.get_env(:erlang_adk_ui, :test_live_voice_state, :active)
    mode = Application.get_env(:erlang_adk_ui, :test_live_voice_mode, :automatic)
    forced_error = Application.get_env(:erlang_adk_ui, :test_live_voice_error)

    cond do
      is_atom(forced_error) and not is_nil(forced_error) ->
        {:error, forced_error}

      state != :active ->
        {:error, :voice_session_not_active}

      mode == :manual ->
        {:error, :automatic_activity_detection_required}

      requested_session_id != session_id(identity) or not is_pid(owner) ->
        {:error, :not_found}

      true ->
        bridge = spawn(fn -> voice_bridge_loop() end)
        token = make_ref()

        input_sample_rate =
          Application.get_env(:erlang_adk_ui, :test_live_voice_input_sample_rate, 16_000)

        voice_ref =
          {__MODULE__, :voice, requested_session_id, bridge, owner, identity.principal, token}

        notify({:voice_opened, requested_session_id, voice_ref, bridge})

        send(
          owner,
          {:adk_live_voice_frame, bridge,
           <<1, 128, input_sample_rate::unsigned-big-integer-size(32), 1, 1>>}
        )

        {:ok,
         %{
           voice_ref: voice_ref,
           bridge: bridge,
           input_format: %{sample_rate: input_sample_rate, channels: 1, format: :pcm_s16le}
         }}
    end
  end

  @impl true
  def voice_frame(identity, voice_ref, frame) do
    notify({:voice_frame, identity, voice_ref, frame})

    case voice_ref do
      {:force_error, reason} -> {:error, reason}
      _other -> if valid_voice_ref?(voice_ref, identity), do: :ok, else: {:error, :not_found}
    end
  end

  @impl true
  def close_voice(identity, voice_ref) do
    notify({:close_voice, identity, voice_ref})

    case voice_ref do
      {__MODULE__, :voice, _session_id, bridge, owner, principal, token}
      when is_pid(bridge) and owner == self() and principal == identity.principal and
             is_reference(token) ->
        send(bridge, :stop)
        :ok

      _other ->
        {:error, :not_found}
    end
  end

  @impl true
  def observability_snapshot(identity) do
    notify({:observability_snapshot, identity})

    {:ok,
     %{
       schema_version: 1,
       metrics: %{request_count: 3},
       delivery: %{queued: 0},
       data: "RAW_OBSERVABILITY_PAYLOAD",
       api_key: "SUPER_SECRET_KEY",
       content_attributes_exposed: false
     }}
  end

  @impl true
  def list_evaluations(identity) do
    notify({:list_evaluations, identity})

    {:ok,
     [
       %{id: "baseline", label: "Baseline"},
       %{id: "current", label: "Current"}
     ]}
  end

  @impl true
  def evaluation_report(identity, report_id) do
    notify({:evaluation_report, identity, report_id})

    if report_id in ["baseline", "current"] do
      {:ok, "# Evaluation #{report_id}\n\npass_rate: 1.0"}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def compare_evaluations(identity, baseline_id, current_id) do
    notify({:compare_evaluations, identity, baseline_id, current_id})

    if baseline_id in ["baseline", "current"] and current_id in ["baseline", "current"] do
      {:ok, "# Baseline comparison\n\npassed: true"}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def list_graphs(identity) do
    notify({:list_graphs, identity})

    {:ok,
     %{
       "graphs" => [graph_summary()],
       "next_cursor" => nil,
       "truncated" => false
     }}
  end

  @impl true
  def graph_detail(identity, graph_id) do
    notify({:graph_detail, identity, graph_id})

    if graph_id == "checkout" do
      {:ok, graph_detail()}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def graph_overlay(identity, graph_id, cursor) do
    notify({:graph_overlay, identity, graph_id, cursor})

    cond do
      graph_id != "checkout" ->
        {:error, :not_found}

      Application.get_env(:erlang_adk_ui, :test_graph_overlay_gap, false) and cursor == 0 ->
        {:error, {:replay_gap, replay_gap()}}

      true ->
        {:ok,
         %{
           "schema_version" => 1,
           "content_captured" => false,
           "graph" => graph_detail(),
           "overlay" => %{
             "node_states" => %{"authorize" => "completed"},
             "active_node" => nil,
             "routes" => [],
             "retry_count" => 0,
             "pause_count" => 0
           },
           "trace" => trace_page(cursor)
         }}
    end
  end

  @impl true
  def trace_timeline(identity, cursor) do
    notify({:trace_timeline, identity, cursor})

    if Application.get_env(:erlang_adk_ui, :test_trace_gap, false) and cursor == 0 do
      {:error, {:replay_gap, replay_gap()}}
    else
      {:ok, trace_page(cursor)}
    end
  end

  defp graph_summary do
    %{
      "id" => "checkout",
      "fingerprint" => String.duplicate("a", 64),
      "generation" => 1,
      "updated_at" => 1_726_000_000_000,
      "encoded_bytes" => 512
    }
  end

  defp graph_detail do
    Map.put(graph_summary(), "graph", %{
      "schema_version" => 1,
      "workflow_id" => "checkout",
      "kind" => "graph",
      "entry" => "authorize",
      "node_order" => ["authorize"],
      "nodes" => [%{"id" => "authorize", "type" => "action"}],
      "edges" => [%{"from" => "authorize", "to" => "$end", "kind" => "edge"}],
      "prompt" => "RAW_GRAPH_PROMPT_SHOULD_NOT_RENDER"
    })
  end

  defp trace_page(cursor) do
    next_cursor = cursor + 1

    %{
      "events" => [
        %{
          "cursor" => next_cursor,
          "kind" => "workflow_lifecycle",
          "timestamp_ms" => 1_726_000_000_000,
          "identity" => %{
            "workflow_id" => "checkout",
            "invocation_id" => "invocation-1"
          },
          "event" => %{
            "schema_version" => 1,
            "type" => "node_completed",
            "sequence" => next_cursor,
            "timestamp" => 1_726_000_000_000,
            "workflow_id" => "checkout",
            "workflow_kind" => "graph",
            "invocation_id" => "invocation-1",
            "node_id" => "authorize",
            "outcome" => "ok",
            "response" => "RAW_TRACE_RESPONSE_SHOULD_NOT_RENDER"
          }
        }
      ],
      "next_cursor" => next_cursor,
      "oldest_available_cursor" => 1,
      "latest_cursor" => next_cursor,
      "encoded_bytes" => 512,
      "truncated" => false
    }
  end

  defp replay_gap do
    %{
      "after_cursor" => 0,
      "oldest_available_cursor" => 4,
      "latest_cursor" => 6,
      "evicted_through" => 3
    }
  end

  defp session_id(%{subject: subject}), do: "live-#{subject}"

  defp valid_attachment?({__MODULE__, session_id, token}, session_id) when is_reference(token),
    do: true

  defp valid_attachment?(_attachment_ref, _session_id), do: false

  defp valid_voice_ref?(
         {__MODULE__, :voice, requested_session_id, bridge, owner, principal, token},
         identity
       )
       when is_pid(bridge) and owner == self() and principal == identity.principal and
              is_reference(token),
       do: requested_session_id == session_id(identity) and Process.alive?(bridge)

  defp valid_voice_ref?(_voice_ref, _identity), do: false

  defp voice_bridge_loop do
    receive do
      :stop -> :ok
      _other -> voice_bridge_loop()
    end
  end

  defp notify(message) do
    case Application.get_env(:erlang_adk_ui, :test_live_gateway_pid) do
      pid when is_pid(pid) -> send(pid, {:live_gateway, message})
      _other -> :ok
    end
  end
end
