expected =
  MapSet.new([
    {"cowlib", "EEF-CVE-2026-43966"},
    {"cowlib", "EEF-CVE-2026-43969"},
    {"gun", "GHSA-w4f7-4cxr-rv3c"}
  ])

{output, status} =
  System.cmd("mix", ["hex.audit"],
    stderr_to_stdout: true,
    env: [{"MIX_ENV", "prod"}]
  )

IO.write(output)

found =
  ~r/^\s{2}([a-z0-9_.-]+)\s+\S+\s+-\s+(\S+)\s+\([^)]+\)$/m
  |> Regex.scan(output, capture: :all_but_first)
  |> Enum.map(fn [package, advisory] -> {package, advisory} end)
  |> MapSet.new()

cond do
  status != 0 and found == expected ->
    IO.puts(
      "Accepted only the three documented package findings for the two unresolved Cowlib advisories; the underlying Hex audit remains non-zero"
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
