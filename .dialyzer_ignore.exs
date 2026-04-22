[
  # =====================================================================
  # External deps — upstream issues we can't fix
  # =====================================================================

  # Nostrum consumer references Nostrum.ConsumerGroup.join/1. Dialyzer
  # reports this with an absolute path inside the dep.
  ~r{deps/nostrum/lib/nostrum/consumer\.ex},

  # Nostrum is listed as `included_applications` so it doesn't auto-start
  # when :discord isn't enabled. That also keeps it out of dialyzer's
  # application set — the functions exist (grep confirms Nostrum.Api.Message.create/2
  # and Nostrum.Struct.Embed.put_image/2 in deps/) but dialyzer can't see them.
  {"lib/sue/mailbox/discord.ex", :unknown_function},

  # GenServer behaviour callbacks missing optional info on some OTP builds.
  {"/home/runner/work/elixir/elixir/lib/elixir/lib/gen_server.ex", :callback_info_missing}
]
