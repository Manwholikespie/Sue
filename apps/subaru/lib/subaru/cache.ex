defmodule Subaru.Cache do
  @moduledoc false

  use GenServer

  # @table_userchats :user_chat_edges_cache

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    state = %{}
    {:ok, state}
  end

  def put(table, key, val), do: Cachex.put(table, key, val)
  def put!(table, key, val), do: Cachex.put!(table, key, val)

  def put_many(table, pairs), do: Cachex.put_many(table, pairs)
  def put_many!(table, pairs), do: Cachex.put_many!(table, pairs)

  def get(table, key), do: Cachex.get(table, key)
  def get!(table, key), do: Cachex.get!(table, key)

  def del(table, key), do: Cachex.del(table, key)
  def del!(table, key), do: Cachex.del!(table, key)

  def exists?(table, key) do
    {:ok, res} = Cachex.exists?(table, key)
    res
  end
end
