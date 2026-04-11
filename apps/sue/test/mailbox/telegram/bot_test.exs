defmodule Sue.Mailbox.Telegram.BotTest do
  use ExUnit.Case
  use ExGram.Test, set_from_context: false

  alias Sue.Mailbox.Telegram.Bot

  setup do
    ExGram.Test.set_global()
    :ok
  end

  test "registers visible commands on bot startup", context do
    test_pid = self()

    ExGram.Test.stub(:set_my_commands, fn body ->
      send(test_pid, {:commands_registered, body})
      {:ok, true}
    end)

    {_bot_name, _module_name} = ExGram.Test.start_bot(context, Bot)

    assert_receive {:commands_registered, body}

    commands = body[:commands]

    assert Enum.any?(commands, fn cmd -> cmd[:command] == "ping" end)
    refute Enum.any?(commands, fn cmd -> String.starts_with?(cmd[:command], "h_") end)
  end
end
