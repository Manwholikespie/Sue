[
  # =====================================================================
  # External deps — upstream issues we can't fix
  # =====================================================================

  # Nostrum consumer references Nostrum.ConsumerGroup.join/1. Dialyzer
  # reports this with an absolute path inside the dep.
  ~r{deps/nostrum/lib/nostrum/consumer\.ex},

  # GenServer behaviour callbacks missing optional info on some OTP builds.
  {"/home/runner/work/elixir/elixir/lib/elixir/lib/gen_server.ex", :callback_info_missing},

  # =====================================================================
  # Subaru opaque type warnings
  #
  # Subaru.Query stores `:queue.queue()` and `MapSet.t()` — both opaque.
  # Working with struct fields that hold opaque types triggers these
  # warnings even though we only use the public APIs. Untangling this
  # cleanly requires giving the Query struct a non-opaque representation,
  # which is a subaru-level architectural change.
  # =====================================================================
  {"lib/subaru/query.ex", :call_without_opaque},
  {"lib/subaru/query.ex", :contract_with_opaque},
  {"lib/subaru/query.ex", :unknown_type},
  {"lib/subaru/subgraph.ex", :unknown_type},

  # =====================================================================
  # Subaru cascade — specs in subaru are looser than the inferred types,
  # so every call site returning a Subaru.dbid() / traverse_v() result
  # has a spec that dialyzer disagrees with. Fixing these means
  # tightening subaru's own specs first.
  # =====================================================================
  {"lib/subaru.ex", :no_return},
  {"lib/subaru.ex", :call},
  {"lib/sue/db/d_b.ex", :no_return},
  {"lib/sue/db/d_b.ex", :call},
  {"lib/sue/db/d_b.ex", :invalid_contract},
  # helper_defndocs/1 empty-list clause is dead because traverse_v is
  # inferred to return non-empty results; fix in subaru by tightening
  # the traverse_v / result specs.
  {"lib/sue/db/d_b.ex", :pattern_match},
  {"lib/sue/models/account.ex", :no_return},
  {"lib/sue/models/account.ex", :invalid_contract},
  {"lib/sue/models/message.ex", :no_return},
  {"lib/sue/models/message.ex", :invalid_contract},
  {"lib/sue/models/message.ex", :unused_fun},
  {"lib/sue/models/poll.ex", :unknown_type},

  # =====================================================================
  # Command / mailbox cascade — return types propagate from DB layer,
  # so these show as no_return until subaru specs are tightened.
  # =====================================================================
  {"lib/sue/commands/defns.ex", :no_return},
  # calldefn/1 {:error, :dne} branch flagged as dead because
  # DB.find_defn's error path is unreachable per dialyzer's flow
  # analysis; keep the defensive clause.
  {"lib/sue/commands/defns.ex", :pattern_match},
  # random_image_from_dir/1 spec disagrees with inferred none() path
  # caused by File.ls! / Enum.random raising; spec is accurate but
  # dialyzer treats the raise path as no-return.
  {"lib/sue/commands/images.ex", :invalid_contract},
  {"lib/sue/mailbox/discord.ex", :unknown_function},
  {"lib/sue/mailbox/i_message.ex", :no_return},
  {"lib/sue/mailbox/telegram.ex", :no_return},

  # =====================================================================
  # Test / mock utilities
  # =====================================================================
  {"lib/mock.ex", :no_return},
  {"lib/mock.ex", :invalid_contract}
]
