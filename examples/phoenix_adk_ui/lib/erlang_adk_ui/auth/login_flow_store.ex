defmodule ErlangAdkUi.Auth.LoginFlowStore do
  @moduledoc """
  Bounded, expiring, one-time storage for OIDC login transactions.

  The browser cookie contains only a random opaque handle. State, nonce and
  PKCE verifier values remain in a private ETS table and are atomically removed
  before the identity provider is called during the callback.
  """

  use GenServer

  @max_encoded_flow_bytes 16_384
  @min_handle_bytes 32
  @max_handle_bytes 128

  def start_link(options) when is_list(options) do
    name = Keyword.get(options, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, options)
      server_name -> GenServer.start_link(__MODULE__, options, name: server_name)
    end
  end

  def issue(flow, server \\ __MODULE__),
    do: safe_call(server, {:issue, flow}, {:error, :login_flow_unavailable})

  def consume(handle, server \\ __MODULE__),
    do: safe_call(server, {:consume, handle}, {:error, :login_flow_unavailable})

  def discard(handle, server \\ __MODULE__),
    do: safe_call(server, {:discard, handle}, {:error, :login_flow_unavailable})

  @impl true
  def init(options) do
    ttl_ms = Keyword.fetch!(options, :ttl_ms)
    max_entries = Keyword.fetch!(options, :max_entries)

    true = is_integer(ttl_ms) and ttl_ms >= 1 and ttl_ms <= :timer.minutes(15)
    true = is_integer(max_entries) and max_entries >= 1 and max_entries <= 100_000

    table = :ets.new(__MODULE__, [:set, :private])
    schedule_sweep(ttl_ms)
    {:ok, %{table: table, ttl_ms: ttl_ms, max_entries: max_entries}}
  end

  @impl true
  def handle_call({:issue, flow}, _from, state) do
    now = System.monotonic_time(:millisecond)
    sweep(state.table, now)

    reply =
      with :ok <- validate_flow(flow),
           true <- :ets.info(state.table, :size) < state.max_entries do
        insert_flow(state.table, flow, now + state.ttl_ms, 3)
      else
        false -> {:error, :login_flow_capacity}
        {:error, _reason} -> {:error, :invalid_login_flow}
      end

    {:reply, reply, state}
  end

  def handle_call({:consume, handle}, _from, state)
      when is_binary(handle) and byte_size(handle) >= @min_handle_bytes and
             byte_size(handle) <= @max_handle_bytes do
    now = System.monotonic_time(:millisecond)
    key = digest(handle)

    reply =
      case :ets.take(state.table, key) do
        [{^key, flow, expires_at}] when expires_at > now -> {:ok, flow}
        [{^key, _flow, _expires_at}] -> {:error, :login_flow_expired}
        [] -> {:error, :login_flow_not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:consume, _handle}, _from, state) do
    {:reply, {:error, :login_flow_not_found}, state}
  end

  def handle_call({:discard, handle}, _from, state)
      when is_binary(handle) and byte_size(handle) >= @min_handle_bytes and
             byte_size(handle) <= @max_handle_bytes do
    :ets.delete(state.table, digest(handle))
    {:reply, :ok, state}
  end

  def handle_call({:discard, _handle}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.table, System.monotonic_time(:millisecond))
    schedule_sweep(state.ttl_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp validate_flow(flow) when is_map(flow) do
    case Jason.encode(flow) do
      {:ok, encoded} when byte_size(encoded) <= @max_encoded_flow_bytes -> :ok
      _other -> {:error, :invalid_login_flow}
    end
  end

  defp validate_flow(_flow), do: {:error, :invalid_login_flow}

  defp insert_flow(_table, _flow, _expires_at, 0), do: {:error, :login_flow_capacity}

  defp insert_flow(table, flow, expires_at, attempts_left) do
    handle = random_handle()

    if :ets.insert_new(table, {digest(handle), flow, expires_at}) do
      {:ok, handle}
    else
      insert_flow(table, flow, expires_at, attempts_left - 1)
    end
  end

  defp sweep(table, now) do
    :ets.select_delete(table, [
      {{:"$1", :"$2", :"$3"}, [{:"=<", :"$3", now}], [true]}
    ])
  end

  defp schedule_sweep(ttl_ms),
    do: Process.send_after(self(), :sweep, min(ttl_ms, :timer.minutes(1)))

  defp random_handle, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp digest(handle), do: :crypto.hash(:sha256, handle)

  defp safe_call(server, request, fallback) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> fallback
  end
end
