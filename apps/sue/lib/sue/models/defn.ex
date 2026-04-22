defmodule Sue.Models.Defn do
  @moduledoc """
  A user-defined alias — `!define lgtm looks good to me`. The triple
  `{var, val, kind}` is the conceptual identity, but we give each one its own
  ULID so the same phrase can be redefined over time without collision.

  Uses `:kind` rather than `:type` so the field doesn't collide with Subaru's
  own `:type` key on stored vertices.
  """

  alias __MODULE__

  @enforce_keys [:var, :val, :kind]
  defstruct [:var, :val, :kind, :date_created, :date_modified, :id]

  @type t() :: %__MODULE__{
          var: bitstring(),
          val: bitstring() | integer(),
          kind: :text | :prompt | :bin | :func,
          date_created: integer(),
          date_modified: integer(),
          id: bitstring() | nil
        }

  @spec new(bitstring(), bitstring(), :text | :prompt) :: t()
  def new(var, val, kind)
      when is_bitstring(var) and is_bitstring(val) and kind in [:text, :prompt] do
    now = Sue.Utils.unix_now()

    %Defn{
      id: Sue.Graph.gen_id(),
      var: var,
      val: val,
      kind: kind,
      date_created: now,
      date_modified: now
    }
  end

  @doc "Build a Defn struct from a Subaru vertex map."
  @spec from_map(map()) :: t()
  def from_map(m), do: struct(__MODULE__, m)
end
