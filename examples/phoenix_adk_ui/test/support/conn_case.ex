defmodule ErlangAdkUiWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ErlangAdkUiWeb.Endpoint

      use Phoenix.VerifiedRoutes,
        endpoint: ErlangAdkUiWeb.Endpoint,
        router: ErlangAdkUiWeb.Router,
        statics: ErlangAdkUiWeb.static_paths()

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
