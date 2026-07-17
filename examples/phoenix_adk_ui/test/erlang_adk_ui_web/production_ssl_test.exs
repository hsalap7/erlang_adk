defmodule ErlangAdkUiWeb.ProductionSSLTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ErlangAdkUiWeb.Plugs.ProductionSSL

  setup do
    previous = Application.get_env(:erlang_adk_ui, :ssl_options)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:erlang_adk_ui, :ssl_options)
        value -> Application.put_env(:erlang_adk_ui, :ssl_options, value)
      end
    end)

    :ok
  end

  test "direct TLS mode does not trust forwarded protocol headers" do
    Application.put_env(:erlang_adk_ui, :ssl_options, hsts: true)

    conn =
      conn(:get, "http://internal.example/health")
      |> put_req_header("x-forwarded-proto", "https")
      |> ProductionSSL.call([])

    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["https://internal.example/health"]
  end

  test "explicit trusted-proxy mode rewrites before enforcing SSL" do
    Application.put_env(:erlang_adk_ui, :ssl_options,
      rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto],
      hsts: true
    )

    conn =
      conn(:get, "http://internal.example/health")
      |> put_req_header("x-forwarded-host", "agents.example.com")
      |> put_req_header("x-forwarded-port", "443")
      |> put_req_header("x-forwarded-proto", "https")
      |> ProductionSSL.call([])

    assert conn.status == nil
    assert conn.scheme == :https
    assert conn.host == "agents.example.com"
    assert conn.port == 443
    assert get_resp_header(conn, "strict-transport-security") != []
  end

  test "invalid runtime options fail closed" do
    Application.put_env(:erlang_adk_ui, :ssl_options, :invalid)

    assert_raise ArgumentError, "invalid runtime SSL options", fn ->
      ProductionSSL.call(conn(:get, "/health"), [])
    end
  end
end
