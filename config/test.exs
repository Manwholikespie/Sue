import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :desu_web, DesuWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7cE/y3SoUvtWz0USNemOWQtEhg7GfCABeqWu4U5q+O9ZOJLuzeT/V6nxbwqdgumR",
  server: false

# Print only warnings and errors during test
config :logger, level: :debug

config :sue,
  cmd_rate_limit: {:timer.seconds(5), 5000},
  query_debug: false,
  # Tests use Message.from_debug/1 and Sue.debug_blocking_process_message/1
  # exclusively. Starting real platform adapters pulls in iMessage DB access
  # (needs Full Disk Access), a live Discord shard, and Telegram polling —
  # all noisy and slow in CI.
  platforms: [:debug]
