defmodule ErlangAdkUi.MixProject do
  use Mix.Project

  def project do
    [
      app: :erlang_adk_ui,
      version: "0.7.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {ErlangAdkUi.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:erlang_adk, path: "../..", manager: :rebar3, override: true},
      {:phoenix, "== 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      # Temporary security pin: official fix for CVE-2026-58228. Return to a
      # Hex requirement once phoenix_live_view >= 1.2.7 is published.
      {:phoenix_live_view,
       github: "phoenixframework/phoenix_live_view",
       ref: "86165533e311469a1b62093fd182d9d874de8106",
       override: true},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.2"},
      {:bandit, "~> 1.10"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["compile", "esbuild erlang_adk_ui"],
      "assets.test": ["cmd node --test assets/js/*_test.mjs"],
      "assets.deploy": [
        "esbuild erlang_adk_ui --minify",
        "phx.digest.clean --all",
        "phx.digest"
      ],
      test: ["assets.build", "assets.test", "test"],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end
end
