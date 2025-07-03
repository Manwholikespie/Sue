defmodule Subaru.Vertex do
  @moduledoc """
  A behaviour for a graph vertex.
  """

  @doc """
  Returns the DB collection associated with the model.
  """
  @callback collection() :: bitstring()

  @doc """
  Transforms the model into a map for DB storage.
  """
  @callback doc(any()) :: map()
end
