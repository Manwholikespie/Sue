defmodule DBTest do
  use ExUnit.Case

  alias Sue.DB
  alias Sue.DB.Schema
  alias Sue.Models.{Account, Chat, Defn, Poll, PlatformAccount}

  # TODO: Figure out if there's a way to limit the scope of a DB change to each
  #   test, or at least maybe automatically call clear_collections at the
  #   beginning and end of each test.

  # test "defns" do
  #   Schema.debug_clear_collections()

  #   d = Defn.new("megumin", "acute", :text)

  #   a = mock_account()

  #   c = mock_chat()

  #   # upsert should prevent this from duplicating.
  #   {:ok, defn_id1} = DB.add_defn(d, a.id, c.id)
  #   {:ok, defn_id2} = DB.add_defn(d, a.id, c.id)
  #   [defn] = DB.get_defns_by_user(a.id)

  #   {:ok, defn_searched} = DB.find_defn(a.id, c.id, "megumin")

  #   assert defn_id1 == defn_id2
  #   assert defn_id1 == defn.id
  #   assert defn.id == defn_searched.id
  # end

  # test "defn ownership" do
  #   Schema.debug_clear_collections()

  #   a1 = Account.resolve(%Account{platform_id: {:debug, 100}})
  #   a2 = Account.resolve(%Account{platform_id: {:debug, 200}})

  #   # this is a direct chat that a1 has with Sue
  #   c_a1 = Chat.resolve(%Chat{platform_id: {:debug, 1}, is_direct: true})
  #   DB.add_user_chat_edge(a1.id, c_a1.id)

  #   # this is a group chat that a1 and a2 are in.
  #   c_a1a2 = Chat.resolve(%Chat{platform_id: {:debug, 2}, is_direct: false})
  #   DB.add_user_chat_edge(a1.id, c_a1a2.id)
  #   DB.add_user_chat_edge(a2.id, c_a1a2.id)

  #   # a1 creates a new definition in his personal chat.
  #   d_a1 = Defn.new("megumin", "acute", :text)
  #   {:ok, d_a1_id} = DB.add_defn(d_a1, a1.id, c_a1.id)

  #   # a2 creates a new definition in the shared chat.
  #   d_a2 = Defn.new("aqua", "baqua", :text)
  #   {:ok, d_a2_id} = DB.add_defn(d_a2, a2.id, c_a1a2.id)

  #   # confirm we can find these defns the normal way
  #   {:ok, _} = DB.find_defn(a1.id, c_a1.id, "megumin")
  #   {:ok, _} = DB.find_defn(a2.id, c_a1a2.id, "aqua")

  #   # confirm we can also find them by their chat
  #   [%Defn{id: d_a1_id}] = DB.get_defns_by_chat(c_a1.id)
  #   [%Defn{id: d_a2_id}] = DB.get_defns_by_chat(c_a1a2.id)

  #   # TODO: FIX: this currently fails. hmm.
  #   # {:ok, _} = DB.find_defn(a2.id, c_a1a2.id, "megumin")
  # end

  test "users" do
    Schema.debug_clear_collections()

    # Robert
    pa1 =
      %PlatformAccount{platform_id: {:telegram, 100}}
      |> PlatformAccount.resolve()

    # William
    pa2 =
      %PlatformAccount{platform_id: {:telegram, 101}}
      |> PlatformAccount.resolve()

    # James
    pa3 =
      %PlatformAccount{platform_id: {:telegram, 103}}
      |> PlatformAccount.resolve()

    # Map each of these Platform Accounts to a Sue Account.
    a1 = Account.from_paccount(pa1)
    a2 = Account.from_paccount(pa2)
    a3 = Account.from_paccount(pa3)

    # Robert and William are in Chat 1
    c1 =
      %Chat{platform_id: {:telegram, 200}, is_direct: false}
      |> Chat.resolve()

    {:ok, _} = DB.add_user_chat_edge(a1, c1)
    {:ok, _} = DB.add_user_chat_edge(a2, c1)

    # William and James are in Chat 2
    c2 =
      %Chat{platform_id: {:telegram, 201}, is_direct: false}
      |> Chat.resolve()

    {:ok, _} = DB.add_user_chat_edge(a2, c2)
    {:ok, _} = DB.add_user_chat_edge(a3, c2)
  end

  # test "polls" do
  #   Schema.debug_clear_collections()

  #   a = mock_account()
  #   c = mock_chat()
  #   p = Poll.new(c, "Best movie?", ["TRON Legacy", "Wild Tales", "Whiplash"], :standard)

  #   {:ok, poll_id} = DB.add_poll(p, c.id)
  #   {:ok, new_poll} = DB.add_poll_vote(c, a, 0)

  #   assert true
  # end
end
