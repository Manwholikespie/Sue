defmodule Sue.Models.PlatformAccount do
  @moduledoc """
  A phone number / messenger handle / Discord snowflake — the identifier the
  platform knows a user by. One Sue `Account` can have many `PlatformAccount`s
  pointing at it (same person on iMessage and Telegram).

  The id is derived from `{platform, external_id}` so the same person from the
  same platform always resolves to the same vertex — `Graph.put` is then a safe
  no-op on repeated encounters.
  """

  alias Sue.Models.Platform
  alias __MODULE__

  @enforce_keys [:platform_id]
  defstruct [:platform_id, :id]

  @type t() :: %__MODULE__{
          platform_id: {Platform.t(), bitstring() | integer()},
          id: nil | bitstring()
        }

  @spec new({Platform.t(), bitstring() | integer()}) :: t()
  def new({platform, external_id} = platform_id) when is_atom(platform) do
    %PlatformAccount{platform_id: platform_id, id: id_for(platform, external_id)}
  end

  @spec id_for(Platform.t(), bitstring() | integer()) :: bitstring()
  def id_for(platform, external_id), do: "pa:#{platform}:#{external_id}"

  @doc "Build a PlatformAccount struct from a Subaru vertex map."
  @spec from_map(map()) :: t()
  def from_map(m), do: struct(__MODULE__, m)
end
