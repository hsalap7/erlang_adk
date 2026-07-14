defmodule ErlangAdkUiWeb.LiveProjectionTest do
  use ExUnit.Case, async: true

  alias ErlangAdkUiWeb.LiveProjection

  test "audio projection exposes metadata and omits the media binary" do
    raw = "RAW_AUDIO_BYTES!"
    {:ok, media} = :adk_live_media.audio_pcm(raw, 24_000, 1)
    event = event(:audio, media)

    assert {:ok, projected} = LiveProjection.project(event)
    assert projected["payload"]["media_omitted"]
    assert projected["payload"]["bytes"] == byte_size(raw)
    assert :binary.match(:erlang.term_to_binary(projected), raw) == :nomatch
  end

  test "text projection never carries a thought signature" do
    event =
      event(:content, %{
        part: %{text: "public text", thought: false, thought_signature: "PRIVATE_SIGNATURE"}
      })

    assert {:ok, projected} = LiveProjection.project(event)
    assert projected["payload"]["part"]["text"] == "public text"
    assert projected["payload"]["part"]["thought_signature_omitted"]
    refute inspect(projected) =~ "PRIVATE_SIGNATURE"
  end

  test "tool payload fields named data are omitted" do
    event =
      event(:tool_response, %{
        id: "call-1",
        name: "lookup",
        response: %{"data" => "RAW_TOOL_BLOB", "status" => "ok"}
      })

    assert {:ok, projected} = LiveProjection.project(event)
    assert projected["payload"]["response"]["data"] == "[binary payload omitted]"
    refute inspect(projected) =~ "RAW_TOOL_BLOB"
  end

  defp event(kind, payload) do
    {:ok, base} = :adk_live_event.new(kind, payload)
    {:ok, checked} = :adk_live_event.with_envelope(base, 1, 0, 0)
    checked
  end
end
