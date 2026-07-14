defmodule ErlangAdkUi.Auth.LoginFlowStoreTest do
  use ExUnit.Case, async: true

  alias ErlangAdkUi.Auth.LoginFlowStore

  test "a login transaction is consumed exactly once" do
    store = start_store(ttl_ms: 60_000, max_entries: 2)
    flow = %{"state" => "state", "nonce" => "nonce", "pkce_verifier" => "verifier"}

    assert {:ok, handle} = LoginFlowStore.issue(flow, store)
    assert {:ok, ^flow} = LoginFlowStore.consume(handle, store)
    assert {:error, :login_flow_not_found} = LoginFlowStore.consume(handle, store)
  end

  test "expired transactions fail closed" do
    store = start_store(ttl_ms: 5, max_entries: 2)
    assert {:ok, handle} = LoginFlowStore.issue(%{"state" => "state"}, store)

    Process.sleep(10)

    assert {:error, reason} = LoginFlowStore.consume(handle, store)
    assert reason in [:login_flow_expired, :login_flow_not_found]
  end

  test "capacity is bounded and is recovered by consumption" do
    store = start_store(ttl_ms: 60_000, max_entries: 1)
    assert {:ok, first} = LoginFlowStore.issue(%{"state" => "first"}, store)
    assert {:error, :login_flow_capacity} = LoginFlowStore.issue(%{"state" => "second"}, store)
    assert {:ok, _flow} = LoginFlowStore.consume(first, store)
    assert {:ok, _second} = LoginFlowStore.issue(%{"state" => "second"}, store)
  end

  test "superseded transactions can be discarded" do
    store = start_store(ttl_ms: 60_000, max_entries: 2)
    assert {:ok, handle} = LoginFlowStore.issue(%{"state" => "old"}, store)
    assert :ok = LoginFlowStore.discard(handle, store)
    assert {:error, :login_flow_not_found} = LoginFlowStore.consume(handle, store)
  end

  test "an unavailable owner fails closed without exiting the caller" do
    assert {:error, :login_flow_unavailable} =
             LoginFlowStore.issue(%{"state" => "state"}, ErlangAdkUi.MissingLoginFlowStore)
  end

  test "oversized or non-JSON flow state is rejected" do
    store = start_store(ttl_ms: 60_000, max_entries: 2)

    assert {:error, :invalid_login_flow} =
             LoginFlowStore.issue(%{"state" => String.duplicate("x", 20_000)}, store)

    assert {:error, :invalid_login_flow} = LoginFlowStore.issue(%{"state" => self()}, store)
  end

  defp start_store(options) do
    start_supervised!(
      Supervisor.child_spec({LoginFlowStore, Keyword.put(options, :name, nil)},
        id: make_ref()
      )
    )
  end
end
