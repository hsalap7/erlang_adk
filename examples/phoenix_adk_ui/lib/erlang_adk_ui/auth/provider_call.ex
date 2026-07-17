defmodule ErlangAdkUi.Auth.ProviderCall do
  @moduledoc """
  Time- and heap-bounded isolation for calls into an external identity provider.

  Provider failures are collapsed to public error atoms. Crash reasons, token
  responses and other provider terms never cross into the Phoenix request
  process. Successful values are normalized and bounded in the worker before
  they are copied back to the caller.
  """

  @max_redirect_bytes 8_192
  @max_flow_bytes 16_384
  @min_timeout_ms 1
  @max_timeout_ms 60_000
  @min_heap_words 10_000
  @max_heap_words 8_000_000
  @guard_heap_words 10_000

  def authorization_request(provider),
    do: authorization_request(provider, configured_options())

  def authorization_request(provider, options) when is_atom(provider) do
    isolated_call(
      provider,
      :authorization_request,
      [],
      &normalize_authorization/1,
      options
    )
  end

  def authorization_request(_provider, _options), do: {:error, :provider_unavailable}

  def complete(provider, params, flow),
    do: complete(provider, params, flow, configured_options())

  def complete(provider, params, flow, options)
      when is_atom(provider) and is_map(params) and is_map(flow) do
    isolated_call(provider, :complete, [params, flow], &normalize_completion/1, options)
  end

  def complete(_provider, _params, _flow, _options), do: {:error, :authentication_failed}

  defp isolated_call(provider, function, arguments, normalizer, options) do
    with {:ok, timeout_ms, max_heap_words} <- validate_options(options) do
      parent = self()
      call_ref = make_ref()
      reply_alias = :erlang.alias([:explicit_unalias])
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      worker = fn ->
        case start_guard(parent, self(), deadline) do
          :ok ->
            result =
              try do
                provider
                |> apply(function, arguments)
                |> normalizer.()
              catch
                _class, _reason -> {:error, :provider_unavailable}
              end

            completed_at = System.monotonic_time(:millisecond)

            :erlang.send(
              reply_alias,
              {__MODULE__, call_ref, self(), completed_at, result},
              [:noconnect, :nosuspend]
            )

          :error ->
            :ok
        end
      end

      try do
        {pid, monitor_ref} =
          :erlang.spawn_opt(worker, [
            :monitor,
            {:message_queue_data, :off_heap},
            {:max_heap_size,
             %{
               size: max_heap_words,
               kill: true,
               error_logger: false,
               include_shared_binaries: true
             }}
          ])

        await_result(pid, monitor_ref, reply_alias, call_ref, deadline)
      after
        :erlang.unalias(reply_alias)
      end
    else
      _error -> {:error, :provider_unavailable}
    end
  catch
    _class, _reason -> {:error, :provider_unavailable}
  end

  defp await_result(pid, monitor_ref, reply_alias, call_ref, deadline) do
    receive do
      {__MODULE__, ^call_ref, ^pid, completed_at, result} when completed_at <= deadline ->
        :erlang.unalias(reply_alias)
        Process.demonitor(monitor_ref, [:flush])
        result

      {__MODULE__, ^call_ref, ^pid, _completed_at, _late_result} ->
        :erlang.unalias(reply_alias)
        Process.exit(pid, :kill)
        await_down(monitor_ref, pid)
        {:error, :provider_unavailable}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :erlang.unalias(reply_alias)
        {:error, :provider_unavailable}
    after
      remaining(deadline) ->
        :erlang.unalias(reply_alias)
        Process.exit(pid, :kill)
        await_down(monitor_ref, pid)
        {:error, :provider_unavailable}
    end
  end

  defp await_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      100 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp start_guard(parent, worker, deadline) do
    guard = fn -> guard_worker(parent, worker, deadline) end

    case :erlang.spawn_opt(guard, [
           {:message_queue_data, :off_heap},
           {:max_heap_size,
            %{
              size: @guard_heap_words,
              kill: true,
              error_logger: false,
              include_shared_binaries: true
            }}
         ]) do
      pid when is_pid(pid) -> :ok
      _other -> :error
    end
  catch
    _class, _reason -> :error
  end

  defp guard_worker(parent, worker, deadline) do
    parent_ref = Process.monitor(parent)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        Process.exit(worker, :kill)
        Process.demonitor(worker_ref, [:flush])

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        Process.demonitor(parent_ref, [:flush])
    after
      remaining(deadline) ->
        Process.exit(worker, :kill)
        Process.demonitor(parent_ref, [:flush])
        Process.demonitor(worker_ref, [:flush])
    end
  end

  defp remaining(deadline),
    do: max(0, deadline - System.monotonic_time(:millisecond))

  defp normalize_authorization({:ok, redirect_uri, flow})
       when is_binary(redirect_uri) and is_map(flow) do
    with :ok <- validate_redirect_uri(redirect_uri),
         {:ok, encoded_flow} <- Jason.encode(flow),
         true <- byte_size(encoded_flow) <= @max_flow_bytes,
         {:ok, safe_flow} when is_map(safe_flow) <- Jason.decode(encoded_flow) do
      {:ok, redirect_uri, safe_flow}
    else
      _error -> {:error, :provider_unavailable}
    end
  end

  defp normalize_authorization({:error, :provider_unavailable} = error), do: error
  defp normalize_authorization(_result), do: {:error, :provider_unavailable}

  defp normalize_completion({:ok, identity}) do
    case normalize_identity(identity) do
      {:ok, safe_identity} -> {:ok, safe_identity}
      {:error, :invalid_identity} -> {:error, :authentication_failed}
    end
  end

  defp normalize_completion({:error, reason} = error)
       when reason in [:authentication_failed, :provider_unavailable],
       do: error

  defp normalize_completion(_result), do: {:error, :authentication_failed}

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

  defp validate_redirect_uri(uri) when byte_size(uri) <= @max_redirect_bytes do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and byte_size(host) > 0 ->
        if String.valid?(uri) and not String.contains?(uri, ["\r", "\n"]) do
          :ok
        else
          {:error, :invalid_redirect_uri}
        end

      _uri ->
        {:error, :invalid_redirect_uri}
    end
  end

  defp validate_redirect_uri(_uri), do: {:error, :invalid_redirect_uri}

  defp configured_options do
    Application.get_env(:erlang_adk_ui, :auth_provider_call, [])
  end

  defp validate_options(options) when is_list(options) do
    timeout_ms = Keyword.get(options, :timeout_ms)
    max_heap_words = Keyword.get(options, :max_heap_words)

    if is_integer(timeout_ms) and timeout_ms >= @min_timeout_ms and
         timeout_ms <= @max_timeout_ms and is_integer(max_heap_words) and
         max_heap_words >= @min_heap_words and max_heap_words <= @max_heap_words do
      {:ok, timeout_ms, max_heap_words}
    else
      {:error, :invalid_provider_call_options}
    end
  end

  defp validate_options(_options), do: {:error, :invalid_provider_call_options}
end
