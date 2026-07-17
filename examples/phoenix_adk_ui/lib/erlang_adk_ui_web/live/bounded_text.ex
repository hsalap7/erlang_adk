defmodule ErlangAdkUiWeb.BoundedText do
  @moduledoc false

  @ellipsis "…"
  @invalid_utf8 "Invalid UTF-8 text omitted."

  def truncate(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    cond do
      not String.valid?(value) -> fit_literal(@invalid_utf8, max_bytes)
      byte_size(value) <= max_bytes -> value
      max_bytes < byte_size(@ellipsis) -> ""
      true -> take_graphemes(value, max_bytes - byte_size(@ellipsis), []) <> @ellipsis
    end
  end

  defp take_graphemes(_value, 0, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_graphemes(value, remaining, acc) do
    case String.next_grapheme(value) do
      {grapheme, rest} when byte_size(grapheme) <= remaining ->
        take_graphemes(rest, remaining - byte_size(grapheme), [grapheme | acc])

      _done_or_too_large ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp fit_literal(value, max_bytes) when byte_size(value) <= max_bytes, do: value
  defp fit_literal(value, max_bytes), do: take_graphemes(value, max_bytes, [])
end
