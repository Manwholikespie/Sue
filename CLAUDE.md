# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sue is an Elixir-based multi-platform chatbot that supports iMessage, Discord, and Telegram. It's built as an umbrella application with Claude (via Bream) and Stable Diffusion integration.

## Architecture

### Umbrella Structure
- **apps/sue**: Core chatbot logic, command processing, and platform integrations

### Key Components

#### Platform Integration (`apps/sue/lib/sue/mailbox/`)
Each platform has its own mailbox integration handling incoming/outgoing messages.

- **IMessage**: Uses `imessaged` library for macOS Messages.app integration
- **Telegram**: Uses `ex_gram` client library
- **Discord**: Uses `nostrum` client library

#### Command System (`apps/sue/lib/sue/commands/`)
Commands are auto-discovered at startup. Any function prefixed with `c_` becomes a command:
- Commands return `%Response{}` structs
- Located in modules under `Sue.Commands.*`
- Documentation becomes help text

#### Message Flow
1. Platform adapters receive messages, creating `%Message{}` structs
2. Sue GenServer processes messages asynchronously
3. Command modules execute and return `%Response{}`
4. Platform adapters send responses back

## Development Commands

### Setup
```bash
# Install dependencies
mix deps.get

# Create secret config file (see README for template)
touch config/config.secret.exs
```

### Running
```bash
# Development mode (interactive)
iex -S mix

# Production build
MIX_ENV=prod mix release

# Start docker services (ArangoDB)
docker-compose up -d
```

### Testing
```bash
# Run all tests
mix test

# Run specific test file
mix test apps/sue/test/command_test.exs

# Run with coverage
mix test --cover
```

### Code Quality
```bash
# Format code
mix format

# Run dialyzer (static analysis)
mix dialyzer
```

## Configuration

### Required Setup
1. **ArangoDB**: Must be running (use docker-compose)
   - Create databases: `subaru_dev`, `subaru_test`, `subaru_prod`
   
2. **config/config.secret.exs**: Contains API keys for:
   - Telegram bot token
   - Discord bot token
   - Replicate API token
   - ArangoDB credentials under `config :sue, :arango_migration` (only needed while running `mix sue.migrate.arango`)

   Claude access comes from Bream, which uses your existing `~/.claude/`
   credentials — no API key needs to be in config.

   Production Khepri data is tied to the Erlang node name in Ra membership. On
   ayame, stop the release and run the Arango migration as
   `SUE_DISABLE_PLATFORMS=1 MIX_ENV=prod elixir --sname sue -S mix sue.migrate.arango`;
   running bare `MIX_ENV=prod mix sue.migrate.arango` creates a
   `:nonode@nohost` store that the named release can read inconsistently and
   will hang on writes.

3. **Platform-specific**:
   - iMessage: Requires macOS with Messages.app
   - Telegram: Commands register automatically on bot startup
   - Discord: Needs message content intent enabled
   - Interjection: startup warms the configured Ollama/OpenAI-compatible model.
     If `:warmup_required` is true and the warmup fails, Sue startup fails
     before platform adapters come online. Use `SUE_DISABLE_PLATFORMS=1` for
     migration-only runs that should not touch Ollama or external platforms.
     `:ollama_options` is sent as the Ollama `options` payload; ayame defaults
     to `Bream.Provider.OllamaChat`, `qwen3:0.6b`, `think: false`, and
     `%{num_gpu: 0}`.

### Known Upstream Issues

- The production `:erts` code path workaround in `config/runtime.exs` is for a
  Horus upstream bug: Horus asks for `:erlang` object code at runtime, but Mix
  releases do not include `erts/ebin` on the code path by default.

## Adding New Commands

Create a module in `apps/sue/lib/sue/commands/` with functions prefixed `c_`:

```elixir
defmodule Sue.Commands.MyCommand do
  alias Sue.Models.{Message, Response}
  
  @doc """
  Description shown in !help
  Usage: !mycommand <args>
  """
  def c_mycommand(%Message{args: args}) do
    %Response{body: "Result: #{args}"}
  end
end
```

## Important Notes

- Rate limiting configured in `config/config.exs`
- Logs stored in `~/Library/Logs/sue/` on macOS
- Database migrations in `apps/sue/lib/sue/db/migrations/`
- Platform list configurable in `config/config.exs` under `:platforms`
