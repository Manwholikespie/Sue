defmodule Sue.MixProject do
  use Mix.Project

  def project do
    [
      app: :sue,
      version: "0.2.3",
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
      included_applications: [:nostrum],
      extra_applications: [:logger, :runtime_tools, :finch, :multipart, :eex]
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
      # until I reach a stable release
      {:imessaged, git: "https://github.com/Manwholikespie/imessaged"},
      {:timex, "~> 3.0"},
      {:logger_file_backend, "~> 0.0.10"},
      {:phoenix_pubsub, "~> 2.0"},
      # telegram - start
      {:telegex, "~> 1.9.0-rc.0"},
      {:finch, "~> 0.19"},
      {:multipart, "~> 0.1.0"},
      # telegram - end
      {:jason, "~> 1.2"},
      {:hammer, "~> 6.1"},
      {:exqlite, "~> 0.13"},
      {:openai, "~> 0.5.2"},
      {:replicate, "~> 1.1.0"},
      # discord
      {:nostrum, git: "https://github.com/Kraigie/nostrum", runtime: false},
      {:cowlib, "~> 2.15"},
      {:gun, "~> 2.2"},
      {:mime, "~> 1.2"},
      # images
      {:image, "~> 0.37"}
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
