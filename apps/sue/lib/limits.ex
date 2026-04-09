defmodule Sue.Limits do
  @moduledoc false

  @doc """
  Checks if the action you wish to perform is within the bounds of the rate limit.
  If can_bypass, rate limit is ignored.
  """
  @spec check_rate(bitstring(), {integer(), integer()}, boolean()) :: :ok | :deny
  def check_rate(id, {scale_ms, limit} = scale_limit, can_bypass \\ false)
      when is_tuple(scale_limit) do
    helper_check_rate(id, scale_ms, limit, can_bypass)
  end

  defp helper_check_rate(_, _, _, true), do: :ok

  defp helper_check_rate(id, scale_ms, limit, _can_bypass) do
    case Hammer.check_rate(id, scale_ms, limit) do
      {:allow, _} -> :ok
      _ -> :deny
    end
  end
end
