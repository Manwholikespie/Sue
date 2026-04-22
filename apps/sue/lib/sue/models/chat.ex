defmodule Sue.Models.Chat do
  @moduledoc """
  A conversation on a platform — an iMessage chat, a Telegram group, a Discord
  channel, or a 1:1 DM with any of those. `{platform, external_id}` is the
  natural key; the Sue id is derived from it deterministically.
  """

  alias Sue.Models.Platform
  alias __MODULE__

  @enforce_keys [:platform_id, :is_direct]
  defstruct [:platform_id, :is_direct, :id, is_ignored: false]

  @type t() :: %__MODULE__{
          platform_id: {Platform.t(), bitstring() | integer()},
          is_direct: boolean(),
          is_ignored: boolean(),
          id: nil | bitstring()
        }

  @spec new({Platform.t(), bitstring() | integer()}, boolean()) :: t()
  def new({platform, external_id} = platform_id, is_direct) when is_atom(platform) do
    %Chat{
      platform_id: platform_id,
      is_direct: is_direct,
      id: id_for(platform, external_id)
    }
  end

  @spec id_for(Platform.t(), bitstring() | integer()) :: bitstring()
  def id_for(platform, external_id), do: "chat:#{platform}:#{external_id}"

  @doc "Build a Chat struct from a Subaru vertex map."
  @spec from_map(map()) :: t()
  def from_map(m), do: struct(__MODULE__, m)
end
