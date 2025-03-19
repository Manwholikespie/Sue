defmodule Sue.DB do
  use GenServer

  require Logger

  alias Sue.DB.Schema
  alias Sue.DB.Migrations
  alias Sue.Models.{Chat, Defn, Poll, Account, PlatformAccount}

  import Subaru, only: [is_dbid: 1]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    init_schema()
    init_migrations()

    {:ok, []}
  end

  # initialize the collections that need to be in our db for sue.
  defp init_schema() do
    for vcolname <- Schema.vertex_collections() do
      Subaru.DB.create_collection(vcolname, :doc)
    end

    for ecolname <- Schema.edge_collections() do
      Subaru.DB.create_collection(ecolname, :edge)
    end
  end

  defp init_migrations() do
    Subaru.DB.create_collection(Migrations.collection(), :doc)
    Migrations.run_new_migrations()
  end

  # TODO: Clean this up. Ideally we should have figured out if we want an edge
  #   or an account ID across all these sorts of calls, and only do that. I also
  #   don't like the naming.
  @doc """
  Try to find Sue Account for Platform Account. If one does not exist, create it.
  Then establish (upsert) an edge between the two and return the Account id.
  """
  @spec link_paccount_to_resolved_user(PlatformAccount.t()) :: Subaru.dbid()
  def link_paccount_to_resolved_user(%PlatformAccount{id: paccount_id})
      when not is_nil(paccount_id) do
    # Find Sue Account for this Platform Account, if not exist we'll create later.
    account_id =
      case Subaru.traverse_v(
             [Schema.ecoll_sue_user_by_platformaccount()],
             :outbound,
             paccount_id,
             1,
             1
           ) do
        {:ok, []} ->
          _account_id = Subaru.insert!(Account.doc(%Account{}), Account.collection())

        {:ok, [account_doc]} ->
          account_doc["_id"]
      end

    {:ok, _} =
      Subaru.upsert_edge(paccount_id, account_id, Schema.ecoll_sue_user_by_platformaccount())

    account_id
  end

  @doc """
  Mark sue accounts as being present in a chat.
  """
  @spec add_user_chat_edge(Account.t(), Chat.t()) :: Subaru.res_id()
  def add_user_chat_edge(%Account{id: account_id}, %Chat{id: chat_id})
      when not is_nil(account_id) and not is_nil(chat_id) do
    Subaru.upsert_edge(account_id, chat_id, Schema.ecoll_sue_user_in_chat())
  end

  # =================
  # || DEFINITIONS ||
  # =================

  @doc """
  Upsert a definition.
  """
  @spec add_defn(Defn.t(), Subaru.dbid(), Subaru.dbid()) :: {:ok, Subaru.dbid()}
  def add_defn(defn, account_id, chat_id) when is_dbid(account_id) and is_dbid(chat_id) do
    defndoc = Defn.doc(defn)
    defncol = Defn.collection()

    d_search = %{var: defn.var, val: defn.val, type: defn.type}

    {:ok, defn_id} = Subaru.upsert(d_search, defndoc, %{}, defncol)
    {:ok, _} = Subaru.upsert_edge(account_id, defn_id, Schema.ecoll_sue_defn_by_user())
    {:ok, _} = Subaru.upsert_edge(chat_id, defn_id, Schema.ecoll_sue_defn_by_chat())

    {:ok, defn_id}
  end

  @doc """
  Important: There are multiple possible algorithms we can use to resolve which
    definition a user is looking for when they call for it. Most of the time,
    these definitions represent inside jokes for a user group. Thus, it is
    useful for defns to be group (chat) writable.

  The search logic is as follows:
    1. If the user is in 1-1 chat with Sue, prefer their personal definition.
    2. Otherwise, retrieve the latest modified defn by any user of the chat.

  # TODO: Make it configurable by user/chat scope, and add another step where
          we search preferring definition made *in* that chat.
  """
  @spec find_defn(Subaru.dbid(), boolean(), bitstring()) :: {:ok, Defn.t()} | {:error, :dne}
  def find_defn(account_id, chat_is_direct, varname)

  def find_defn(account_id, false, varname) do
    {:ok, hits} = find_defn_by_friends(account_id, varname)

    case helper_defndocs(hits) do
      {:ok, [defn | _]} -> {:ok, defn}
      otherwise -> otherwise
    end
  end

  def find_defn(account_id, true, varname) do
    # First attempt to get the user's personal definition
    case find_defn_by_user(account_id, varname) do
      {:ok, [_hit | _] = hits} ->
        {:ok, [defn | _]} = helper_defndocs(hits)
        {:ok, defn}

      # Otherwise, retrieve the latest modified defn by any user of the chat.
      _ ->
        find_defn(account_id, false, varname)
    end
  end

  @doc """
  Find definition objects made by a user.
  """
  def find_defn_by_user(account_id, varname) do
    Subaru.traverse_v(
      [Schema.ecoll_sue_defn_by_user()],
      :outbound,
      account_id,
      1,
      1,
      %{},
      {:==, "v.var", varname}
    )
  end

  def find_defn_by_friends(account_id, varname) do
    Subaru.traverse_v(
      [Schema.ecoll_sue_user_in_chat(), Schema.ecoll_sue_defn_by_user()],
      :any,
      account_id,
      1,
      3,
      %{"order" => "bfs", "uniqueVertices" => "global"},
      {:and, {:is_same_collection, Defn.collection(), :v}, {:==, "v.var", varname}}
    )
  end

  @spec get_defns_by_chat(Subaru.dbid()) :: [Defn.t()]
  def get_defns_by_user(account_id) do
    with {:ok, hits} <-
           Subaru.traverse_v([Schema.ecoll_sue_defn_by_user()], :outbound, account_id, 1, 1),
         {:ok, defns} <- helper_defndocs(hits) do
      defns
    else
      _ -> []
    end
  end

  def get_defns_by_chat(chat_id) do
    with {:ok, hits} <-
           Subaru.traverse_v([Schema.ecoll_sue_defn_by_chat()], :outbound, chat_id, 1, 1),
         {:ok, defns} <- helper_defndocs(hits) do
      defns
    else
      _ -> []
    end
  end

  @spec helper_defndocs([map()]) :: {:ok, [Defn.t(), ...]} | {:error, :dne}
  defp helper_defndocs([]), do: {:error, :dne}

  defp helper_defndocs([defndoc | _] = defndocs) when is_map(defndoc) do
    {:ok,
     defndocs
     |> Enum.map(&Defn.from_doc/1)
     |> Enum.sort_by(fn d -> d.date_modified end, :desc)}
  end

  # ===========
  # || POLLS ||
  # ===========
  @doc """
  Adds a poll to a chat.

  This function creates a new poll or replaces an existing one for a given chat.
  It establishes an edge between the chat and the poll in the graph database.

  ## Parameters

  - `poll`: A `Poll.t()` struct containing the poll data
  - `chat_id`: The database ID of the chat to which the poll belongs

  ## Returns

  - `{:ok, Poll.t()}`: The newly created or updated poll

  ## Examples

      {:ok, poll} = Sue.DB.add_poll(%Poll{title: "Lunch options", choices: ["Pizza", "Salad"]}, chat_id)
  """
  @spec add_poll(Poll.t(), Subaru.dbid()) :: {:ok, Poll.t()}
  def add_poll(%Poll{chat_id: chat_id} = poll, chat_id) when is_dbid(chat_id) do
    polldoc = Poll.doc(poll)
    pollcol = Poll.collection()

    d_search = %{chat_id: chat_id}
    {:ok, newpoll} = Subaru.repsert(d_search, polldoc, polldoc, pollcol, true)
    {:ok, _} = Subaru.upsert_edge(chat_id, newpoll["_id"], Schema.ecoll_sue_poll_by_chat())

    {:ok, Poll.from_doc(newpoll)}
  end

  @spec find_poll(Chat.t()) :: {:ok, Poll.t()} | {:error, :dne}
  def find_poll(chat) do
    case Subaru.find_one(Poll.collection(), {:==, "x.chat_id", chat.id}) do
      {:ok, doc} when is_map(doc) -> {:ok, Poll.from_doc(doc)}
      {:ok, :dne} -> {:error, :dne}
    end
  end

  @spec add_poll_vote(Subaru.dbid(), Subaru.dbid(), integer()) :: {:ok, Poll.t()}
  def add_poll_vote(chat_id, account_id, choice_idx)
      when is_dbid(chat_id) and is_dbid(account_id) and is_integer(choice_idx) do
    d_search = %{chat_id: chat_id}

    {:ok, newpoll} =
      Subaru.upsert(
        d_search,
        %{},
        %{votes: %{account_id => choice_idx}},
        Poll.collection(),
        true
      )

    {:ok, Poll.from_doc(newpoll)}
  end

  # ==========
  # || User ||
  # ==========
  @spec change_name(Subaru.dbid(), bitstring()) :: :ok
  def change_name(account_id, newname) do
    {:ok, ^account_id} = Subaru.update_with(account_id, %{name: newname}, Account.collection())
    :ok
  end
end
