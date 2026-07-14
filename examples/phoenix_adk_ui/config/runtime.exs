import Config

if System.get_env("PHX_SERVER") do
  config :erlang_adk_ui, ErlangAdkUiWeb.Endpoint, server: true
end

if config_env() != :test do
  issuer = System.fetch_env!("OIDC_ISSUER")
  client_id = System.fetch_env!("OIDC_CLIENT_ID")
  redirect_uri = System.fetch_env!("OIDC_REDIRECT_URI")

  client_secret =
    case System.get_env("OIDC_PUBLIC_CLIENT", "false") do
      "true" -> :unauthenticated
      "false" -> System.fetch_env!("OIDC_CLIENT_SECRET")
      _ -> raise "OIDC_PUBLIC_CLIENT must be true or false"
    end

  signing_algs =
    System.get_env("OIDC_SIGNING_ALGS", "RS256")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  scopes =
    System.get_env(
      "OIDC_SCOPES",
      "openid adk.agents.read adk.run.start adk.run.read adk.run.control " <>
        "adk.live.read adk.live.control adk.observability.read adk.evaluation.read"
    )
    |> String.split(" ", trim: true)

  unless String.starts_with?(issuer, "https://") do
    raise "OIDC_ISSUER must be an https URI"
  end

  unless config_env() == :dev or String.starts_with?(redirect_uri, "https://") do
    raise "OIDC_REDIRECT_URI must be an https URI outside development"
  end

  unless "openid" in scopes do
    raise "OIDC_SCOPES must include openid"
  end

  config :erlang_adk, :oidc_providers, [
    %{
      name: ErlangAdkUi.OidcProvider,
      issuer: issuer,
      backoff_min: 1_000,
      backoff_max: 30_000,
      backoff_type: :random_exponential
    }
  ]

  config :erlang_adk_ui, :oidc,
    issuer: issuer,
    client_id: client_id,
    client_secret: client_secret,
    provider: ErlangAdkUi.OidcProvider,
    redirect_uri: redirect_uri,
    scopes: scopes,
    signing_algs: signing_algs,
    clock_skew_seconds: 60
end

config :erlang_adk_ui, ErlangAdkUiWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing; generate one with mix phx.gen.secret"

  host = System.fetch_env!("PHX_HOST")
  port = String.to_integer(System.get_env("PORT", "4000"))
  external_port = String.to_integer(System.get_env("PHX_URL_PORT", "443"))
  tls_cert = System.get_env("TLS_CERT_PATH")
  tls_key = System.get_env("TLS_KEY_PATH")
  behind_proxy = System.get_env("PHX_BEHIND_HTTPS_PROXY", "false")

  {endpoint_transport, ssl_options} =
    case {tls_cert, tls_key, behind_proxy} do
      {cert, key, _} when is_binary(cert) and is_binary(key) ->
        {
          [
            https: [
              ip: {0, 0, 0, 0, 0, 0, 0, 0},
              port: port,
              cipher_suite: :strong,
              certfile: cert,
              keyfile: key
            ],
            http: false
          ],
          [hsts: true]
        }

      {nil, nil, "true"} ->
        {
          [http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port]],
          [
            rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto],
            hsts: true
          ]
        }

      {nil, nil, "false"} ->
        raise "configure TLS_CERT_PATH/TLS_KEY_PATH or explicitly set PHX_BEHIND_HTTPS_PROXY=true"

      _ ->
        raise "TLS_CERT_PATH and TLS_KEY_PATH must be configured together"
    end

  config :erlang_adk_ui, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :erlang_adk_ui, :ssl_options, ssl_options

  config :erlang_adk_ui,
         ErlangAdkUiWeb.Endpoint,
         [
           url: [host: host, port: external_port, scheme: "https"],
           check_origin: :conn,
           secret_key_base: secret_key_base
         ] ++ endpoint_transport
end
