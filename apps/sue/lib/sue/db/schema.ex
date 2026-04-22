defmodule Sue.DB.Schema do
  @moduledoc """
  Edge-type atoms used across Sue's graph.

  Subaru edges are keyed by `(from, type, to)` — these atoms are the `type`.
  Keeping them here (instead of inline string literals scattered through
  `Sue.DB`) means a typo surfaces at compile time, not runtime.
  """

  @typedoc "Every edge in the Sue graph has one of these types."
  @type edge_type ::
          :user_in_chat
          | :defn_by_user
          | :defn_by_chat
          | :poll_by_chat
          | :account_for_platform_account

  @doc "User ↔ chat membership. `account -> chat`."
  def user_in_chat, do: :user_in_chat

  @doc "A definition authored by a user. `account -> defn`."
  def defn_by_user, do: :defn_by_user

  @doc "A definition surfaced in a chat. `chat -> defn`."
  def defn_by_chat, do: :defn_by_chat

  @doc "A poll belonging to a chat. `chat -> poll`."
  def poll_by_chat, do: :poll_by_chat

  @doc "Platform identity resolved to a unified Sue account. `pa -> account`."
  def account_for_platform_account, do: :account_for_platform_account

  @doc """
  Test-support: wipe every vertex and edge under `Sue.Graph`.
  """
  def debug_clear do
    Subaru.Adapters.Khepri.clear(Sue.Graph)
  end
end
