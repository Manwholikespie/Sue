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
      elixir: "~> 1.15",
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
      extra_applications: [:logger, :runtime_tools, :eex],
      included_applications: included_applications()
    ]
  end

  defp included_applications do
    # Nostrum 0.10+ starts automatically as an OTP app, but we only want it
    # to start if Discord is enabled in the config. By including it here,
    # we prevent it from auto-starting, and manually start it in Sue.Application
    # only when :discord is in the platforms list.
    [:nostrum]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:subaru, path: "../../../subaru"},
      {:bream, path: "../../../bream"},
      # Used only by `mix sue.migrate.arango` to read the old ArangoDB.
      # Drop once the migration is done.
      {:arangox, "~> 0.7.0", only: [:dev, :test]},
      # until I reach a stable release
      {:imessaged, git: "https://github.com/Manwholikespie/imessaged"},
      {:timex, "~> 3.0"},
      {:logger_file_backend, "~> 0.0.10"},
      {:phoenix_pubsub, "~> 2.0"},
      # telegram - start
      {:ex_gram, "~> 0.65"},
      {:req, "~> 0.5.17"},
      # telegram - end
      {:jason, "~> 1.2"},
      {:hammer, "~> 6.1"},
      {:replicate, "~> 1.1.0"},
      # discord
      {:nostrum, "~> 0.10"},
      {:cowlib, "~> 2.15"},
      {:gun, "~> 2.2"},
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
