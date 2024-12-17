![](https://i.imgur.com/TIVNQ7o.jpg)

# Sue

Greetings and welcome to Sue, a chatbot for iMessage, Discord, and Telegram written in Elixir. Now with ChatGPT and Stable Diffusion!

## Demo

Feedback is greatly appreciated!

| Platform |                                 |
| ---------|---------------------------------|
| iMessage | send !help to sue@robertism.com |
| Telegram | send /help to @ImSueBot         |
| Discord  | send !help after [adding to your server](https://discord.com/api/oauth2/authorize?client_id=1087905317838409778&permissions=534723950656&scope=bot%20applications.commands) |

## Introduction

Sue has a long history. You'll have to ask me about it, because I'm not writing it. I made a [YouTube Video](https://www.youtube.com/watch?v=ocTAFPCH_A0) about an earlier version. Some things have been added since then, some things have been removed since then.

The following commands are currently supported:

```
!1984
!8ball
!box
!choose
!cringe
!define
!doog
!emoji
!flip
!fortune
!gpt
!motivate
!name
!phrases
!ping
!poll
!qt
!random
!rub
!sd
!uptime
!vote
```

Telegram uses the slash (/) prefix instead. Sue will not respond to you unless you use the proper prefix. **Do not just message her "hi", expecting a miracle**. You would be amazed how many people do. Discord uses exclamation mark same as iMessage.

## How do I run it?

1. If you want to use iMessage, you need a mac with iMessage. You may be asked to enable disk access and Message control for this program (or, rather, Terminal/iTerm).
2. If you want to use Telegram, you should make a Telegram API key. Look up how, it's pretty straightforward. Similarly if you want to use ChatGPT, make an OpenAI account and generate an API key.
3. If you want to use Discord, again, make an API key, a bot, and under gateway intents enable message content intent.
4. If you wish to disable any platforms such as Telegram or iMessage, modify the platform list under `config/config.exs` to what you wish to keep.
6. This program uses [ArangoDB](https://www.arangodb.com/download-major/) as its primary database. In the years since I made this transition, someone there has sadly decided to drop support for MacOS. Eventually, I'll move back to the Mnesia implementation I was using for Sue, but until then, you'll need to install Docker. The following will only start Arango in Docker, as the rest of the Sue Elixir application needs AppleScript to function.

```bash
brew install docker
brew install docker-compose

# in Sue directory
docker-compose up -d
```

6. Make a user account and remember the password. You'll later enter it in the config described below. Create three databases:

```
subaru_test
subaru_dev
subaru_prod
```

If you don't want to connect via the root Arango account, make sure the user you created has access to the databases. You can edit user permissions by being in the `_system` database, clicking the `Users` sidebar, selecting a user, then navigating to the `Permissions` tab.

7. Make a `config/config.secret.exs` file, here is an example:

```elixir
import Config

# Telegram API
config :ex_gram, token: "mytoken"

# Discord API
config :nostrum,
  gateway_intents: [
    :guilds,
    :guild_messages,
    :guild_message_reactions,
    :direct_messages,
    :direct_message_reactions,
    :message_content
  ],
  token: "mytoken"

config :desu_web, DesuWeb.Endpoint,
  secret_key_base: "Run this command: $ mix phx.gen.secret"

config :arangox,
  endpoints: "tcp://localhost:8529",
  username: "myuser",
  password: "mypass"

config :openai,
  api_key: "myapikey",
  http_options: [recv_timeout: 40_000]

config :replicate,
  replicate_api_token: "myapikey"
```

8. [Install Elixir](https://gist.github.com/Manwholikespie/1bc76cba05f536fc5ec5f998cb56ac97) if you don't already have it.

9. Install Xcode. This is needed for the sdp tool for [imessaged](github.com/Manwholikespie/imessaged).

```bash
# After installing, switch the active developer directory to Xcode
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

10. `mix deps.get`

11. To create a prod build, run `MIX_ENV=prod mix release` It should then tell you the path to the newly created executable.

12. To run in interactive dev mode, you can run `iex -S mix`.  If you want to Telegram to autocomplete your commands, run `Sue.post_init()` from within this interactive prompt. Sorry this part is a little scuffed.

## How do I add a command?

1. When Sue loads (see `sue.ex`), it iterates through the modules under `Sue.Commands`, reading the methods defined in them. If a method name starts with `c_`, it is saved as a callable command. For example, see `rand.ex`:

```elixir
@doc """
Flip a coin. Will return heads or tails.
Usage: !flip
"""
def c_flip(_msg) do
  %Response{body: ["heads", "tails"] |> Enum.random()}
end
```

If your command takes args, these are found in the Message's `args` field. Another example from rand:

```elixir
@doc """
Returns a random object in your space-delimited argument.
Usage: !choose up down left right
"""
def c_choose(%Message{args: ""}) do
  %Response{body: "Please provide a list of things to select. See !help choose"}
end

def c_choose(%Message{args: args}) do
  %Response{
    body:
      args
      |> String.split(" ")
      |> Enum.random()
  }
end
```

## How do I help contribute?

1. Submit an issue and I'll put together some instructions. Basically, just look at the tests. They do a good job of explaining most of Sue's major components, even if there isn't a test for everything.

## Known Issues

- Image functions stopped working in Telegram. I think there's a new Telegram client for Elixir that I'll probably switch to.

## Special Thanks

- Thanks for [Zeke's](https://github.com/ZekeSnider) work on [Jared](https://github.com/ZekeSnider/Jared). Your applescript files were cleaner than mine. Good thinking with sqlite.
- [Peter's](https://github.com/reteps) work on [Otto](https://github.com/reteps/Otto), whose applescript handler was instrumental in Sue V1.
- Multiple bloggers who wrote about iMessage's sqlite schema.
- [Rick](https://github.com/rsrickshaw) for popping a shell in Sue V1, prompting the development of V2.
- All the random [people](https://github.com/Sam1370) that have messaged and broken Sue, pushing me ever forward in its development.