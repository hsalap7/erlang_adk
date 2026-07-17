defmodule ErlangAdkUi.LiveGateway.Local do
  @moduledoc """
  Node-local `ErlangAdkUi.LiveGateway` implementation.

  Live sessions are discovered from the fixed ADK supervisor and every call is
  authorized again with the exact principal. Evaluation inputs are immutable
  report maps from release configuration; this module never loads paths or
  resolves a browser-supplied module.
  """

  @behaviour ErlangAdkUi.LiveGateway

  alias ErlangAdkUiWeb.BoundedText

  @max_live_sessions 100
  @status_timeout_ms 500
  @status_concurrency 16

  @scope_by_operation %{
    live_read: "adk.live.read",
    live_control: "adk.live.control",
    observability_read: "adk.observability.read",
    evaluation_read: "adk.evaluation.read"
  }

  @impl true
  def discover(identity) do
    with {:ok, principal} <- authorize(identity, :live_read),
         {:ok, children} <- live_children() do
      sessions =
        children
        |> live_statuses(principal)
        |> Enum.map(&public_status/1)
        |> Enum.sort_by(& &1.id)

      {:ok, sessions}
    end
  end

  @impl true
  def attach(identity, session_id, subscriber, credit) when is_pid(subscriber) do
    with {:ok, principal} <- authorize(identity, :live_read),
         {:ok, session} <- find_session(session_id, principal) do
      attach_bridge(session, session_id, principal, subscriber, credit)
    end
  end

  def attach(_identity, _session_id, _subscriber, _credit), do: {:error, :invalid_request}

  @impl true
  def detach(identity, attachment_ref, subscriber) when is_pid(subscriber) do
    with {:ok, principal} <- authorize(identity, :live_read),
         {:ok, session, bridge, token} <- resolve_subscription(attachment_ref, subscriber) do
      result = safe_live_call(:unsubscribe, [session, principal, bridge])
      send(bridge, {:stop, token})
      result
    end
  end

  def detach(_identity, _session_id, _subscriber), do: {:error, :invalid_request}

  @impl true
  def send_text(identity, attachment_ref, text) when is_binary(text) do
    with {:ok, principal} <- authorize(identity, :live_control),
         {:ok, session} <- resolve_session(attachment_ref) do
      safe_live_call(:send_text, [session, principal, text])
    end
  end

  def send_text(_identity, _session_id, _text), do: {:error, :invalid_request}

  @impl true
  def ack(identity, attachment_ref, subscriber, sequence)
      when is_pid(subscriber) and is_integer(sequence) and sequence >= 0 do
    with {:ok, principal} <- authorize(identity, :live_read),
         {:ok, session, bridge, _token} <- resolve_subscription(attachment_ref, subscriber) do
      safe_live_call(:ack, [session, principal, bridge, sequence])
    end
  end

  def ack(_identity, _session_id, _subscriber, _sequence), do: {:error, :invalid_request}

  @impl true
  def open_voice(identity, session_id, owner, options) when is_pid(owner) and is_map(options) do
    with {:ok, principal} <- authorize(identity, :live_read),
         {:ok, ^principal} <- authorize(identity, :live_control),
         {:ok, checked_options} <- voice_options(options),
         {:ok, session, status} <- find_session_with_status(session_id, principal),
         :ok <- require_active_voice_session(status),
         :ok <- require_automatic_voice(status),
         {:ok, bridge} when is_pid(bridge) <-
           safe_core_call(:start_live_voice_bridge, [
             session,
             principal,
             owner,
             checked_options
           ]) do
      voice_ref = {__MODULE__, :voice, bridge, owner, principal, make_ref()}
      {:ok, %{voice_ref: voice_ref, bridge: bridge}}
    else
      {:ok, _invalid_bridge} -> {:error, :service_unavailable}
      {:error, _reason} = error -> error
      _other -> {:error, :service_unavailable}
    end
  end

  def open_voice(_identity, _session_id, _owner, _options), do: {:error, :invalid_request}

  @impl true
  def voice_frame(identity, voice_ref, frame) when is_binary(frame) do
    with {:ok, principal} <- authorize(identity, :live_read),
         {:ok, ^principal} <- authorize(identity, :live_control),
         {:ok, bridge} <- resolve_voice_ref(voice_ref, principal, true) do
      normalize_voice_result(safe_core_call(:live_voice_frame, [bridge, frame]))
    end
  end

  def voice_frame(_identity, _voice_ref, _frame), do: {:error, :invalid_request}

  @impl true
  def close_voice(identity, voice_ref) do
    with {:ok, principal} <- authorize(identity, :live_read),
         {:ok, ^principal} <- authorize(identity, :live_control),
         {:ok, bridge} <- resolve_voice_ref(voice_ref, principal, false) do
      normalize_voice_result(safe_core_call(:stop_live_voice_bridge, [bridge]))
    end
  end

  @impl true
  def observability_snapshot(identity) do
    with {:ok, _principal} <- authorize(identity, :observability_read) do
      {:ok,
       %{
         schema_version: 1,
         metrics: fixed_service_snapshot(:adk_observability_metrics, :snapshot),
         delivery: fixed_service_snapshot(:adk_observability_bus, :stats),
         content_attributes_exposed: false
       }}
    end
  end

  @impl true
  def list_evaluations(identity) do
    with {:ok, _principal} <- authorize(identity, :evaluation_read),
         {:ok, reports} <- configured_reports() do
      evaluations =
        reports
        |> Enum.map(fn {id, %{label: label}} -> %{id: id, label: label} end)
        |> Enum.sort_by(& &1.id)

      {:ok, evaluations}
    end
  end

  @impl true
  def evaluation_report(identity, report_id) do
    with {:ok, _principal} <- authorize(identity, :evaluation_read),
         {:ok, report} <- configured_report(report_id),
         {:ok, rendered} <-
           :adk_eval_dev_view.render(report, "markdown", %{
             "max_output_bytes" => evaluation_output_limit()
           }) do
      {:ok, rendered}
    else
      {:error, {:eval_dev_view, _reason}} -> {:error, :invalid_evaluation_report}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def compare_evaluations(identity, baseline_id, current_id) do
    with {:ok, _principal} <- authorize(identity, :evaluation_read),
         {:ok, baseline} <- configured_report(baseline_id),
         {:ok, current} <- configured_report(current_id),
         {:ok, comparison} <-
           :adk_eval_dev_view.compare(baseline, current, %{
             "max_output_bytes" => evaluation_output_limit()
           }),
         {:ok, rendered} <-
           :adk_eval_dev_view.render(comparison, "markdown", %{
             "max_output_bytes" => evaluation_output_limit()
           }) do
      {:ok, rendered}
    else
      {:error, {:eval_dev_view, _reason}} -> {:error, :invalid_evaluation_report}
      {:error, _reason} = error -> error
    end
  end

  defp authorize(%{principal: principal, scopes: scopes}, operation)
       when is_binary(principal) and byte_size(principal) > 0 and byte_size(principal) <= 128 and
              is_list(scopes) do
    required = Map.fetch!(@scope_by_operation, operation)

    if required in scopes do
      {:ok, principal}
    else
      {:error, :forbidden}
    end
  end

  defp authorize(_identity, _operation), do: {:error, :unauthenticated}

  defp live_children do
    supervisor = :adk_live_session_sup

    if Process.whereis(supervisor) do
      children =
        supervisor
        |> Supervisor.which_children()
        |> Enum.flat_map(fn
          {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
          _child -> []
        end)

      case length(children) <= @max_live_sessions do
        true -> {:ok, children}
        false -> {:error, :lookup_limit}
      end
    else
      {:error, :service_unavailable}
    end
  catch
    :exit, _reason -> {:error, :service_unavailable}
  end

  defp find_session(session_id, principal) when is_binary(session_id) do
    with {:ok, session, _status} <- find_session_with_status(session_id, principal) do
      {:ok, session}
    end
  end

  defp find_session(_session_id, _principal), do: {:error, :not_found}

  defp find_session_with_status(session_id, principal) when is_binary(session_id) do
    with true <- valid_id?(session_id),
         {:ok, children} <- live_children() do
      matches =
        children
        |> live_statuses(principal)
        |> Enum.flat_map(fn
          %{session_id: ^session_id, session_pid: pid} = status -> [{pid, status}]
          _status -> []
        end)

      case matches do
        [{session, status}] -> {:ok, session, status}
        [] -> {:error, :not_found}
        _multiple -> {:error, :ambiguous}
      end
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp find_session_with_status(_session_id, _principal), do: {:error, :not_found}

  defp attach_bridge(session, session_id, principal, subscriber, credit) do
    token = make_ref()

    bridge =
      :erlang.spawn_opt(
        fn -> subscription_bridge(subscriber, session_id, token) end,
        [
          {:message_queue_data, :off_heap},
          {:max_heap_size,
           %{size: 100_000, kill: true, error_logger: false, include_shared_binaries: true}}
        ]
      )

    attachment_ref = session_ref(session, session_id, bridge, subscriber, token)

    case safe_live_call(:subscribe, [session, principal, bridge, credit]) do
      {:ok, subscription} ->
        {:ok, public_subscription(subscription, attachment_ref, token)}

      {:error, _reason} = error ->
        send(bridge, {:stop, token})
        error

      _other ->
        send(bridge, {:stop, token})
        {:error, :service_unavailable}
    end
  end

  defp subscription_bridge(subscriber, session_id, token) do
    monitor = Process.monitor(subscriber)
    subscription_bridge_loop(subscriber, session_id, token, monitor)
  end

  defp subscription_bridge_loop(subscriber, session_id, token, monitor) do
    receive do
      {:adk_live_event, ^session_id, sequence, event} ->
        send(subscriber, {:adk_live_event, token, session_id, sequence, event})
        subscription_bridge_loop(subscriber, session_id, token, monitor)

      {:adk_live_subscriber_dropped, ^session_id, reason} ->
        send(subscriber, {:adk_live_subscriber_dropped, token, session_id, reason})
        :ok

      {:stop, ^token} ->
        :ok

      {:DOWN, ^monitor, :process, ^subscriber, _reason} ->
        :ok

      _other ->
        subscription_bridge_loop(subscriber, session_id, token, monitor)
    end
  end

  defp session_ref(session, session_id, bridge, subscriber, token),
    do: {__MODULE__, session, session_id, bridge, subscriber, token}

  defp resolve_session({__MODULE__, session, session_id, bridge, subscriber, token})
       when is_pid(session) and is_binary(session_id) and is_pid(bridge) and is_pid(subscriber) and
              is_reference(token) do
    if Process.alive?(session) and Process.alive?(bridge) and Process.alive?(subscriber) and
         valid_id?(session_id),
       do: {:ok, session},
       else: {:error, :not_found}
  end

  defp resolve_session(_attachment_ref), do: {:error, :not_found}

  defp resolve_subscription(
         {__MODULE__, session, _session_id, bridge, subscriber, token} = attachment_ref,
         subscriber
       ) do
    with {:ok, ^session} <- resolve_session(attachment_ref) do
      {:ok, session, bridge, token}
    end
  end

  defp resolve_subscription(_attachment_ref, _subscriber), do: {:error, :not_found}

  defp resolve_voice_ref(
         {__MODULE__, :voice, bridge, owner, principal, token},
         principal,
         require_alive
       )
       when is_pid(bridge) and is_pid(owner) and is_reference(token) and is_boolean(require_alive) do
    cond do
      owner != self() -> {:error, :not_found}
      require_alive and not Process.alive?(bridge) -> {:error, :not_found}
      true -> {:ok, bridge}
    end
  end

  defp resolve_voice_ref(_voice_ref, _principal, _require_alive), do: {:error, :not_found}

  defp live_statuses(children, principal) do
    children
    |> Task.async_stream(
      fn pid ->
        case safe_live_call(:status, [pid, principal, @status_timeout_ms]) do
          {:ok, status} when is_map(status) -> Map.put(status, :session_pid, pid)
          _other -> nil
        end
      end,
      max_concurrency: @status_concurrency,
      ordered: false,
      on_timeout: :kill_task,
      timeout: @status_timeout_ms + 100
    )
    |> Enum.flat_map(fn
      {:ok, status} when is_map(status) -> [status]
      _other -> []
    end)
  end

  defp safe_live_call(function, arguments) do
    apply(:adk_live_session, function, arguments)
  catch
    :exit, _reason -> {:error, :service_unavailable}
    _kind, _reason -> {:error, :service_unavailable}
  end

  defp safe_core_call(function, arguments) do
    apply(:erlang_adk, function, arguments)
  catch
    :exit, _reason -> {:error, :service_unavailable}
    _kind, _reason -> {:error, :service_unavailable}
  end

  defp normalize_voice_result(:ok), do: :ok
  defp normalize_voice_result({:ok, _sequence}), do: :ok
  defp normalize_voice_result({:error, _reason} = error), do: error
  defp normalize_voice_result(_other), do: {:error, :service_unavailable}

  defp public_status(status) do
    public =
      %{
        id: Map.fetch!(status, :session_id),
        state: public_state(Map.get(status, :state)),
        model: bounded_string(Map.get(status, :model, "unknown"), 256),
        latest_sequence: non_negative(Map.get(status, :latest_sequence, 0)),
        turn_epoch: non_negative(Map.get(status, :turn_epoch, 0)),
        generation_epoch: non_negative(Map.get(status, :generation_epoch, 0)),
        replayed_inputs: false
      }

    mode =
      case voice_mode(status) do
        {:ok, value} -> Atom.to_string(value)
        {:error, :voice_mode_unavailable} -> "unavailable"
      end

    Map.put(public, :voice_mode, mode)
  end

  defp public_subscription(subscription, attachment_ref, attachment_token)
       when is_map(subscription) do
    %{
      latest_sequence: non_negative(Map.get(subscription, :latest_sequence, 0)),
      state: public_state(Map.get(subscription, :state)),
      turn_epoch: non_negative(Map.get(subscription, :turn_epoch, 0)),
      generation_epoch: non_negative(Map.get(subscription, :generation_epoch, 0)),
      replay: false,
      attachment_ref: attachment_ref,
      attachment_token: attachment_token
    }
  end

  defp fixed_service_snapshot(service, function) do
    if Process.whereis(service) do
      apply(service, function, [])
    else
      %{available: false}
    end
  catch
    _kind, _reason -> %{available: false}
  end

  defp configured_reports do
    configured = Application.get_env(:erlang_adk_ui, :evaluation_reports, %{})

    reports =
      if is_map(configured) and map_size(configured) <= 100 do
        Enum.reduce_while(configured, %{}, fn
          {id, %{label: label, report: report}}, acc
          when is_binary(id) and is_binary(label) and is_map(report) ->
            if valid_id?(id) and valid_label?(label) do
              {:cont, Map.put(acc, id, %{label: label, report: report})}
            else
              {:halt, :error}
            end

          _entry, _acc ->
            {:halt, :error}
        end)
      else
        :error
      end

    case reports do
      :error -> {:error, :invalid_evaluation_catalog}
      checked when is_map(checked) -> {:ok, checked}
      _other -> {:error, :invalid_evaluation_catalog}
    end
  rescue
    _error -> {:error, :invalid_evaluation_catalog}
  end

  defp configured_report(report_id) do
    with true <- valid_id?(report_id),
         {:ok, reports} <- configured_reports(),
         %{report: report} <- Map.get(reports, report_id) do
      {:ok, report}
    else
      _other -> {:error, :not_found}
    end
  end

  defp evaluation_output_limit do
    :erlang_adk_ui
    |> Application.fetch_env!(:ui_limits)
    |> Keyword.fetch!(:max_evaluation_bytes)
  end

  defp valid_id?(value), do: valid_utf8_binary?(value, 128)
  defp valid_label?(value), do: valid_utf8_binary?(value, 256)

  defp voice_options(
         %{
           credit: %{messages: messages, bytes: bytes} = credit,
           max_audio_frame_bytes: maximum
         } = options
       )
       when map_size(options) == 2 and map_size(credit) == 2 and is_integer(messages) and
              messages >= 1 and
              messages <= 256 and is_integer(bytes) and bytes >= 1 and bytes <= 8_388_608 and
              is_integer(maximum) and maximum >= 1 and maximum <= 65_536,
       do:
         {:ok,
          %{
            credit: %{messages: messages, bytes: bytes},
            max_audio_frame_bytes: maximum
          }}

  defp voice_options(_options), do: {:error, :invalid_request}

  defp require_active_voice_session(%{state: state}) when state in [:active, "active"], do: :ok

  defp require_active_voice_session(_status), do: {:error, :voice_session_not_active}

  defp require_automatic_voice(status) do
    case voice_mode(status) do
      {:ok, :automatic} -> :ok
      {:ok, :manual} -> {:error, :automatic_activity_detection_required}
      {:error, :voice_mode_unavailable} = error -> error
    end
  end

  defp voice_mode(status) when is_map(status) do
    explicit = Map.get(status, :voice_mode, :missing)
    automatic = Map.get(status, :automatic_activity_detection, :missing)

    case {explicit, automatic} do
      {value, :missing} -> normalize_voice_mode(value)
      {:missing, true} -> {:ok, :automatic}
      {:missing, false} -> {:ok, :manual}
      {value, true} -> consistent_voice_mode(value, :automatic)
      {value, false} -> consistent_voice_mode(value, :manual)
      _other -> {:error, :voice_mode_unavailable}
    end
  end

  defp voice_mode(_status), do: {:error, :voice_mode_unavailable}

  defp consistent_voice_mode(value, expected) do
    case normalize_voice_mode(value) do
      {:ok, ^expected} = result -> result
      _other -> {:error, :voice_mode_unavailable}
    end
  end

  defp normalize_voice_mode(:automatic), do: {:ok, :automatic}
  defp normalize_voice_mode("automatic"), do: {:ok, :automatic}
  defp normalize_voice_mode(:manual), do: {:ok, :manual}
  defp normalize_voice_mode("manual"), do: {:ok, :manual}
  defp normalize_voice_mode(_value), do: {:error, :voice_mode_unavailable}

  defp public_state(:connecting), do: "connecting"
  defp public_state(:setup_pending), do: "setup_pending"
  defp public_state(:active), do: "active"
  defp public_state(:reconnecting), do: "reconnecting"
  defp public_state(:closed), do: "closed"
  defp public_state("connecting"), do: "connecting"
  defp public_state("setup_pending"), do: "setup_pending"
  defp public_state("active"), do: "active"
  defp public_state("reconnecting"), do: "reconnecting"
  defp public_state("closed"), do: "closed"
  defp public_state(_state), do: "unknown"

  defp valid_utf8_binary?(value, maximum) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= maximum and String.valid?(value)
  end

  defp valid_utf8_binary?(_value, _maximum), do: false

  defp bounded_string(value, maximum) when is_binary(value) do
    if String.valid?(value),
      do: BoundedText.truncate(value, maximum),
      else: "omitted"
  end

  defp bounded_string(value, maximum), do: value |> to_string() |> bounded_string(maximum)

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0
end
