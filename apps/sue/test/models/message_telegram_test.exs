defmodule Sue.Models.MessageTelegramTest do
  use ExUnit.Case

  alias ExGram.Model.Chat
  alias ExGram.Model.Message, as: TelegramMessage
  alias ExGram.Model.User
  alias Sue.DB.Schema
  alias Sue.Models.Message

  setup do
    Schema.debug_clear_collections()
    :ok
  end

  test "from_telegram2 parses slash commands from the original Telegram message text" do
    msg = Message.from_telegram2(telegram_message("/ping hello there"))

    assert msg.platform == :telegram
    assert msg.command == "ping"
    assert msg.args == "hello there"
    assert msg.body == "/ping hello there"
    refute msg.is_ignorable
  end

  test "from_telegram_command reconstructs command messages from ex_gram dispatch data" do
    msg = Message.from_telegram_command("ping", telegram_message("hello there"))

    assert msg.platform == :telegram
    assert msg.command == "ping"
    assert msg.args == "hello there"
    assert msg.body == "/ping hello there"
    refute msg.is_ignorable
  end

  test "from_telegram_command strips botname suffixes from parsed commands" do
    msg = Message.from_telegram_command("ping@SueTestBot", telegram_message("status"))

    assert msg.command == "ping"
    assert msg.args == "status"
    assert msg.body == "/ping status"
    refute msg.is_ignorable
  end

  defp telegram_message(text) do
    %TelegramMessage{
      message_id: 100,
      date: 1_700_000_000,
      text: text,
      chat: %Chat{id: 123, type: "private"},
      from: %User{id: 456, is_bot: false, first_name: "Test"}
    }
  end
end
