defmodule Sue.Models.Chat do
  @moduledoc false

  alias __MODULE__
  alias Sue.Models.Platform

  @enforce_keys [:platform_id, :is_direct]
  defstruct [:platform_id, :is_direct, :id, is_ignored: false]

  @behaviour Subaru.Vertex

  @type t() :: %__MODULE__{
          platform_id: {Platform.t(), bitstring() | integer()},
          is_direct: boolean(),
          is_ignored: boolean(),
          id: nil | bitstring()
        }

  @collection "sue_chats"

  @spec resolve(t) :: t
  def resolve(c) do
    {platform, id} = c.platform_id
    doc_search = %{platform: platform, id: id}
    doc_insert = doc(c)

    {:ok, new_chat} = Subaru.upsert(doc_search, doc_insert, %{}, @collection, true)
    from_doc(new_chat)
  end

  @spec from_doc(map()) :: t
  def from_doc(d) do
    %Chat{
      platform_id: {Sue.Utils.string_to_atom(d["platform"]), d["id"]},
      is_direct: d["is_direct"],
      is_ignored: d["is_ignored"],
      id: d["_id"]
    }
  end

  @impl Subaru.Vertex
  def collection(), do: @collection

  @impl Subaru.Vertex
  def doc(%Chat{platform_id: {platform, id}} = c) do
    Sue.Utils.struct_to_map(c, [:id, :platform_id])
    |> Map.put(:platform, platform)
    |> Map.put(:id, id)
  end
end
