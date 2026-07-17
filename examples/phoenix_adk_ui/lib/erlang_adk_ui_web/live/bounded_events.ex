defmodule ErlangAdkUiWeb.BoundedEvents do
  @moduledoc false

  def append(events, total_bytes, item, max_events, max_bytes)
      when is_list(events) and is_integer(total_bytes) and total_bytes >= 0 and
             is_integer(max_events) and max_events > 0 and is_integer(max_bytes) and
             max_bytes > 0 do
    item_bytes = item_bytes(item)

    if item_bytes > max_bytes do
      {events, total_bytes, :item_too_large}
    else
      trim(events ++ [item], total_bytes + item_bytes, max_events, max_bytes, 0)
    end
  end

  defp trim(entries, bytes, max_events, max_bytes, dropped)
       when length(entries) > max_events or bytes > max_bytes do
    [item | rest] = entries
    trim(rest, bytes - item_bytes(item), max_events, max_bytes, dropped + 1)
  end

  defp trim(entries, bytes, _max_events, _max_bytes, dropped) do
    {entries, bytes, {:ok, dropped}}
  end

  defp item_bytes(item), do: item |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
