defmodule Sue.AI.Sessions do
  @moduledoc """
  Per-chat persistent Bream sessions for Sue.

  Each chat keeps at most one open Bream/Claude session. Sessions stay alive
  across `!gpt` invocations and interjection-driven turns, then close after
  12h of idle to release the underlying Claude CLI process. The next turn
  after expiry starts a fresh session — Sue's `RecentMessages` cache is left
  alone so the new session can still be seeded with whatever's still cached.
  """

  use GenServer
  require Logger

  alias Sue.Models.Chat

  @sweep_interval :timer.hours(1)
  @idle_threshold :timer.hours(12)
  @model "claude-sonnet-4-6"
  @start_timeout 60_000

  defstruct sessions: %{}

  @type session_record :: %{
          bream_session_id: String.t(),
          last_seen_msg_time: DateTime.t() | nil,
          last_interaction_at: DateTime.t(),
          started_at: DateTime.t()
        }

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get (or start) the Bream session for a chat.

  Returns `{:ok, :fresh | :continuing, bream_session_id, last_seen_msg_time}`.
  `:fresh` means this is a brand-new session (no prior turns); the caller
  should seed Claude with chat context. `:continuing` means we're appending
  to an existing session and `last_seen_msg_time` is the timestamp of the
  most recent message Claude has already been shown.
  """
  @spec prepare_turn(Chat.t()) ::
          {:ok, :fresh | :continuing, String.t(), DateTime.t() | nil}
          | {:error, term()}
  def prepare_turn(%Chat{} = chat) do
    GenServer.call(__MODULE__, {:prepare_turn, chat}, @start_timeout + 5_000)
  end

  @doc """
  Mark a turn as completed. Updates the watermark to `last_msg_time` (the
  timestamp of the latest message that was part of the turn we just sent)
  and bumps last_interaction_at.
  """
  @spec record_turn(String.t(), DateTime.t()) :: :ok
  def record_turn(chat_id, %DateTime{} = last_msg_time) when is_binary(chat_id) do
    GenServer.cast(__MODULE__, {:record_turn, chat_id, last_msg_time})
  end

  @doc "Forcibly close and forget a chat's session. Useful for tests and `/reset`-style ops."
  @spec forget(String.t()) :: :ok
  def forget(chat_id) when is_binary(chat_id) do
    GenServer.call(__MODULE__, {:forget, chat_id})
  end

  ## GenServer

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:prepare_turn, %Chat{id: chat_id} = chat}, _from, state) do
    case Map.get(state.sessions, chat_id) do
      %{bream_session_id: id, last_seen_msg_time: ts} = rec ->
        if session_alive?(id) do
          rec = %{rec | last_interaction_at: DateTime.utc_now()}
          state = put_in(state.sessions[chat_id], rec)
          {:reply, {:ok, :continuing, id, ts}, state}
        else
          Logger.info("[Sue.AI.Sessions] stale session for chat=#{chat_id}, restarting")
          state = %{state | sessions: Map.delete(state.sessions, chat_id)}
          start_fresh(chat, state)
        end

      nil ->
        start_fresh(chat, state)
    end
  end

  def handle_call({:forget, chat_id}, _from, state) do
    case Map.pop(state.sessions, chat_id) do
      {nil, _} ->
        {:reply, :ok, state}

      {%{bream_session_id: id}, sessions} ->
        _ = Bream.close(id)
        {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  @impl true
  def handle_cast({:record_turn, chat_id, %DateTime{} = ts}, state) do
    sessions =
      case Map.get(state.sessions, chat_id) do
        nil ->
          state.sessions

        rec ->
          Map.put(state.sessions, chat_id, %{
            rec
            | last_seen_msg_time: latest(rec.last_seen_msg_time, ts),
              last_interaction_at: DateTime.utc_now()
          })
      end

    {:noreply, %{state | sessions: sessions}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = DateTime.utc_now()

    {expired, kept} =
      Enum.split_with(state.sessions, fn {_chat_id, rec} ->
        DateTime.diff(now, rec.last_interaction_at, :millisecond) > @idle_threshold
      end)

    Enum.each(expired, fn {chat_id, rec} ->
      Logger.info(
        "[Sue.AI.Sessions] expiring session for chat=#{chat_id} bream_id=#{rec.bream_session_id}"
      )

      _ = Bream.close(rec.bream_session_id)
    end)

    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, %{state | sessions: Map.new(kept)}}
  end

  ## Helpers

  defp start_fresh(%Chat{id: chat_id} = chat, state) do
    case Bream.start_session(system_prompt: Sue.AI.system_prompt(chat), model: @model) do
      {:ok, id} ->
        now = DateTime.utc_now()

        rec = %{
          bream_session_id: id,
          last_seen_msg_time: nil,
          last_interaction_at: now,
          started_at: now
        }

        state = put_in(state.sessions[chat_id], rec)
        {:reply, {:ok, :fresh, id, nil}, state}

      {:error, reason} = err ->
        Logger.error("[Sue.AI.Sessions] start_session failed: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  defp session_alive?(id) do
    case Bream.info(id) do
      %{} -> true
      _ -> false
    end
  end

  defp latest(nil, ts), do: ts
  defp latest(a, b), do: if(DateTime.compare(b, a) == :gt, do: b, else: a)
end
