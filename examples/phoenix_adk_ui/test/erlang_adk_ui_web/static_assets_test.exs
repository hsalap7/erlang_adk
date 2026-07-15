defmodule ErlangAdkUiWeb.StaticAssetsTest do
  use ErlangAdkUiWeb.ConnCase, async: false

  alias ErlangAdkUi.Auth.LocalDev

  setup do
    previous_local_dev_mode = Application.get_env(:erlang_adk_ui, :local_dev_mode)
    previous_auth_provider = Application.get_env(:erlang_adk_ui, :auth_provider)

    Application.put_env(:erlang_adk_ui, :local_dev_mode, true)
    Application.put_env(:erlang_adk_ui, :auth_provider, LocalDev)

    on_exit(fn ->
      restore_env(:local_dev_mode, previous_local_dev_mode)
      restore_env(:auth_provider, previous_auth_provider)
    end)

    :ok
  end

  test "the endpoint serves the application stylesheet as meaningful CSS", %{conn: conn} do
    conn = get(conn, ~p"/assets/css/app.css")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "text/css")
    assert byte_size(conn.resp_body) >= 1_024
    assert conn.resp_body =~ ":root"
    assert conn.resp_body =~ ".shell"
    assert conn.resp_body =~ ".panel"
  end

  test "the rendered root layout references the served stylesheet", %{conn: conn} do
    html = conn |> get(~p"/auth/login") |> html_response(200)

    assert html =~ ~s(rel="stylesheet")
    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ ~s(rel="icon")
    assert html =~ ~s(href="/favicon.svg")
  end

  test "the endpoint serves the favicon and handles the conventional ico path", %{conn: conn} do
    favicon = get(conn, ~p"/favicon.svg")

    assert favicon.status == 200
    assert [content_type] = get_resp_header(favicon, "content-type")
    assert String.starts_with?(content_type, "image/svg+xml")
    assert favicon.resp_body =~ "<svg"
    assert favicon.resp_body =~ "Erlang ADK"

    fallback = get(recycle(favicon), ~p"/favicon.ico")
    assert redirected_to(fallback) == ~p"/favicon.svg"
  end

  test "the endpoint serves a digested root favicon target", %{conn: conn} do
    filename = "favicon-test-#{System.unique_integer([:positive])}.svg"
    path = Application.app_dir(:erlang_adk_ui, Path.join("priv/static", filename))
    body = ~s(<svg xmlns="http://www.w3.org/2000/svg"><title>Digest target</title></svg>)

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)

    favicon = get(conn, "/#{filename}?vsn=d")

    assert favicon.status == 200
    assert [content_type] = get_resp_header(favicon, "content-type")
    assert String.starts_with?(content_type, "image/svg+xml")

    assert get_resp_header(favicon, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]

    assert favicon.resp_body == body
  end

  test "the endpoint serves the dedicated voice worklet as JavaScript", %{conn: conn} do
    conn = get(conn, "/assets/js/live_voice_worklet.js")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "javascript"
    assert byte_size(conn.resp_body) >= 1_024
    assert conn.resp_body =~ ~s(registerProcessor("adk-pcm-capture")
  end

  defp restore_env(key, nil), do: Application.delete_env(:erlang_adk_ui, key)
  defp restore_env(key, value), do: Application.put_env(:erlang_adk_ui, key, value)
end
