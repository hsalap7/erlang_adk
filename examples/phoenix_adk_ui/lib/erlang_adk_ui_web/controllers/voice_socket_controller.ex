defmodule ErlangAdkUiWeb.VoiceSocketController do
  @moduledoc false

  use ErlangAdkUiWeb, :controller

  alias ErlangAdkUiWeb.VoiceSocket

  def upgrade(conn, %{"session_id" => session_id}) do
    with :ok <- same_origin(conn),
         true <- valid_session_id?(session_id),
         auth_session_id when is_binary(auth_session_id) <-
           get_session(conn, "auth_session_id"),
         identity when is_map(identity) <- conn.assigns[:current_identity] do
      WebSockAdapter.upgrade(
        conn,
        VoiceSocket,
        %{
          auth_session_id: auth_session_id,
          identity: identity,
          session_id: session_id
        },
        VoiceSocket.connection_options()
      )
    else
      {:error, :origin} -> send_resp(conn, :forbidden, "forbidden")
      false -> send_resp(conn, :not_found, "not found")
      _error -> send_resp(conn, :unauthorized, "unauthenticated")
    end
  rescue
    WebSockAdapter.UpgradeError -> send_resp(conn, :bad_request, "invalid websocket upgrade")
  end

  def upgrade(conn, _params), do: send_resp(conn, :not_found, "not found")

  defp same_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin] ->
        if origin == expected_origin(conn), do: :ok, else: {:error, :origin}

      _other ->
        {:error, :origin}
    end
  end

  defp expected_origin(conn) do
    default_port =
      case conn.scheme do
        :http -> 80
        :https -> 443
        _other -> nil
      end

    URI.to_string(%URI{
      scheme: Atom.to_string(conn.scheme),
      host: conn.host,
      port: if(conn.port == default_port, do: nil, else: conn.port)
    })
  end

  defp valid_session_id?(session_id) when is_binary(session_id) do
    byte_size(session_id) > 0 and byte_size(session_id) <= 128 and String.valid?(session_id) and
      not String.contains?(session_id, ["\r", "\n", <<0>>])
  end

  defp valid_session_id?(_session_id), do: false
end
