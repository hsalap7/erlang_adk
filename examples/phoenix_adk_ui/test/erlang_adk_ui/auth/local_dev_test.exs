defmodule ErlangAdkUi.Auth.LocalDevTest do
  use ExUnit.Case, async: false

  alias ErlangAdkUi.Auth.LocalDev

  @issuer "https://local.erlang-adk.invalid"
  @subject "local-developer"
  @audiences ["erlang-adk-ui"]
  @scopes [
    "adk.agents.read",
    "adk.run.start",
    "adk.run.read",
    "adk.run.control",
    "adk.live.read",
    "adk.live.control",
    "adk.observability.read",
    "adk.evaluation.read"
  ]

  setup do
    previous = Application.get_env(:erlang_adk_ui, :local_dev_auth)
    Application.put_env(:erlang_adk_ui, :local_dev_auth, valid_config())

    on_exit(fn ->
      if previous do
        Application.put_env(:erlang_adk_ui, :local_dev_auth, previous)
      else
        Application.delete_env(:erlang_adk_ui, :local_dev_auth)
      end
    end)

    :ok
  end

  test "returns the configured identity with an authorizer-derived principal" do
    assert {:ok, identity} = LocalDev.identity()
    owner_scope = :adk_scope_authorizer.owner_scope(@issuer, @subject)

    assert identity == %{
             principal: "oidc_" <> Base.url_encode64(owner_scope, padding: false),
             subject: @subject,
             issuer: @issuer,
             audiences: @audiences,
             scopes: @scopes,
             claims: %{}
           }
  end

  test "external authorization-code entry points always fail closed" do
    assert {:error, :provider_unavailable} = LocalDev.authorization_request()
    assert {:error, :authentication_failed} = LocalDev.complete(%{}, %{})
    assert {:error, :authentication_failed} = LocalDev.complete(:anything, :anything)
  end

  test "identity fails closed while disabled or when configuration is absent" do
    Application.put_env(
      :erlang_adk_ui,
      :local_dev_auth,
      Keyword.put(valid_config(), :enabled, false)
    )

    assert {:error, :provider_unavailable} = LocalDev.identity()

    Application.delete_env(:erlang_adk_ui, :local_dev_auth)
    assert {:error, :provider_unavailable} = LocalDev.identity()
  end

  test "rejects non-HTTPS and ambiguous issuers" do
    invalid_issuers = [
      "http://local.erlang-adk.invalid",
      "https://user@local.erlang-adk.invalid",
      "https://local.erlang-adk.invalid?query=true",
      "https://local.erlang-adk.invalid#fragment",
      "not a URI"
    ]

    for issuer <- invalid_issuers do
      Application.put_env(
        :erlang_adk_ui,
        :local_dev_auth,
        Keyword.put(valid_config(), :issuer, issuer)
      )

      assert {:error, :provider_unavailable} = LocalDev.identity()
    end
  end

  test "rejects unknown, duplicate, missing, empty and oversized configuration" do
    invalid_configs = [
      valid_config() ++ [unknown: true],
      valid_config() ++ [enabled: true],
      Keyword.delete(valid_config(), :subject),
      Keyword.put(valid_config(), :subject, ""),
      Keyword.put(valid_config(), :subject, String.duplicate("x", 1_025)),
      Keyword.put(valid_config(), :audiences, []),
      Keyword.put(valid_config(), :audiences, List.duplicate("audience", 33)),
      Keyword.put(valid_config(), :scopes, []),
      Keyword.put(valid_config(), :scopes, List.duplicate("scope", 129)),
      Keyword.put(valid_config(), :scopes, [String.duplicate("s", 257)]),
      Map.new(valid_config()),
      :not_configuration
    ]

    for config <- invalid_configs do
      Application.put_env(:erlang_adk_ui, :local_dev_auth, config)
      assert {:error, :provider_unavailable} = LocalDev.identity()
    end
  end

  defp valid_config do
    [
      enabled: true,
      issuer: @issuer,
      subject: @subject,
      audiences: @audiences,
      scopes: @scopes
    ]
  end
end
