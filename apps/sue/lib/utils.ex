defmodule Sue.Utils do
  @doc """
  Resolve a path to an absolute path.
  """
  @spec resolve_filepath(bitstring()) :: bitstring()
  def resolve_filepath(maybe_path) do
    if String.starts_with?(maybe_path, "~") do
      Path.expand(maybe_path)
    else
      Path.absname(maybe_path)
    end
  end

  def dbid_number(dbid) do
    Enum.at(String.split(dbid, "/"), 1)
  end

  def quoted(s) when is_bitstring(s) do
    "\"#{s}\""
  end

  @spec tokenize(bitstring()) :: [bitstring()]
  def tokenize(args) do
    cond do
      String.contains?(args, "\n") -> String.split(args, "\n")
      String.contains?(args, ",") -> String.split(args, ",", trim: true)
      true -> String.split(args, " ")
    end
  end

  @spec contains?(Enumerable.t(), any()) :: boolean()
  def contains?(enum, item) do
    item in enum
  end

  def unique_string() do
    :os.timestamp()
    |> :erlang.phash2()
    |> Integer.to_string()
  end

  def tmp_file_name(suffix) when is_bitstring(suffix) do
    prefix = "#{:os.getpid()}-#{random_string()}-"
    prefix <> suffix
  end

  @spec unix_now() :: integer()
  def unix_now() do
    DateTime.utc_now() |> DateTime.to_unix()
  end

  def random_string do
    Integer.to_string(rand_uniform(0x100000000), 36) |> String.downcase()
  end

  if :erlang.system_info(:otp_release) >= ~c"18" do
    defp rand_uniform(num) do
      :rand.uniform(num)
    end
  else
    defp rand_uniform(num) do
      :random.uniform(num)
    end
  end

  @spec list_modules_of_prefix(bitstring()) :: [module()]
  def list_modules_of_prefix(prefix) do
    :code.all_available()
    |> Enum.map(fn {module, _, _} ->
      List.to_string(module)
    end)
    |> Enum.filter(fn m ->
      String.starts_with?(m, prefix)
    end)
    |> Enum.map(&String.to_atom/1)
  end

  # We drop :id as in our models we store the arango document's _id value there.
  # If we end up re-inserting/updating the document, we don't want this value
  # duplicated to another key.
  def struct_to_map(s, dropkeys \\ [:id]) do
    s
    |> Map.from_struct()
    |> Map.drop(dropkeys)
  end

  @spec string_to_atom(atom() | bitstring()) :: atom
  def string_to_atom(s) when is_bitstring(s), do: String.to_atom(s)
  def string_to_atom(a) when is_atom(a), do: a
end
