defmodule Sue.Models.Poll do
  @moduledoc """
  A poll in a chat. At most one poll per chat at a time; creating a new poll
  replaces the previous one. The id is derived from the chat id so the replace
  semantics fall out of `Graph.put` for free.
  """

  alias __MODULE__

  @enforce_keys [:chat_id, :topic, :options, :votes, :interface]
  defstruct [:chat_id, :topic, :options, :votes, :id, interface: :standard]

  @type interface() :: :standard | :platform
  @type t() :: %__MODULE__{
          chat_id: bitstring(),
          topic: bitstring(),
          options: [bitstring()],
          # k: AccountID, v: ChoiceIndex
          votes: map(),
          interface: interface(),
          id: bitstring() | nil
        }

  @spec new(Sue.Models.Chat.t(), bitstring(), [bitstring(), ...], interface()) :: t()
  def new(chat, topic, options, interface) do
    %Poll{
      id: id_for(chat.id),
      chat_id: chat.id,
      topic: topic,
      options: options,
      votes: %{},
      interface: interface
    }
  end

  @spec id_for(bitstring()) :: bitstring()
  def id_for(chat_id), do: "poll:#{chat_id}"

  @doc "Build a Poll struct from a Subaru vertex map."
  @spec from_map(map()) :: t()
  def from_map(m), do: struct(__MODULE__, m)
end
