defmodule Sue.Models.Account do
  @moduledoc """
  The unified Sue identity for a user. One Account can be reached via many
  `PlatformAccount`s (same person on iMessage + Telegram). The id is a ULID —
  a new Account is minted the first time we see an unresolved PlatformAccount.
  """

  alias __MODULE__

  defstruct [
    :id,
    name: "",
    handle: "",
    is_premium: false,
    is_admin: false,
    is_banned: false,
    is_ignored: false,
    ban_reason: ""
  ]

  @type t() :: %__MODULE__{
          id: bitstring() | nil,
          name: bitstring(),
          handle: bitstring(),
          is_premium: boolean(),
          is_admin: boolean(),
          is_banned: boolean(),
          is_ignored: boolean(),
          ban_reason: bitstring()
        }

  @doc """
  Mint a new Account with a fresh ULID.

  Account ids stay opaque — a single Sue user can eventually link multiple
  `PlatformAccount`s (iMessage + Telegram + Discord) to one Account without
  rewriting any ids.
  """
  @spec new() :: t()
  def new, do: %Account{id: Sue.Graph.gen_id()}

  @doc "Build an Account struct from a Subaru vertex map."
  @spec from_map(map()) :: t()
  def from_map(m), do: struct(__MODULE__, m)

  @spec friendly_name(t()) :: bitstring()
  def friendly_name(a) do
    case {a.name, a.handle, a.id} do
      {"", "", id} -> "User" <> Sue.Utils.dbid_number(id)
      {"", handle, _} -> handle
      {name, _handle, _} -> name
    end
  end
end
