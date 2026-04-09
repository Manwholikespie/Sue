defmodule Subaru.Subgraph do
  @moduledoc false

  defstruct [:vs, :es]

  @type t() :: %__MODULE__{
          vs: [Subaru.Vertex.t()],
          es: [Subaru.Edge.t()]
        }
end
