defmodule ErlangAdkUiWeb.LiveProjection do
  @moduledoc """
  Projects process-local Live events into browser-safe metadata.

  The raw event is never returned for assignment. Audio bytes, provider media
  blobs and thought signatures are deliberately omitted.
  """

  alias ErlangAdkUiWeb.{BoundedText, PublicData}

  @max_transcription_bytes 16_384
  @max_content_bytes 16_384

  def project(event) when is_map(event) do
    with :ok <- validate(event),
         kind when is_atom(kind) <- :adk_live_event.kind(event) do
      {:ok,
       %{
         "schema_version" => Map.fetch!(event, :schema_version),
         "kind" => Atom.to_string(kind),
         "payload" => project_payload(kind, Map.fetch!(event, :payload)),
         "sequence" => Map.fetch!(event, :sequence),
         "turn_epoch" => Map.fetch!(event, :turn_epoch),
         "generation_epoch" => Map.fetch!(event, :generation_epoch),
         "timestamp" => Map.fetch!(event, :timestamp),
         "durability" => event |> Map.fetch!(:durability) |> Atom.to_string()
       }}
    else
      _other -> {:error, :invalid_live_event}
    end
  rescue
    _error -> {:error, :invalid_live_event}
  catch
    _kind, _reason -> {:error, :invalid_live_event}
  end

  def project(_event), do: {:error, :invalid_live_event}

  defp project_payload(:audio, media) do
    %{
      "media_omitted" => true,
      "kind" => "audio",
      "format" => media |> Map.get(:format, :unknown) |> to_string(),
      "sample_rate" => Map.get(media, :sample_rate),
      "channels" => Map.get(media, :channels),
      "bytes" => safe_media_bytes(media)
    }
  end

  defp project_payload(kind, %{text: text, final: final})
       when kind in [:input_transcription, :output_transcription] and is_binary(text) and
              is_boolean(final) do
    %{
      "text" => BoundedText.truncate(text, @max_transcription_bytes),
      "final" => final
    }
  end

  defp project_payload(:content, %{part: %{text: text, thought: thought}})
       when is_binary(text) and is_boolean(thought) do
    %{
      "part" => %{
        "text" => BoundedText.truncate(text, @max_content_bytes),
        "thought" => thought,
        "thought_signature_omitted" => true
      }
    }
  end

  defp project_payload(:content, _payload), do: %{"content_omitted" => true}
  defp project_payload(_kind, payload), do: PublicData.project(payload)

  defp safe_media_bytes(media) do
    :adk_live_media.bytes(media)
  catch
    _kind, _reason -> 0
  end

  defp validate(event) do
    :adk_live_event.validate(event)
  catch
    _kind, _reason -> {:error, :invalid_live_event}
  end
end
