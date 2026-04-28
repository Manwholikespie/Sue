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
          strip_beams: [keep: ["Docs"]],
          # horus 0.4.0 (transitive via khepri) calls `:code.get_object_code(:erlang)`
          # at runtime, which needs `erts/ebin/*.beam` on the code path. Mix releases
          # don't bundle those .beam files. include_erts: false makes the release rely
          # on the system's OTP install, whose erts/ebin has them. Keep the system
          # Erlang/OTP version in sync with what the release was built against.
          include_erts: false
        ]
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit],
        plt_add_deps: :app_tree,
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"]
    ]
  end
end
