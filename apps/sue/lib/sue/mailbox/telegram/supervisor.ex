defmodule Sue.Mailbox.Telegram.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    token = Keyword.fetch!(opts, :token)

    children = [
      ExGram,
      {Sue.Mailbox.Telegram.Bot, [method: :polling, token: token]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
