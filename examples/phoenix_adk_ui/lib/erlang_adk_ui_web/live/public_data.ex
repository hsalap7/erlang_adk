defmodule ErlangAdkUiWeb.PublicData do
  @moduledoc false

  alias ErlangAdkUiWeb.BoundedText

  @max_depth 8
  @max_entries 200
  @max_string_bytes 4_096
  @omitted "[omitted]"
  @binary_payload_keys MapSet.new([
                         "audio",
                         "blob",
                         "data",
                         "inline_data",
                         "inlinedata",
                         "video"
                       ])

  def project(value), do: do_project(redact(value), 0)

  defp do_project(_value, depth) when depth >= @max_depth, do: @omitted

  defp do_project(value, _depth) when is_boolean(value) or is_nil(value), do: value
  defp do_project(value, _depth) when is_integer(value) or is_float(value), do: value

  defp do_project(value, _depth) when is_binary(value) do
    if String.valid?(value), do: BoundedText.truncate(value, @max_string_bytes), else: @omitted
  end

  defp do_project(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp do_project(value, depth) when is_list(value) do
    value
    |> Enum.take(@max_entries)
    |> Enum.map(&do_project(&1, depth + 1))
  end

  defp do_project(value, depth) when is_map(value) do
    value
    |> Enum.take(@max_entries)
    |> Enum.reduce(%{}, fn {key, item}, acc ->
      public_key = key_string(key)

      projected =
        if binary_payload_key?(public_key) do
          "[binary payload omitted]"
        else
          do_project(item, depth + 1)
        end

      Map.put(acc, public_key, projected)
    end)
  end

  defp do_project(_value, _depth), do: @omitted

  defp redact(value) do
    :adk_secret_redactor.redact(value)
  catch
    _kind, _reason -> @omitted
  end

  defp key_string(key) when is_binary(key) do
    if String.valid?(key), do: BoundedText.truncate(key, 128), else: @omitted
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(_key), do: @omitted

  defp binary_payload_key?(key) do
    MapSet.member?(@binary_payload_keys, String.downcase(key))
  end
end
