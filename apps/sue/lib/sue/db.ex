defmodule Sue.DB do
  @moduledoc """
  Domain operations on Sue's graph. Callers work in `%Account{}`/`%Chat{}`/
  `%Defn{}`/`%Poll{}`, never in raw vertices or edges — `Sue.DB` is the only
  module that knows the graph layout.

  Subaru stores and returns plain maps with an `:id` field (and `:type` set
  to the struct module when it was stored as a struct). `Sue.DB` converts at
  the boundary: Subaru's maps in → typed Sue structs out.
  """

  alias Sue.Graph
  alias Sue.DB.Schema
  alias Sue.Models.{Account, Chat, Defn, PlatformAccount, Poll}

  import Subaru.Query

  # ==================
  # || Resolution  ||
  # ==================

  @doc """
  Make sure the chat exists in the graph and return it with `:id` populated.
  The id is deterministic from `{platform, external_id}`, so repeated calls
  are a safe no-op.
  """
  @spec resolve_chat(Chat.t()) :: Chat.t()
  def resolve_chat(%Chat{platform_id: {platform, external_id}} = chat) do
    chat = %Chat{chat | id: Chat.id_for(platform, external_id)}
    :ok = Graph.put(chat, on_conflict: :skip)
    chat
  end

  @doc """
  Make sure the platform account exists in the graph and return it with
  `:id` populated. Deterministic id — safe to call on every incoming message.
  """
  @spec resolve_paccount(PlatformAccount.t()) :: PlatformAccount.t()
  def resolve_paccount(%PlatformAccount{platform_id: {platform, external_id}} = pa) do
    pa = %PlatformAccount{pa | id: PlatformAccount.id_for(platform, external_id)}
    :ok = Graph.put(pa, on_conflict: :skip)
    pa
  end

  @doc """
  Resolve a platform account to its unified Sue `%Account{}`. If no account
  is linked yet, mint a fresh one (ULID) and draw the edge.

  Account ids are opaque ULIDs — that way the same Sue identity can later
  absorb a second `PlatformAccount` (linking someone's iMessage to their
  Telegram) without renaming anything. We look up the existing link via the
  outgoing `:account_for_platform_account` edge from the PA.

  Not wrapped in a transaction: all message processing funnels through the
  `Sue` GenServer, so check-and-create is already serialized per-BEAM. The
  theoretical race exists only across nodes, which Sue doesn't have.
  """
  @spec resolve_paccount_to_account(PlatformAccount.t()) :: Account.t()
  def resolve_paccount_to_account(%PlatformAccount{id: pa_id}) when is_binary(pa_id) do
    case Graph.run(v(pa_id) |> out(Schema.account_for_platform_account()) |> take(1)) do
      [raw | _] ->
        Account.from_map(raw)

      [] ->
        account = Account.new()
        :ok = Graph.put(account)
        :ok = Graph.link(pa_id, Schema.account_for_platform_account(), account.id)
        account
    end
  end

  @doc "Mark a user as present in a chat. Idempotent."
  @spec add_user_chat_edge(Account.t(), Chat.t()) :: :ok
  def add_user_chat_edge(%Account{id: a}, %Chat{id: c})
      when is_binary(a) and is_binary(c) do
    Graph.link(a, Schema.user_in_chat(), c)
  end

  # =================
  # || Definitions ||
  # =================

  @doc """
  Upsert a definition and draw author/surface edges.

  A fresh `%Defn{}` (new ULID) is written every time — old definitions of the
  same `var` are not deleted, they just lose the "latest" race in lookup. This
  gives us history for free.
  """
  @spec add_defn(Defn.t(), bitstring(), bitstring()) :: {:ok, bitstring()}
  def add_defn(%Defn{id: defn_id} = defn, account_id, chat_id)
      when is_binary(defn_id) and is_binary(account_id) and is_binary(chat_id) do
    :ok = Graph.put(defn)
    :ok = Graph.link(account_id, Schema.defn_by_user(), defn_id)
    :ok = Graph.link(chat_id, Schema.defn_by_chat(), defn_id)
    {:ok, defn_id}
  end

  @doc """
  Find the best-matching definition for a user asking about `varname`.

  Algorithm:
    1. If in a 1:1 chat with Sue, prefer the user's own definition.
    2. Otherwise (or if no personal defn exists), return the latest definition
       authored by any user who shares a chat with this account.
  """
  @spec find_defn(bitstring(), boolean(), bitstring()) :: {:ok, Defn.t()} | {:error, :dne}
  def find_defn(account_id, is_direct, varname)

  def find_defn(account_id, true, varname) do
    case own_defns(account_id, varname) do
      [defn | _] -> {:ok, defn}
      [] -> find_defn(account_id, false, varname)
    end
  end

  def find_defn(account_id, false, varname) do
    case friends_defns(account_id, varname) do
      [defn | _] -> {:ok, defn}
      [] -> {:error, :dne}
    end
  end

  @doc "All definitions authored by this user."
  @spec get_defns_by_user(bitstring()) :: [Defn.t()]
  def get_defns_by_user(account_id) when is_binary(account_id) do
    Graph.run(v(account_id) |> out(Schema.defn_by_user()))
    |> Enum.map(&Defn.from_map/1)
    |> latest_first()
  end

  @doc "All definitions surfaced in this chat (regardless of author)."
  @spec get_defns_by_chat(bitstring()) :: [Defn.t()]
  def get_defns_by_chat(chat_id) when is_binary(chat_id) do
    Graph.run(v(chat_id) |> out(Schema.defn_by_chat()))
    |> Enum.map(&Defn.from_map/1)
    |> latest_first()
  end

  # The user's own definitions of `varname`, newest first.
  defp own_defns(account_id, varname) do
    account_id
    |> get_defns_by_user()
    |> Enum.filter(&(&1.var == varname))
  end

  # Definitions of `varname` authored by anyone who shares a chat with
  # `account_id`. Three hops, cycle-safe via unique/1 between the social
  # steps so a user in multiple shared chats isn't visited multiple times.
  defp friends_defns(account_id, varname) do
    Graph.run(
      v(account_id)
      |> out(Schema.user_in_chat())
      |> in_(Schema.user_in_chat())
      |> unique()
      |> out(Schema.defn_by_user())
      |> filter(&(&1.var == varname))
    )
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&Defn.from_map/1)
    |> latest_first()
  end

  defp latest_first(defns), do: Enum.sort_by(defns, & &1.date_modified, :desc)

  # ===========
  # || Polls ||
  # ===========

  @doc """
  Create or replace the poll for a chat. One poll per chat — the poll id is
  derived from the chat id, so `put` replaces the previous poll (if any)
  atomically.
  """
  @spec add_poll(Poll.t(), bitstring()) :: {:ok, Poll.t()}
  def add_poll(%Poll{chat_id: chat_id} = poll, chat_id) when is_binary(chat_id) do
    :ok = Graph.put(poll)
    :ok = Graph.link(chat_id, Schema.poll_by_chat(), poll.id)
    {:ok, poll}
  end

  @spec find_poll(Chat.t()) :: {:ok, Poll.t()} | {:error, :dne}
  def find_poll(%Chat{id: chat_id}) when is_binary(chat_id) do
    case Graph.get(Poll.id_for(chat_id)) do
      {:ok, raw} -> {:ok, Poll.from_map(raw)}
      :error -> {:error, :dne}
    end
  end

  @doc "Record a user's vote. Overwrites any prior vote by the same user."
  @spec add_poll_vote(bitstring(), bitstring(), integer()) :: {:ok, Poll.t()}
  def add_poll_vote(chat_id, account_id, choice_idx)
      when is_binary(chat_id) and is_binary(account_id) and is_integer(choice_idx) do
    case Graph.get(Poll.id_for(chat_id)) do
      {:ok, raw} ->
        %Poll{} = poll = Poll.from_map(raw)
        updated = %Poll{poll | votes: Map.put(poll.votes, account_id, choice_idx)}
        :ok = Graph.put(updated)
        {:ok, updated}

      :error ->
        {:error, :dne}
    end
  end

  # ==========
  # || User ||
  # ==========

  @spec change_name(bitstring(), bitstring()) :: :ok | {:error, :dne}
  def change_name(account_id, newname) when is_binary(account_id) and is_binary(newname) do
    case Graph.get(account_id) do
      {:ok, raw} ->
        %Account{} = account = Account.from_map(raw)
        Graph.put(%Account{account | name: newname})

      :error ->
        {:error, :dne}
    end
  end
end
