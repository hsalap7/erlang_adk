defmodule ErlangAdkUiWeb.Plugs.ProductionSSL do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    case Application.get_env(:erlang_adk_ui, :ssl_options, false) do
      false ->
        conn

      options when is_list(options) ->
        Plug.SSL.call(conn, Plug.SSL.init(options))

      _invalid ->
        raise ArgumentError, "invalid runtime SSL options"
    end
  end
end
