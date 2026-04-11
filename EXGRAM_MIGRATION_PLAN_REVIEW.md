# Book Debate Review — EXGRAM_MIGRATION_PLAN.md

Synthesis of a 6-agent book debate critiquing the migration plan. Each agent advocated for a different book's frameworks:

- **cesarini** — *Designing for Scalability with Erlang/OTP* (Cesarini & Vinoski)
- **logan** — *Erlang and OTP in Action* (Logan, Merritt, Carlsson)
- **ousterhout** — *A Philosophy of Software Design* (Ousterhout)
- **thomas** — *Programming Elixir* (Dave Thomas)
- **richards** — *Fundamentals of Software Architecture* (Richards & Ford)
- **martin** — *Clean Code* (Robert C. Martin)

---

## Headline finding: the plan is currently broken

All six agents unanimously identified **one critical bug** as the top priority. Credit to **thomas** for catching it on a careful read of ex_gram's dispatcher source — none of the initial analyses flagged it.

### The `_cmd` discard bug

The plan's proposed handler:

```elixir
def handle({:command, _cmd, msg}, context), do: ingest(msg, context)
```

discards the command name. But ex_gram's dispatcher has already **mutated `msg.text`** to strip the `/command` prefix. Tracing it:

1. `dispatcher.ex:376` — `{:command, key, rest} -> {:command, key, %{message | field => rest}}` replaces `msg.text` with the post-command remainder. `"/ping hello"` becomes `"hello"`.
2. The plan's handler passes the mutated `msg` to `from_telegram2/1`.
3. `message.ex:136` — `command_args_from_body(:telegram, msg.text || "")` receives `"hello"`, not `"/ping hello"`.
4. `message.ex:323-332` — the regex `^/(\S+)(?:\s+(.*))?$` doesn't match `"hello"`. Returns `{"", "", "hello"}`.
5. `message.ex:166` — `is_ignorable: command == ""` → **every command is marked ignorable and silently dropped**.

**Impact:** The plan as written would ship a Telegram bot where `/ping`, `/gpt`, `/poll`, `/motivate`, and every other slash command silently does nothing. The smoke test in Step 9 would only catch it if someone actually ran a command manually. There are no unit tests for `from_telegram2/1`.

### The fix everyone converged on (Option 2)

Add `Message.from_telegram_command/2` to `apps/sue/lib/sue/models/message.ex` that accepts the pre-parsed command directly. Extract a shared private `build_telegram_message/4` to avoid duplicating struct construction:

```elixir
# apps/sue/lib/sue/models/message.ex

# Existing entry point, unchanged callers
def from_telegram2(msg) do
  {command, args, body} = command_args_from_body(:telegram, msg.text || msg.caption || "")
  command = parse_command_potentially_with_botname_suffix(command)
  build_telegram_message(command, args, body, msg)
end

# New: for ex_gram's pre-parsed command dispatch.
# ex_gram strips the "/cmd" prefix from msg.text; cmd is the command name
# already parsed out. msg.text / msg.caption is the args-only remainder.
def from_telegram_command(cmd, msg) do
  args = msg.text || msg.caption || ""
  body = if args == "", do: "/#{cmd}", else: "/#{cmd} #{args}"
  build_telegram_message(cmd, args, body, msg)
end

defp build_telegram_message(command, args, body, msg) do
  # ... existing struct construction from from_telegram2/1 ...
end
```

And in `apps/sue/lib/sue/mailbox/telegram_bot.ex` (the new file in Step 2):

```elixir
def handle({:command, cmd, msg}, context) do
  Sue.process_messages([Message.from_telegram_command(cmd, msg)])
  context
end
def handle({:text, _text, msg}, context),  do: ingest(msg, context)
def handle({:message, msg}, context),      do: ingest(msg, context)
```

**Strike the plan's Step 4 claim "likely zero code changes" entirely.** It's demonstrably false.

**Add a unit test.** Every agent who addressed testing agreed: a unit test using `ExGram.Test` (which ex_gram ships) that pushes `{:command, "ping", mutated_msg}` and asserts on the resulting `%Message{}` should be added to the plan's testing section. This would have caught the bug in development. The "`mix test` — existing tests should still pass" step is insufficient because no existing tests cover this path.

---

## Broad consensus items

### 1. The plan's proposed `init/1` fix won't work

**cesarini** verified at `dispatcher.ex:162` that ex_gram's Dispatcher calls `state.bot_module.init(opts)` and **discards the return value entirely**. This means the `{:ok, state, {:continue, :register_commands}}` pattern used in the plan's own code block would be silently ignored — `handle_continue` never fires.

**The correct fix:** use ex_gram's `ExGram.BotInit` hook (the designed extension point for pre-start work). Register it via `on_bot_init(SomeModule)` in the bot module. **Critical constraint:** the hook must swallow errors and return `:ok` even on Telegram API failure — returning `{:error, reason}` triggers `{:stop, {:shutdown, {:on_bot_init_failed, ...}}}`, producing the same crash loop the fix is meant to prevent.

```elixir
defmodule Sue.Mailbox.TelegramBot.CommandRegistrar do
  @behaviour ExGram.BotInit
  require Logger

  @impl ExGram.BotInit
  def on_bot_init(opts) do
    bot = opts[:bot]
    commands = build_commands()
    case ExGram.set_my_commands(commands, bot: bot) do
      {:ok, true} ->
        Logger.info("[Telegram] registered #{length(commands)} commands")
        :ok
      {:error, err} ->
        Logger.warning("[Telegram] setMyCommands failed: #{inspect(err)} — continuing without autocomplete")
        :ok  # swallow — never return {:error, ...} or you'll crash-loop
    end
  end

  defp build_commands, do: # ... pull from Sue.get_commands/0
end

defmodule Sue.Mailbox.TelegramBot do
  use ExGram.Bot, name: :sue_bot
  on_bot_init(Sue.Mailbox.TelegramBot.CommandRegistrar)
  # ...
end
```

**thomas** initially called the blocking `init/1` "fine at Sue's scale" and later conceded — the failure mode (crash loop when Telegram's API is unreachable at startup, eventually exhausting the supervisor's MaxRestarts and killing the whole `:sue` app) is scale-independent.

### 2. Supervision: `rest_for_one` in a dedicated Telegram sub-supervisor

**The failure mode** (cesarini): under the plan's flat `one_for_one` root with `[ExGram, TelegramBot]` as sibling children, if ExGram crashes and restarts, `Registry.ExGram` is re-initialized empty. TelegramBot's `:sue_bot` registration is gone. Subsequent `ExGram.send_message(bot: :sue_bot)` calls return nil tokens and silently fail. **No crash, no restart, just a zombie bot.**

**The fix:** `rest_for_one` strategy in a dedicated `Sue.Mailbox.TelegramSupervisor` containing `[ExGram, TelegramBot, Telegram]` in dependency order. If ExGram crashes, all Telegram-stack children restart together, re-registering `:sue_bot`. As a bonus, the restart-frequency budget is scoped to the Telegram sub-supervisor, so flapping doesn't exhaust the root supervisor and take down `Sue.DB` and the rest of the app.

```elixir
# apps/sue/lib/sue/mailbox/telegram_supervisor.ex
defmodule Sue.Mailbox.TelegramSupervisor do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    children = [
      ExGram,
      {Sue.Mailbox.TelegramBot, [method: :polling, token: token]},
      Sue.Mailbox.Telegram
    ]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

Root supervisor's `children_telegram` block becomes one line:
```elixir
[{Sue.Mailbox.TelegramSupervisor, [token: token]}]
```

**thomas** explicitly conceded to logan's restart-frequency-isolation argument. **ousterhout** prefers inline supervisor syntax in `application.ex` with an explicit `:name` option — either form achieves the isolation.

### 3. Drop `multipart` dep in Step 1 (don't defer)

**thomas** verified: `multipart` is only used by the HTTPoison multipart block in `telegram.ex:74-87` that gets replaced by `ExGram.send_photo/3`. The `desu_web/lib/desu_web/endpoint.ex:42` reference is Plug's built-in `:multipart` atom parser, **not** the hex package. Remove it from `deps/0` and `extra_applications` in `apps/sue/mix.exs` in Step 1. The plan's "verify still needed" hedge is unnecessary work — it's already been verified.

### 4. `send_response_text/2` must return `{:ok, integer()} | {:error, term()}` explicitly

The plan's "capture the return value and thread it through" is vague. Specify the type now while the module is being rewritten — the cost of specifying it explicitly now is ~zero; the cost of cascading a return-type change through the call chain later is substantial. This is strategic programming while the iron is hot.

### 5. Pre-existing `msg.from` nil fragility

`from_telegram2/1` crashes on channel posts where `msg.from` is nil. The migration doesn't introduce this bug, but the plan's Step 4 currently claims "zero code changes" which papers over an existing bug. The plan should note it, even if not fixing it in this PR.

---

## Real trade-offs (where agents genuinely disagreed)

### Trade-off A — `ExGram.*` calls: wrap, or leave direct?

| Position | Advocates | Core argument |
|---|---|---|
| **Wrap: all ExGram calls go through existing `Sue.Mailbox.Telegram`** | ousterhout, cesarini, richards (conceded) | Information Hiding. `attachment.ex` and `poll.ex` are platform-agnostic model modules; `:sue_bot` and `ExGram.*` have no business appearing in them. One file to change when ex_gram changes. |
| **Wrap: new `Sue.Mailbox.TelegramClient` module** | martin | Clean Code Ch 8 Boundaries. Same benefit, but ousterhout won the framing — a new module is a shallow wrapper when the existing module already owns the same concern. |
| **Don't wrap; use named constant `@bot_name`** | thomas | In Elixir, the compiler IS the dependency graph. `mix compile` reports every broken site when ex_gram's API changes — it's not a search problem. Also: `attachment.ex` performs a raw HTTPS file download (`api.telegram.org/file/bot{token}/{path}`), which ExGram doesn't abstract anyway. |

**Debate's converged recommendation:** Extend the existing `Sue.Mailbox.Telegram` module with public wrapper functions (`get_file/1`, `send_poll/4`, `send_photo/2`, etc.). `poll.ex` calls `Sue.Mailbox.Telegram.send_poll/4` instead of `ExGram.send_poll/4`. `attachment.ex` calls `Sue.Mailbox.Telegram.get_file/1` which internally handles both `ExGram.get_file/2` AND the raw HTTPS download (thomas's point about the download being raw HTTP is real — but the wrapper can absorb that complexity, keeping the token hidden).

**Fitness function worth writing** (cesarini's framing, richards agrees): "no direct `ExGram.*` references outside the `Sue.Mailbox.Telegram*` namespace." That's a permanent architectural invariant regardless of streaming, webhooks, or multi-bot decisions.

### Trade-off B — Outbox: plain module or GenServer?

| Position | Advocates | Core argument |
|---|---|---|
| **Keep as GenServer** | cesarini, logan | Natural owner of a `DynamicSupervisor` for per-stream streaming workers when Gap 2 lands. Concrete scenario: if a streaming task crashes mid-stream, the `message_id` is lost with the process and the half-finished Telegram message is orphaned. A supervised GenServer owning `{chat_id → message_id}` state (ETS or sub-supervisor) can survive this. |
| **Plain module now; per-stream GenServer when streaming lands** | ousterhout, thomas, martin, richards | YAGNI. No TODAY failure mode justifies the process. The zombie-bot problem (logan/cesarini's strongest argument) is solved by `rest_for_one`, not by making the outbox a GenServer. Streaming state belongs in a dedicated `Sue.Mailbox.Telegram.Stream` GenServer spawned per stream from the command layer. |

**This is genuinely irreconcilable.** It comes down to whether you trust the streaming story enough to build the outbox to support it speculatively (2 agents) or wait until streaming is actually being implemented (4 agents).

**Recommendation:** Go with the 4-agent majority (plain module) for this migration. But save cesarini's "orphaned message on task crash" scenario as an open question for whoever implements Gap 2 — it's real and should be explicitly considered when the streaming design happens.

### Trade-off C — ADRs and fitness functions

| Position | Advocates | Core argument |
|---|---|---|
| **Both essential** | richards | Every concrete fix has an entropy gradient pointing away from it. Personal project + no team process = MORE need for enforcement, not less. `Sue.post_init()` in CLAUDE.md (which never existed) is literal evidence of the Groundhog Day anti-pattern. |
| **ADRs yes, fitness functions for unsettled decisions no** | ousterhout, thomas, martin, cesarini, logan | Don't encode an actively debated decision as a permanent invariant. The right fitness function is "no `ExGram.*` outside `Sue.Mailbox.Telegram*`" — permanent. Not "outbox must not be a GenServer" — contested. |

**Converged position:** Write ADRs for the settled decisions below. Add **one** fitness function.

**ADRs to write:**
1. Why `rest_for_one` in `TelegramSupervisor` (the ExGram registry invalidation failure mode)
2. Why inbox and outbox are separate processes (fault isolation + framework imposition by ex_gram)
3. Why `:sue_bot` is hardcoded (single-bot application design, not multi-tenant)
4. Why Option 2 (`from_telegram_command/2`) was chosen over the alternatives for the `_cmd` fix (ex_gram contract made explicit at the function signature level)

**Fitness function to add:** No direct `ExGram.*` references outside `Sue.Mailbox.Telegram*`. Simple to implement (grep in a `mix` task or a credo check); permanent architectural invariant; catches the `:sue_bot` leakage problem automatically.

### Trade-off D — Streaming state location (Gap 2 follow-up)

Three positions, converging partially:

- **cesarini:** per-stream GenServer under `DynamicSupervisor` with `:transient` restart. Survives mid-stream crashes — restart resumes editing the existing `message_id`.
- **logan:** per-stream GenServer OR ETS table; Task `:temporary` under `Task.Supervisor` also acceptable for Sue's scale.
- **ousterhout:** per-stream GenServer in a new `Sue.Mailbox.Telegram.Stream` module, spawned by the command — NOT state added to the outbox. Conceded to cesarini that `Task.async` is wrong for event-loop-style debounce timers (Tasks don't have `handle_info`).

**Converged position:** Whatever the process flavor, streaming state lives in a **dedicated per-stream GenServer** (for the debounce timer), spawned by the command layer, managing its own `{chat_id, message_id, buffer, timer_ref}`. The plan should add this as an explicit Gap 2 design constraint.

Whether the process restarts on crash (cesarini — can resume editing the existing message) or dies with the stream (ousterhout — the Anthropic connection is gone anyway) is the decision to make at streaming implementation time, not prejudged here. The migration plan should NOT commit to either.

---

## Ordered punch list for the plan author

1. **[BLOCKING]** Fix the `_cmd` discard bug. Add `Message.from_telegram_command/2`, extract shared `build_telegram_message/4`, update the `{:command, ...}` handler clause. Add unit tests for both functions using synthetic `ExGram.Model.Message` structs.

2. **[BLOCKING]** Fix `init/1` — use `ExGram.BotInit` hook with mandatory error swallowing (`:ok` on both success and failure; log warning on failure). The plan's current code block would silently do nothing because ex_gram discards the return value.

3. **[REQUIRED]** `rest_for_one` supervision — either dedicated `Sue.Mailbox.TelegramSupervisor` module or inline supervisor in `application.ex`. Must include all three children in dependency order: `[ExGram, TelegramBot, Telegram]`.

4. **[REQUIRED]** Drop `multipart` dep in Step 1. Don't defer. Verified unused after file upload moves to `ExGram.send_photo/3`.

5. **[REQUIRED]** Specify `send_response_text/2` return type as `{:ok, integer()} | {:error, term()}` explicitly now, while the module is being rewritten.

6. **[STRONGLY RECOMMENDED]** Wrap all `ExGram.*` calls inside `Sue.Mailbox.Telegram` as public wrapper functions. `attachment.ex` and `poll.ex` call these wrappers instead of ExGram directly. `Sue.Mailbox.Telegram.get_file/1` absorbs both the `ExGram.get_file/2` call AND the raw HTTPS download.

7. **[RECOMMENDED]** Write the 4 ADRs listed in Trade-off C. Add the one fitness function: "no direct `ExGram.*` references outside `Sue.Mailbox.Telegram*`".

8. **[NOTE]** Pre-existing `msg.from` nil fragility for channel posts. Don't claim "zero code changes" in Step 4.

9. **[DEFER, but flag in plan]** Gap 2 streaming requires a dedicated per-stream GenServer (for the debounce timer) with `{chat_id, message_id, buffer}`. The design decision (does it restart on crash to resume editing, or die with the stream?) should be made at streaming implementation time. The migration plan should note this as an open question, not pre-decide it.

---

## Findings that emerged only from the debate

None of these were in any initial analysis — they came out of the cross-debate:

1. **The `_cmd` discard bug itself** (thomas, round 1 after deep source reading)
2. **The plan's own `init/1` fix doesn't work** (cesarini verified at `dispatcher.ex:162`)
3. **`multipart` is already droppable** (thomas, round 2 — the `desu_web` reference is Plug's atom, not the hex package)
4. **Missing test for the command handler path** (multiple agents converged here; there are no existing tests for `from_telegram2/1`)
5. **`attachment.ex` genuinely needs the raw token** (thomas, round 3 — the file download is a raw HTTPS call, not an ExGram call, so any wrapper has to either keep the token visible or absorb the raw HTTP itself)

---

## Meta-observation

This debate's most important finding (the `_cmd` bug) was not in any of the six initial analyses, including the team-lead's framing questions. It emerged from **thomas's deep read of ex_gram's dispatcher source** during initial analysis and was validated by cross-verification from the team lead, cesarini, logan, ousterhout, martin, and richards. The bug survives a casual read of the plan because the handler code looks correct — ousterhout correctly diagnosed this as an "obscurity" problem (APoSD Ch 2): the `ingest(msg, context)` unification across three handle clauses creates a false uniformity that hides the real difference in what `msg.text` contains.

If you take one process lesson from this debate: **read the third-party library's source, not just its docs, when adopting it into a hot path.** ex_gram's documentation describes the handler tuples but does not prominently note that `msg.text` is mutated in the `{:command, ...}` case. The behavior is only visible in `dispatcher.ex:376`.
