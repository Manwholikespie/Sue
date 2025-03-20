defmodule Sue.Models.Defn do
  @behaviour Subaru.Vertex

  @enforce_keys [:var, :val, :type]
  defstruct [:var, :val, :type, :date_created, :date_modified, :id]

  @type t() :: %__MODULE__{
          var: bitstring(),
          val: bitstring() | integer(),
          type: :text | :prompt | :bin | :func,
          date_created: integer(),
          date_modified: integer(),
          id: Subaru.dbid() | nil
        }

  @collection "sue_defns"

  alias __MODULE__

  # Support for multiple defn types
  @spec new(bitstring(), bitstring(), atom()) :: t
  def new(var, val, type) when is_bitstring(var) and is_bitstring(val) and type in [:text, :prompt] do
    now = Sue.Utils.unix_now()

    %Defn{
      var: var,
      val: val,
      type: type,
      date_created: now,
      date_modified: now
    }
  end

  @spec from_doc(map()) :: t
  def from_doc(doc) do
    %Defn{
      var: doc["var"],
      val: doc["val"],
      type: Sue.Utils.string_to_atom(doc["type"]),
      date_created: doc["date_created"],
      date_modified: doc["date_modified"],
      id: doc["_id"]
    }
  end

  @impl Subaru.Vertex
  def collection(), do: @collection

  @impl Subaru.Vertex
  def doc(d), do: Sue.Utils.struct_to_map(d)
end
