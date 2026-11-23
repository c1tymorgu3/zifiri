defmodule Zifiri.MixProject do
  use Mix.Project

  def project do
    [
      app: :zifiri,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # `test/support` holds `Zifiri.DataCase`, which every database-backed test
  # uses; without it in the path the module is not compiled and `use` fails.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Zifiri.Application, []}
    ]
  end

  # Deliberately short. Every dependency here is either the HTTP stack or the
  # single-file store; nothing that logs requests, resolves addresses, or
  # ships telemetry to a third party is allowed in (plan §5.1).
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.2"},
      {:ecto_sqlite3, "~> 0.26"},
      {:bandit, "~> 1.15"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end
