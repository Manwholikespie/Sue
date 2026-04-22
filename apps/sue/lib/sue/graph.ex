defmodule Sue.Graph do
  @moduledoc """
  The graph store for Sue. All persistent state lives here: users, chats,
  definitions, polls, and the edges between them.

  Callers should go through `Sue.DB`, not this module directly. `Sue.Graph`
  exposes the raw graph primitives (`put`, `link`, `run/1` on `Subaru.Query`)
  that `Sue.DB` composes into domain operations.
  """

  use Subaru, otp_app: :sue
end
