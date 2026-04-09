defmodule Sue.DB.RecentMessages do
  @moduledoc """
  Cache the N most recent messages from a chat so we can use the context of the
  conversation in commands that require it.

  For example:
    !gpt can have the context of previous questions it was asked.
    !desu can add the last message to the quote page of whoever sent it.

  1000 chats only takes up around 10MB of memory storing 5 previous messages each
  of length 1000. Don't bother persisting anything.
  """

  use GenServer

  alias :queue, as: Queue

  import Subaru, only: [is_dbid: 1]

  @type queue() :: Queue.queue()

  # Keep 6 prev messages per chat
  @context_length 6

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    # keys will be chats, vals will be queues of last few messages.
    state = %{}

    {:ok, state}
  end

  @impl true
  def handle_call({:add, chat_id, message}, _from, state)
      when is_bitstring(chat_id) and is_map(message) and map_size(message) > 0 do
    {q, qlen} = Map.get(state, chat_id, {Queue.new(), 0})
    {q, qlen} = helper_add(q, message, qlen)

    {:reply, :ok, Map.put(state, chat_id, {q, qlen})}
  end

  def handle_call({:get, chat_id}, _from, state) when is_bitstring(chat_id) do
    {q, _qlen} = Map.get(state, chat_id, {Queue.new(), 0})
    {:reply, Queue.to_list(q), state}
  end

  # === Helpers ===

  @spec helper_add(queue(), map(), integer()) :: {queue(), integer()}
  defp helper_add(queue, item, queue_len) when queue_len < @context_length do
    {Queue.in(item, queue), queue_len + 1}
  end

  defp helper_add(queue, item, queue_len) do
    {:queue.in(item, :queue.drop(queue)), queue_len}
  end

  # === Public API ===

  @spec add(Subaru.dbid(), map()) :: :ok
  def add(chat_id, message) when is_dbid(chat_id) do
    GenServer.call(__MODULE__, {:add, chat_id, message})
  end

  @spec get(Subaru.dbid()) :: [map()]
  def get(chat_id) when is_dbid(chat_id) do
    GenServer.call(__MODULE__, {:get, chat_id})
  end

  @doc """
  Get recent messages, ignoring the most recent. Useful when a command was just
  executed (and thus logged) and we only care about the msgs just before then.
  """
  @spec get_tail(Subaru.dbid()) :: [map()]
  def get_tail(chat_id) when is_dbid(chat_id) do
    # Somehow this is fastest https://stackoverflow.com/a/52322926/2877738
    get(chat_id)
    |> Enum.reverse()
    |> tl()
    |> Enum.reverse()
  end
end
