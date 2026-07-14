defmodule ErlangAdkUi.Gateway do
  @moduledoc """
  Starts `:adk_web_gateway` from a server-owned catalog provider.

  The provider module is deployment configuration, never request input. The
  resulting gateway catalog and authorization policy are immutable for the
  process lifetime.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(_opts) do
    provider = Application.fetch_env!(:erlang_adk_ui, :gateway_provider)

    with {:ok, options} when is_map(options) <- provider.gateway_options() do
      :adk_web_gateway.start_link(Map.put(options, :name, __MODULE__))
    else
      other -> {:error, {:invalid_gateway_catalog, safe_shape(other)}}
    end
  end

  defp safe_shape({:error, reason}) when is_atom(reason), do: reason
  defp safe_shape(_other), do: :invalid_result
end
