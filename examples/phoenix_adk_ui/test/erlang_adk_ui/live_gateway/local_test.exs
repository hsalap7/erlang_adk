defmodule ErlangAdkUi.LiveGateway.LocalTest do
  use ExUnit.Case, async: false

  alias ErlangAdkUi.LiveGateway.Local

  test "each operations surface requires its explicit server-side scope" do
    identity = %{principal: "principal", scopes: []}

    assert {:error, :forbidden} = Local.discover(identity)
    assert {:error, :forbidden} = Local.send_text(identity, "session", "hello")
    assert {:error, :forbidden} = Local.observability_snapshot(identity)
    assert {:error, :forbidden} = Local.list_evaluations(identity)
  end

  test "evaluation catalog accepts only a bounded server-configured map" do
    original = Application.fetch_env!(:erlang_adk_ui, :evaluation_reports)
    identity = %{principal: "principal", scopes: ["adk.evaluation.read"]}

    on_exit(fn -> Application.put_env(:erlang_adk_ui, :evaluation_reports, original) end)

    Application.put_env(:erlang_adk_ui, :evaluation_reports, [])
    assert {:error, :invalid_evaluation_catalog} = Local.list_evaluations(identity)

    Application.put_env(:erlang_adk_ui, :evaluation_reports, %{})
    assert {:ok, []} = Local.list_evaluations(identity)
  end

  test "public session identifiers cannot be reused as post-attach handles" do
    identity = %{
      principal: "principal",
      scopes: ["adk.live.read", "adk.live.control"]
    }

    assert {:error, :not_found} = Local.send_text(identity, "public-session-id", "hello")
    assert {:error, :not_found} = Local.ack(identity, "public-session-id", self(), 1)
    assert {:error, :not_found} = Local.detach(identity, "public-session-id", self())
  end
end
