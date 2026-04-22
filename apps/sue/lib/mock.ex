defmodule Sue.Mock do
  @moduledoc false

  alias Sue.DB
  alias Sue.Models.{Account, PlatformAccount, Chat}

  @spec mock_paccount_account() :: {PlatformAccount.t(), Account.t()}
  def mock_paccount_account(paccount_id \\ 100) do
    pa = DB.resolve_paccount(%PlatformAccount{platform_id: {:debug, paccount_id}})
    a = DB.resolve_paccount_to_account(pa)
    {pa, a}
  end

  def mock_chat(chat_id \\ 200, is_direct \\ false) do
    DB.resolve_chat(%Chat{platform_id: {:debug, chat_id}, is_direct: is_direct})
  end
end
