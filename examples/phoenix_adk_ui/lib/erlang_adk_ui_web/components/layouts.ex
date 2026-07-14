defmodule ErlangAdkUiWeb.Layouts do
  use ErlangAdkUiWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="shell">
      <header class="topbar">
        <div>
          <h1>Erlang ADK</h1>
          <span class="muted">Production LiveView companion</span>
          <nav class="nav" aria-label="ADK console">
            <a href={~p"/agent"}>Agent runs</a>
            <a href={~p"/live"}>Live and operations</a>
          </nav>
        </div>
        <form action={~p"/auth/logout"} method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <input type="hidden" name="_method" value="delete" />
          <button class="secondary" type="submit">Sign out</button>
        </form>
      </header>
      <p :if={Phoenix.Flash.get(@flash, :info)} class="notice">{Phoenix.Flash.get(@flash, :info)}</p>
      <p :if={Phoenix.Flash.get(@flash, :error)} class="notice error">
        {Phoenix.Flash.get(@flash, :error)}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
