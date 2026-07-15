defmodule ErlangAdkUiWeb.AgentLive do
  use ErlangAdkUiWeb, :live_view

  alias ErlangAdkUi.Auth.SessionStore
  alias ErlangAdkUiWeb.{BoundedEvents, BoundedText, HITL}

  @impl true
  def mount(_params, _session, socket) do
    limits = Application.fetch_env!(:erlang_adk_ui, :ui_limits)

    socket =
      assign(socket,
        page_title: "Agent",
        run_id: nil,
        cursor: 0,
        events: [],
        event_bytes: 0,
        dropped_events: 0,
        phase: :idle,
        pause: nil,
        outcome: nil,
        error: nil,
        limits: limits
      )

    if connected?(socket), do: reconnect(socket), else: {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <header class="page-heading">
        <div>
          <p class="eyebrow">Agent workspace</p>
          <h1>Run a supervised agent</h1>
          <p>
            Start a Gemini-backed task, follow its bounded event stream, and reconnect without
            taking ownership away from the server.
          </p>
        </div>
        <span class={"phase-badge phase-#{@phase}"} role="status" aria-live="polite">
          {@phase}
        </span>
      </header>

      <section class="panel panel-primary stack" id="agent-console">
        <div class="panel-heading">
          <div>
            <p class="panel-kicker">New invocation</p>
            <h2>Run an agent</h2>
            <p class="muted">
              Runs are supervised independently of this browser connection. Reconnects resume from the last acknowledged event.
            </p>
          </div>
        </div>

        <form id="prompt-form" phx-submit="start" class="stack">
          <label>
            Agent
            <select name="agent" required disabled={@phase in [:running, :cancelling, :paused]}>
              <option :for={agent <- @agents} value={agent.id}>{agent.label}</option>
            </select>
          </label>
          <label>
            Message <textarea
              name="message"
              required
              maxlength={@limits[:max_message_bytes]}
              autocomplete="off"
              disabled={@phase in [:running, :cancelling, :paused]}
            ></textarea>
          </label>
          <div class="actions">
            <button
              type="submit"
              disabled={@phase in [:running, :cancelling, :paused]}
              phx-disable-with="Starting…"
            >Start run</button>
            <button
              :if={@phase == :running}
              class="danger"
              type="button"
              phx-click="cancel"
            >Cancel</button>
          </div>
        </form>
      </section>

      <section :if={@run_id || @outcome || @error} class="panel stack" id="run-status">
        <div :if={@run_id}>
          <strong>Run</strong> <code>{@run_id}</code>
          <span class={"phase-badge compact phase-#{@phase}"}>{@phase}</span>
        </div>
        <p :if={@error} class="notice error" id="run-error" role="alert">{@error}</p>
        <pre :if={@outcome} class="outcome" id="run-outcome" role="status" aria-live="polite"><%= @outcome %></pre>
        <p :if={@dropped_events > 0} class="muted">
          {@dropped_events} older event(s) were removed from the bounded view.
        </p>
      </section>

      <section :if={@pause} class="panel stack" id="approval-panel">
        <h2>Human decision required</h2>
        <p>{@pause.summary}</p>
        <div :if={@pause.supported} class="actions">
          <button type="button" phx-click="decide" phx-value-decision="approve">Approve</button>
          <button class="danger" type="button" phx-click="decide" phx-value-decision="reject">Reject</button>
        </div>
        <p :if={!@pause.supported} class="notice error" role="alert">
          This pause type is not supported by the UI. It was left paused and was not resumed.
        </p>
      </section>

      <section :if={@events != []} class="panel" id="event-history">
        <h2>Events</h2>
        <ol class="events">
          <li :for={item <- @events} class="event" id={"event-#{item.sequence}"}>
            <strong>Sequence {item.sequence}</strong>
            <pre><%= item.json %></pre>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("start", %{"agent" => agent_id, "message" => message}, socket)
      when is_binary(agent_id) and is_binary(message) do
    with :idle <- socket.assigns.phase,
         true <- valid_agent?(socket.assigns.agents, agent_id),
         true <- valid_message?(message, socket.assigns.limits[:max_message_bytes]),
         {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id),
         {:ok, run_id} <-
           :adk_web_gateway.start_run(
             gateway(),
             context.identity,
             agent_id,
             context.agent_session_id,
             message
           ),
         :ok <- SessionStore.save_run(socket.assigns.auth_session_id, run_id, 0),
         {:ok, _subscription} <-
           :adk_web_gateway.subscribe_credit(gateway(), context.identity, run_id, self(), 0) do
      {:noreply,
       assign(socket,
         run_id: run_id,
         cursor: 0,
         events: [],
         event_bytes: 0,
         dropped_events: 0,
         phase: :running,
         pause: nil,
         outcome: nil,
         error: nil
       )}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, error: "The run could not be started.")}
    end
  end

  def handle_event("start", _params, socket),
    do: {:noreply, assign(socket, error: "Invalid run request.")}

  def handle_event("cancel", _params, %{assigns: %{run_id: run_id, phase: :running}} = socket)
      when is_binary(run_id) do
    with {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id),
         :ok <- :adk_web_gateway.cancel(gateway(), context.identity, run_id) do
      {:noreply, assign(socket, phase: :cancelling, error: nil)}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, error: "The run could not be cancelled.")}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, socket}

  def handle_event("decide", %{"decision" => decision}, %{assigns: %{pause: pause}} = socket)
      when decision in ["approve", "reject"] and is_map(pause) do
    confirmed = decision == "approve"

    with true <- pause.supported,
         {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id),
         {:ok, payload} <- HITL.resume_payload(pause.type, confirmed, context.identity.principal),
         {:ok, resumed_run_id} <-
           :adk_web_gateway.resume(gateway(), context.identity, socket.assigns.run_id, payload),
         :ok <- SessionStore.save_run(socket.assigns.auth_session_id, resumed_run_id, 0),
         {:ok, _subscription} <-
           :adk_web_gateway.subscribe_credit(
             gateway(),
             context.identity,
             resumed_run_id,
             self(),
             0
           ) do
      {:noreply,
       assign(socket,
         run_id: resumed_run_id,
         cursor: 0,
         events: [],
         event_bytes: 0,
         phase: :running,
         pause: nil,
         outcome: nil,
         error: nil
       )}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, error: "The paused run was not resumed.")}
    end
  end

  def handle_event("decide", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:adk_run_event, run_id, sequence, event},
        %{assigns: %{run_id: run_id}} = socket
      ) do
    with {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id),
         {:ok, public_event} <- safe_event(event),
         {:ok, item} <- event_item(sequence, public_event),
         {events, bytes, result} <-
           BoundedEvents.append(
             socket.assigns.events,
             socket.assigns.event_bytes,
             item,
             socket.assigns.limits[:max_events],
             socket.assigns.limits[:max_event_bytes]
           ),
         :ok <- SessionStore.save_run(socket.assigns.auth_session_id, run_id, sequence),
         :ok <- :adk_web_gateway.ack(gateway(), context.identity, run_id, self(), sequence) do
      dropped = socket.assigns.dropped_events + dropped_count(result)

      {:noreply,
       assign(socket,
         cursor: sequence,
         events: events,
         event_bytes: bytes,
         dropped_events: dropped,
         pause: HITL.from_event(public_event) || socket.assigns.pause,
         error: item_error(result)
       )}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> stop_stream(socket, "The event stream could not be processed safely.")
    end
  end

  def handle_info(
        {:adk_run_terminal, run_id, _sequence, outcome},
        %{assigns: %{run_id: run_id}} = socket
      ) do
    with {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id),
         {:ok, _status} <- :adk_web_gateway.status(gateway(), context.identity, run_id) do
      _ = :adk_web_gateway.unsubscribe(gateway(), context.identity, run_id, self())
      terminal_outcome(socket, outcome)
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> stop_stream(socket, "The run is no longer available.")
    end
  end

  def handle_info({:adk_run_replay_gap, run_id, _gap}, %{assigns: %{run_id: run_id}} = socket) do
    with {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id),
         {:ok, _status} <- :adk_web_gateway.status(gateway(), context.identity, run_id) do
      stop_stream(
        socket,
        "The retained event window was exceeded. Reload the run from a trusted snapshot."
      )
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> stop_stream(socket, "The run is no longer available.")
    end
  end

  def handle_info({kind, stale_run_id, _sequence, _payload}, socket)
      when kind in [:adk_run_event, :adk_run_terminal] and is_binary(stale_run_id) do
    _ = unsubscribe(socket, stale_run_id)
    {:noreply, socket}
  end

  def handle_info({:adk_run_replay_gap, stale_run_id, _gap}, socket)
      when is_binary(stale_run_id) do
    _ = unsubscribe(socket, stale_run_id)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, %{assigns: %{run_id: run_id}} = socket) when is_binary(run_id) do
    _ = unsubscribe(socket, run_id)
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp reconnect(socket) do
    with {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id),
         %{run_id: run_id, cursor: cursor} when is_binary(run_id) <- context.ui,
         {:ok, _status} <- :adk_web_gateway.status(gateway(), context.identity, run_id),
         {:ok, _subscription} <-
           :adk_web_gateway.subscribe_credit(gateway(), context.identity, run_id, self(), cursor) do
      {:ok, assign(socket, run_id: run_id, cursor: cursor, phase: :running)}
    else
      %{run_id: nil} ->
        {:ok, socket}

      {:error, :unauthenticated} ->
        {:ok, redirect(socket, to: "/auth/login")}

      {:error, {:replay_gap, _details}} ->
        _ = SessionStore.clear_run(socket.assigns.auth_session_id)
        {:ok, assign(socket, error: "The retained event window was exceeded.")}

      _error ->
        _ = SessionStore.clear_run(socket.assigns.auth_session_id)
        {:ok, assign(socket, error: "The previous run is no longer available.")}
    end
  end

  defp stop_stream(socket, message) do
    if is_binary(socket.assigns.run_id), do: unsubscribe(socket, socket.assigns.run_id)
    _ = SessionStore.clear_run(socket.assigns.auth_session_id)
    {:noreply, terminal(socket, message)}
  end

  defp terminal(socket, outcome) do
    assign(socket, run_id: nil, cursor: 0, phase: :idle, pause: nil, outcome: outcome)
  end

  defp terminal_outcome(socket, {:paused, _event}) do
    {:noreply, assign(socket, phase: :paused, outcome: "Run paused for a human decision.")}
  end

  defp terminal_outcome(socket, {:completed, output}) do
    _ = SessionStore.clear_run(socket.assigns.auth_session_id)

    {:noreply,
     terminal(
       socket,
       "Completed\n" <> safe_output(output, socket.assigns.limits[:max_output_bytes])
     )}
  end

  defp terminal_outcome(socket, {:cancelled, _reason}) do
    _ = SessionStore.clear_run(socket.assigns.auth_session_id)
    {:noreply, terminal(socket, "Run cancelled.")}
  end

  defp terminal_outcome(socket, {:failed, _reason}) do
    _ = SessionStore.clear_run(socket.assigns.auth_session_id)
    {:noreply, terminal(socket, "Run failed.")}
  end

  defp terminal_outcome(socket, _unknown) do
    _ = SessionStore.clear_run(socket.assigns.auth_session_id)
    {:noreply, terminal(socket, "Run ended with an unsupported outcome.")}
  end

  defp unsubscribe(socket, run_id) do
    with {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id) do
      :adk_web_gateway.unsubscribe(gateway(), context.identity, run_id, self())
    end
  end

  defp reauthenticate(socket), do: {:noreply, redirect(socket, to: "/auth/login")}

  defp safe_event(event) do
    case :adk_event.encode(event) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _other -> {:error, :invalid_event}
    end
  catch
    _class, _reason -> {:error, :invalid_event}
  end

  defp event_item(sequence, event) when is_integer(sequence) and sequence >= 0 do
    {:ok, %{sequence: sequence, json: Jason.encode!(event, pretty: true)}}
  rescue
    _error -> {:error, :invalid_event}
  end

  defp safe_output(output, max_bytes) when is_binary(output),
    do: BoundedText.truncate(output, max_bytes)

  defp safe_output(output, max_bytes) when is_map(output) do
    output |> Jason.encode!() |> BoundedText.truncate(max_bytes)
  rescue
    _error -> "Output was not renderable."
  end

  defp safe_output(_output, _max_bytes), do: "Output omitted because its type is not web-safe."

  defp valid_agent?(agents, id), do: Enum.any?(agents, &(&1.id == id))

  defp valid_message?(message, max_bytes) do
    byte_size(message) > 0 and byte_size(message) <= max_bytes and String.valid?(message)
  end

  defp dropped_count({:ok, count}), do: count
  defp dropped_count(:item_too_large), do: 1
  defp item_error(:item_too_large), do: "An oversized event was omitted from the browser view."
  defp item_error({:ok, _count}), do: nil

  defp gateway, do: Application.fetch_env!(:erlang_adk_ui, :gateway_server)
end
