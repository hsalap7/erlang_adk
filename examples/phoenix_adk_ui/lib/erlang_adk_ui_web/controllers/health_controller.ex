defmodule ErlangAdkUiWeb.HealthController do
  use ErlangAdkUiWeb, :controller

  def show(conn, _params), do: send_resp(conn, :ok, "ok")
end
