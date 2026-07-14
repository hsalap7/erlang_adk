defmodule ErlangAdkUi.Auth.SessionStoreTest do
  use ExUnit.Case, async: true

  alias ErlangAdkUi.Auth.SessionStore

  test "session state is API-accessible but its unnamed private table cannot be enumerated" do
    store = start_store(ttl_ms: 60_000, max_entries: 2)
    assert {:ok, handle} = SessionStore.issue(identity(), store)
    assert {:ok, %{identity: %{subject: "alice"}}} = SessionStore.fetch_context(handle, store)

    table = :sys.get_state(store).table
    assert :ets.whereis(SessionStore) == :undefined
    assert_raise ArgumentError, fn -> :ets.tab2list(table) end
  end

  test "expired sessions fail closed" do
    store = start_store(ttl_ms: 5, max_entries: 2)
    assert {:ok, handle} = SessionStore.issue(identity(), store)
    Process.sleep(10)
    assert {:error, :unauthenticated} = SessionStore.fetch_context(handle, store)
  end

  test "capacity is bounded and consumption is not implied by fetch" do
    store = start_store(ttl_ms: 60_000, max_entries: 1)
    assert {:ok, first} = SessionStore.issue(identity(), store)
    assert {:ok, _context} = SessionStore.fetch_context(first, store)
    assert {:error, :session_capacity} = SessionStore.issue(identity("bob"), store)
    assert :ok = SessionStore.revoke(first, store)
    assert {:ok, _second} = SessionStore.issue(identity("bob"), store)
  end

  test "handle collisions retry without replacing an existing session or crashing the owner" do
    first = String.duplicate("a", 43)
    second = String.duplicate("b", 43)
    {:ok, sequence} = Agent.start_link(fn -> [first, first, second] end)

    generator = fn ->
      Agent.get_and_update(sequence, fn [next | rest] -> {next, rest} end)
    end

    store =
      start_store(ttl_ms: 60_000, max_entries: 3, handle_generator: generator)

    assert {:ok, ^first} = SessionStore.issue(identity(), store)
    assert {:ok, ^second} = SessionStore.issue(identity("bob"), store)
    assert Process.alive?(store)
    assert {:ok, %{identity: %{subject: "alice"}}} = SessionStore.fetch_context(first, store)
    assert {:ok, %{identity: %{subject: "bob"}}} = SessionStore.fetch_context(second, store)
  end

  test "run cursor updates remain bounded behind the owning process" do
    store = start_store(ttl_ms: 60_000, max_entries: 2)
    assert {:ok, handle} = SessionStore.issue(identity(), store)
    assert :ok = SessionStore.save_run(handle, "run-1", 7, store)

    assert {:ok, %{ui: %{run_id: "run-1", cursor: 7}}} =
             SessionStore.fetch_context(handle, store)

    assert {:error, :invalid_run_state} =
             SessionStore.save_run(handle, String.duplicate("x", 129), 8, store)
  end

  test "an unavailable owner fails closed without exiting the caller" do
    assert {:error, :session_unavailable} =
             SessionStore.issue(identity(), ErlangAdkUi.MissingSessionStore)

    assert {:error, :unauthenticated} =
             SessionStore.fetch_context(
               "opaque-session-handle-that-is-long-enough",
               ErlangAdkUi.MissingSessionStore
             )
  end

  defp start_store(options) do
    start_supervised!(
      Supervisor.child_spec({SessionStore, Keyword.put(options, :name, nil)}, id: make_ref())
    )
  end

  defp identity(subject \\ "alice"), do: ErlangAdkUi.TestAuthProvider.identity(subject)
end
