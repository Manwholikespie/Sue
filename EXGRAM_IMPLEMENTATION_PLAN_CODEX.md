# Revised ExGram Implementation Plan

This plan is based on the current Sue codebase and the checked-in `inspiration/ex_gram` source, not just on the earlier migration notes.

## What I verified first

- The current Telegram integration footprint is still small: one mailbox module, one attachment download path, one poll call site, one message parser, one dependency/config block, and one supervisor child.
- The review's `_cmd` bug is real. `ex_gram` rewrites command messages so `msg.text` / `msg.caption` only contains the post-command remainder before `handle/2` runs.
- The review's `on_bot_init` point is also real. `Dispatcher` runs bot-init hooks before calling the bot module's `init/1`, and the `init/1` return value is ignored.
- The old plan's adapter example is wrong. There is no `ExGram.Adapter.Finch` in the checked-in `ex_gram` source. The real choices are `ExGram.Adapter.Req` or `ExGram.Adapter.Tesla`, with Finch only available as a Tesla backend.
- `ex_gram` defaults `get_me: true`, which means bot startup will fail if `getMe` fails. Sue does not need `bot_info` for this migration, so that should be disabled explicitly.
- `ExGram.File.file_url/2` exists, so Telegram file downloads do not need to read the bot token directly from config or a global.
- In this repo, the resolved `Req` version did not match the `ex_gram` Req adapter API, so the practical adapter choice here is `ExGram.Adapter.Tesla` with Gun.

## Recommended shape

- Keep `Sue.Mailbox.Telegram` as the Telegram boundary module for all transport operations.
- Add a new `Sue.Mailbox.TelegramBot` inbox adapter using `ExGram.Bot`.
- Add a dedicated `Sue.Mailbox.TelegramSupervisor` with `:rest_for_one` so `ExGram` restarting also restarts the bot and re-registers `:sue_bot`.
- Do not make the outbox a GenServer in this PR. Keep it a plain module and add lower-level helpers for future streaming work.
- Use `ExGram.Adapter.Tesla` with Gun for bot API calls, and keep raw file downloads in the Telegram boundary on `HTTPoison`.

## Phase 0: preflight cleanup

1. Align `apps/sue/mix.exs` with the Elixir version the project actually supports.
   The repo currently has inconsistent child-app version declarations. `ex_gram 0.65.0` requires Elixir `~> 1.15`, and local compile succeeded on Elixir `1.20.0-rc.4`.
2. Treat `inspiration/` as reference-only and do not ship it in the migration PR.
3. Decide the HTTP client path up front.
   Recommended for this repo: `ExGram.Adapter.Tesla` plus `config :tesla, adapter: Tesla.Adapter.Gun`.
   Avoid the `Req` adapter here unless the resolved `Req` version is upgraded to one that matches `ex_gram`'s adapter implementation.

## Phase 1: dependency and config swap

1. In `apps/sue/mix.exs`:
   - Replace `{:telegex, ...}` with `{:ex_gram, "~> 0.65"}`.
   - Add the chosen adapter dependency.
     Recommended here: `{:tesla, "~> 1.16"}`.
   - Remove `{:multipart, ...}`. It is only used by the current Telegram upload path.
2. In `config/config.exs`:
   - Remove `config :telegex, caller_adapter: ...`.
   - Add `config :ex_gram, adapter: ExGram.Adapter.Tesla, json_engine: Jason`.
   - Add `config :tesla, adapter: Tesla.Adapter.Gun`.
3. Move the bot token out of `config :telegex` and into `config :sue, telegram_token: ...`.
4. Run dependency refresh and compile after the swap before touching behavior.

## Phase 2: introduce the Telegram boundary API

Rewrite `apps/sue/lib/sue/mailbox/telegram.ex` from a `Telegex.Polling.GenHandler` into a plain module with transport helpers.

Required public surface:

- `send_response/2` as the compatibility entry point for existing Sue code
- `send_text/2` returning the sent `ExGram.Model.Message` structs for each chunk
- `edit_text/3` for future streaming work
- `send_photo/2`
- `send_poll/3`
- `get_file/1`
- `download_file/1` or `download_file/2`

Rules for this module:

- All `ExGram.*` calls live here.
- `split_message/1` stays here and keeps its current behavior for now.
- `send_response/2` may still discard low-level return values, but `send_text/2` should preserve them for future streaming code.
- Use `ExGram.File.file_url(file, bot: :sue_bot)` when downloading Telegram-hosted files instead of reading tokens directly.

## Phase 3: add the inbox bot and supervision

1. Create `Sue.Mailbox.TelegramBot`.
   - `use ExGram.Bot, name: :sue_bot, get_me: false`
   - No `command/2` declarations are needed.
   - Add `on_bot_init(Sue.Mailbox.TelegramBot.CommandRegistrar)`.
2. Create `Sue.Mailbox.TelegramBot.CommandRegistrar`.
   - Build commands from `Sue.get_commands/0`.
   - Filter hidden `h_` commands and blank docs.
   - Call `ExGram.set_my_commands/2`.
   - Log failures and return `:ok` even if registration fails, so autocomplete problems do not crash-loop the bot.
3. Implement handlers:
   - `{:command, cmd, msg}` -> `Sue.process_messages([Message.from_telegram_command(cmd, msg)])`
   - `{:text, _text, msg}` and `{:message, msg}` -> existing text/caption ingestion path
   - ignore edited messages and unrelated updates
4. Create `Sue.Mailbox.TelegramSupervisor` with children in this order:
   - `ExGram`
   - `{Sue.Mailbox.TelegramBot, [method: :polling, token: token]}`
   Strategy: `:rest_for_one`
5. Update `Sue.Application` so Telegram starts through the dedicated supervisor instead of starting `Sue.Mailbox.Telegram` directly.

## Phase 4: fix message parsing for ex_gram command dispatch

`apps/sue/lib/sue/models/message.ex` needs real changes. This is not a no-op.

1. Extract shared Telegram message construction into a private helper.
2. Keep `from_telegram2/1` for normal Telegram messages.
3. Add `from_telegram_command/2` for `ex_gram` command tuples.
   - Use the provided `cmd` instead of reparsing `msg.text`
   - Keep `msg.text || msg.caption || ""` as args
   - Rebuild `body` as `"/#{cmd}"` or `"/#{cmd} #{args}"`
   - Still strip any `@botname` suffix from the command
4. Do not broaden support to channel posts in this PR. Just avoid regressing command handling.

## Phase 5: move call sites behind the Telegram boundary

1. `apps/sue/lib/sue/models/attachment.ex`
   - Replace direct `Telegex.get_file/1` usage with `Sue.Mailbox.Telegram.get_file/1`
   - Replace raw Telegram URL construction with the boundary's download helper
   - Remove direct token lookup
2. `apps/sue/lib/sue/commands/poll.ex`
   - Replace direct `Telegex.send_poll/4` with `Sue.Mailbox.Telegram.send_poll/3`
   - Convert poll options to `ExGram.Model.InputPollOption`
3. Keep `ExGram.*` references out of model and command modules.

## Phase 6: tests

Add tests before the final cleanup pass.

1. Keep the existing `split_message/1` tests.
2. Add unit tests for:
   - `Message.from_telegram2/1`
   - `Message.from_telegram_command/2`
   - `/command@botname args` normalization
3. Add a focused bot test using `ExGram.Test` that proves a Telegram command is not dropped after the migration.
4. Add a command-registration test for the registrar module, or at minimum for the command-building/filtering logic.
5. Run full compile and the Sue test suite after the dependency swap.

## Phase 7: docs and cleanup

1. Update README and CLAUDE references that currently mention `Sue.post_init()`.
2. Document the new token/config shape.
3. Remove any leftover `Telegex.*` references.
4. Ensure `inspiration/` does not land in the migration PR unless intentionally kept out of tree.

## Explicit follow-up, not part of this PR

Streaming edits should be a separate change after the migration is stable.

When that follow-up lands:

- build it on top of `Sue.Mailbox.Telegram.send_text/2` and `edit_text/3`
- use full-text replacement with debounce/backoff
- roll over to a new message after Telegram's text limit
- keep streaming state in a dedicated per-stream process, not in the generic outbox API
