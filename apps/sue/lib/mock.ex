defmodule Sue.Mock do
  @moduledoc false

  alias Sue.Models.{Account, PlatformAccount, Chat}

  @spec mock_paccount_account() :: {PlatformAccount.t(), Account.t()}
  def mock_paccount_account(paccount_id \\ 100) do
    pa =
      %PlatformAccount{platform_id: {:debug, paccount_id}}
      |> PlatformAccount.resolve()

    a = Account.from_paccount(pa)

    {pa, a}
  end

  def mock_chat(chat_id \\ 200, is_direct \\ false) do
    %Chat{platform_id: {:debug, chat_id}, is_direct: is_direct}
    |> Chat.resolve()
  end
end
