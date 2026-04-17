defmodule Sue.Mailbox.Telegram.Bot do
  @moduledoc false

  use ExGram.Bot, name: :sue_bot, get_me: false
  @dialyzer {:nowarn_function, ingest: 2}

  alias ExGram.Model.Chat
  alias ExGram.Model.Message, as: TelegramMessage
  alias ExGram.Model.User
  alias Sue.Models.Message

  on_bot_init(Sue.Mailbox.Telegram.Bot.CommandRegistrar)

  def handle({:command, cmd, %{from: %{id: _}, chat: %{id: _}, date: date} = msg}, context)
      when is_integer(date) do
    Sue.process_messages([Message.from_telegram_command(cmd, msg)])
    context
  end

  def handle({:command, _cmd, _msg}, context), do: context

  def handle({:text, _text, %{from: %{id: _}, chat: %{id: _}, date: date} = msg}, context)
      when is_integer(date),
      do: ingest(msg, context)

  def handle({:text, _text, _msg}, context), do: context

  def handle({:message, %{from: %{id: _}, chat: %{id: _}, date: date} = msg}, context)
      when is_integer(date),
      do: ingest(msg, context)

  def handle({:message, _msg}, context), do: context

  def handle({:edited_message, _msg}, context), do: context
  def handle({:update, _update}, context), do: context
  def handle(_other, context), do: context

  defp ingest(
         %TelegramMessage{
           from: %User{id: _},
           chat: %Chat{id: _, type: chat_type},
           message_id: message_id,
           date: date
         } = msg,
         context
       )
       when is_binary(chat_type) and is_integer(message_id) and is_integer(date) do
    Sue.process_messages([Message.from_telegram2(msg)])
    context
  end
end

defmodule Sue.Mailbox.Telegram.Bot.CommandRegistrar do
  @moduledoc false

  @behaviour ExGram.BotInit

  require Logger

  alias ExGram.Model.BotCommand

  @max_commands 100
  @max_description_length 256

  @impl ExGram.BotInit
  def on_bot_init(opts) do
    bot = Keyword.fetch!(opts, :bot)

    # set_my_commands is a synchronous HTTP call to Telegram. Running it
    # inline would block the bot's init and, transitively, the supervisor
    # tree's startup on a network round trip. Kick it to an unlinked task so
    # startup proceeds immediately; the registration logs its own outcome.
    Task.start(fn -> register_commands(bot) end)
    :ok
  end

  defp register_commands(bot) do
    commands = build_commands()

    case ExGram.set_my_commands(commands, bot: bot) do
      {:ok, true} ->
        Logger.info("[Telegram] registered #{length(commands)} commands")

      {:error, error} ->
        Logger.warning(
          "[Telegram] set_my_commands failed: #{inspect(error)}; continuing without autocomplete"
        )
    end
  rescue
    error ->
      Logger.warning("[Telegram] command registration crashed: #{inspect(error)}")
  end

  defp build_commands do
    Sue.get_commands()
    |> Enum.reject(fn {name, {_module, _function, doc}} ->
      String.starts_with?(name, "h_") or blank_doc?(doc)
    end)
    |> Enum.map(fn {name, {_module, _function, doc}} ->
      %BotCommand{
        command: name,
        description: first_line_trimmed(doc)
      }
    end)
    |> Enum.take(@max_commands)
  end

  defp blank_doc?(doc), do: is_nil(doc) or String.trim(doc) == ""

  defp first_line_trimmed(doc) do
    doc
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.trim()
    |> String.slice(0, @max_description_length)
  end
end
