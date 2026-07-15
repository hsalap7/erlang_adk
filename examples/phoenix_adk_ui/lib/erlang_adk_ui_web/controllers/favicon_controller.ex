defmodule ErlangAdkUiWeb.FaviconController do
  use ErlangAdkUiWeb, :controller

  def show(conn, _params), do: redirect(conn, to: ~p"/favicon.svg")
end
