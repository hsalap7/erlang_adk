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
         state: "active",
         model: "gemini-3.1-flash-live-preview",
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
      notify({:attached, session_id, attachment_ref, attachment_token})

      {:ok,
       %{
         latest_sequence: 0,
         state: "active",
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

  defp session_id(%{subject: subject}), do: "live-#{subject}"

  defp valid_attachment?({__MODULE__, session_id, token}, session_id) when is_reference(token),
    do: true

  defp valid_attachment?(_attachment_ref, _session_id), do: false

  defp notify(message) do
    case Application.get_env(:erlang_adk_ui, :test_live_gateway_pid) do
      pid when is_pid(pid) -> send(pid, {:live_gateway, message})
      _other -> :ok
    end
  end
end
