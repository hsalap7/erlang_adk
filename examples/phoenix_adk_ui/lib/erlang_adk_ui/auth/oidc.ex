defmodule ErlangAdkUi.Auth.Oidc do
  @moduledoc """
  OIDC authorization-code boundary with mandatory S256 PKCE, nonce and state.

  Oidcc performs provider discovery, code exchange and token validation. The
  Erlang ADK JWT policy then independently applies the configured issuer,
  audience, algorithms and time policy. Tokens are never put in a Phoenix
  session or LiveView assign.
  """

  @behaviour ErlangAdkUi.Auth.Provider
  @max_flow_age_seconds 600
  @max_code_bytes 4_096

  @impl true
  def authorization_request do
    config = config!()
    state = random(32)
    nonce = random(32)
    verifier = random(64)

    options = %{
      redirect_uri: config[:redirect_uri],
      scopes: config[:scopes],
      state: state,
      nonce: nonce,
      pkce_verifier: verifier,
      require_pkce: true
    }

    case :oidcc.create_redirect_url(
           config[:provider],
           config[:client_id],
           config[:client_secret],
           options
         ) do
      {:ok, uri} ->
        {:ok, IO.iodata_to_binary(uri),
         %{
           "state" => state,
           "nonce" => nonce,
           "pkce_verifier" => verifier,
           "started_at" => System.system_time(:second)
         }}

      _other ->
        {:error, :provider_unavailable}
    end
  catch
    :exit, _reason -> {:error, :provider_unavailable}
    _class, _reason -> {:error, :provider_unavailable}
  end

  @impl true
  def complete(params, flow) when is_map(params) and is_map(flow) do
    config = config!()

    with :ok <- validate_callback(params, flow),
         {:ok, token} <- retrieve_token(params["code"], flow, config),
         {:ok, id_token, granted_scopes} <- unpack_token(token, config[:scopes]),
         {:ok, policy} <- :adk_jwt_policy.new(jwt_policy(config)),
         {:ok, identity} <-
           :adk_jwt_policy.authenticate(
             policy,
             %{<<"authorization">> => <<"Bearer ", id_token::binary>>}
           ) do
      scopes = Enum.uniq(Map.get(identity, :scopes, []) ++ granted_scopes)
      {:ok, Map.put(identity, :scopes, scopes)}
    else
      {:error, :provider_unavailable} = error -> error
      _other -> {:error, :authentication_failed}
    end
  catch
    :exit, _reason -> {:error, :provider_unavailable}
    _class, _reason -> {:error, :authentication_failed}
  end

  def complete(_params, _flow), do: {:error, :authentication_failed}

  defp validate_callback(%{"code" => code, "state" => state} = params, flow)
       when is_binary(code) and byte_size(code) > 0 and byte_size(code) <= @max_code_bytes and
              is_binary(state) do
    expected_state = flow["state"]
    started_at = flow["started_at"]
    now = System.system_time(:second)

    valid =
      not Map.has_key?(params, "error") and
        is_binary(expected_state) and byte_size(expected_state) > 0 and
        :adk_dev_auth.constant_time_equal(state, expected_state) and
        is_integer(started_at) and started_at <= now and
        started_at >= now - @max_flow_age_seconds and
        valid_secret(flow["nonce"]) and valid_secret(flow["pkce_verifier"])

    if valid, do: :ok, else: {:error, :authentication_failed}
  end

  defp validate_callback(_params, _flow), do: {:error, :authentication_failed}

  defp retrieve_token(code, flow, config) do
    case :oidcc.retrieve_token(
           code,
           config[:provider],
           config[:client_id],
           config[:client_secret],
           %{
             redirect_uri: config[:redirect_uri],
             pkce_verifier: flow["pkce_verifier"],
             require_pkce: true,
             nonce: flow["nonce"],
             trusted_audiences: [],
             validate_azp: :client_id
           }
         ) do
      {:ok, token} -> {:ok, token}
      {:error, {:http_error, _status, _body}} -> {:error, :provider_unavailable}
      {:error, _reason} -> {:error, :authentication_failed}
    end
  end

  # Oidcc's public Erlang API returns its public record representation. Keep
  # this record-specific code at one adapter boundary.
  defp unpack_token(
         {:oidcc_token, {:oidcc_token_id, token, _claims}, _access, _refresh, scope},
         requested_scopes
       )
       when is_binary(token) do
    with {:ok, scopes} <- normalize_scopes(scope, requested_scopes) do
      {:ok, token, scopes}
    end
  end

  defp unpack_token(_token, _requested_scopes), do: {:error, :authentication_failed}

  # RFC 6749 section 5.1 permits the token endpoint to omit `scope` when it is
  # identical to the authorization request. Only that omission uses the fixed,
  # server-owned requested scopes; an explicit empty or reduced scope is kept.
  defp normalize_scopes(:undefined, requested_scopes) when is_list(requested_scopes),
    do: {:ok, requested_scopes}

  defp normalize_scopes(scopes, _requested_scopes) when is_list(scopes) do
    Enum.reduce_while(scopes, {:ok, []}, fn
      scope, {:ok, acc} when is_binary(scope) and byte_size(scope) > 0 ->
        {:cont, {:ok, [scope | acc]}}

      scope, {:ok, acc} when is_atom(scope) ->
        {:cont, {:ok, [Atom.to_string(scope) | acc]}}

      _scope, _acc ->
        {:halt, {:error, :authentication_failed}}
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_scopes(scope, _requested_scopes) when is_binary(scope) do
    {:ok, String.split(scope, " ", trim: true)}
  end

  defp normalize_scopes(_scope, _requested_scopes), do: {:error, :authentication_failed}

  defp jwt_policy(config) do
    %{
      token_use: :id_token,
      issuer: config[:issuer],
      audience: config[:client_id],
      trusted_audiences: [],
      signing_algs: config[:signing_algs],
      clock_skew_seconds: config[:clock_skew_seconds],
      required_scopes: [],
      provider: config[:provider],
      claim_allowlist: [<<"sub">>, <<"iss">>, <<"aud">>, <<"scope">>, <<"scp">>, <<"azp">>]
    }
  end

  defp config! do
    config = Application.fetch_env!(:erlang_adk_ui, :oidc)

    required = [
      :issuer,
      :client_id,
      :client_secret,
      :provider,
      :redirect_uri,
      :scopes,
      :signing_algs,
      :clock_skew_seconds
    ]

    unless Keyword.keyword?(config) and Enum.all?(required, &Keyword.has_key?(config, &1)) do
      raise "invalid OIDC application configuration"
    end

    config
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp valid_secret(value),
    do: is_binary(value) and byte_size(value) >= 43 and byte_size(value) <= 128
end
