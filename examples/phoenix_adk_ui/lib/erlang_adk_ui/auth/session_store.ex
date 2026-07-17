defmodule ErlangAdkUi.Auth.SessionStore do
  @moduledoc """
  Bounded, expiring server-side web sessions.

  Cookies contain only a random opaque handle. Entries contain a sanitized
  identity, a server-generated ADK session id and reconnect cursor; no OIDC or
  provider token is retained.
  """

  use GenServer

  @table __MODULE__
  @default_ui %{run_id: nil, cursor: 0}
  @max_collision_retries 3

  def start_link(options) when is_list(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  def issue(identity, server \\ __MODULE__),
    do: safe_call(server, {:issue, identity}, {:error, :session_unavailable})

  def revoke(handle, server \\ __MODULE__),
    do: safe_call(server, {:revoke, handle}, {:error, :session_unavailable})

  def save_run(handle, run_id, cursor, server \\ __MODULE__),
    do:
      safe_call(
        server,
        {:save_run, handle, run_id, cursor},
        {:error, :session_unavailable}
      )

  def clear_run(handle, server \\ __MODULE__),
    do: safe_call(server, {:save_run, handle, nil, 0}, {:error, :session_unavailable})

  def fetch(handle, server \\ __MODULE__) do
    with {:ok, context} <- fetch_context(handle, server) do
      {:ok, context.identity}
    end
  end

  def fetch_context(handle), do: fetch_context(handle, __MODULE__)

  def fetch_context(handle, server),
    do: safe_call(server, {:fetch_context, handle}, {:error, :unauthenticated})

  @impl true
  def init(options) do
    ttl_ms = Keyword.fetch!(options, :ttl_ms)
    max_entries = Keyword.fetch!(options, :max_entries)
    handle_generator = Keyword.get(options, :handle_generator, &random_handle/0)

    true = is_integer(ttl_ms) and ttl_ms >= 1 and ttl_ms <= :timer.hours(24)
    true = is_integer(max_entries) and max_entries >= 1 and max_entries <= 100_000
    true = is_function(handle_generator, 0)

    table =
      :ets.new(@table, [
        :set,
        :private,
        write_concurrency: true
      ])

    Process.send_after(self(), :sweep, min(ttl_ms, :timer.minutes(1)))

    {:ok,
     %{
       table: table,
       ttl_ms: ttl_ms,
       max_entries: max_entries,
       handle_generator: handle_generator
     }}
  end

  @impl true
  def handle_call({:issue, identity}, _from, state) do
    now = System.monotonic_time(:millisecond)
    sweep(state.table, now)

    reply =
      with {:ok, safe_identity} <- normalize_identity(identity),
           true <- :ets.info(state.table, :size) < state.max_entries do
        insert_session(
          state.table,
          safe_identity,
          now + state.ttl_ms,
          state.handle_generator,
          @max_collision_retries
        )
      else
        false -> {:error, :session_capacity}
        {:error, :invalid_identity} -> {:error, :invalid_identity}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:revoke, handle}, _from, state) do
    if valid_handle?(handle), do: :ets.delete(state.table, digest(handle))
    {:reply, :ok, state}
  end

  def handle_call({:save_run, handle, run_id, cursor}, _from, state) do
    reply = update_run(state.table, handle, run_id, cursor)
    {:reply, reply, state}
  end

  def handle_call({:fetch_context, handle}, _from, state) do
    reply =
      case lookup_context(state.table, handle, System.monotonic_time(:millisecond)) do
        {:expired, key} ->
          :ets.delete(state.table, key)
          {:error, :unauthenticated}

        result ->
          result
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.table, System.monotonic_time(:millisecond))
    Process.send_after(self(), :sweep, min(state.ttl_ms, :timer.minutes(1)))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp update_run(table, handle, run_id, cursor)
       when is_binary(handle) and byte_size(handle) >= 32 and byte_size(handle) <= 128 and
              ((is_binary(run_id) and byte_size(run_id) <= 128) or is_nil(run_id)) and
              is_integer(cursor) and cursor >= 0 do
    key = digest(handle)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, identity, agent_session_id, expires_at, _ui}] when expires_at > now ->
        true =
          :ets.insert(
            table,
            {key, identity, agent_session_id, expires_at, %{run_id: run_id, cursor: cursor}}
          )

        :ok

      _other ->
        :ets.delete(table, key)
        {:error, :unauthenticated}
    end
  end

  defp update_run(_table, _handle, _run_id, _cursor), do: {:error, :invalid_run_state}

  defp normalize_identity(%{
         principal: principal,
         subject: subject,
         issuer: issuer,
         audiences: audiences,
         scopes: scopes
       })
       when is_binary(principal) and byte_size(principal) > 0 and byte_size(principal) <= 128 and
              is_binary(subject) and byte_size(subject) > 0 and byte_size(subject) <= 1_024 and
              is_binary(issuer) and byte_size(issuer) > 0 and byte_size(issuer) <= 2_048 and
              is_list(audiences) and is_list(scopes) do
    if valid_binaries(audiences, 32) and valid_binaries(scopes, 128) do
      {:ok,
       %{
         principal: principal,
         subject: subject,
         issuer: issuer,
         audiences: Enum.uniq(audiences),
         scopes: Enum.uniq(scopes),
         claims: %{}
       }}
    else
      {:error, :invalid_identity}
    end
  end

  defp normalize_identity(_identity), do: {:error, :invalid_identity}

  defp valid_binaries(values, max_count) do
    length(values) <= max_count and
      Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 0 and byte_size(&1) <= 512))
  end

  defp valid_handle?(handle),
    do: is_binary(handle) and byte_size(handle) >= 32 and byte_size(handle) <= 128

  defp lookup_context(table, handle, now)
       when is_binary(handle) and byte_size(handle) >= 32 and byte_size(handle) <= 128 do
    key = digest(handle)

    case :ets.lookup(table, key) do
      [{^key, identity, agent_session_id, expires_at, ui}] when expires_at > now ->
        {:ok, %{identity: identity, agent_session_id: agent_session_id, ui: ui}}

      [{^key, _identity, _agent_session_id, _expires_at, _ui}] ->
        {:expired, key}

      [] ->
        {:error, :unauthenticated}
    end
  catch
    :error, :badarg -> {:error, :unauthenticated}
  end

  defp lookup_context(_table, _handle, _now), do: {:error, :unauthenticated}

  defp insert_session(_table, _identity, _expires_at, _generator, 0),
    do: {:error, :session_handle_collision}

  defp insert_session(table, identity, expires_at, generator, attempts_left) do
    with {:ok, handle} <- generate_handle(generator) do
      key = digest(handle)
      agent_session_id = <<"web-", random_handle()::binary>>

      if :ets.insert_new(
           table,
           {key, identity, agent_session_id, expires_at, @default_ui}
         ) do
        {:ok, handle}
      else
        insert_session(table, identity, expires_at, generator, attempts_left - 1)
      end
    end
  end

  defp generate_handle(generator) do
    case generator.() do
      handle when is_binary(handle) and byte_size(handle) >= 32 and byte_size(handle) <= 128 ->
        {:ok, handle}

      _invalid ->
        {:error, :invalid_handle_generator}
    end
  catch
    _class, _reason -> {:error, :invalid_handle_generator}
  end

  defp sweep(table, now) do
    :ets.select_delete(table, [
      {{:"$1", :"$2", :"$3", :"$4", :"$5"}, [{:"=<", :"$4", now}], [true]}
    ])
  end

  defp random_handle, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp digest(handle), do: :crypto.hash(:sha256, handle)

  defp safe_call(server, request, fallback) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> fallback
  end
end
