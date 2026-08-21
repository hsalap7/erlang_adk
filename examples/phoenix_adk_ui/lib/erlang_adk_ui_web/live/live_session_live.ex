defmodule ErlangAdkUiWeb.LiveSessionLive do
  use ErlangAdkUiWeb, :live_view

  alias ErlangAdkUi.Auth.SessionStore
  alias ErlangAdkUi.LiveGateway
  alias ErlangAdkUiWeb.{BoundedEvents, BoundedText, LiveProjection, PublicData}

  @content_keys MapSet.new([
                  "arguments",
                  "audio",
                  "body",
                  "completion",
                  "content",
                  "data",
                  "inline_data",
                  "input",
                  "media",
                  "output",
                  "payload",
                  "prompt",
                  "request",
                  "response",
                  "result",
                  "thought_signature",
                  "tool_arguments",
                  "tool_result",
                  "video"
                ])

  @impl true
  def mount(_params, _session, socket) do
    limits = Application.fetch_env!(:erlang_adk_ui, :ui_limits)

    socket =
      assign(socket,
        page_title: "Live and operations",
        limits: limits,
        live_sessions: [],
        attached_session_id: nil,
        attached_session_state: nil,
        attached_voice_mode: nil,
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
        evaluation_error: nil,
        graphs: [],
        graph_catalog_truncated: false,
        graph_detail: nil,
        graph_overlay: nil,
        selected_graph_id: nil,
        graph_overlay_cursor: 0,
        graph_overlay_recovery_cursor: nil,
        graph_error: nil,
        trace_timeline: nil,
        trace_cursor: 0,
        trace_recovery_cursor: nil,
        trace_truncated: false,
        trace_error: nil,
        dashboard_loaded: false
      )

    if connected?(socket), do: load_dashboard(socket), else: {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title}>
      <header class="page-heading">
        <div>
          <p class="eyebrow">Realtime control plane</p>
          <h1>Live and operations</h1>
          <p>
            Attach to server-owned Gemini Live sessions and inspect bounded operational data
            without exposing credentials, media payloads, or provider internals.
          </p>
        </div>
        <span class="phase-badge phase-ready" role="status">Operational</span>
      </header>

      <div class="dashboard-grid">
        <section class="panel panel-primary stack dashboard-wide" id="live-console">
          <div class="panel-heading">
            <div>
              <p class="panel-kicker">Realtime sessions</p>
              <h2>ADK Live sessions</h2>
              <p class="muted">
                Sessions are created and owned by the server. Attaching receives future events only;
                this UI does not request or claim event replay.
              </p>
            </div>
            <span class="panel-icon" aria-hidden="true">⌁</span>
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

          <p :if={@live_error} class="notice error" id="live-error" role="alert">
            {@live_error}
          </p>

          <form :if={@live_sessions != []} id="attach-form" phx-submit="attach" class="stack">
            <label>
              Principal-scoped session
              <select name="session_id" required>
                <option :for={session <- @live_sessions} value={session.id}>
                  {session.id} · {session.state} · voice: {session.voice_mode} · {session.model}
                </option>
              </select>
            </label>
            <button type="submit" phx-disable-with="Attaching…">Attach without replay</button>
          </form>

          <p
            :if={!@dashboard_loaded}
            class="empty-state"
            id="live-sessions-loading"
            role="status"
            aria-live="polite"
          >
            <strong>Connecting to the operations gateway</strong>
            <span>Discovering principal-scoped Live sessions.</span>
          </p>

          <p
            :if={@dashboard_loaded && @live_sessions == []}
            class="empty-state"
            id="no-live-sessions"
            role="status"
          >
            <strong>No visible Live sessions</strong>
            <span>Start a server-owned session for this principal, then refresh.</span>
          </p>

          <div
            :if={@attached_session_id}
            id="live-attachment"
            class="notice"
            role="status"
            aria-live="polite"
          >
            Attached to <code>{@attached_session_id}</code>. Credit is fixed server-side and each
            event is acknowledged only after safe projection into the bounded view.
          </div>

          <div
            :if={
              @attached_session_id && @attached_session_state == "active" &&
                @attached_voice_mode == "automatic"
            }
            id="live-voice-container"
          >
            <section
              id="live-voice-console"
              class="voice-console"
              phx-hook="LiveVoice"
              phx-update="ignore"
              data-session-id={@attached_session_id}
              data-voice-path="/live/voice"
              data-worklet-url={~p"/assets/js/live_voice_worklet.js"}
              aria-labelledby="live-voice-title"
            >
              <div class="voice-heading">
                <div>
                  <p class="panel-kicker">Native audio</p>
                  <h3 id="live-voice-title">Full-duplex voice</h3>
                  <p class="muted">
                    Stream microphone PCM through the authenticated ADK voice bridge and play the
                    model response in real time. Headphones are recommended.
                  </p>
                </div>
                <span class="voice-orb" data-voice-orb aria-hidden="true"></span>
              </div>

              <div class="voice-level" aria-hidden="true">
                <span data-voice-level></span>
              </div>

              <div class="actions voice-actions">
                <button id="voice-start" type="button" data-voice-start>Start voice</button>
                <button
                  id="voice-mute"
                  type="button"
                  class="secondary"
                  data-voice-mute
                  aria-pressed="false"
                  disabled
                >
                  Mute microphone
                </button>
                <button id="voice-stop" type="button" class="danger" data-voice-stop disabled>
                  Stop voice
                </button>
              </div>

              <p class="voice-status" data-voice-status role="status" aria-live="polite">
                Voice is idle. Starting will request microphone access.
              </p>
              <p
                class="voice-transcript"
                data-voice-transcript
                role="region"
                aria-label="Current voice transcription"
              >
              </p>
              <p
                class="visually-hidden"
                data-voice-announcement
                aria-live="polite"
                aria-atomic="true"
              >
              </p>
            </section>
          </div>

          <p
            :if={
              @attached_session_id &&
                not (@attached_session_state == "active" &&
                       @attached_voice_mode == "automatic")
            }
            id="live-voice-unavailable"
            class="notice"
            role="status"
          >
            {voice_unavailable_message(@attached_session_state, @attached_voice_mode)}
          </p>

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
            <button type="submit" phx-disable-with="Sending…">Send text</button>
          </form>
        </section>

        <section :if={@live_events != []} class="panel dashboard-wide" id="live-event-history">
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
          <div class="panel-heading">
            <div>
              <p class="panel-kicker">Telemetry</p>
              <h2>Observability snapshot</h2>
              <p class="muted">
                Read-only, bounded metric and delivery metadata. Prompt, response and media content are not exposed.
              </p>
            </div>
            <span class="panel-icon" aria-hidden="true">◫</span>
          </div>
          <button type="button" class="secondary" phx-click="refresh-observability">Refresh snapshot</button>
          <p :if={@observability_error} class="notice error" role="alert">
            {@observability_error}
          </p>
          <pre :if={@observability} class="outcome" id="observability-snapshot" role="status"><%= @observability %></pre>
        </section>

        <section class="panel stack dashboard-wide" id="graph-panel">
          <div class="panel-heading">
            <div>
              <p class="panel-kicker">Workflow topology</p>
              <h2>Graph catalog and execution overlay</h2>
              <p class="muted">
                Graphs come from a server-owned catalog. The browser can select only a returned ID;
                service handles, owners, trace principals, modules and paths stay in release configuration.
              </p>
            </div>
            <span class="panel-icon" aria-hidden="true">⌘</span>
          </div>

          <button type="button" class="secondary" phx-click="refresh-graphs">
            Refresh graph catalog
          </button>

          <p :if={@graphs == [] && !@graph_error} class="empty-state" id="no-graphs" role="status">
            <strong>No graphs available</strong>
            <span>Publish compiled graphs through the trusted server-side catalog.</span>
          </p>

          <p :if={@graph_catalog_truncated} class="muted" id="graphs-truncated">
            The bounded catalog view omits additional server-owned graphs.
          </p>

          <form :if={@graphs != []} id="graph-form" phx-submit="show-graph" class="stack">
            <label>
              Server-owned graph
              <select name="graph_id" required>
                <option :for={graph <- @graphs} value={graph.id}>{graph.id}</option>
              </select>
            </label>
            <button type="submit" phx-disable-with="Loading…">Inspect graph</button>
          </form>

          <div :if={@selected_graph_id} class="actions">
            <button type="button" class="secondary" phx-click="refresh-graph-overlay">
              Continue overlay from cursor {@graph_overlay_cursor}
            </button>
            <button
              :if={is_integer(@graph_overlay_recovery_cursor)}
              type="button"
              class="secondary"
              id="resume-graph-overlay"
              phx-click="resume-graph-overlay"
            >
              Resume overlay at retained boundary
            </button>
          </div>

          <p :if={@graph_error} class="notice error" id="graph-error" role="alert">
            {@graph_error}
          </p>
          <pre :if={@graph_detail} class="outcome" id="graph-detail" role="status"><%= @graph_detail %></pre>
          <pre :if={@graph_overlay} class="outcome" id="graph-overlay" role="status"><%= @graph_overlay %></pre>
        </section>

        <section class="panel stack dashboard-wide" id="trace-panel">
          <div class="panel-heading">
            <div>
              <p class="panel-kicker">Execution metadata</p>
              <h2>Trace timeline</h2>
              <p class="muted">
                The trace store and selector are fixed server-side. Only redacted lifecycle and
                observability metadata is rendered; prompts, responses, media and tool payloads are excluded.
              </p>
            </div>
            <span class="panel-icon" aria-hidden="true">⋮</span>
          </div>

          <div class="actions">
            <button type="button" class="secondary" phx-click="refresh-traces">
              Continue from cursor {@trace_cursor}
            </button>
            <button
              :if={is_integer(@trace_recovery_cursor)}
              type="button"
              class="secondary"
              id="resume-traces"
              phx-click="resume-traces"
            >
              Resume at retained boundary
            </button>
          </div>

          <p :if={@trace_truncated} class="muted" id="trace-truncated">
            More retained metadata is available after cursor {@trace_cursor}.
          </p>
          <p :if={@trace_error} class="notice error" id="trace-error" role="alert">
            {@trace_error}
          </p>
          <pre :if={@trace_timeline} class="outcome" id="trace-timeline" role="status"><%= @trace_timeline %></pre>
        </section>

        <section class="panel stack" id="evaluation-panel">
          <div class="panel-heading">
            <div>
              <p class="panel-kicker">Quality</p>
              <h2>Evaluation reports</h2>
              <p class="muted">
                Reports are server-configured maps rendered through the pure ADK evaluation boundary.
                Browser-supplied paths and module names are never accepted.
              </p>
            </div>
            <span class="panel-icon" aria-hidden="true">◇</span>
          </div>

          <p
            :if={!@dashboard_loaded}
            class="empty-state"
            id="evaluations-loading"
            role="status"
            aria-live="polite"
          >
            <strong>Loading evaluation catalog</strong>
            <span>Checking the server-configured reports available to this principal.</span>
          </p>

          <p
            :if={@dashboard_loaded && @evaluations == []}
            class="empty-state"
            id="no-evaluations"
            role="status"
          >
            <strong>No reports configured</strong>
            <span>Add trusted evaluation results in the server configuration.</span>
          </p>

          <form
            :if={@evaluations != []}
            id="evaluation-form"
            phx-submit="show-evaluation"
            class="stack"
          >
            <label>
              Report
              <select name="report_id" required>
                <option :for={report <- @evaluations} value={report.id}>{report.label}</option>
              </select>
            </label>
            <button type="submit" phx-disable-with="Rendering…">Render report</button>
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
            <button type="submit" phx-disable-with="Comparing…">Compare baseline</button>
          </form>

          <p :if={@evaluation_error} class="notice error" role="alert">{@evaluation_error}</p>
          <pre
            :if={@evaluation_report}
            class="outcome"
            id="evaluation-report"
            role="status"
            aria-live="polite"
          ><%= @evaluation_report %></pre>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("refresh-live", _params, socket) do
    with {:ok, identity} <- current_identity(socket),
         {:ok, sessions} <- LiveGateway.discover(identity),
         {:ok, checked} <- validate_sessions(sessions) do
      {:noreply,
       socket
       |> assign(live_sessions: checked, live_error: nil)
       |> sync_attached_session(checked)}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, live_error: "Live sessions are unavailable.")}
    end
  end

  def handle_event("attach", %{"session_id" => session_id}, socket) when is_binary(session_id) do
    with {:ok, selected_session} <- selected_session(socket.assigns.live_sessions, session_id),
         {:ok, identity} <- current_identity(socket),
         :ok <- detach_current(socket, identity),
         {:ok, public_subscription, attachment_ref, event_token} <-
           attach_checked(identity, session_id) do
      {:noreply,
       assign(socket,
         attached_session_id: session_id,
         attached_session_state: Map.fetch!(public_subscription, "state"),
         attached_voice_mode: selected_session.voice_mode,
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

  def handle_event("refresh-graphs", _params, socket) do
    with {:ok, identity} <- current_identity(socket),
         {:ok, updated} <- load_graphs(socket, identity) do
      {:noreply, updated}
    else
      {:error, :unauthenticated} -> reauthenticate(socket)
      _error -> {:noreply, assign(socket, graph_error: "The graph catalog is unavailable.")}
    end
  end

  def handle_event("show-graph", %{"graph_id" => graph_id}, socket)
      when is_binary(graph_id) do
    with true <- visible_graph?(socket.assigns.graphs, graph_id),
         {:ok, identity} <- current_identity(socket),
         {:ok, detail} <- LiveGateway.graph_detail(identity, graph_id),
         {:ok, detail_json} <-
           validate_graph_detail(
             detail,
             graph_id,
             socket.assigns.limits[:max_graph_bytes]
           ) do
      prepared =
        assign(socket,
          selected_graph_id: graph_id,
          graph_detail: detail_json,
          graph_overlay: nil,
          graph_overlay_cursor: 0,
          graph_overlay_recovery_cursor: nil,
          graph_error: nil
        )

      case load_graph_overlay(prepared, identity, graph_id, 0) do
        {:ok, updated} ->
          {:noreply, updated}

        {:error, {:replay_gap, recovery}} ->
          {:noreply,
           assign(prepared,
             graph_overlay_recovery_cursor: recovery,
             graph_error: replay_gap_message("Graph overlay")
           )}

        {:error, {:cursor_ahead, recovery}} ->
          {:noreply,
           assign(prepared,
             graph_overlay_recovery_cursor: recovery,
             graph_error: cursor_ahead_message("Graph overlay")
           )}

        _error ->
          {:noreply, assign(prepared, graph_error: "The execution overlay is unavailable.")}
      end
    else
      {:error, :unauthenticated} ->
        reauthenticate(socket)

      _error ->
        {:noreply, assign(socket, graph_error: "The graph could not be inspected safely.")}
    end
  end

  def handle_event("show-graph", _params, socket),
    do: {:noreply, assign(socket, graph_error: "Invalid graph selection.")}

  def handle_event(
        "refresh-graph-overlay",
        _params,
        %{assigns: %{selected_graph_id: graph_id, graph_overlay_cursor: cursor}} = socket
      )
      when is_binary(graph_id) and is_integer(cursor) and cursor >= 0 do
    continue_graph_overlay(socket, graph_id, cursor)
  end

  def handle_event(
        "resume-graph-overlay",
        _params,
        %{
          assigns: %{
            selected_graph_id: graph_id,
            graph_overlay_recovery_cursor: cursor
          }
        } = socket
      )
      when is_binary(graph_id) and is_integer(cursor) and cursor >= 0 do
    continue_graph_overlay(socket, graph_id, cursor)
  end

  def handle_event("refresh-graph-overlay", _params, socket),
    do: {:noreply, assign(socket, graph_error: "Select a visible graph first.")}

  def handle_event("resume-graph-overlay", _params, socket),
    do: {:noreply, assign(socket, graph_error: "No graph replay gap can be resumed.")}

  def handle_event("refresh-traces", _params, socket) do
    continue_traces(socket, socket.assigns.trace_cursor)
  end

  def handle_event(
        "resume-traces",
        _params,
        %{assigns: %{trace_recovery_cursor: cursor}} = socket
      )
      when is_integer(cursor) and cursor >= 0 do
    continue_traces(socket, cursor)
  end

  def handle_event("resume-traces", _params, socket),
    do: {:noreply, assign(socket, trace_error: "No trace replay gap can be resumed.")}

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
          dashboard_loaded: true,
          live_error: nil,
          evaluation_error: nil
        )

      socket =
        case load_observability(socket, identity) do
          {:ok, updated} ->
            updated

          {:error, _reason} ->
            assign(socket, observability_error: "Observability is unavailable.")
        end

      socket =
        case load_graphs(socket, identity) do
          {:ok, updated} -> updated
          {:error, _reason} -> assign(socket, graph_error: "The graph catalog is unavailable.")
        end

      socket =
        case load_trace(socket, identity, 0) do
          {:ok, updated} ->
            updated

          {:error, {:replay_gap, recovery}} ->
            assign(socket,
              trace_recovery_cursor: recovery,
              trace_error: replay_gap_message("Trace timeline")
            )

          {:error, {:cursor_ahead, recovery}} ->
            assign(socket,
              trace_recovery_cursor: recovery,
              trace_error: cursor_ahead_message("Trace timeline")
            )

          {:error, _reason} ->
            assign(socket, trace_error: "The trace timeline is unavailable.")
        end

      {:ok, socket}
    else
      {:error, :unauthenticated} ->
        {:ok, redirect(socket, to: "/auth/login")}

      _error ->
        {:ok,
         assign(socket,
           dashboard_loaded: true,
           live_error: "The operations gateway is unavailable."
         )}
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

  defp load_graphs(socket, identity) do
    with {:ok, page} <- LiveGateway.list_graphs(identity),
         {:ok, graphs, truncated} <-
           validate_graph_catalog(page, socket.assigns.limits[:max_graphs]) do
      {:ok,
       assign(socket,
         graphs: graphs,
         graph_catalog_truncated: truncated,
         graph_detail: nil,
         graph_overlay: nil,
         selected_graph_id: nil,
         graph_overlay_cursor: 0,
         graph_overlay_recovery_cursor: nil,
         graph_error: nil
       )}
    end
  end

  defp load_graph_overlay(socket, identity, graph_id, cursor) do
    case LiveGateway.graph_overlay(identity, graph_id, cursor) do
      {:ok, overlay} ->
        with {:ok, json, next_cursor} <-
               validate_graph_overlay(
                 overlay,
                 graph_id,
                 cursor,
                 socket.assigns.limits
               ) do
          {:ok,
           assign(socket,
             graph_overlay: json,
             graph_overlay_cursor: next_cursor,
             graph_overlay_recovery_cursor: nil,
             graph_error: nil
           )}
        end

      {:error, {:replay_gap, gap}} ->
        with {:ok, recovery} <- recovery_cursor(gap, :replay_gap) do
          {:error, {:replay_gap, recovery}}
        end

      {:error, {:cursor_ahead, gap}} ->
        with {:ok, recovery} <- recovery_cursor(gap, :cursor_ahead) do
          {:error, {:cursor_ahead, recovery}}
        end

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_gateway_result}
    end
  end

  defp load_trace(socket, identity, cursor) do
    case LiveGateway.trace_timeline(identity, cursor) do
      {:ok, timeline} ->
        with {:ok, json, next_cursor, truncated} <-
               validate_trace_page(timeline, cursor, socket.assigns.limits) do
          {:ok,
           assign(socket,
             trace_timeline: json,
             trace_cursor: next_cursor,
             trace_recovery_cursor: nil,
             trace_truncated: truncated,
             trace_error: nil
           )}
        end

      {:error, {:replay_gap, gap}} ->
        with {:ok, recovery} <- recovery_cursor(gap, :replay_gap) do
          {:error, {:replay_gap, recovery}}
        end

      {:error, {:cursor_ahead, gap}} ->
        with {:ok, recovery} <- recovery_cursor(gap, :cursor_ahead) do
          {:error, {:cursor_ahead, recovery}}
        end

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_gateway_result}
    end
  end

  defp continue_graph_overlay(socket, graph_id, cursor) do
    with {:ok, identity} <- current_identity(socket),
         {:ok, updated} <- load_graph_overlay(socket, identity, graph_id, cursor) do
      {:noreply, updated}
    else
      {:error, :unauthenticated} ->
        reauthenticate(socket)

      {:error, {:replay_gap, recovery}} ->
        {:noreply,
         assign(socket,
           graph_overlay_recovery_cursor: recovery,
           graph_error: replay_gap_message("Graph overlay")
         )}

      {:error, {:cursor_ahead, recovery}} ->
        {:noreply,
         assign(socket,
           graph_overlay_recovery_cursor: recovery,
           graph_error: cursor_ahead_message("Graph overlay")
         )}

      _error ->
        {:noreply, assign(socket, graph_error: "The execution overlay is unavailable.")}
    end
  end

  defp continue_traces(socket, cursor) do
    with {:ok, identity} <- current_identity(socket),
         {:ok, updated} <- load_trace(socket, identity, cursor) do
      {:noreply, updated}
    else
      {:error, :unauthenticated} ->
        reauthenticate(socket)

      {:error, {:replay_gap, recovery}} ->
        {:noreply,
         assign(socket,
           trace_recovery_cursor: recovery,
           trace_error: replay_gap_message("Trace timeline")
         )}

      {:error, {:cursor_ahead, recovery}} ->
        {:noreply,
         assign(socket,
           trace_recovery_cursor: recovery,
           trace_error: cursor_ahead_message("Trace timeline")
         )}

      _error ->
        {:noreply, assign(socket, trace_error: "The trace timeline is unavailable.")}
    end
  end

  defp validate_graph_catalog(page, maximum) when is_integer(maximum) and maximum > 0 do
    case metadata_projection(page) do
      %{"graphs" => graphs, "truncated" => truncated, "next_cursor" => next_cursor}
      when is_list(graphs) and is_boolean(truncated) ->
        with true <- length(graphs) <= maximum,
             true <- is_nil(next_cursor) or valid_id?(next_cursor),
             {:ok, checked} <- validate_graph_summaries(graphs) do
          {:ok, checked, truncated}
        else
          _other -> {:error, :invalid_gateway_result}
        end

      _other ->
        {:error, :invalid_gateway_result}
    end
  end

  defp validate_graph_catalog(_page, _maximum), do: {:error, :invalid_gateway_result}

  defp validate_graph_summaries(graphs) do
    Enum.reduce_while(graphs, {:ok, []}, fn graph, {:ok, acc} ->
      case graph_summary(graph) do
        {:ok, checked} -> {:cont, {:ok, [checked | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, checked} -> {:ok, Enum.reverse(checked)}
      {:error, _reason} = error -> error
    end
  end

  defp graph_summary(%{
         "id" => id,
         "fingerprint" => fingerprint,
         "generation" => generation,
         "updated_at" => updated_at,
         "encoded_bytes" => encoded_bytes
       })
       when is_binary(fingerprint) and byte_size(fingerprint) > 0 and
              byte_size(fingerprint) <= 128 and is_integer(generation) and generation >= 0 and
              is_integer(updated_at) and updated_at >= 0 and is_integer(encoded_bytes) and
              encoded_bytes >= 0 do
    if valid_id?(id) and String.valid?(fingerprint) do
      {:ok,
       %{
         id: id,
         fingerprint: fingerprint,
         generation: generation,
         updated_at: updated_at,
         encoded_bytes: encoded_bytes
       }}
    else
      {:error, :invalid_gateway_result}
    end
  end

  defp graph_summary(_graph), do: {:error, :invalid_gateway_result}

  defp validate_graph_detail(detail, graph_id, maximum) do
    projected = metadata_projection(detail)

    with %{"id" => ^graph_id, "graph" => graph} when is_map(graph) <- projected,
         {:ok, _summary} <- graph_summary(projected),
         {:ok, json} <- encode_bounded(projected, maximum) do
      {:ok, json}
    else
      _other -> {:error, :invalid_gateway_result}
    end
  end

  defp validate_graph_overlay(overlay, graph_id, cursor, limits) do
    projected = metadata_projection(overlay)

    with %{
           "content_captured" => false,
           "graph" => %{"id" => ^graph_id, "graph" => graph},
           "overlay" => execution_overlay,
           "trace" => trace
         }
         when is_map(graph) and is_map(execution_overlay) <- projected,
         {:ok, next_cursor, _truncated} <-
           validate_trace_shape(trace, cursor, limits[:max_trace_events]),
         {:ok, json} <- encode_bounded(projected, limits[:max_graph_bytes]) do
      {:ok, json, next_cursor}
    else
      _other -> {:error, :invalid_gateway_result}
    end
  end

  defp validate_trace_page(page, cursor, limits) do
    projected = metadata_projection(page)

    with {:ok, next_cursor, truncated} <-
           validate_trace_shape(projected, cursor, limits[:max_trace_events]),
         {:ok, json} <- encode_bounded(projected, limits[:max_trace_bytes]) do
      {:ok, json, next_cursor, truncated}
    end
  end

  defp validate_trace_shape(
         %{
           "events" => events,
           "next_cursor" => next_cursor,
           "oldest_available_cursor" => oldest,
           "latest_cursor" => latest,
           "encoded_bytes" => encoded_bytes,
           "truncated" => truncated
         },
         cursor,
         maximum
       )
       when is_list(events) and is_integer(next_cursor) and next_cursor >= cursor and
              (is_nil(oldest) or (is_integer(oldest) and oldest >= 0)) and is_integer(latest) and
              latest >= 0 and is_integer(encoded_bytes) and encoded_bytes >= 0 and
              is_boolean(truncated) and is_integer(maximum) and maximum > 0 do
    with true <- length(events) <= maximum,
         true <- valid_trace_events?(events, cursor, next_cursor) do
      {:ok, next_cursor, truncated}
    else
      _other -> {:error, :invalid_gateway_result}
    end
  end

  defp validate_trace_shape(_page, _cursor, _maximum),
    do: {:error, :invalid_gateway_result}

  defp valid_trace_events?(events, after_cursor, next_cursor) do
    Enum.reduce_while(events, after_cursor, fn event, previous ->
      case event do
        %{
          "cursor" => cursor,
          "kind" => kind,
          "timestamp_ms" => timestamp,
          "identity" => identity,
          "event" => metadata
        }
        when is_integer(cursor) and cursor > previous and cursor <= next_cursor and
               kind in ["observability", "workflow_lifecycle"] and is_integer(timestamp) and
               timestamp >= 0 and is_map(identity) and is_map(metadata) ->
          {:cont, cursor}

        _other ->
          {:halt, :error}
      end
    end) != :error
  end

  defp recovery_cursor(gap, mode) do
    case metadata_projection(gap) do
      %{
        "oldest_available_cursor" => oldest,
        "latest_cursor" => latest,
        "evicted_through" => evicted
      }
      when (is_nil(oldest) or (is_integer(oldest) and oldest >= 0)) and is_integer(latest) and
             latest >= 0 and is_integer(evicted) and evicted >= 0 ->
        cursor = if mode == :cursor_ahead, do: latest, else: evicted
        {:ok, cursor}

      _other ->
        {:error, :invalid_gateway_result}
    end
  end

  defp metadata_projection(value) do
    value
    |> :adk_secret_redactor.redact()
    |> normalize_operations(0)
  catch
    _kind, _reason -> :invalid
  end

  defp normalize_operations(_value, depth) when depth >= 16, do: "[omitted]"
  defp normalize_operations(value, _depth) when is_boolean(value) or is_nil(value), do: value
  defp normalize_operations(value, _depth) when value in [:null, :undefined], do: nil

  defp normalize_operations(value, _depth) when is_integer(value) or is_float(value), do: value

  defp normalize_operations(value, _depth) when is_binary(value) do
    if String.valid?(value), do: value, else: "[omitted]"
  end

  defp normalize_operations(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp normalize_operations(value, depth) when is_list(value) do
    Enum.map(value, &normalize_operations(&1, depth + 1))
  end

  defp normalize_operations(value, depth) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, item}, acc ->
      case operations_key(key) do
        {:ok, public_key} ->
          if content_key?(public_key) do
            acc
          else
            Map.put(acc, public_key, normalize_operations(item, depth + 1))
          end

        :error ->
          acc
      end
    end)
  end

  defp normalize_operations(_value, _depth), do: "[omitted]"

  defp operations_key(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) > 0 and byte_size(key) <= 512,
      do: {:ok, key},
      else: :error
  end

  defp operations_key(key) when is_atom(key), do: operations_key(Atom.to_string(key))
  defp operations_key(_key), do: :error

  defp content_key?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace("-", "_")
    MapSet.member?(@content_keys, normalized)
  end

  defp content_key?(_key), do: true

  defp encode_bounded(value, maximum)
       when is_integer(maximum) and maximum > 0 do
    encoded = Jason.encode!(value, pretty: true)

    if byte_size(encoded) <= maximum,
      do: {:ok, encoded},
      else: {:error, :invalid_gateway_result}
  rescue
    _error -> {:error, :invalid_gateway_result}
  end

  defp encode_bounded(_value, _maximum), do: {:error, :invalid_gateway_result}

  defp replay_gap_message(surface),
    do: "#{surface} has a replay gap. Resume explicitly at the retained boundary."

  defp cursor_ahead_message(surface),
    do: "#{surface} cursor is ahead of retained data. Resume explicitly at the retained boundary."

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
      attached_session_state: nil,
      attached_voice_mode: nil,
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
          if valid_id?(id) and checked_session_state?(state) and
               String.valid?(model) and byte_size(model) <= 256 do
            case checked_voice_mode(Map.get(session, :voice_mode)) do
              {:ok, voice_mode} ->
                public = %{
                  id: id,
                  state: state,
                  model: model,
                  voice_mode: voice_mode,
                  latest_sequence: non_negative(Map.get(session, :latest_sequence, 0))
                }

                {:cont, [public | acc]}

              :error ->
                {:halt, :error}
            end
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

  defp checked_voice_mode("automatic"), do: {:ok, "automatic"}
  defp checked_voice_mode("manual"), do: {:ok, "manual"}
  defp checked_voice_mode("unavailable"), do: {:ok, "unavailable"}
  defp checked_voice_mode(_mode), do: :error

  defp checked_session_state?(state),
    do: state in ["connecting", "setup_pending", "active", "reconnecting", "closed", "unknown"]

  defp validate_subscription(subscription) when is_map(subscription) do
    with {:ok, attachment_ref} <- Map.fetch(subscription, :attachment_ref),
         true <- not is_nil(attachment_ref),
         {:ok, event_token} <- Map.fetch(subscription, :attachment_token),
         true <- is_reference(event_token),
         projected when is_map(projected) <-
           subscription
           |> Map.drop([:attachment_ref, :attachment_token])
           |> PublicData.project(),
         state when is_binary(state) <- Map.get(projected, "state"),
         true <- checked_session_state?(state) do
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

  defp selected_session(sessions, id) do
    case Enum.filter(sessions, &(&1.id == id)) do
      [session] -> {:ok, session}
      _other -> {:error, :not_found}
    end
  end

  defp sync_attached_session(%{assigns: %{attached_session_id: nil}} = socket, _sessions),
    do: socket

  defp sync_attached_session(socket, sessions) do
    case selected_session(sessions, socket.assigns.attached_session_id) do
      {:ok, session} ->
        assign(socket,
          attached_session_state: session.state,
          attached_voice_mode: session.voice_mode
        )

      {:error, :not_found} ->
        assign(socket, attached_session_state: "unknown", attached_voice_mode: "unavailable")
    end
  end

  defp voice_unavailable_message(state, _mode) when state != "active" do
    "Browser voice is available only while the selected Live session reports active. Refresh after it reconnects or finishes setup."
  end

  defp voice_unavailable_message("active", "manual") do
    "Browser voice requires automatic activity detection. Text and metadata remain available for this manual-VAD session."
  end

  defp voice_unavailable_message(_state, _mode) do
    "Browser voice is unavailable because this session does not expose a supported activity-detection mode."
  end

  defp visible_evaluation?(reports, id), do: Enum.any?(reports, &(&1.id == id))
  defp visible_graph?(graphs, id), do: Enum.any?(graphs, &(&1.id == id))

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
