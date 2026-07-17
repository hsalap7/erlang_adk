expected = MapSet.new(["EEF-CVE-2026-43966", "EEF-CVE-2026-43969"])

{output, status} =
  System.cmd("mix", ["hex.audit"],
    stderr_to_stdout: true,
    env: [{"MIX_ENV", "prod"}]
  )

IO.write(output)

found =
  ~r/\bEEF-CVE-\d{4}-\d+\b/
  |> Regex.scan(output)
  |> List.flatten()
  |> MapSet.new()

cond do
  status != 0 and found == expected ->
    IO.puts(
      "Accepted only the two documented Cowlib advisories; the underlying Hex audit remains non-zero"
    )

  status == 0 and MapSet.size(found) == 0 ->
    IO.puts(
      :stderr,
      "The known advisory exception is stale; update dependencies and release documentation"
    )

    System.halt(1)

  true ->
    IO.puts(
      :stderr,
      "Unexpected Hex advisory set: #{inspect(MapSet.to_list(found) |> Enum.sort())}"
    )

    System.halt(1)
end
