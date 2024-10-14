defmodule Subaru.MixProject do
  use Mix.Project

  def project do
    [
      app: :subaru,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Subaru.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mint, "~> 1.0"},
      {:arangox, git: "https://github.com/ArangoDB-Community/arangox"},
      {:cachex, "~> 3.4"},
      # override for nostrum discord
      {:gun, "2.0.1", [env: :prod, hex: "remedy_gun", override: true, repo: "hexpm"]}
    ]
  end
end
