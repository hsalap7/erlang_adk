defmodule ErlangAdkUiWeb.Layouts do
  use ErlangAdkUiWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :page_title, :string, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a class="skip-link" href="#main-content">Skip to main content</a>
    <div class="shell">
      <header class="topbar">
        <a class="brand" href={~p"/agent"} aria-label="Erlang ADK agent console">
          <span class="brand-mark" aria-hidden="true">EA</span>
          <span class="brand-copy">
            <strong>Erlang ADK</strong>
            <small>Developer workspace</small>
          </span>
        </a>

        <div class="topbar-actions">
          <span :if={local_dev_mode?()} class="mode-badge">
            <span class="status-dot" aria-hidden="true"></span> Local authentication
          </span>
          <nav class="nav" aria-label="ADK console">
            <a href={~p"/agent"} aria-current={active_page(@page_title, "Agent")}>Agent runs</a>
            <a href={~p"/live"} aria-current={active_page(@page_title, "Live and operations")}>
              Live and operations
            </a>
          </nav>
          <form action={~p"/auth/logout"} method="post">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <input type="hidden" name="_method" value="delete" />
            <button class="quiet" type="submit">Sign out</button>
          </form>
        </div>
      </header>

      <main class="workspace" id="main-content" tabindex="-1">
        <p :if={Phoenix.Flash.get(@flash, :info)} class="notice" role="status">
          {Phoenix.Flash.get(@flash, :info)}
        </p>
        <p :if={Phoenix.Flash.get(@flash, :error)} class="notice error" role="alert">
          {Phoenix.Flash.get(@flash, :error)}
        </p>
        {render_slot(@inner_block)}
      </main>

      <footer class="console-footer">
        <span>Erlang ADK v0.7</span>
        <span>Bounded · supervised · server-owned</span>
      </footer>
    </div>
    """
  end

  defp local_dev_mode?, do: Application.get_env(:erlang_adk_ui, :local_dev_mode, false)
  defp active_page(page_title, page_title), do: "page"
  defp active_page(_page_title, _link_title), do: nil
end
