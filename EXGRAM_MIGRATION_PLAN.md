# Migration Plan: `telegex` → `ex_gram`

**Branch:** `exgram` (currently clean, even with master)
**Reference:** `inspiration/ex_gram` (the ex_gram source, checked out locally for reference — **do not ship**, add to `.gitignore` or delete before merge)

## Why migrate

- `telegex` hasn't been updated in ~2 years.
- Two concrete gaps to close during the migration:
  1. **Command autocomplete** via `setMyCommands` — today Sue has `Sue.post_init()` referenced in README/CLAUDE.md but the function doesn't actually exist.
  2. **Message editing** — needed for the upcoming Anthropic streaming swap. Neither library is easier than the other here, but we want a clean handle on `editMessageText` in the new wrapper from day one.

## Current telegex footprint

Only 6 touchpoints. This is small.

| File | What it does |
|---|---|
| `apps/sue/mix.exs:55` | `{:telegex, "~> 1.9.0-rc.0"}` dep |
| `config/config.exs:88-89` | `config :telegex, caller_adapter: {Finch, …}` |
| `apps/sue/lib/sue/mailbox/telegram.ex` | Whole module: `use Telegex.Polling.GenHandler`, `on_boot/0`, `on_update/1`, `send_response_*/2`, `split_message/1` |
| `apps/sue/lib/sue/models/attachment.ex:145-168` | `Telegex.get_file/1` + `Telegex.Global.token/0` for downloading Telegram-hosted files |
| `apps/sue/lib/sue/commands/poll.ex:91` | `Telegex.send_poll/4` |
| `apps/sue/lib/sue/models/message.ex:134` | `from_telegram2/1` — consumes a `Telegex.Type.Message`, but only via field access. Shape is identical in ex_gram, so changes are minimal. |

Supervision: `apps/sue/lib/sue/application.ex:26-31` — `Sue.Mailbox.Telegram` starts as a child (because `use Telegex.Polling.GenHandler` is a GenServer).

## Conceptual differences

| Concern | `telegex` | `ex_gram` |
|---|---|---|
| Dep + HTTP adapter | `config :telegex, caller_adapter: {Finch, …}` — global | `config :ex_gram, adapter: ExGram.Adapter.Finch` — also global. Can keep Finch, no new HTTP dep needed. |
| Token scope | `Telegex.Global.token/0` — one token per app | Per-bot, passed in child spec. Retrieved via the bot context or by passing `bot: :sue_bot` / `token: "…"` to each call. |
| Supervision | One module: `use Telegex.Polling.GenHandler` | Two children: `ExGram` + `{MyBot, [method: :polling, token: token]}`. The bot is `use ExGram.Bot, name: :sue_bot`. |
| Update callback | `on_update(update)` — you pattern-match `update.message` yourself | `handle(update_tuple, context)`, with updates pre-parsed into `{:command, :name, msg}`, `{:text, text, msg}`, `{:callback_query, cb}`, `{:edited_message, msg}`, `{:message, msg}`, `{:update, u}`, etc. |
| Sending | Imperative: `Telegex.send_message/2` | Two styles, both available:<br>**Low-level** — `ExGram.send_message(chat_id, text, bot: :sue_bot)` (same feel as telegex, use this in Sue's existing outbox flow).<br>**DSL** — `context \|> answer("hi") \|> edit("…")`, queued and flushed after `handle/2` returns (reserve for anything brand-new). |
| Models | `Telegex.Type.*` (e.g., `Telegex.Type.File`) | `ExGram.Model.*` (e.g., `ExGram.Model.File`). Field names are identical (snake_case from the Bot API). |
| File sending | Sue currently hand-rolls a multipart POST to `…/sendPhoto` via HTTPoison (`telegram.ex:74-87`) | Native: `ExGram.send_photo(chat_id, {:file, path}, bot: :sue_bot)`. Also `{:file_content, iodata, "name.jpg"}` for streaming. **Big cleanup — HTTPoison usage for file upload goes away.** |
| `getFile` / download | `Telegex.get_file(file_id)` returns `%Telegex.Type.File{}`, token from `Telegex.Global.token/0` | `ExGram.get_file(file_id, bot: :sue_bot)` returns `%ExGram.Model.File{}`. Token lookup needs a small helper (see step 5 below). |
| Poll options | Sue passes `[String.t()]` to `Telegex.send_poll` | ex_gram's `sendPoll` expects `[ExGram.Model.InputPollOption.t()]`. Tiny wrap. |

## The two specific gaps

### Gap 1 — Command autocomplete (`setMyCommands`)

ex_gram has a `command/2` macro + `setup_commands: true` option that auto-registers on startup. But Sue's command system is **platform-agnostic and discovery-based** (`apps/sue/lib/sue.ex:98-118` crawls `Sue.Commands.*` modules via `Code.fetch_docs/1`). We don't want to duplicate every command into the bot module just to get a description.

**Plan:** skip `setup_commands: true`. Instead, in the bot's `init/1` callback, pull from `Sue.get_commands/0` and push to Telegram manually:

```elixir
@impl ExGram.Handler
def init(opts) do
  commands =
    Sue.get_commands()
    |> Enum.reject(fn {name, {_m, _f, doc}} ->
      # Skip hidden/admin commands and commands without docs
      String.starts_with?(name, "h_") or doc in [nil, ""]
    end)
    |> Enum.map(fn {name, {_m, _f, doc}} ->
      %ExGram.Model.BotCommand{
        command: name,
        description: first_line_trimmed(doc, 256)  # Telegram caps at 256 chars
      }
    end)
    |> Enum.take(100)  # Telegram caps at 100 commands

  case ExGram.set_my_commands(commands, bot: opts[:bot]) do
    {:ok, true} -> Logger.info("[Telegram] registered #{length(commands)} commands")
    {:error, err} -> Logger.error("[Telegram] setMyCommands failed: #{inspect(err)}")
  end

  :ok
end
```

This keeps the single source of truth for commands (the `@doc` strings + `c_` naming convention) and runs automatically every time the bot starts. Hidden commands (`c_h_*` like `c_h_debug`, `c_h_version`) stay hidden.

**Open question:** do we want scopes later (e.g., admin commands only for specific users)? The `BotCommandScope` API is there if we do. Not blocking this migration.

### Gap 2 — Message editing (for Anthropic streaming)

ex_gram auto-generates `ExGram.edit_message_text/2`:

```elixir
{:ok, %ExGram.Model.Message{message_id: mid}} =
  ExGram.send_message(chat_id, initial_text, bot: :sue_bot)

ExGram.edit_message_text(new_full_text,
  chat_id: chat_id,
  message_id: mid,
  bot: :sue_bot,
  parse_mode: "MarkdownV2"
)
```

Constraints to design around (these are Telegram's, not ex_gram's):

- **Full-text replacement, not deltas.** Each edit sends the entire accumulated response. During streaming, buffer the full text so far and resend.
- **Rate limits.** Telegram allows ~1 edit/sec per message before 429. Debounce: edit every ~750ms, or on every N tokens, or on newlines. Catch `{:error, %ExGram.Error{code: 429}}` and back off.
- **4096 char ceiling.** If a stream runs past 4096 chars, commit the current message (stop editing it) and start a fresh `send_message` for the next chunk. The existing `split_message/1` logic in `telegram.ex:96-210` is the right algorithm but needs to be adapted to run incrementally rather than all-at-once.
- **Response plumbing.** Today `send_response_text` drops the `Telegex.send_message` return value (`telegram.ex:54-64`). The streaming path needs the `message_id` fed back to the command. The `%Response{is_complete: false}` field already exists (`sue.ex:178` has a code path for it), so the scaffolding is half-there — we just need to route `{chat_id, message_id}` back to the streamer.

**Scope decision:** the streaming work is a follow-up, not part of this migration. But we should make sure the new `Sue.Mailbox.Telegram` exposes the returned message_id instead of dropping it, so the streaming swap doesn't need another round of refactoring.

## Migration steps (ordered by blast radius, smallest first)

### Step 1 — Dep + config swap
- `apps/sue/mix.exs:55`: replace `{:telegex, "~> 1.9.0-rc.0"}` with `{:ex_gram, "~> 0.65"}`.
- Keep `{:finch, "~> 0.19"}` and `{:multipart, "~> 0.1.0"}` for now — verify `multipart` is still needed after ex_gram takes over file upload; likely can be dropped.
- `config/config.exs:88-89`: replace `config :telegex, …` with `config :ex_gram, adapter: ExGram.Adapter.Finch`.
- `config/config.secret.exs`: the telegram token still lives here. Rename the key if it currently uses `:telegex` namespace; Sue will read it from `Application.get_env(:sue, :telegram_token)` or equivalent and pass it to the bot child spec.
- `mix deps.get`, `mix deps.clean telegex`.

### Step 2 — New bot module
Create `apps/sue/lib/sue/mailbox/telegram_bot.ex`:

```elixir
defmodule Sue.Mailbox.TelegramBot do
  use ExGram.Bot, name: :sue_bot

  require Logger
  alias Sue.Models.Message

  @impl ExGram.Handler
  def init(opts) do
    register_commands(opts[:bot])
    :ok
  end

  @impl ExGram.Handler
  def handle({:command, _cmd, msg}, context), do: ingest(msg, context)
  def handle({:text, _text, msg}, context),   do: ingest(msg, context)
  def handle({:message, msg}, context),       do: ingest(msg, context)
  def handle({:edited_message, _msg}, context), do: context
  def handle({:update, _update}, context),    do: context
  def handle(_other, context),                do: context

  defp ingest(msg, context) do
    sue_msg = Message.from_telegram2(msg)
    Sue.process_messages([sue_msg])
    context
  end

  defp register_commands(bot_name), do: # see Gap 1 code block above
end
```

Note: we return `context` unchanged from every handler because we're **not** using the DSL — Sue's outbox handles sending via `Sue.Mailbox.Telegram.send_response/2` after the async command executes. The ex_gram bot is just an inbox adapter.

### Step 3 — Rewrite the outbox (`apps/sue/lib/sue/mailbox/telegram.ex`)
Keep the module — it's still where `send_response/2` lives and where `split_message/1` lives (the splitting logic stays 100% unchanged). Gut the `use Telegex.Polling.GenHandler` parts:

- **Delete:** `on_boot/0`, `on_update/1`, the `use Telegex.Polling.GenHandler` declaration.
- **Replace:** `Telegex.send_message(id, chunk)` → `ExGram.send_message(id, chunk, bot: :sue_bot)`. **Capture the return value** and thread it through so streaming can use the message_id later.
- **Replace:** `Telegex.send_photo(id, att.url)` → `ExGram.send_photo(id, att.url, bot: :sue_bot)`.
- **Delete:** the whole `HTTPoison.post(url, {:multipart, form})` block (`telegram.ex:74-87`) → `ExGram.send_photo(id, {:file, att.filepath}, bot: :sue_bot)`.
- `split_message/1` and friends stay as-is.

The outbox module is no longer a GenServer — it becomes a plain module of helper functions. Remove it from the supervision tree (replaced by the bot in step 7).

### Step 4 — Update `Sue.Models.Message.from_telegram2/1`
Field access (`msg.from.id`, `msg.chat.id`, `msg.photo`, `msg.document`, `msg.reply_to_message`, `msg.date`, `msg.message_id`, `msg.text`, `msg.caption`) is identical between `Telegex.Type.Message` and `ExGram.Model.Message`. **Likely zero code changes**, just verify no `Telegex.Type.*` references in specs.

`construct_attachments/2` (`message.ex:260-282`) uses `.photo`, `.document`, `.file_size`, `.file_id`, `.file_unique_id` — all identical. No changes expected.

### Step 5 — `Sue.Models.Attachment.download_telegram_file/2` (`attachment.ex:145-168`)
- `Telegex.get_file(file_id)` → `ExGram.get_file(file_id, bot: :sue_bot)`
- `%Telegex.Type.File{file_path: …, file_size: …}` → `%ExGram.Model.File{file_path: …, file_size: …}` (same fields)
- `Telegex.Global.token()` → needs a replacement. Options:
  - (a) Stash the token in `:persistent_term` or application env during `Sue.Mailbox.TelegramBot.init/1`.
  - (b) Read it from config each time: `Application.get_env(:sue, :telegram_token)`.
  - (c) Ask ex_gram for it via `ExGram.Token.fetch(:sue_bot)` or similar — verify the exact API when implementing.
- **Decision:** (b) is simplest, no new state, already how the token gets into the bot's child spec. Just make sure `config.secret.exs` exposes it via `config :sue, telegram_token: "…"`.

### Step 6 — `Sue.Commands.Poll.poll_to_response/2` (`poll.ex:91`)
```elixir
options = Enum.map(poll.options, &%ExGram.Model.InputPollOption{text: &1})
{:ok, _} = ExGram.send_poll(chatid, poll.topic, options,
  is_anonymous: false, bot: :sue_bot)
```

### Step 7 — Supervision (`apps/sue/lib/sue/application.ex:26-31`)
```elixir
children_telegram =
  if Sue.Utils.contains?(@platforms, :telegram) do
    token = Application.fetch_env!(:sue, :telegram_token)
    [
      ExGram,
      {Sue.Mailbox.TelegramBot, [method: :polling, token: token]}
    ]
  else
    []
  end
```

Note: `ExGram` (the top-level supervisor) needs to start **before** the bot. If other platforms are on, `ExGram` should still only start when Telegram is enabled — keep it inside the conditional block.

### Step 8 — Docs cleanup
- `CLAUDE.md:97`: delete the `Sue.post_init()` reference (the function never existed).
- `README.md:133`: same.
- `README.md:82`: update the config snippet from `config :telegex, token: "mytoken"` to the new `config :sue, telegram_token: "…"` + `config :ex_gram, adapter: …` shape.

### Step 9 — Clean up `inspiration/`
Before the PR lands: either delete `inspiration/ex_gram` or add `inspiration/` to `.gitignore`. It's ~MBs of reference code that shouldn't ship.

## Testing plan

1. `mix deps.get && mix compile` — catch any `Telegex.*` references I missed.
2. `mix dialyzer` — the repo already runs clean per the recent `68d3f5a` commit; keep it that way.
3. `mix test` — existing tests should still pass. Any test that mocks `Telegex.*` needs updating.
4. Manual smoke test in `iex -S mix`:
   - Bot starts, no crashes.
   - Slash-typing in Telegram shows the command autocomplete menu populated from Sue's registry.
   - `/ping` returns "pong".
   - `/gpt hello` returns a GPT response (text).
   - `/poll topic;a;b;c` creates a native Telegram poll.
   - Send a photo + `/motivate` caption → attachment downloads, motivate runs, result photo sends back.
   - Send a long GPT response that exceeds 4096 chars → `split_message/1` still chunks it correctly.

## Gotchas I want to remember

- **Don't mix `setup_commands: true` with manual `set_my_commands`** — they'll race. Pick the manual path, per Gap 1.
- **`ExGram` goes in the supervision tree alongside the bot**, not inside it. Two separate children.
- **The bot name (`:sue_bot`) is a key** — it's how every `ExGram.send_message(…, bot: :sue_bot)` finds the token. Hardcode it, don't make it configurable.
- **`{:edited_message, _}` falls into `handle/3`** — the default handler must not crash on it. The catch-all clause above handles this.
- **Sue's command registry filters `c_h_*` prefix** when registering with Telegram so admin commands don't leak into autocomplete.
- **Capture `message_id` from send_message return values** in the outbox so streaming can use them later.

## What's explicitly out of scope

- Anthropic SDK streaming implementation (follow-up).
- Webhook mode — polling is fine for Sue's scale.
- Multi-bot support — `:sue_bot` is the only bot.
- Inline queries, callback queries, inline keyboards — Sue doesn't use these today.
- Scoped commands (admin-only etc.) — possible later, not blocking.
