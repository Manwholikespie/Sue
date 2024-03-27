defmodule Desu.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the PubSub system
      {Phoenix.PubSub, name: Desu.PubSub},
      # Start Finch
      {Finch, name: Desu.Finch},
      Desu.Login
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Desu.Supervisor)
  end
end
