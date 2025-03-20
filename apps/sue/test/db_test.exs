defmodule DBTest do
  use ExUnit.Case

  alias Sue.DB
  alias Sue.DB.Schema
  alias Sue.Models.{Account, Chat, Defn, Poll, PlatformAccount}

  import Sue.Mock

  # TODO: Figure out if there's a way to limit the scope of a DB change to each
  #   test, or at least maybe automatically call clear_collections at the
  #   beginning and end of each test.

  test "defns" do
    Schema.debug_clear_collections()

    text_defn = Defn.new("megumin", "acute", :text)
    prompt_defn = Defn.new("poem", "Write a poem about $topic", :prompt)

    {_, a} = mock_paccount_account()

    c = mock_chat()

    # upsert should prevent this from duplicating.
    {:ok, text_defn_id1} = DB.add_defn(text_defn, a.id, c.id)
    {:ok, text_defn_id2} = DB.add_defn(text_defn, a.id, c.id)
    {:ok, prompt_defn_id} = DB.add_defn(prompt_defn, a.id, c.id)

    defns = DB.get_defns_by_user(a.id)
    assert length(defns) == 2

    # Test finding text definition
    {:ok, text_defn_searched} = DB.find_defn(a.id, c.is_direct, "megumin")

    # Test finding prompt definition
    {:ok, prompt_defn_searched} = DB.find_defn(a.id, c.is_direct, "poem")

    assert text_defn_id1 == text_defn_id2
    assert text_defn_id1 == text_defn_searched.id
    assert text_defn_searched.type == :text
    assert prompt_defn_id == prompt_defn_searched.id
    assert prompt_defn_searched.type == :prompt
  end

  test "defn ownership" do
    Schema.debug_clear_collections()

    {_, a1} = mock_paccount_account(100)
    {_, a2} = mock_paccount_account(101)

    # this is a direct chat that a1 has with Sue
    c_a1 = mock_chat(1, true)
    DB.add_user_chat_edge(a1, c_a1)

    # this is a group chat that a1 and a2 are in.
    c_a1a2 = mock_chat(2, false)
    DB.add_user_chat_edge(a1, c_a1a2)
    DB.add_user_chat_edge(a2, c_a1a2)

    # a1 creates a new definition in his personal chat.
    d_a1 = Defn.new("megumin", "acute", :text)
    {:ok, d_a1_id} = DB.add_defn(d_a1, a1.id, c_a1.id)

    # a2 creates a new definition in the shared chat.
    d_a2 = Defn.new("aqua", "baqua", :text)
    {:ok, d_a2_id} = DB.add_defn(d_a2, a2.id, c_a1a2.id)

    # confirm we can find these defns the normal way
    {:ok, _} = DB.find_defn(a1.id, true, "megumin")
    {:ok, _} = DB.find_defn(a2.id, false, "aqua")

    # confirm we can also find them by their chat
    [%Defn{id: ^d_a1_id}] = DB.get_defns_by_chat(c_a1.id)
    [%Defn{id: ^d_a2_id}] = DB.get_defns_by_chat(c_a1a2.id)

    # a2 is sue_users/173417
    {:ok, _} = DB.find_defn(a2.id, c_a1a2.is_direct, "megumin")
  end

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

  test "polls" do
    Schema.debug_clear_collections()

    {_pa, a} = mock_paccount_account()
    c = mock_chat()

    p = Poll.new(c, "Best movie?", ["TRON Legacy", "Wild Tales", "Whiplash"], :standard)

    {:ok, _poll_id} = DB.add_poll(p, c.id)
    {:ok, _new_poll} = DB.add_poll_vote(c.id, a.id, 0)

    assert true
  end
end
