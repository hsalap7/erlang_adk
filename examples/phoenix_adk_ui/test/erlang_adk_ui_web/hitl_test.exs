defmodule ErlangAdkUiWeb.HITLTest do
  use ExUnit.Case, async: true

  alias ErlangAdkUiWeb.{BoundedText, HITL}

  test "tool confirmation decisions retain their boolean type" do
    event = pause_event(%{"type" => "tool_confirmation"})
    assert %{type: :tool_confirmation, supported: true} = HITL.from_event(event)

    assert {:ok, %{"confirmed" => true}} =
             HITL.resume_payload(:tool_confirmation, true, "principal")

    assert {:ok, %{"confirmed" => false}} =
             HITL.resume_payload(:tool_confirmation, false, "principal")
  end

  test "human approval binds the server principal and retains the decision type" do
    event = %{
      "actions" => %{
        "pause" => %{"summary" => "Review", "tool_name" => "request_human_approval"}
      }
    }

    assert %{type: :human_approval, supported: true} = HITL.from_event(event)

    assert {:ok, %{"approved" => true, "approver" => "oidc_server_principal"}} =
             HITL.resume_payload(:human_approval, true, "oidc_server_principal")

    assert {:ok, %{"approved" => false, "approver" => "oidc_server_principal"}} =
             HITL.resume_payload(:human_approval, false, "oidc_server_principal")
  end

  test "unknown pause types fail closed" do
    assert %{type: {:unsupported, "future_pause"}, supported: false} =
             HITL.from_event(pause_event(%{"type" => "future_pause"}))

    assert {:error, :unsupported_pause} =
             HITL.resume_payload({:unsupported, "future_pause"}, true, "principal")
  end

  test "bounded text never splits a UTF-8 grapheme or exceeds the byte limit" do
    value = "a👩‍💻b"
    truncated = BoundedText.truncate(value, 6)

    assert truncated == "a…"
    assert String.valid?(truncated)
    assert byte_size(truncated) <= 6
  end

  defp pause_event(details) do
    %{"actions" => %{"pause" => %{"summary" => "Review", "details" => details}}}
  end
end
