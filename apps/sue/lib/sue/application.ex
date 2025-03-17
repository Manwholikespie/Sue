defmodule Sue.Application do
  @moduledoc false

  use Application
  require Logger

  @platforms Application.compile_env(:sue, :platforms, [])
  @chat_db_path Application.compile_env(:sue, :chat_db_path)

  def start(_type, _args) do
    children = [
      Sue,
      Sue.DB,
      Sue.DB.RecentMessages,
      Sue.AI
    ]

    children_imessage =
      if Sue.Utils.contains?(@platforms, :imessage) do
        # Method used to avoid strange Dialyzer error...
        [
          Sue.Mailbox.IMessage,
          {Sue.Mailbox.IMessageSqlite, [@chat_db_path]}
        ]
      else
        []
      end

    children_telegram =
      if Sue.Utils.contains?(@platforms, :telegram) do
        [Sue.Mailbox.Telegram]
      else
        []
      end

    children_discord =
      if Sue.Utils.contains?(@platforms, :discord) do
        [
          Nostrum.Application,
          Sue.Mailbox.Discord
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Sue.Supervisor]

    Supervisor.start_link(
      children ++ children_imessage ++ children_telegram ++ children_discord,
      opts
    )
  end
end
