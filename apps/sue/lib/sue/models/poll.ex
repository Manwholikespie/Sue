defmodule Sue.Models.Poll do
  @moduledoc false

  @behaviour Subaru.Vertex

  @enforce_keys [:chat_id, :topic, :options, :votes, :interface]
  defstruct [:chat_id, :topic, :options, :votes, :id, interface: :standard]

  @type interface() :: :standard | :platform
  @type t() :: %__MODULE__{
          chat_id: Subaru.dbid(),
          topic: bitstring(),
          options: [bitstring()],
          # k:AccountID, v:ChoiceIndex
          votes: map(),
          interface: interface(),
          id: Subaru.dbid() | nil
        }

  @collection "sue_polls"

  alias __MODULE__

  @spec new(Chat.t(), bitstring(), [bitstring(), ...], interface()) :: t
  def new(chat, topic, options, interface) do
    %Poll{
      chat_id: chat.id,
      topic: topic,
      options: options,
      votes: %{},
      interface: interface
    }
  end

  @spec from_doc(map()) :: t
  def from_doc(doc) do
    %Poll{
      chat_id: doc["chat_id"],
      topic: doc["topic"],
      options: doc["options"],
      votes: doc["votes"],
      interface: Sue.Utils.string_to_atom(doc["interface"]),
      id: doc["_id"]
    }
  end

  def collection(), do: @collection

  def doc(p) do
    Sue.Utils.struct_to_map(p)
  end
end
