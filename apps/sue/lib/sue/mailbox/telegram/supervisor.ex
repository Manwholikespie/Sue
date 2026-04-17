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

    # Wider restart window than the default (3/5s). A Telegram outage can
    # easily produce a flurry of transient errors; we want the supervisor to
    # absorb those without tearing itself down.
    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
