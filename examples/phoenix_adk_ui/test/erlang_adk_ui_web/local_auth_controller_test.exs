defmodule ErlangAdkUiWeb.LocalAuthControllerTest do
  use ErlangAdkUiWeb.ConnCase, async: false

  alias ErlangAdkUi.Auth.{LocalDev, SessionStore}

  @issuer "https://local.erlang-adk.invalid"
  @subject "local-developer"
  @scopes [
    "adk.agents.read",
    "adk.run.start",
    "adk.run.read",
    "adk.run.control",
    "adk.live.read",
    "adk.live.control",
    "adk.observability.read",
    "adk.evaluation.read"
  ]

  setup do
    previous = %{
      local_dev_mode: Application.get_env(:erlang_adk_ui, :local_dev_mode),
      auth_provider: Application.get_env(:erlang_adk_ui, :auth_provider),
      local_dev_auth: Application.get_env(:erlang_adk_ui, :local_dev_auth)
    }

    Application.put_env(:erlang_adk_ui, :local_dev_mode, true)
    Application.put_env(:erlang_adk_ui, :auth_provider, LocalDev)

    Application.put_env(:erlang_adk_ui, :local_dev_auth,
      enabled: true,
      issuer: @issuer,
      subject: @subject,
      audiences: ["erlang-adk-ui"],
      scopes: @scopes
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:erlang_adk_ui, key)
        {key, value} -> Application.put_env(:erlang_adk_ui, key, value)
      end)
    end)

    :ok
  end

  test "local login is an explicit CSRF-protected POST and stores only an opaque handle", %{
    conn: conn
  } do
    login_conn = get(conn, ~p"/auth/login")
    body = html_response(login_conn, 200)

    assert body =~ "Continue as local developer"
    assert [_, csrf_token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body)
    refute get_session(login_conn, "auth_session_id")

    authenticated_conn =
      login_conn
      |> recycle()
      |> post(~p"/auth/local", %{"_csrf_token" => csrf_token})

    assert redirected_to(authenticated_conn) == ~p"/agent"
    handle = get_session(authenticated_conn, "auth_session_id")
    assert is_binary(handle)
    assert byte_size(handle) >= 32

    assert {:ok, identity} = SessionStore.fetch(handle)
    owner_scope = :adk_scope_authorizer.owner_scope(@issuer, @subject)

    assert identity.principal == "oidc_" <> Base.url_encode64(owner_scope, padding: false)
    assert identity.subject == @subject
    assert identity.issuer == @issuer
    assert identity.scopes == @scopes

    response =
      authenticated_conn.resp_body <> Enum.join(get_resp_header(authenticated_conn, "set-cookie"))

    refute response =~ @subject
    refute response =~ @issuer
    refute response =~ identity.principal
    refute response =~ "GEMINI_API_KEY"
  end

  test "a fresh browser request can submit the rendered CSRF token with the returned cookie", %{
    conn: conn
  } do
    login_conn = get(conn, ~p"/auth/login")
    body = html_response(login_conn, 200)

    assert [_, csrf_token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body)
    assert [set_cookie] = get_resp_header(login_conn, "set-cookie")

    cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()
    assert String.starts_with?(cookie_pair, "_erlang_adk_ui_session=")

    authenticated_conn =
      build_conn()
      |> put_req_header("cookie", cookie_pair)
      |> post(~p"/auth/local", %{"_csrf_token" => csrf_token})

    assert redirected_to(authenticated_conn) == ~p"/agent"
    assert is_binary(get_session(authenticated_conn, "auth_session_id"))
  end

  test "revisiting local login rotates CSRF state before the form is submitted", %{conn: conn} do
    first_login = get(conn, ~p"/auth/login")
    first_body = html_response(first_login, 200)
    assert [_, first_token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, first_body)

    second_login = first_login |> recycle() |> get(~p"/auth/login")
    second_body = html_response(second_login, 200)
    assert [_, second_token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, second_body)
    refute second_token == first_token

    authenticated_conn =
      second_login
      |> recycle()
      |> post(~p"/auth/local", %{"_csrf_token" => second_token})

    assert redirected_to(authenticated_conn) == ~p"/agent"
    assert is_binary(get_session(authenticated_conn, "auth_session_id"))
  end

  test "the OIDC callback cannot create a session in local mode", %{conn: conn} do
    conn = get(conn, ~p"/auth/callback", %{"code" => "forged", "state" => "forged"})
    assert conn.status == 404
    assert conn.resp_body == "not found"
    refute get_session(conn, "auth_session_id")
  end

  test "local login route is unavailable when the local provider is not selected", %{conn: conn} do
    login_conn = get(conn, ~p"/auth/login")
    body = html_response(login_conn, 200)
    assert [_, csrf_token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body)

    Application.put_env(:erlang_adk_ui, :auth_provider, ErlangAdkUi.TestAuthProvider)

    conn =
      login_conn
      |> recycle()
      |> post(~p"/auth/local", %{"_csrf_token" => csrf_token})

    assert conn.status == 404
    refute get_session(conn, "auth_session_id")
  end
end
