defmodule Sue.DB.Migrations.M1694479355 do
  @moduledoc """
  https://github.com/Manwholikespie/Sue/pull/45

  Move Account.platform_id metadata into a PlatformAccount.
  Create connect the two via an edge (sue_user_by_platformaccount).
  """

  alias Sue.DB.Schema
  alias Sue.Models.{PlatformAccount, Account}
  alias Subaru.Query

  def run() do
    # Create new PlatformAccounts and draw edges to these accounts.
    for doc <- Subaru.find!(Account.collection(), {:!=, "x.id", nil}) do
      pa =
        %PlatformAccount{platform_id: {String.to_atom(doc["platform"]), doc["id"]}}
        |> PlatformAccount.resolve()

      Subaru.upsert_edge(pa.id, doc["_id"], Schema.ecoll_sue_user_by_platformaccount())
    end

    # Remove their old fields.
    Query.new()
    |> Query.for(:x, Account.collection())
    |> Query.filter({:!=, "x.id", nil})
    |> Query.replace_with("x._key", "UNSET(x, ['id', 'platform'])", Account.collection())
    |> Query.exec()

    :ok
  end

  def vsn() do
    {0, 1, 1}
  end
end
