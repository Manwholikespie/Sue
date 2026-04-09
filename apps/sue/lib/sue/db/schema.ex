defmodule Sue.DB.Schema do
  @moduledoc false

  alias Sue.Models.{Account, Chat, Defn, PlatformAccount, Poll}

  @ecoll_sue_user_in_chat "sue_user_in_chat"
  @ecoll_sue_defn_by_user "sue_defn_by_user"
  @ecoll_sue_defn_by_chat "sue_defn_by_chat"
  @ecoll_sue_poll_by_chat "sue_poll_by_chat"
  @ecoll_sue_user_by_platformaccount "sue_user_by_platformaccount"

  @spec vertex_collections() :: [bitstring()]
  def vertex_collections() do
    defined_vertices() ++ []
  end

  @spec edge_collections() :: [bitstring()]
  def edge_collections() do
    [
      @ecoll_sue_user_in_chat,
      @ecoll_sue_defn_by_user,
      @ecoll_sue_defn_by_chat,
      @ecoll_sue_poll_by_chat,
      @ecoll_sue_user_by_platformaccount
    ]
  end

  # TODO: It would be really nice if there was a way to auto-register these
  #   when creating them to begin with.
  defp defined_vertices() do
    [
      Account.collection(),
      Chat.collection(),
      Defn.collection(),
      Poll.collection(),
      PlatformAccount.collection()
    ]
  end

  def debug_clear_collections() do
    for vc <- vertex_collections() do
      Subaru.remove_all(vc)
    end

    for ec <- edge_collections() do
      Subaru.remove_all(ec)
    end
  end

  def ecoll_sue_user_in_chat(), do: @ecoll_sue_user_in_chat
  def ecoll_sue_defn_by_user(), do: @ecoll_sue_defn_by_user
  def ecoll_sue_defn_by_chat(), do: @ecoll_sue_defn_by_chat
  def ecoll_sue_poll_by_chat(), do: @ecoll_sue_poll_by_chat
  def ecoll_sue_user_by_platformaccount(), do: @ecoll_sue_user_by_platformaccount
end
