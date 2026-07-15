defmodule ErlangAdkUi.Auth.LocalDev do
  @moduledoc """
  Explicit, server-owned authentication identity for local development.

  The local controller obtains this fixed identity through `identity/0` after
  its own loopback and CSRF checks. The external authorization-code callbacks
  deliberately remain unavailable, so this module cannot turn a GET request
  or a forged callback into a session.

  This module fails closed unless its complete, bounded configuration is
  present and `:enabled` is the literal value `true`. Runtime configuration
  must select it only for an explicitly enabled development server bound to
  loopback; production continues to use the OIDC provider.
  """

  @behaviour ErlangAdkUi.Auth.Provider

  @config_keys [:audiences, :enabled, :issuer, :scopes, :subject]
  @max_issuer_bytes 2_048
  @max_subject_bytes 1_024
  @max_audiences 32
  @max_scopes 128
  @max_audience_bytes 512
  @max_scope_bytes 256

  @impl true
  def authorization_request, do: {:error, :provider_unavailable}

  @impl true
  def complete(_params, _flow), do: {:error, :authentication_failed}

  @doc "Returns the fixed, bounded identity configured for loopback development."
  def identity do
    with {:ok, config} <- config(),
         {:ok, principal} <- principal(config.issuer, config.subject) do
      {:ok,
       %{
         principal: principal,
         subject: config.subject,
         issuer: config.issuer,
         audiences: config.audiences,
         scopes: config.scopes,
         claims: %{}
       }}
    else
      _error -> {:error, :provider_unavailable}
    end
  catch
    _class, _reason -> {:error, :provider_unavailable}
  end

  defp config do
    with {:ok, values} <- exact_keyword(Application.get_env(:erlang_adk_ui, :local_dev_auth)),
         true <- values[:enabled] === true,
         {:ok, issuer} <- issuer(values[:issuer]),
         {:ok, subject} <- bounded_binary(values[:subject], @max_subject_bytes),
         {:ok, audiences} <-
           bounded_binary_list(values[:audiences], @max_audiences, @max_audience_bytes),
         {:ok, scopes} <- bounded_binary_list(values[:scopes], @max_scopes, @max_scope_bytes) do
      {:ok,
       %{
         issuer: issuer,
         subject: subject,
         audiences: Enum.uniq(audiences),
         scopes: Enum.uniq(scopes)
       }}
    else
      _error -> {:error, :provider_unavailable}
    end
  end

  defp exact_keyword(values) do
    with {:ok, pairs} <- bounded_pairs(values, length(@config_keys), []),
         keys <- Enum.map(pairs, &elem(&1, 0)),
         true <- Enum.sort(keys) == @config_keys do
      {:ok, pairs}
    else
      _error -> {:error, :provider_unavailable}
    end
  end

  defp bounded_pairs([], _remaining, acc), do: {:ok, Enum.reverse(acc)}

  defp bounded_pairs([{key, _value} = pair | rest], remaining, acc)
       when is_atom(key) and remaining > 0,
       do: bounded_pairs(rest, remaining - 1, [pair | acc])

  defp bounded_pairs(_values, _remaining, _acc), do: {:error, :provider_unavailable}

  defp issuer(value) do
    with {:ok, safe_value} <- bounded_binary(value, @max_issuer_bytes),
         %{scheme: "https", host: host} = uri <- :uri_string.parse(safe_value),
         true <- is_binary(host) and byte_size(host) > 0,
         false <- Map.has_key?(uri, :userinfo),
         false <- Map.has_key?(uri, :query),
         false <- Map.has_key?(uri, :fragment) do
      {:ok, safe_value}
    else
      _error -> {:error, :provider_unavailable}
    end
  end

  defp bounded_binary(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value) and not String.contains?(value, ["\r", "\n", <<0>>]) do
      {:ok, value}
    else
      {:error, :provider_unavailable}
    end
  end

  defp bounded_binary(_value, _max_bytes), do: {:error, :provider_unavailable}

  defp bounded_binary_list(values, max_count, max_bytes),
    do: bounded_binary_list(values, max_count, max_bytes, [])

  defp bounded_binary_list([], _remaining, _max_bytes, []),
    do: {:error, :provider_unavailable}

  defp bounded_binary_list([], _remaining, _max_bytes, acc), do: {:ok, Enum.reverse(acc)}

  defp bounded_binary_list([value | rest], remaining, max_bytes, acc) when remaining > 0 do
    with {:ok, safe_value} <- bounded_binary(value, max_bytes) do
      bounded_binary_list(rest, remaining - 1, max_bytes, [safe_value | acc])
    end
  end

  defp bounded_binary_list(_values, _remaining, _max_bytes, _acc),
    do: {:error, :provider_unavailable}

  defp principal(issuer, subject) do
    owner_scope = :adk_scope_authorizer.owner_scope(issuer, subject)
    value = "oidc_" <> Base.url_encode64(owner_scope, padding: false)

    if byte_size(value) <= 128 do
      {:ok, value}
    else
      {:error, :provider_unavailable}
    end
  end
end
