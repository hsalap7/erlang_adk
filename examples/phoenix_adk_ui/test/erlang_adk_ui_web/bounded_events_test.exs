defmodule ErlangAdkUiWeb.BoundedEventsTest do
  use ExUnit.Case, async: true

  alias ErlangAdkUiWeb.BoundedEvents

  test "oldest events are removed to satisfy count and byte bounds" do
    first = %{sequence: 1, json: "one"}
    second = %{sequence: 2, json: "two"}
    third = %{sequence: 3, json: "three"}

    {events, bytes, {:ok, 0}} = BoundedEvents.append([], 0, first, 2, 1_000)
    {events, bytes, {:ok, 0}} = BoundedEvents.append(events, bytes, second, 2, 1_000)
    {events, _bytes, {:ok, 1}} = BoundedEvents.append(events, bytes, third, 2, 1_000)

    assert Enum.map(events, & &1.sequence) == [2, 3]
  end

  test "a single oversized event is omitted without growing state" do
    existing = [%{sequence: 1, json: "small"}]
    total = existing |> hd() |> Jason.encode_to_iodata!() |> IO.iodata_length()
    oversized = %{sequence: 2, json: String.duplicate("x", 100)}

    assert {^existing, ^total, :item_too_large} =
             BoundedEvents.append(existing, total, oversized, 10, 20)
  end
end
