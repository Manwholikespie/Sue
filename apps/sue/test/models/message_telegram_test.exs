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

  test "parses slash commands from message text" do
    msg = Message.from_telegram(telegram_message("/ping hello there"))

    assert msg.platform == :telegram
    assert msg.command == "ping"
    assert msg.args == "hello there"
    assert msg.body == "/ping hello there"
    refute msg.is_ignorable
  end

  test "parses slash commands from photo caption" do
    telegram_msg = %TelegramMessage{
      message_id: 100,
      date: 1_700_000_000,
      text: nil,
      caption: "/ping hello",
      chat: %Chat{id: 123, type: "private"},
      from: %User{id: 456, is_bot: false, first_name: "Test"}
    }

    msg = Message.from_telegram(telegram_msg)

    assert msg.command == "ping"
    assert msg.args == "hello"
  end

  test "strips botname suffix from commands" do
    msg = Message.from_telegram(telegram_message("/ping@SueTestBot status"))

    assert msg.command == "ping"
    assert msg.args == "status"
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
