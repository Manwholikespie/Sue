defmodule Sue.MixProject do
  use Mix.Project

  def project do
    [
      app: :sue,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Sue.Application, []},
      extra_applications: [:logger, :runtime_tools, :mint, :eex]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:subaru, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.0"},
      {:ex_gram, git: "https://github.com/rockneurotiko/ex_gram"},
      # {:tesla, "~> 1.4"},
      {:tesla, git: "https://github.com/teamon/tesla", override: true},
      {:jason, "~> 1.2"},
      {:castore, "~> 0.1.0"},
      {:mint, "~> 1.1"},
      {:sqlitex, "~> 1.7"},

      # imagemagick
      {:mogrify, "~> 0.8.0"},
      {:openai, "~> 0.3.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
