defmodule ErlangAdkUiWeb.HITL do
  @moduledoc false

  alias ErlangAdkUiWeb.BoundedText

  @max_summary_bytes 4_096
  @default_summary "A decision is required."

  def from_event(%{<<"actions">> => %{<<"pause">> => pause}}) when is_map(pause) do
    summary = summary(Map.get(pause, <<"summary">>, @default_summary))

    case Map.get(pause, <<"details">>) do
      %{<<"type">> => <<"tool_confirmation">>} ->
        %{type: :tool_confirmation, summary: summary, supported: true}

      %{<<"type">> => type} when is_binary(type) ->
        %{type: {:unsupported, type}, summary: summary, supported: false}

      nil ->
        case Map.get(pause, <<"tool_name">>) do
          <<"request_human_approval">> ->
            %{type: :human_approval, summary: summary, supported: true}

          _other ->
            %{type: :unknown, summary: summary, supported: false}
        end

      _other ->
        %{type: :unknown, summary: summary, supported: false}
    end
  end

  def from_event(_event), do: nil

  def resume_payload(:tool_confirmation, confirmed, _principal) when is_boolean(confirmed),
    do: {:ok, %{<<"confirmed">> => confirmed}}

  def resume_payload(:human_approval, confirmed, principal)
      when is_boolean(confirmed) and is_binary(principal) and byte_size(principal) > 0,
      do: {:ok, %{<<"approved">> => confirmed, <<"approver">> => principal}}

  def resume_payload(_type, _confirmed, _principal), do: {:error, :unsupported_pause}

  defp summary(value) when is_binary(value), do: BoundedText.truncate(value, @max_summary_bytes)
  defp summary(_value), do: @default_summary
end
