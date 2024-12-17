defmodule Sue.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "3.1.3",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [
        sue: [
          applications: [sue: :permanent, subaru: :permanent],
          strip_beams: [keep: ["Docs"]]
        ]
      ]
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"]
    ]
  end
end
