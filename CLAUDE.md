# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sue is an Elixir-based multi-platform chatbot that supports iMessage, Discord, and Telegram. It's built as an umbrella application with ChatGPT and Stable Diffusion integration.

## Architecture

### Umbrella Structure
- **apps/sue**: Core chatbot logic, command processing, and platform integrations
- **apps/subaru**: Database abstraction layer using ArangoDB
- **apps/desu**: Business logic for a social network leveraging Sue for group-chat integrations (not yet implemented)
- **apps/desu_web**: Phoenix web interface for desu (not yet implemented)

### Key Components

#### Platform Integration (`apps/sue/lib/sue/mailbox/`)
Each platform has its own GenServer handling incoming/outgoing messages.

- **IMessage**: Uses `imessaged` library for macOS Messages.app integration
- **Telegram**: Uses `telegex` client library
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

# Setup all child apps
mix setup

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
   - OpenAI API key
   - Replicate API token
   - ArangoDB credentials

3. **Platform-specific**:
   - iMessage: Requires macOS with Messages.app
   - Telegram: Set commands with `Sue.post_init()` in iex
   - Discord: Needs message content intent enabled

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