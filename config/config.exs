import Config

# Load .env file if it exists
if File.exists?(".env") do
  File.read!(".env")
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(key, value)
      _ -> :ok
    end
  end)
end

config :desu_web,
  generators: [context_app: false]

# Configures the endpoint
config :desu_web, DesuWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: DesuWeb.ErrorHTML, json: DesuWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Desu.PubSub,
  live_view: [signing_salt: "YEBB28eM"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/desu_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.2.7",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/desu_web/assets", __DIR__)
  ]

# Configure Elixir's Logger. On Linux, if you want it in /var/log, I'll let you
#   set up those permissions yourself. On Windows, idk where it ought to go.
logger_dir =
  case :os.type() do
    {:unix, :darwin} -> Path.join(System.user_home(), "Library/Logs/sue")
    _ -> "logs/"
  end

config :logger,
  backends: [:console, {LoggerFileBackend, :file_log}, {LoggerFileBackend, :error_log}],
  format: "$time [$level] $message\n"

config :logger, :console, level: :debug

config :logger, :file_log,
  path: Path.join(logger_dir, "info.log"),
  level: :info

config :logger, :error_log,
  path: Path.join(logger_dir, "error.log"),
  level: :error

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 25, cleanup_interval_ms: 60_000 * 10]}

config :sue,
  query_debug: false,
  # options include :discord, :imessage, :telegram - :debug is just for testing
  platforms: [:debug, :discord, :imessage, :telegram],
  chat_db_path: Path.join(System.user_home(), "Library/Messages/chat.db"),
  # Rate limits
  cmd_rate_limit: {:timer.seconds(5), 5},
  gpt_rate_limit: {:timer.hours(24), 50},
  sd_rate_limit: {:timer.hours(24), 17}

config :telegex,
  caller_adapter: {Finch, [receive_timeout: 5 * 1000]}

config :subaru,
  dbname: "subaru_#{config_env()}"

import_config "config.secret.exs"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
