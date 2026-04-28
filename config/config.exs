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

# Configure Elixir's Logger. On Linux, if you want it in /var/log, I'll let you
#   set up those permissions yourself. On Windows, idk where it ought to go.
logger_dir =
  case :os.type() do
    {:unix, :darwin} -> Path.join(System.user_home(), "Library/Logs/sue")
    _ -> "logs/"
  end

config :logger, format: "$time [$level] $message\n"

config :logger, :console, level: :debug

config :logger, :file_log,
  path: Path.join(logger_dir, "info.log"),
  level: :info

config :logger, :error_log,
  path: Path.join(logger_dir, "error.log"),
  level: :error

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 25, cleanup_interval_ms: 60_000 * 10]}

config :sue,
  query_debug: false,
  # options include :discord, :imessage, :telegram - :debug is just for testing
  platforms: [:debug, :discord, :imessage, :telegram],
  chat_db_path: Path.join(System.user_home(), "Library/Messages/chat.db"),
  interjection: [
    enabled: true,
    base_url: "http://localhost:11434/v1",
    model: "LiquidAI/lfm2.5-1.2b-instruct:q5_k_m",
    timeout: 8_000,
    threshold: 0.7,
    invoke_rate_limit: {:timer.minutes(5), 20}
  ],
  # Rate limits
  cmd_rate_limit: {:timer.seconds(5), 5},
  gpt_rate_limit: {:timer.hours(24), 50},
  sd_rate_limit: {:timer.hours(24), 17}

config :ex_gram,
  adapter: ExGram.Adapter.Req,
  json_engine: Jason

config :sue, Sue.Graph,
  dir: Path.expand("../priv/khepri_#{config_env()}", __DIR__),
  store_id: :"sue_graph_#{config_env()}"

import_config "config.secret.exs"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
