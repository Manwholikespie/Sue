defmodule Sue.Application do
  @moduledoc false

  use Application

  @configured_platforms Application.compile_env(:sue, :platforms, [])

  def start(_type, _args) do
    register_file_log_backends()
    platforms = enabled_platforms()

    children = [
      Sue.Graph,
      Sue,
      Sue.DB.RecentMessages,
      Sue.AI.Sessions
    ]

    children_imessage =
      if Sue.Utils.contains?(platforms, :imessage) do
        # Method used to avoid strange Dialyzer error...
        [
          Sue.Mailbox.IMessage
        ]
      else
        []
      end

    children_telegram =
      if Sue.Utils.contains?(platforms, :telegram) do
        token = Application.fetch_env!(:sue, :telegram_token)
        [{Sue.Mailbox.Telegram.Supervisor, [token: token]}]
      else
        []
      end

    children_discord =
      if Sue.Utils.contains?(platforms, :discord) do
        # Nostrum 0.10+ is an included_application (doesn't auto-start)
        # Start Nostrum first, then our consumer which will register itself
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

  defp register_file_log_backends do
    Enum.each([:file_log, :error_log], fn id ->
      _ = LoggerBackends.add({LoggerFileBackend, id})
    end)
  end

  defp enabled_platforms do
    if truthy_env?("SUE_DISABLE_PLATFORMS"), do: [], else: @configured_platforms
  end

  defp truthy_env?(name) do
    System.get_env(name) in ["1", "true", "TRUE", "yes", "YES"]
  end
end
