defmodule ErlangAdkUiWeb.AuthControllerTest do
  use ErlangAdkUiWeb.ConnCase, async: false

  alias ErlangAdkUi.Auth.SessionStore

  setup do
    Application.put_env(:erlang_adk_ui, :test_auth_pid, self())

    on_exit(fn ->
      Application.delete_env(:erlang_adk_ui, :test_auth_pid)
      Application.delete_env(:erlang_adk_ui, :test_auth_complete_mode)
    end)

    :ok
  end

  test "the browser receives only an opaque login handle and callback replay fails", %{conn: conn} do
    login_conn = get(conn, ~p"/auth/login")
    assert_receive {:authorization_request, flow}

    assert redirected_to(login_conn) ==
             "https://idp.example.test/authorize?state=#{URI.encode_www_form(flow["state"])}"

    flow_handle = get_session(login_conn, "oidc_flow_handle")
    assert is_binary(flow_handle)
    assert byte_size(flow_handle) >= 32
    assert get_session(login_conn, "oidc_flow") == nil

    [set_cookie] = get_resp_header(login_conn, "set-cookie")
    refute set_cookie =~ flow["state"]
    refute set_cookie =~ flow["nonce"]
    refute set_cookie =~ flow["pkce_verifier"]

    callback_params = %{"code" => "good", "state" => flow["state"]}

    callback_conn =
      login_conn
      |> recycle()
      |> get(~p"/auth/callback", callback_params)

    assert_receive {:complete, ^callback_params, ^flow}
    assert redirected_to(callback_conn) == ~p"/agent"
    assert {:ok, _identity} = SessionStore.fetch(get_session(callback_conn, "auth_session_id"))

    replay_conn =
      login_conn
      |> recycle()
      |> get(~p"/auth/callback", callback_params)

    assert replay_conn.status == 401
    assert replay_conn.resp_body == "authentication failed"
    refute_received {:complete, _params, _flow}
  end

  test "a failed callback also consumes the login transaction", %{conn: conn} do
    login_conn = get(conn, ~p"/auth/login")
    assert_receive {:authorization_request, flow}

    bad_params = %{"code" => "good", "state" => "wrong-state"}

    bad_conn =
      login_conn
      |> recycle()
      |> get(~p"/auth/callback", bad_params)

    assert_receive {:complete, ^bad_params, ^flow}
    assert bad_conn.status == 401

    good_params = %{"code" => "good", "state" => flow["state"]}

    replay_conn =
      login_conn
      |> recycle()
      |> get(~p"/auth/callback", good_params)

    assert replay_conn.status == 401
    refute_received {:complete, ^good_params, _flow}
  end

  test "starting a new login retires prior auth and login handles", %{conn: conn} do
    assert {:ok, auth_handle} = SessionStore.issue(ErlangAdkUi.TestAuthProvider.identity())

    assert {:ok, old_flow_handle} =
             ErlangAdkUi.Auth.LoginFlowStore.issue(%{"state" => "superseded"})

    conn =
      conn
      |> init_test_session(%{
        "auth_session_id" => auth_handle,
        "oidc_flow_handle" => old_flow_handle
      })
      |> get(~p"/auth/login")

    assert_receive {:authorization_request, _new_flow}
    assert conn.status == 302
    assert {:error, :unauthenticated} = SessionStore.fetch(auth_handle)

    assert {:error, :login_flow_not_found} =
             ErlangAdkUi.Auth.LoginFlowStore.consume(old_flow_handle)
  end

  test "a timed-out code exchange consumes state before returning a safe error", %{conn: conn} do
    login_conn = get(conn, ~p"/auth/login")
    assert_receive {:authorization_request, flow}
    Application.put_env(:erlang_adk_ui, :test_auth_complete_mode, :timeout)

    callback_params = %{"code" => "good", "state" => flow["state"]}

    callback_conn =
      login_conn
      |> recycle()
      |> get(~p"/auth/callback", callback_params)

    assert_receive {:complete, ^callback_params, ^flow}
    assert callback_conn.status == 503
    assert callback_conn.resp_body == "identity provider unavailable"

    Application.delete_env(:erlang_adk_ui, :test_auth_complete_mode)

    replay_conn =
      login_conn
      |> recycle()
      |> get(~p"/auth/callback", callback_params)

    assert replay_conn.status == 401
    refute_received {:complete, _params, _flow}
  end

  test "security headers keep LiveView connections same-origin", %{conn: conn} do
    conn = get(conn, ~p"/health")
    [policy] = get_resp_header(conn, "content-security-policy")

    assert policy =~ "connect-src 'self' ws://www.example.com"
    refute policy =~ "connect-src *"
    refute policy =~ "wss://"
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "secure pages authorize only their exact wss origin" do
    conn =
      Plug.Test.conn(:get, "https://agents.example.com/health")
      |> ErlangAdkUiWeb.Endpoint.call([])

    [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "connect-src 'self' wss://agents.example.com"
    refute policy =~ "ws://"
  end
end
