defmodule ErlangAdkUiWeb.LiveSessionLive do
  use ErlangAdkUiWeb, :live_view

  alias ErlangAdkUi.Auth.SessionStore
  alias ErlangAdkUi.LiveGateway
  alias ErlangAdkUiWeb.{BoundedEvents, BoundedText, LiveProjection, PublicData}

  @impl true
  def mount(_params, _session, socket) do
    limits = Application.fetch_env!(:erlang_adk_ui, :ui_limits)

    socket =
      assign(socket,
        page_title: "Live and operations",
        limits: limits,
        live_sessions: [],
        attached_session_id: nil,
        attached_session_ref: nil,
        attached_event_token: nil,
        subscription: nil,
        live_events: [],
        live_event_bytes: 0,
        dropped_live_events: 0,
        live_error: nil,
        observability: nil,
        observability_error: nil,
        evaluations: [],
        evaluation_report: nil,
        evaluation_error: nil
      )

    if connected?(socket), do: load_dashboard(socket), else: {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="panel stack" id="live-console">
        <div>
          <h2>ADK Live sessions</h2>
          <p class="muted">
            Sessions are created and owned by the server. Attaching receives future events only;
            this UI does not request or claim event replay.
          </p>
        </div>

        <div class="actions">
          <button type="button" class="secondary" phx-click="refresh-live">Refresh sessions</button>
          <button
            :if={@attached_session_id}
            type="button"
            class="danger"
            phx-click="detach"
          >Detach</button>
        </div>

        <p :if={@live_error} class="notice error" id="live-error">{@live_error}</p>

        <form :if={@live_sessions != []} id="attach-form" phx-submit="attach" class="stack">
          <label>
            Principal-scoped session
            <select name="session_id" required>
              <option :for={session <- @live_sessions} value={session.id}>
                {session.id} · {session.state} · {session.model}
              </option>
            </select>
          </label>
          <button type="submit">Attach without replay</button>
        </form>

        <p :if={@live_sessions == []} class="muted" id="no-live-sessions">
          No Live sessions are visible to this principal.
        </p>

        <div :if={@attached_session_id} id="live-attachment" class="notice">
          Attached to <code>{@attached_session_id}</code>. Credit is fixed server-side and each
          event is acknowledged only after safe projection into the bounded view.
        </div>

        <form
          :if={@attached_session_id}
          id="live-text-form"
          phx-submit="live-text"
          class="stack"
        >
          <label>
            Realtime text <textarea
              name="text"
              required
              maxlength={@limits[:max_live_text_bytes]}
              autocomplete="off"
            ></textarea>
          </label>
          <button type="submit">Send text</button>
        </form>
      </section>

      <section :if={@live_events != []} class="panel" id="live-event-history">
        <h2>Live metadata and text events</h2>
        <p class="muted">
          Audio/video payloads and thought signatures are omitted before an event enters LiveView assigns.
        </p>
        <p :if={@dropped_live_events > 0} class="muted">
          {@dropped_live_events} event(s) were omitted from this bounded browser view.
        </p>
        <ol class="events">
          <li :for={item <- @live_events} class="event" id={"live-event-#{item.sequence}"}>
            <strong>Sequence {item.sequence}</strong>
            <pre><%= item.json %></pre>
          </li>
        </ol>
      </section>

      <section class="panel stack" id="observability-panel">
        <div>
          <h2>Observability snapshot</h2>
          <p class="muted">
            Read-only, bounded metric and delivery metadata. Prompt, response and media content are not exposed.
          </p>
        </div>
        <button type="button" class="secondary" phx-click="refresh-observability">Refresh snapshot</button>
        <p :if={@observability_error} class="notice error">{@observability_error}</p>
        <pre :if={@observability} class="outcome" id="observability-snapshot"><%= @observability %></pre>
      </section>

      <section class="panel stack" id="evaluation-panel">
        <div>
          <h2>Evaluation reports</h2>
          <p class="muted">
            Reports are server-configured maps rendered through the pure ADK evaluation boundary.
            Browser-supplied paths and module names are never accepted.
          </p>
        </div>

        <p :if={@evaluations == []} class="muted" id="no-evaluations">
          No evaluation reports are configured.
        </p>

        <form :if={@evaluations != []} id="evaluation-form" phx-submit="show-evaluation" class="stack">
          <label>
            Report
            <select name="report_id" required>
              <option :for={report <- @evaluations} value={report.id}>{report.label}</option>
            </select>
          </label>
          <button type="submit">Render report</button>
        </form>

        <form
          :if={length(@evaluations) > 1}
          id="comparison-form"
          phx-submit="compare-evaluations"
          class="stack"
        >
          <label>
            Baseline
            <select name="baseline_id" required>
              <option :for={report <- @evaluations} value={report.id}>{report.label}</option>
            </select>
          </label>
          <label>
            Current
            <select name="current_id" required>
              <option :for={report <- @evaluations} value={report.id}>{report.label}</option>
            </select>
          </label>
          <button type="submit">Compare baseline</button>
        </form>

        <p :if={@evaluation_error} class="notice error">{@evaluation_error}</p>
        <pre :if={@evaluation_report} class="outcome" id="evaluation-report"><%= @evaluation_report %></pre>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("refresh-live", _params, socket) do
    with {:ok, identity} <- current_identity(socket),
         {:ok, sessions} <- LiveGateway.discover(identity),
         {:ok, checked} <- validate_sessions(sessions) do
      {:noreply, assign(socket, live_sessions: checked, live_error: nil)}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, live_error: "Live sessions are unavailable.")}
    end
  end

  def handle_event("attach", %{"session_id" => session_id}, socket) when is_binary(session_id) do
    with true <- visible_session?(socket.assigns.live_sessions, session_id),
         {:ok, identity} <- current_identity(socket),
         :ok <- detach_current(socket, identity),
         {:ok, public_subscription, attachment_ref, event_token} <-
           attach_checked(identity, session_id) do
      {:noreply,
       assign(socket,
         attached_session_id: session_id,
         attached_session_ref: attachment_ref,
         attached_event_token: event_token,
         subscription: public_subscription,
         live_events: [],
         live_event_bytes: 0,
         dropped_live_events: 0,
         live_error: nil
       )}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, detached(socket, "The Live session could not be attached.")}
    end
  end

  def handle_event("attach", _params, socket),
    do: {:noreply, assign(socket, live_error: "Invalid Live session selection.")}

  def handle_event("detach", _params, socket) do
    with {:ok, identity} <- current_identity(socket),
         :ok <- detach_current(socket, identity) do
      {:noreply, detached(socket, nil)}
    else
      {:error, :unauthenticated} ->
        reauthenticate(socket)

      _error ->
        {:noreply, detached(socket, "The Live subscription could not be detached cleanly.")}
    end
  end

  def handle_event(
        "live-text",
        %{"text" => text},
        %{assigns: %{attached_session_ref: attachment_ref}} = socket
      )
      when not is_nil(attachment_ref) and is_binary(text) do
    with true <- valid_text?(text, socket.assigns.limits[:max_live_text_bytes]),
         {:ok, identity} <- current_identity(socket),
         {:ok, _input_sequence} <- LiveGateway.send_text(identity, attachment_ref, text) do
      {:noreply, assign(socket, live_error: nil)}
    else
      {:error, :unauthenticated} ->
        reauthenticate(socket)

      {:error, :ingress_backpressure} ->
        {:noreply, assign(socket, live_error: "The Live input window is full; retry later.")}

      _error ->
        {:noreply, assign(socket, live_error: "Realtime text was not accepted.")}
    end
  end

  def handle_event("live-text", _params, socket),
    do: {:noreply, assign(socket, live_error: "Invalid realtime text request.")}

  def handle_event("refresh-observability", _params, socket) do
    case load_observability(socket) do
      {:ok, updated} ->
        {:noreply, updated}

      {:error, :unauthenticated} ->
        reauthenticate(socket)

      {:error, _reason} ->
        {:noreply, assign(socket, observability_error: "Observability is unavailable.")}
    end
  end

  def handle_event("show-evaluation", %{"report_id" => report_id}, socket)
      when is_binary(report_id) do
    with true <- visible_evaluation?(socket.assigns.evaluations, report_id),
         {:ok, identity} <- current_identity(socket),
         {:ok, report} <- LiveGateway.evaluation_report(identity, report_id),
         {:ok, bounded} <- bounded_report(report, socket.assigns.limits[:max_evaluation_bytes]) do
      {:noreply, assign(socket, evaluation_report: bounded, evaluation_error: nil)}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, evaluation_error: "The report could not be rendered.")}
    end
  end

  def handle_event("show-evaluation", _params, socket),
    do: {:noreply, assign(socket, evaluation_error: "Invalid evaluation selection.")}

  def handle_event(
        "compare-evaluations",
        %{"baseline_id" => baseline_id, "current_id" => current_id},
        socket
      )
      when is_binary(baseline_id) and is_binary(current_id) do
    with true <- visible_evaluation?(socket.assigns.evaluations, baseline_id),
         true <- visible_evaluation?(socket.assigns.evaluations, current_id),
         {:ok, identity} <- current_identity(socket),
         {:ok, report} <- LiveGateway.compare_evaluations(identity, baseline_id, current_id),
         {:ok, bounded} <- bounded_report(report, socket.assigns.limits[:max_evaluation_bytes]) do
      {:noreply, assign(socket, evaluation_report: bounded, evaluation_error: nil)}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, evaluation_error: "The baseline comparison failed.")}
    end
  end

  def handle_event("compare-evaluations", _params, socket),
    do: {:noreply, assign(socket, evaluation_error: "Invalid comparison selection.")}

  @impl true
  def handle_info(
        {:adk_live_event, event_token, session_id, sequence, event},
        %{
          assigns: %{
            attached_session_id: session_id,
            attached_session_ref: attachment_ref,
            attached_event_token: event_token
          }
        } = socket
      )
      when not is_nil(attachment_ref) and is_integer(sequence) and sequence > 0 do
    with {:ok, identity} <- current_identity(socket),
         {:ok, public_event} <- LiveProjection.project(event),
         {:ok, item} <- live_event_item(sequence, public_event),
         {events, bytes, result} <-
           BoundedEvents.append(
             socket.assigns.live_events,
             socket.assigns.live_event_bytes,
             item,
             socket.assigns.limits[:max_live_events],
             socket.assigns.limits[:max_live_event_bytes]
           ),
         :ok <- LiveGateway.ack(identity, attachment_ref, self(), sequence) do
      {:noreply,
       assign(socket,
         live_events: events,
         live_event_bytes: bytes,
         dropped_live_events: socket.assigns.dropped_live_events + dropped_count(result),
         live_error: item_error(result)
       )}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> stop_live_stream(socket, "The Live event stream could not be processed safely.")
    end
  end

  def handle_info(
        {:adk_live_subscriber_dropped, event_token, session_id, _reason},
        %{assigns: %{attached_session_id: session_id, attached_event_token: event_token}} = socket
      ) do
    {:noreply, detached(socket, "The Live subscription exceeded its bounded credit window.")}
  end

  def handle_info({:adk_live_event, _token, _session_id, _sequence, _event}, socket),
    do: {:noreply, socket}

  def handle_info({:adk_live_event, _session_id, _sequence, _event}, socket),
    do: {:noreply, socket}

  def handle_info({:adk_live_subscriber_dropped, _token, _session_id, _reason}, socket),
    do: {:noreply, socket}

  def handle_info({:adk_live_subscriber_dropped, _session_id, _reason}, socket),
    do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, %{assigns: %{attached_session_ref: attachment_ref}} = socket)
      when not is_nil(attachment_ref) do
    _ = detach_attachment(socket, attachment_ref)
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp load_dashboard(socket) do
    with {:ok, identity} <- current_identity(socket),
         {:ok, sessions} <- LiveGateway.discover(identity),
         {:ok, checked_sessions} <- validate_sessions(sessions),
         {:ok, evaluations} <- LiveGateway.list_evaluations(identity),
         {:ok, checked_evaluations} <- validate_evaluations(evaluations) do
      socket =
        assign(socket,
          live_sessions: checked_sessions,
          evaluations: checked_evaluations,
          live_error: nil,
          evaluation_error: nil
        )

      case load_observability(socket, identity) do
        {:ok, updated} ->
          {:ok, updated}

        {:error, _reason} ->
          {:ok, assign(socket, observability_error: "Observability is unavailable.")}
      end
    else
      {:error, :unauthenticated} -> {:ok, redirect(socket, to: "/auth/login")}
      _error -> {:ok, assign(socket, live_error: "The operations gateway is unavailable.")}
    end
  end

  defp load_observability(socket) do
    with {:ok, identity} <- current_identity(socket) do
      load_observability(socket, identity)
    end
  end

  defp load_observability(socket, identity) do
    with {:ok, snapshot} <- LiveGateway.observability_snapshot(identity),
         {:ok, json} <- encode_public(snapshot),
         bounded <- BoundedText.truncate(json, socket.assigns.limits[:max_observability_bytes]) do
      {:ok, assign(socket, observability: bounded, observability_error: nil)}
    end
  end

  defp current_identity(socket) do
    with {:ok, context} <- SessionStore.fetch_context(socket.assigns.auth_session_id) do
      {:ok, context.identity}
    end
  end

  defp detach_current(%{assigns: %{attached_session_ref: nil}}, _identity), do: :ok

  defp detach_current(%{assigns: %{attached_session_ref: attachment_ref}}, identity) do
    LiveGateway.detach(identity, attachment_ref, self())
  end

  defp attach_checked(identity, session_id) do
    case LiveGateway.attach(identity, session_id, self(), configured_credit()) do
      {:ok, subscription} ->
        case validate_subscription(subscription) do
          {:ok, public_subscription, attachment_ref, event_token} ->
            {:ok, public_subscription, attachment_ref, event_token}

          {:error, _reason} = error ->
            _ = detach_invalid_subscription(identity, subscription)
            error
        end

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_gateway_result}
    end
  end

  defp detach_attachment(socket, attachment_ref) do
    with {:ok, identity} <- current_identity(socket) do
      LiveGateway.detach(identity, attachment_ref, self())
    end
  end

  defp stop_live_stream(socket, message) do
    _ = detach_attachment(socket, socket.assigns.attached_session_ref)
    {:noreply, detached(socket, message)}
  end

  defp detached(socket, error) do
    assign(socket,
      attached_session_id: nil,
      attached_session_ref: nil,
      attached_event_token: nil,
      subscription: nil,
      live_error: error
    )
  end

  defp configured_credit do
    Application.fetch_env!(:erlang_adk_ui, :live_credit)
  end

  defp validate_sessions(sessions) when is_list(sessions) and length(sessions) <= 100 do
    checked =
      Enum.reduce_while(sessions, [], fn
        %{id: id, state: state, model: model} = session, acc
        when is_binary(id) and is_binary(state) and is_binary(model) ->
          if valid_id?(id) and String.valid?(state) and byte_size(state) <= 64 and
               String.valid?(model) and byte_size(model) <= 256 do
            public = %{
              id: id,
              state: state,
              model: model,
              latest_sequence: non_negative(Map.get(session, :latest_sequence, 0))
            }

            {:cont, [public | acc]}
          else
            {:halt, :error}
          end

        _session, _acc ->
          {:halt, :error}
      end)

    case checked do
      :error -> {:error, :invalid_gateway_result}
      values -> {:ok, Enum.reverse(values)}
    end
  end

  defp validate_sessions(_sessions), do: {:error, :invalid_gateway_result}

  defp validate_subscription(subscription) when is_map(subscription) do
    with {:ok, attachment_ref} <- Map.fetch(subscription, :attachment_ref),
         true <- not is_nil(attachment_ref),
         {:ok, event_token} <- Map.fetch(subscription, :attachment_token),
         true <- is_reference(event_token),
         projected when is_map(projected) <-
           subscription
           |> Map.drop([:attachment_ref, :attachment_token])
           |> PublicData.project() do
      {:ok, projected, attachment_ref, event_token}
    else
      _other -> {:error, :invalid_gateway_result}
    end
  end

  defp validate_subscription(_subscription), do: {:error, :invalid_gateway_result}

  defp detach_invalid_subscription(identity, %{attachment_ref: attachment_ref})
       when not is_nil(attachment_ref) do
    LiveGateway.detach(identity, attachment_ref, self())
  end

  defp detach_invalid_subscription(_identity, _subscription), do: :ok

  defp validate_evaluations(evaluations)
       when is_list(evaluations) and length(evaluations) <= 100 do
    checked =
      Enum.reduce_while(evaluations, [], fn
        %{id: id, label: label}, acc when is_binary(id) and is_binary(label) ->
          if valid_id?(id) and String.valid?(label) and byte_size(label) <= 256 do
            {:cont, [%{id: id, label: label} | acc]}
          else
            {:halt, :error}
          end

        _evaluation, _acc ->
          {:halt, :error}
      end)

    case checked do
      :error -> {:error, :invalid_gateway_result}
      values -> {:ok, Enum.reverse(values)}
    end
  end

  defp validate_evaluations(_evaluations), do: {:error, :invalid_gateway_result}

  defp visible_session?(sessions, id), do: Enum.any?(sessions, &(&1.id == id))
  defp visible_evaluation?(reports, id), do: Enum.any?(reports, &(&1.id == id))

  defp valid_id?(value) when is_binary(value),
    do: byte_size(value) > 0 and byte_size(value) <= 128 and String.valid?(value)

  defp valid_id?(_value), do: false

  defp valid_text?(text, max_bytes) do
    byte_size(text) > 0 and byte_size(text) <= max_bytes and String.valid?(text)
  end

  defp live_event_item(sequence, event) do
    {:ok, %{sequence: sequence, json: Jason.encode!(event, pretty: true)}}
  rescue
    _error -> {:error, :invalid_live_event}
  end

  defp encode_public(value) do
    {:ok, value |> PublicData.project() |> Jason.encode!(pretty: true)}
  rescue
    _error -> {:error, :invalid_public_data}
  end

  defp bounded_report(report, max_bytes)
       when is_binary(report) and is_integer(max_bytes) and byte_size(report) <= max_bytes and
              byte_size(report) > 0 do
    if String.valid?(report), do: {:ok, report}, else: {:error, :invalid_report}
  end

  defp bounded_report(_report, _max_bytes), do: {:error, :invalid_report}

  defp dropped_count({:ok, count}), do: count
  defp dropped_count(:item_too_large), do: 1

  defp item_error(:item_too_large),
    do: "An oversized Live event was omitted from the browser view."

  defp item_error({:ok, _count}), do: nil
  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp reauthenticate(socket), do: {:noreply, redirect(socket, to: "/auth/login")}
end
