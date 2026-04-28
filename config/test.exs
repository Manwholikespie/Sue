import Config

khepri_test_dir =
  Path.join(
    System.tmp_dir!(),
    "sue-khepri-test-#{System.unique_integer([:positive])}"
  )

config :sue, Sue.Graph,
  dir: khepri_test_dir,
  store_id: :sue_graph_test

# Print only warnings and errors during test
config :logger, level: :warning
config :logger, :console, level: :warning

config :ex_gram,
  token: "test_token",
  adapter: ExGram.Adapter.Test,
  updates: ExGram.Updates.Test,
  json_engine: Jason

config :sue,
  cmd_rate_limit: {:timer.seconds(5), 5000},
  interjection: [
    enabled: false,
    invoke_rate_limit: nil,
    gpt_rate_limit: nil
  ],
  query_debug: false,
  # Tests use Message.from_debug/1 and Sue.debug_blocking_process_message/1
  # exclusively. Starting real platform adapters pulls in iMessage DB access
  # (needs Full Disk Access), a live Discord shard, and Telegram polling —
  # all noisy and slow in CI.
  platforms: [:debug]
