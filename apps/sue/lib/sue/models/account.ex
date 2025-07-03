defmodule Sue.Models.Account do
  @behaviour Subaru.Vertex

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

  @collection "sue_users"

  @type t() :: %__MODULE__{
          name: bitstring(),
          handle: bitstring(),
          id: nil | bitstring(),
          is_premium: boolean(),
          is_admin: boolean()
        }

  alias Sue.Models.PlatformAccount
  alias __MODULE__

  @spec from_paccount(PlatformAccount.t()) :: t()
  @doc """
  Resolves a Sue Account from its associated PlatformAccount.
  An edge should ideally exist between the two in the database.
  If not, the account is created. As the PAccount cannot be nil, it is assumed
    the PAccount is already resolved to a Subaru.dbid
  """
  def from_paccount(pa) do
    account_id = Sue.DB.link_paccount_to_resolved_user(pa)

    Subaru.get!(@collection, account_id)
    |> from_doc()
  end

  @spec from_doc(map()) :: t
  def from_doc(doc) do
    %Account{
      name: doc["name"],
      handle: doc["handle"],
      id: doc["_id"],
      is_premium: doc["is_premium"],
      is_admin: doc["is_admin"],
      is_banned: doc["is_banned"],
      is_ignored: doc["is_ignored"],
      ban_reason: doc["ban_reason"]
    }
  end

  def friendly_name(a) do
    case {a.name, a.handle, a.id} do
      {"", "", id} -> "User" <> Sue.Utils.dbid_number(id)
      {"", handle, _} -> handle
      {name, _handle, _} -> name
    end
  end

  @impl Subaru.Vertex
  def collection(), do: @collection

  @impl Subaru.Vertex
  def doc(a) do
    Sue.Utils.struct_to_map(a)
  end
end
