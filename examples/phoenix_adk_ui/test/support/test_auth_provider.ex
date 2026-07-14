defmodule ErlangAdkUi.TestAuthProvider do
  @behaviour ErlangAdkUi.Auth.Provider

  @issuer "https://identity.example.test"
  @scopes [
    "adk.agents.read",
    "adk.run.start",
    "adk.run.read",
    "adk.run.control"
  ]

  @impl true
  def authorization_request do
    state = random()

    flow = %{
      "state" => state,
      "nonce" => random(),
      "pkce_verifier" => random(),
      "started_at" => System.system_time(:second)
    }

    notify({:authorization_request, flow})
    {:ok, "https://idp.example.test/authorize?state=#{URI.encode_www_form(state)}", flow}
  end

  @impl true
  def complete(params, flow) do
    notify({:complete, params, flow})

    case Application.get_env(:erlang_adk_ui, :test_auth_complete_mode, :normal) do
      :timeout ->
        receive do
          :never_sent -> {:error, :provider_unavailable}
        end

      :normal ->
        if params["code"] == "good" and params["state"] == flow["state"] do
          {:ok, identity()}
        else
          {:error, :authentication_failed}
        end
    end
  end

  def identity(subject \\ "alice") when is_binary(subject) do
    owner_scope = :adk_scope_authorizer.owner_scope(@issuer, subject)

    %{
      principal: "oidc_" <> Base.url_encode64(owner_scope, padding: false),
      subject: subject,
      issuer: @issuer,
      audiences: ["erlang-adk-ui"],
      scopes: @scopes,
      claims: %{}
    }
  end

  def issuer, do: @issuer
  def scopes, do: @scopes

  defp notify(message) do
    case Application.get_env(:erlang_adk_ui, :test_auth_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end

  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
